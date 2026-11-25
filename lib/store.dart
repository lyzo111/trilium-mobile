import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What the phone keeps of one note for offline reading.
class LocalNote {
  LocalNote({
    required this.id,
    required this.title,
    required this.type,
    required this.mime,
    required this.blobId,
    required this.isProtected,
    required this.modified,
    required this.children,
    required this.parents,
    this.iconClass,
    this.hasContent = false,
    this.refs = const [],
  });

  factory LocalNote.fromJson(String id, Map<String, dynamic> j) => LocalNote(
        id: id,
        title: j['t'] as String? ?? '',
        type: j['y'] as String? ?? 'text',
        mime: j['m'] as String? ?? '',
        blobId: j['b'] as String?,
        isProtected: j['p'] == true,
        modified: j['d'] as String? ?? '',
        children: List<String>.from(j['c'] as List? ?? const []),
        parents: List<String>.from(j['r'] as List? ?? const []),
        iconClass: j['i'] as String?,
        hasContent: j['h'] == true,
        refs: List<String>.from(j['f'] as List? ?? const []),
      );

  Map<String, dynamic> toJson() => {
        't': title,
        'y': type,
        'm': mime,
        if (blobId != null) 'b': blobId,
        if (isProtected) 'p': true,
        'd': modified,
        if (children.isNotEmpty) 'c': children,
        if (parents.isNotEmpty) 'r': parents,
        if (iconClass != null) 'i': iconClass,
        if (hasContent) 'h': true,
        if (refs.isNotEmpty) 'f': refs,
      };

  final String id;
  String title;
  String type;
  String mime;

  /// Changes whenever the content changes, so it decides whether content must be fetched again.
  String? blobId;
  bool isProtected;
  String modified;
  List<String> children;
  List<String> parents;
  String? iconClass;

  /// True when content was stored and is worth showing (not just an empty paragraph).
  bool hasContent;

  /// Images the content refers to: `a:<attachmentId>` or `n:<noteId>`.
  List<String> refs;
}

/// Offline copy of the note tree: one JSON index plus one file per note content and attachment.
class OfflineStore {
  OfflineStore(this.root);

  final Directory root;

  Map<String, LocalNote> notes = {};
  DateTime? lastSync;
  String? serverVersion;

  /// MIME types of stored attachments, by attachmentId.
  Map<String, String> attachmentMimes = {};

  File get _indexFile => File('${root.path}/index.json');
  Directory get _contentDir => Directory('${root.path}/content');
  Directory get _attDir => Directory('${root.path}/att');

  bool get isEmpty => notes.isEmpty;

  Future<void> load() async {
    await _contentDir.create(recursive: true);
    await _attDir.create(recursive: true);
    if (!await _indexFile.exists()) return;
    try {
      final j = jsonDecode(await _indexFile.readAsString()) as Map<String, dynamic>;
      notes = {
        for (final e in (j['notes'] as Map<String, dynamic>).entries)
          e.key: LocalNote.fromJson(e.key, e.value as Map<String, dynamic>),
      };
      attachmentMimes = Map<String, String>.from(j['att'] as Map? ?? const {});
      lastSync = DateTime.tryParse(j['lastSync'] as String? ?? '');
      serverVersion = j['serverVersion'] as String?;
    } catch (_) {
      // A damaged index only costs a full download on the next sync.
      notes = {};
    }
  }

  Future<void> save() async {
    final tmp = File('${_indexFile.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'version': 1,
      'lastSync': lastSync?.toIso8601String(),
      'serverVersion': serverVersion,
      'att': attachmentMimes,
      'notes': {for (final n in notes.values) n.id: n.toJson()},
    }));
    await tmp.rename(_indexFile.path);
  }

  File contentFile(String noteId) => File('${_contentDir.path}/${_safe(noteId)}');
  File attachmentFile(String attachmentId) => File('${_attDir.path}/${_safe(attachmentId)}');

  static String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');

  Future<Uint8List?> readContent(String noteId) async {
    final f = contentFile(noteId);
    return await f.exists() ? f.readAsBytes() : null;
  }

  Future<String?> readText(String noteId) async {
    final b = await readContent(noteId);
    return b == null ? null : utf8.decode(b, allowMalformed: true);
  }

  Future<void> writeContent(String noteId, List<int> bytes) => contentFile(noteId).writeAsBytes(bytes, flush: false);

  Future<void> writeAttachment(String id, List<int> bytes, String mime) async {
    await attachmentFile(id).writeAsBytes(bytes);
    attachmentMimes[id] = mime;
  }

  /// Deletes every stored file that no longer belongs to a known note or referenced attachment.
  Future<void> prune() async {
    final keepContent = notes.keys.map(_safe).toSet();
    // Image notes referenced from text but outside the tree are stored as content too.
    final keepAtt = <String>{};
    for (final n in notes.values) {
      for (final r in n.refs) {
        if (r.startsWith('a:')) keepAtt.add(_safe(r.substring(2)));
        if (r.startsWith('n:')) keepContent.add(_safe(r.substring(2)));
      }
    }
    await for (final f in _contentDir.list()) {
      if (f is File && !keepContent.contains(f.uri.pathSegments.last)) await f.delete();
    }
    await for (final f in _attDir.list()) {
      if (f is File && !keepAtt.contains(f.uri.pathSegments.last)) await f.delete();
    }
    attachmentMimes.removeWhere((k, _) => !keepAtt.contains(_safe(k)));
  }

  Future<int> sizeOnDisk() async {
    var total = 0;
    await for (final f in root.list(recursive: true)) {
      if (f is File) total += await f.length();
    }
    return total;
  }

  Future<void> clear() async {
    notes = {};
    attachmentMimes = {};
    lastSync = null;
    serverVersion = null;
    if (await root.exists()) await root.delete(recursive: true);
    await load();
  }

  /// Path from root to [noteId] along the first parents, for breadcrumbs and search results.
  List<LocalNote> pathTo(String noteId) {
    final path = <LocalNote>[];
    final seen = <String>{};
    var id = noteId;
    while (seen.add(id)) {
      final n = notes[id];
      if (n == null) break;
      path.insert(0, n);
      final parent = n.parents.where(notes.containsKey).firstOrNull;
      if (parent == null) break;
      id = parent;
    }
    return path;
  }
}
