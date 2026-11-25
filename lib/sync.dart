import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'etapi.dart';
import 'render.dart';
import 'store.dart';

enum SyncState { idle, running, done, failed }

class SyncStatus {
  const SyncStatus(this.state, {this.message = '', this.done = 0, this.total = 0, this.errors = 0});

  final SyncState state;
  final String message;
  final int done;
  final int total;

  /// Notes whose content could not be fetched; they are tried again next time.
  final int errors;
}

/// Mirrors the server's note tree into the [OfflineStore]. Read-only: the phone never writes
/// back, so there is nothing to merge and no way to lose edits made on the server.
class SyncService extends ChangeNotifier {
  SyncService(this.store);

  final OfflineStore store;
  SyncStatus status = const SyncStatus(SyncState.idle);

  Future<void>? _running;

  bool get isRunning => _running != null;

  void _set(SyncStatus s) {
    status = s;
    notifyListeners();
  }

  /// Runs a sync, or joins the one already running.
  Future<void> sync(EtapiClient client) => _running ??= _sync(client).whenComplete(() => _running = null);

  Future<void> _sync(EtapiClient client) async {
    _set(const SyncStatus(SyncState.running, message: 'Verbinde …'));
    try {
      final info = await client.appInfo();

      _set(const SyncStatus(SyncState.running, message: 'Lade Notizbaum …'));
      final remote = await _fetchTree(client);

      final old = store.notes;
      // Parents as seen inside the mirrored tree, in tree order (clones have several).
      final parentsOf = <String, List<String>>{};
      for (final r in remote.values) {
        for (final c in r.childNoteIds) {
          if (remote.containsKey(c)) (parentsOf[c] ??= []).add(r.noteId);
        }
      }
      final next = <String, LocalNote>{};
      final toFetch = <RemoteNote>[];
      for (final r in remote.values) {
        final prev = old[r.noteId];
        final wantsContent = offlineContentTypes.contains(r.type) && !r.isProtected;
        final unchanged = prev != null &&
            prev.blobId == r.blobId &&
            prev.type == r.type &&
            (!wantsContent || await store.contentFile(r.noteId).exists());
        next[r.noteId] = LocalNote(
          id: r.noteId,
          title: r.title,
          type: r.type,
          mime: r.mime,
          blobId: r.blobId,
          isProtected: r.isProtected,
          modified: r.utcDateModified,
          // Only children inside the mirrored tree, in the server's order.
          children: r.childNoteIds.where(remote.containsKey).toList(),
          parents: parentsOf[r.noteId] ?? const [],
          iconClass: r.iconClass,
          hasContent: unchanged ? prev.hasContent : false,
          refs: unchanged ? prev.refs : const [],
        );
        if (wantsContent && !unchanged) toFetch.add(r);
      }

      var done = 0;
      var errors = 0;
      void progress() => _set(SyncStatus(SyncState.running,
          message: 'Lade Inhalte $done / ${toFetch.length}', done: done, total: toFetch.length, errors: errors));
      progress();

      await _parallel(toFetch, 6, (r) async {
        try {
          final bytes = await client.noteContent(r.noteId);
          await store.writeContent(r.noteId, bytes);
          final n = next[r.noteId]!;
          if (r.type == 'text') {
            final html = utf8.decode(bytes, allowMalformed: true);
            n.hasContent = htmlHasContent(html);
            n.refs = imageRefs(html);
          } else {
            n.hasContent = bytes.isNotEmpty;
          }
        } catch (e) {
          errors++;
          // Forget the blobId so the next sync tries this note again.
          next[r.noteId]!.blobId = null;
          debugPrint('content ${r.noteId}: $e');
        }
        done++;
        if (done % 10 == 0 || done == toFetch.length) progress();
      });

      // Images in text notes: attachments, and image notes that may sit outside the tree.
      final missing = <String>{};
      for (final n in next.values) {
        for (final ref in n.refs) {
          final id = ref.substring(2);
          if (ref.startsWith('a:')) {
            if (!await store.attachmentFile(id).exists()) missing.add(ref);
          } else if (!next.containsKey(id) && !await store.contentFile(id).exists()) {
            missing.add(ref);
          }
        }
      }
      if (missing.isNotEmpty) {
        var i = 0;
        _set(SyncStatus(SyncState.running, message: 'Lade Bilder 0 / ${missing.length}'));
        await _parallel(missing.toList(), 6, (ref) async {
          final id = ref.substring(2);
          try {
            if (ref.startsWith('a:')) {
              final a = await client.attachmentContent(id);
              await store.writeAttachment(id, a.bytes, a.mime);
            } else {
              await store.writeContent(id, await client.noteContent(id));
            }
          } catch (e) {
            errors++;
            debugPrint('image $ref: $e');
          }
          i++;
          if (i % 10 == 0) _set(SyncStatus(SyncState.running, message: 'Lade Bilder $i / ${missing.length}'));
        });
      }
      // Image notes outside the tree need their MIME type for the data URI.
      for (final n in next.values) {
        for (final ref in n.refs.where((r) => r.startsWith('n:'))) {
          final id = ref.substring(2);
          if (!next.containsKey(id)) store.attachmentMimes['n:$id'] ??= 'image/png';
        }
      }

      store.notes = next;
      store.lastSync = DateTime.now();
      store.serverVersion = info['appVersion'] as String?;
      await store.prune();
      await store.save();
      _set(SyncStatus(SyncState.done,
          message: errors == 0 ? '${next.length} Notizen offline verfügbar' : '${next.length} Notizen, $errors Fehler',
          errors: errors));
    } catch (e) {
      _set(SyncStatus(SyncState.failed, message: describeError(e)));
      rethrow;
    }
  }

  /// Every note reachable from root, skipping Trilium's hidden system subtree (ids starting
  /// with "_"). Uses one search for all metadata and fetches single notes only as a fallback.
  Future<Map<String, RemoteNote>> _fetchTree(EtapiClient client) async {
    final byId = <String, RemoteNote>{};
    try {
      for (final n in await client.allNotes()) {
        byId[n.noteId] = n;
      }
    } on EtapiException catch (e) {
      if (e.isAuthError) rethrow;
    } on TimeoutException {
      // Very large databases: walk the tree note by note instead.
    }
    byId['root'] ??= await client.getNote('root');

    final reachable = <String, RemoteNote>{};
    var frontier = ['root'];
    while (frontier.isNotEmpty) {
      final unknown = frontier.where((id) => !byId.containsKey(id)).toList();
      await _parallel(unknown, 8, (id) async {
        try {
          byId[id] = await client.getNote(id);
        } catch (e) {
          debugPrint('note $id: $e');
        }
      });
      final nextFrontier = <String>[];
      for (final id in frontier) {
        final n = byId[id];
        if (n == null || reachable.containsKey(id)) continue;
        reachable[id] = n;
        for (final c in n.childNoteIds) {
          if (!c.startsWith('_') && !reachable.containsKey(c)) nextFrontier.add(c);
        }
      }
      frontier = nextFrontier;
    }
    return reachable;
  }

  static Future<void> _parallel<T>(List<T> items, int workers, Future<void> Function(T) task) async {
    var i = 0;
    Future<void> worker() async {
      while (i < items.length) {
        await task(items[i++]);
      }
    }

    await Future.wait([for (var w = 0; w < workers && w < items.length; w++) worker()]);
  }
}

/// A short German explanation of what went wrong, for the status line.
String describeError(Object e) {
  if (e is EtapiException) {
    switch (e.code) {
      case 'WRONG_PASSWORD':
        return 'Falsches Passwort.';
      case 'TOTP_REQUIRED':
        return 'Zwei-Faktor-Code erforderlich.';
      case 'WRONG_TOTP':
        return 'Falscher Zwei-Faktor-Code.';
    }
    if (e.isAuthError) return 'Zugang abgelehnt – bitte neu anmelden.';
    return 'Serverfehler ${e.status}: ${e.message}';
  }
  if (e is TimeoutException) return 'Server antwortet nicht.';
  final s = e.toString();
  if (s.contains('SocketException') || s.contains('ClientException') || s.contains('HandshakeException')) {
    return 'Server nicht erreichbar.';
  }
  return s;
}
