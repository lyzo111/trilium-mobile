import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app_state.dart';
import '../files.dart';
import '../render.dart';
import '../store.dart';
import '../sync.dart';

/// Opens a note from the offline copy: notes with children as a list, others as content.
void openOfflineNote(BuildContext context, AppState state, String noteId) {
  final n = state.store.notes[noteId];
  if (n == null) return;
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => n.children.isNotEmpty
        ? OfflineBrowser(state: state, noteId: noteId)
        : NoteViewPage(state: state, noteId: noteId),
  ));
}

IconData noteIcon(LocalNote n) {
  if (n.children.isNotEmpty && !n.hasContent) return Icons.folder_outlined;
  return switch (n.type) {
    'text' => n.children.isNotEmpty ? Icons.snippet_folder_outlined : Icons.description_outlined,
    'code' => Icons.code,
    'image' => Icons.image_outlined,
    'file' => Icons.attach_file,
    'book' => Icons.menu_book_outlined,
    'search' => Icons.search,
    'mermaid' => Icons.schema_outlined,
    'canvas' => Icons.draw_outlined,
    'mindMap' => Icons.hub_outlined,
    'relationMap' || 'noteMap' => Icons.account_tree_outlined,
    'render' || 'webView' => Icons.web_outlined,
    _ => Icons.note_outlined,
  };
}

/// Children of one note from the offline copy.
class OfflineBrowser extends StatelessWidget {
  const OfflineBrowser({super.key, required this.state, required this.noteId, this.embedded = false});

  final AppState state;
  final String noteId;

  /// Shown inside the home screen (offline mode) rather than as its own page.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state.sync,
      builder: (context, _) {
        final store = state.store;
        final note = store.notes[noteId];
        final children = [for (final id in note?.children ?? const <String>[]) ?store.notes[id]];
        final title = noteId == 'root' ? 'Offline-Notizen' : (note?.title ?? '');
        final list = ListView(
          children: [
            if (note != null && noteId != 'root' && note.hasContent)
              ListTile(
                leading: Icon(noteIcon(note)),
                title: const Text('Inhalt dieser Notiz'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => NoteViewPage(state: state, noteId: noteId, fromList: true),
                )),
              ),
            if (note != null && noteId != 'root' && note.hasContent) const Divider(height: 1),
            for (final c in children)
              ListTile(
                leading: Icon(noteIcon(c)),
                title: Text(c.title.isEmpty ? '(ohne Titel)' : c.title),
                subtitle: c.children.isEmpty ? null : Text('${c.children.length} Unternotizen'),
                trailing: c.children.isEmpty ? null : const Icon(Icons.chevron_right),
                onTap: () => openOfflineNote(context, state, c.id),
              ),
            if (children.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Keine Notizen'))),
          ],
        );
        final searchButton = IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Offline suchen',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchPage(state: state))),
        );
        if (embedded) {
          return Column(
            children: [
              ListTile(
                title: Text(title, style: Theme.of(context).textTheme.titleMedium),
                trailing: searchButton,
              ),
              const Divider(height: 1),
              Expanded(child: list),
            ],
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(title), actions: [searchButton]),
          body: SafeArea(top: false, child: list),
        );
      },
    );
  }
}

/// The content of one note from the offline copy.
class NoteViewPage extends StatefulWidget {
  const NoteViewPage({super.key, required this.state, required this.noteId, this.fromList = false});

  final AppState state;
  final String noteId;

  /// Opened from the note's own child list, so offering that list again would loop.
  final bool fromList;

  @override
  State<NoteViewPage> createState() => _NoteViewPageState();
}

class _NoteViewPageState extends State<NoteViewPage> {
  WebViewController? _web;
  Uint8List? _imageBytes;
  String? _message;
  bool _loading = true;
  bool _downloading = false;

  OfflineStore get store => widget.state.store;
  LocalNote? get note => store.notes[widget.noteId];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final n = note;
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (n == null) {
      _done(message: 'Diese Notiz ist nicht in der Offline-Kopie.');
      return;
    }
    if (n.isProtected) {
      _done(message: 'Geschützte Notiz – nur online lesbar.');
      return;
    }
    if (!offlineContentTypes.contains(n.type)) {
      _done(message: 'Notizen vom Typ „${n.type}“ gibt es nur online.');
      return;
    }
    final bytes = await store.readContent(n.id);
    if (bytes == null) {
      _done(message: 'Inhalt noch nicht synchronisiert.');
      return;
    }
    if (n.type == 'image') {
      _imageBytes = bytes;
      _done();
      return;
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    final String body;
    if (n.type == 'text') {
      final images = <String, String>{};
      for (final ref in n.refs) {
        final id = ref.substring(2);
        final isAtt = ref.startsWith('a:');
        final data = isAtt ? await _readAttachment(id) : await store.readContent(id);
        if (data == null) continue;
        final mime = isAtt
            ? (store.attachmentMimes[id] ?? 'image/png')
            : (store.notes[id]?.mime ?? store.attachmentMimes['n:$id'] ?? 'image/png');
        images[ref] = dataUri(mime, data);
      }
      final html = inlineImages(text, (ref) => images[ref]);
      body = n.hasContent ? html : '<p class="offline-hint">Leere Notiz</p>';
    } else {
      body = '<pre><code>${escapeHtml(text)}</code></pre>';
    }
    final web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(dark ? const Color(0xFF121212) : Colors.white)
      ..addJavaScriptChannel('TriliumLinks', onMessageReceived: (m) => _onLink(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        // Everything the page could navigate to is handled by the click handler instead.
        onNavigationRequest: (r) =>
            r.url.startsWith('about:') || r.url.startsWith('data:') ? NavigationDecision.navigate : NavigationDecision.prevent,
      ));
    await web.loadHtmlString(offlinePage(title: n.title, body: body, dark: dark));
    _web = web;
    _done();
  }

  Future<List<int>?> _readAttachment(String id) async {
    final f = store.attachmentFile(id);
    return await f.exists() ? f.readAsBytes() : null;
  }

  void _done({String? message}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _loading = false;
    });
  }

  void _onLink(String href) {
    final target = noteIdFromLink(href);
    if (target != null && store.notes.containsKey(target)) {
      openOfflineNote(context, widget.state, target);
      return;
    }
    final uri = Uri.tryParse(href);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'mailto')) {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (target != null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Verlinkte Notiz ist nicht offline verfügbar')));
    }
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    final messenger = ScaffoldMessenger.of(context);
    final client = widget.state.client();
    try {
      final error = await downloadAndOpen(client, id: widget.noteId, attachment: false);
      if (error != null) messenger.showSnackBar(SnackBar(content: Text(error)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    } finally {
      client.close();
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = note;
    final Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_imageBytes != null) {
      body = InteractiveViewer(
        maxScale: 6,
        child: Center(child: Image.memory(_imageBytes!, fit: BoxFit.contain)),
      );
    } else if (_web != null) {
      body = WebViewWidget(controller: _web!);
    } else {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_outlined, size: 40),
              const SizedBox(height: 12),
              Text(_message ?? '', textAlign: TextAlign.center),
              if (n?.type == 'file') ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _downloading ? null : _download,
                  icon: const Icon(Icons.download),
                  label: const Text('Vom Server laden und öffnen'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(n?.title ?? ''),
        actions: [
          if (n != null && n.children.isNotEmpty && !widget.fromList)
            IconButton(
              icon: const Icon(Icons.list),
              tooltip: 'Unternotizen',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => OfflineBrowser(state: widget.state, noteId: n.id),
              )),
            ),
        ],
      ),
      body: SafeArea(top: false, child: body),
    );
  }
}

/// Searches titles and text of the offline copy.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.state});

  final AppState state;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _query = TextEditingController();
  final Map<String, String> _textCache = {};
  List<({LocalNote note, String? snippet})> _results = [];
  int _generation = 0;
  bool _searching = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search(String raw) async {
    final q = raw.trim().toLowerCase();
    final gen = ++_generation;
    if (q.length < 2) {
      setState(() => _results = []);
      return;
    }
    final store = widget.state.store;
    final results = <({LocalNote note, String? snippet})>[];
    final seen = <String>{};
    for (final n in store.notes.values) {
      if (n.id != 'root' && n.title.toLowerCase().contains(q)) {
        results.add((note: n, snippet: null));
        seen.add(n.id);
      }
    }
    setState(() {
      _results = List.of(results);
      _searching = true;
    });

    // Then the content, a few notes at a time so typing stays smooth.
    var count = 0;
    for (final n in store.notes.values) {
      if (gen != _generation) return;
      if (seen.contains(n.id) || !n.hasContent || (n.type != 'text' && n.type != 'code')) continue;
      var text = _textCache[n.id];
      if (text == null) {
        final raw = await store.readText(n.id);
        if (raw == null) continue;
        text = n.type == 'text' ? htmlToText(raw) : raw;
        _textCache[n.id] = text;
      }
      final i = text.toLowerCase().indexOf(q);
      if (i >= 0) {
        final start = (i - 40).clamp(0, text.length);
        final end = (i + q.length + 60).clamp(0, text.length);
        final snippet = '${start > 0 ? '…' : ''}${text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ')}…';
        results.add((note: n, snippet: snippet));
        if (results.length >= 200) break;
      }
      if (++count % 50 == 0 && gen == _generation) setState(() => _results = List.of(results));
    }
    if (gen == _generation && mounted) {
      setState(() {
        _results = results;
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.state.store;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Offline-Notizen durchsuchen', border: InputBorder.none),
          onChanged: _search,
        ),
        bottom: _searching
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
            : null,
      ),
      body: SafeArea(
        top: false,
        child: ListView.builder(
          itemCount: _results.length,
          itemBuilder: (context, i) {
            final r = _results[i];
            final path = store.pathTo(r.note.id).where((p) => p.id != 'root' && p.id != r.note.id).map((p) => p.title).join(' › ');
            return ListTile(
              leading: Icon(noteIcon(r.note)),
              title: Text(r.note.title),
              subtitle: Text(
                [if (path.isNotEmpty) path, if (r.snippet != null) r.snippet!].join('\n'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => openOfflineNote(context, widget.state, r.note.id),
            );
          },
        ),
      ),
    );
  }
}
