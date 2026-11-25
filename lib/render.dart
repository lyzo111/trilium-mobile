import 'dart:convert';

/// Note types whose content is downloaded for offline reading.
const offlineContentTypes = {'text', 'code', 'mermaid', 'image'};

/// Matches the image sources Trilium writes into text notes, with or without a leading path:
/// `api/attachments/<id>/image/<name>` (current) and `api/images/<noteId>/<name>` (older notes).
final _imageRef = RegExp(r'''(["'])((?:[^"']*/)?api/(attachments|images)/([A-Za-z0-9_]+)/[^"']*)\1''');

/// The images a text note refers to, as `a:<attachmentId>` or `n:<noteId>`.
List<String> imageRefs(String html) {
  final refs = <String>{};
  for (final m in _imageRef.allMatches(html)) {
    refs.add('${m.group(3) == 'attachments' ? 'a' : 'n'}:${m.group(4)}');
  }
  return refs.toList();
}

/// Whether a text note has anything to show beyond empty paragraphs.
bool htmlHasContent(String html) {
  if (RegExp(r'<(img|table|iframe|video|audio|hr|section)\b', caseSensitive: false).hasMatch(html)) return true;
  final text = html.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll('&nbsp;', '').trim();
  return text.isNotEmpty;
}

/// Plain text of a text note, for offline search.
String htmlToText(String html) => html
    .replaceAll(RegExp(r'<(br|/p|/div|/li|/h\d)[^>]*>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");

String escapeHtml(String s) => const HtmlEscape().convert(s);

/// Replaces the server image URLs in [html] with data URIs from [resolve], so the note renders
/// without a connection. [resolve] gets `a:<id>` / `n:<id>` and returns a data URI or null.
String inlineImages(String html, String? Function(String ref) resolve) {
  return html.replaceAllMapped(_imageRef, (m) {
    final ref = '${m.group(3) == 'attachments' ? 'a' : 'n'}:${m.group(4)}';
    final data = resolve(ref);
    return data == null ? m.group(0)! : '${m.group(1)}$data${m.group(1)}';
  });
}

String dataUri(String mime, List<int> bytes) => 'data:$mime;base64,${base64Encode(bytes)}';

/// The note id an internal Trilium link points to: "#root/abc/def" → "def".
String? noteIdFromLink(String href) {
  final hash = href.indexOf('#');
  if (hash < 0) return null;
  var path = href.substring(hash + 1);
  final q = path.indexOf('?');
  if (q >= 0) path = path.substring(0, q);
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  final id = parts.last;
  return RegExp(r'^[A-Za-z0-9_]+$').hasMatch(id) ? id : null;
}

/// A complete page for the offline viewer. Links are reported to the app through the
/// `TriliumLinks` JavaScript channel instead of navigating inside the WebView.
String offlinePage({required String title, required String body, required bool dark}) {
  final bg = dark ? '#121212' : '#ffffff';
  final fg = dark ? '#e4e4e4' : '#1d1d1d';
  final muted = dark ? '#2a2a2a' : '#f2f2f2';
  final border = dark ? '#3a3a3a' : '#d8d8d8';
  final link = dark ? '#8ab4f8' : '#1a6bd6';
  return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
  :root { color-scheme: ${dark ? 'dark' : 'light'}; }
  body { background:$bg; color:$fg; font: 16px/1.55 -apple-system, Roboto, "Segoe UI", sans-serif;
         margin:0; padding:16px; overflow-wrap:anywhere; }
  a { color:$link; }
  img { max-width:100%; height:auto; }
  pre { background:$muted; padding:12px; border-radius:8px; overflow-x:auto; font-size:14px; }
  code { font-family: ui-monospace, "Roboto Mono", monospace; }
  :not(pre) > code { background:$muted; padding:1px 4px; border-radius:4px; }
  table { border-collapse:collapse; display:block; overflow-x:auto; max-width:100%; }
  td, th { border:1px solid $border; padding:6px 8px; vertical-align:top; }
  blockquote { border-left:3px solid $border; margin:0; padding-left:12px; opacity:.85; }
  figure { margin:8px 0; }
  figure.table { overflow-x:auto; }
  ul.todo-list { list-style:none; padding-left:4px; }
  .todo-list__label input { margin-right:6px; }
  hr { border:0; border-top:1px solid $border; }
  .include-note { border:1px dashed $border; border-radius:8px; padding:8px; }
  .offline-hint { opacity:.7; font-style:italic; }
</style></head>
<body>$body
<script>
  document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('a');
    if (!a) return;
    e.preventDefault();
    TriliumLinks.postMessage(a.getAttribute('href') || '');
  }, true);
</script>
</body></html>''';
}
