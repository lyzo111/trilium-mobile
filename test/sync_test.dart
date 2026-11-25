import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:trilium_mobile/etapi.dart';
import 'package:trilium_mobile/store.dart';
import 'package:trilium_mobile/sync.dart';

/// A tiny stand-in for the ETAPI of a Trilium server.
class FakeServer {
  final notes = <String, Map<String, dynamic>>{};
  final contents = <String, List<int>>{};
  final attachments = <String, List<int>>{};
  final requests = <String>[];
  bool searchWorks = true;

  void add(String id, String title,
      {String type = 'text', List<String> children = const [], String content = '', String blob = 'b1'}) {
    notes[id] = {
      'noteId': id,
      'title': title,
      'type': type,
      'mime': type == 'image' ? 'image/png' : 'text/html',
      'blobId': blob,
      'isProtected': false,
      'utcDateModified': '2026-11-25 10:00:00.000Z',
      'childNoteIds': children,
      'parentNoteIds': <String>[],
      'attributes': <dynamic>[],
    };
    contents[id] = utf8.encode(content);
  }

  http.Client client() => MockClient((req) async {
        final p = req.url.path.replaceFirst('/etapi/', '');
        requests.add(p);
        if (req.headers['Authorization'] != 'tok') return http.Response('{"code":"NOT_AUTHENTICATED"}', 401);
        if (p == 'app-info') return http.Response('{"appVersion":"0.107.0"}', 200);
        if (p == 'notes') {
          if (!searchWorks) return http.Response('{"code":"X","message":"no"}', 500);
          return http.Response(jsonEncode({'results': notes.values.toList()}), 200);
        }
        final content = RegExp(r'^notes/([^/]+)/content$').firstMatch(p);
        if (content != null) return http.Response.bytes(contents[content.group(1)]!, 200);
        final att = RegExp(r'^attachments/([^/]+)/content$').firstMatch(p);
        if (att != null) {
          return http.Response.bytes(attachments[att.group(1)]!, 200, headers: {'content-type': 'image/png'});
        }
        final note = RegExp(r'^notes/([^/]+)$').firstMatch(p);
        if (note != null && notes.containsKey(note.group(1))) {
          return http.Response(jsonEncode(notes[note.group(1)]), 200);
        }
        return http.Response('{"code":"NOT_FOUND"}', 404);
      });
}

void main() {
  late Directory dir;
  late FakeServer server;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('trilium_test');
    server = FakeServer()
      ..add('root', 'root', children: ['A', 'B', '_hidden'])
      ..add('A', 'Projekte', children: ['C'], content: '<p>Hallo <img src="api/attachments/att1/image/x.png"></p>')
      ..add('B', 'Bild', type: 'image', content: 'PNG')
      ..add('C', 'Unterseite', content: '<p></p>')
      ..add('_hidden', 'Hidden', children: ['_x'])
      ..add('_x', 'System');
    server.attachments['att1'] = [1, 2, 3];
  });

  tearDown(() => dir.delete(recursive: true));

  Future<OfflineStore> run() async {
    final store = OfflineStore(dir);
    await store.load();
    await SyncService(store).sync(EtapiClient('http://x', token: 'tok', client: server.client()));
    return store;
  }

  test('mirrors the tree without the hidden subtree', () async {
    final store = await run();
    expect(store.notes.keys, unorderedEquals(['root', 'A', 'B', 'C']));
    expect(store.notes['root']!.children, ['A', 'B']);
    expect(store.notes['A']!.hasContent, isTrue);
    expect(store.notes['C']!.hasContent, isFalse);
    expect(store.notes['A']!.refs, ['a:att1']);
    expect(await store.attachmentFile('att1').readAsBytes(), [1, 2, 3]);
    expect(await store.readText('B'), 'PNG');
  });

  test('second sync downloads only changed content and prunes deleted notes', () async {
    await run();
    server.requests.clear();
    server.add('A', 'Projekte', children: [], content: '<p>Neu</p>', blob: 'b2');
    server.notes['root']!['childNoteIds'] = ['A', 'B'];
    server.notes.remove('C');
    final store = await run();
    final contentRequests = server.requests.where((r) => r.endsWith('/content')).toList();
    expect(contentRequests, ['notes/A/content']);
    expect(await store.readText('A'), '<p>Neu</p>');
    expect(store.notes.containsKey('C'), isFalse);
    expect(await store.contentFile('C').exists(), isFalse);
    expect(await store.attachmentFile('att1').exists(), isFalse, reason: 'no longer referenced');
  });

  test('index survives a reload', () async {
    await run();
    final again = OfflineStore(dir);
    await again.load();
    expect(again.notes.length, 4);
    expect(again.lastSync, isNotNull);
    expect(again.serverVersion, '0.107.0');
    expect(again.pathTo('C').map((n) => n.id), ['root', 'A', 'C']);
  });

  test('walks the tree note by note when search fails', () async {
    server.searchWorks = false;
    final store = await run();
    expect(store.notes.keys, unorderedEquals(['root', 'A', 'B', 'C']));
  });

  test('rejected token fails the sync', () async {
    final store = OfflineStore(dir);
    await store.load();
    final sync = SyncService(store);
    await expectLater(
      sync.sync(EtapiClient('http://x', token: 'bad', client: server.client())),
      throwsA(isA<EtapiException>()),
    );
    expect(sync.status.state, SyncState.failed);
  });
}
