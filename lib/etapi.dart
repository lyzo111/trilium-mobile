import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Thrown for any answer the server gives that is not what was asked for.
class EtapiException implements Exception {
  EtapiException(this.status, this.code, this.message);

  final int status;

  /// Trilium's own error code, e.g. WRONG_PASSWORD or TOTP_REQUIRED.
  final String code;
  final String message;

  bool get isAuthError => status == 401;

  @override
  String toString() => 'EtapiException($status, $code): $message';
}

/// The metadata ETAPI returns for a note (see mapNoteToPojo in the Trilium server).
class RemoteNote {
  RemoteNote({
    required this.noteId,
    required this.title,
    required this.type,
    required this.mime,
    required this.blobId,
    required this.isProtected,
    required this.utcDateModified,
    required this.childNoteIds,
    required this.parentNoteIds,
    required this.iconClass,
  });

  factory RemoteNote.fromJson(Map<String, dynamic> j) {
    String? icon;
    for (final a in (j['attributes'] as List? ?? const [])) {
      if (a is Map && a['type'] == 'label' && a['name'] == 'iconClass') {
        icon = a['value'] as String?;
      }
    }
    return RemoteNote(
      noteId: j['noteId'] as String,
      title: (j['title'] as String?) ?? '',
      type: (j['type'] as String?) ?? 'text',
      mime: (j['mime'] as String?) ?? '',
      blobId: j['blobId'] as String?,
      isProtected: j['isProtected'] == true,
      utcDateModified: (j['utcDateModified'] as String?) ?? '',
      childNoteIds: List<String>.from(j['childNoteIds'] as List? ?? const []),
      parentNoteIds: List<String>.from(j['parentNoteIds'] as List? ?? const []),
      iconClass: icon,
    );
  }

  final String noteId;
  final String title;
  final String type;
  final String mime;
  final String? blobId;
  final bool isProtected;
  final String utcDateModified;
  final List<String> childNoteIds;
  final List<String> parentNoteIds;
  final String? iconClass;
}

/// Thin client for Trilium's External API (ETAPI). Only the read side plus login is needed:
/// editing happens in the server's own web UI, which is always the newest version.
class EtapiClient {
  EtapiClient(String baseUrl, {this.token, http.Client? client})
      : baseUrl = normalizeBaseUrl(baseUrl),
        _http = client ?? http.Client();

  final String baseUrl;
  final String? token;
  final http.Client _http;

  static const _timeout = Duration(seconds: 20);

  /// "trilium.example.com/" → "https://trilium.example.com"
  static String normalizeBaseUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return url;
    if (!url.contains('://')) url = 'https://$url';
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final u = Uri.parse('$baseUrl/etapi/$path');
    return query == null ? u : u.replace(queryParameters: query);
  }

  Map<String, String> get _headers => {'Authorization': ?token};

  Future<http.Response> _get(String path, {Map<String, String>? query, Duration? timeout}) async {
    final res = await _http.get(_uri(path, query), headers: _headers).timeout(timeout ?? _timeout);
    if (res.statusCode >= 400) throw _error(res);
    return res;
  }

  EtapiException _error(http.Response res) {
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return EtapiException(res.statusCode, '${j['code'] ?? 'ERROR'}', '${j['message'] ?? res.reasonPhrase}');
    } catch (_) {
      return EtapiException(res.statusCode, 'HTTP_${res.statusCode}', res.reasonPhrase ?? 'HTTP ${res.statusCode}');
    }
  }

  /// Exchanges the Trilium password for an ETAPI token. The password itself is never needed for sync.
  Future<String> login(String password, {String? totpToken, String tokenName = 'Trilium Mobile'}) async {
    final res = await _http
        .post(
          _uri('auth/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'password': password,
            'tokenName': tokenName,
            if (totpToken != null && totpToken.isNotEmpty) 'totpToken': totpToken,
          }),
        )
        .timeout(_timeout);
    if (res.statusCode >= 400) throw _error(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['authToken'] as String;
  }

  /// Invalidates this client's token on the server.
  Future<void> logout() async {
    final res = await _http.post(_uri('auth/logout'), headers: _headers).timeout(_timeout);
    if (res.statusCode >= 400) throw _error(res);
  }

  Future<Map<String, dynamic>> appInfo({Duration? timeout}) async {
    final res = await _get('app-info', timeout: timeout);
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  Future<RemoteNote> getNote(String noteId) async {
    final res = await _get('notes/${Uri.encodeComponent(noteId)}');
    return RemoteNote.fromJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
  }

  /// All notes in one request. Trilium has no "list all" endpoint, but a search that every note
  /// matches returns the full metadata of each, which is far faster than walking the tree.
  Future<List<RemoteNote>> allNotes() async {
    final res = await _get(
      'notes',
      query: {'search': 'note.noteId != ""', 'includeArchivedNotes': 'true', 'fastSearch': 'false'},
      timeout: const Duration(minutes: 2),
    );
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return [for (final n in j['results'] as List) RemoteNote.fromJson(n as Map<String, dynamic>)];
  }

  Future<Uint8List> noteContent(String noteId) async =>
      (await _get('notes/${Uri.encodeComponent(noteId)}/content', timeout: const Duration(minutes: 2))).bodyBytes;

  Future<({Uint8List bytes, String mime})> attachmentContent(String attachmentId) async {
    final res = await _get('attachments/${Uri.encodeComponent(attachmentId)}/content', timeout: const Duration(minutes: 2));
    return (bytes: res.bodyBytes, mime: (res.headers['content-type'] ?? 'application/octet-stream').split(';').first);
  }

  Future<Map<String, dynamic>> attachment(String attachmentId) async {
    final res = await _get('attachments/${Uri.encodeComponent(attachmentId)}');
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  void close() => _http.close();
}
