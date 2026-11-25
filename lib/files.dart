import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'etapi.dart';

/// `api/notes/<id>/download`, `api/attachments/<id>/open` … as the web UI uses them for files.
final _fileUrl = RegExp(r'/api/(notes|attachments)/([A-Za-z0-9_]+)/(download|open|open-partial)\b');

/// The note or attachment a web UI file URL points to, if it is one.
({bool attachment, String id})? fileTarget(String url) {
  final m = _fileUrl.firstMatch(url);
  if (m == null) return null;
  return (attachment: m.group(1) == 'attachments', id: m.group(2)!);
}

/// Downloads a note's or attachment's content through ETAPI and hands it to the system viewer.
/// The WebView cannot download by itself, and ETAPI works without the browser session.
Future<String?> downloadAndOpen(EtapiClient client, {required String id, required bool attachment}) async {
  final String title;
  final String mime;
  final List<int> bytes;
  if (attachment) {
    final meta = await client.attachment(id);
    final content = await client.attachmentContent(id);
    title = (meta['title'] as String?) ?? id;
    mime = content.mime;
    bytes = content.bytes;
  } else {
    final note = await client.getNote(id);
    title = note.title;
    mime = note.mime;
    bytes = await client.noteContent(id);
  }
  final dir = Directory('${(await getTemporaryDirectory()).path}/files');
  await dir.create(recursive: true);
  final name = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final file = File('${dir.path}/$name${_extensionFor(name, mime)}');
  await file.writeAsBytes(bytes);
  final result = await OpenFilex.open(file.path, type: mime.isEmpty ? null : mime);
  return result.type == ResultType.done ? null : result.message;
}

String _extensionFor(String name, String mime) {
  if (RegExp(r'\.[A-Za-z0-9]{1,5}$').hasMatch(name)) return '';
  const known = {
    'application/pdf': '.pdf',
    'image/png': '.png',
    'image/jpeg': '.jpg',
    'image/gif': '.gif',
    'image/webp': '.webp',
    'image/svg+xml': '.svg',
    'text/plain': '.txt',
    'text/html': '.html',
    'application/zip': '.zip',
    'audio/mpeg': '.mp3',
    'video/mp4': '.mp4',
  };
  return known[mime] ?? '';
}
