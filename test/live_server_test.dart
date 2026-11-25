// Runs only against a real Trilium server:
//   TRILIUM_URL=http://127.0.0.1:8089 TRILIUM_PASSWORD=... flutter test test/live_server_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trilium_mobile/etapi.dart';
import 'package:trilium_mobile/store.dart';
import 'package:trilium_mobile/sync.dart';

void main() {
  final url = Platform.environment['TRILIUM_URL'];
  final password = Platform.environment['TRILIUM_PASSWORD'];

  test(
    'login, full sync and incremental sync against a real server',
    () async {
      final token = await EtapiClient(url!).login(password!, tokenName: 'live test');
      final client = EtapiClient(url, token: token);
      final dir = await Directory.systemTemp.createTemp('trilium_live');
      final store = OfflineStore(dir);
      await store.load();
      final sync = SyncService(store);

      final sw = Stopwatch()..start();
      await sync.sync(client);
      // ignore: avoid_print
      print('full sync: ${store.notes.length} notes, ${sync.status.message}, ${sw.elapsedMilliseconds} ms, '
          '${await store.sizeOnDisk()} bytes, ${store.attachmentMimes.length} attachments');
      expect(store.notes['root'], isNotNull);
      expect(store.notes.keys.where((k) => k.startsWith('_')), isEmpty);
      expect(sync.status.errors, 0);

      sw.reset();
      await sync.sync(client);
      // ignore: avoid_print
      print('incremental sync: ${sw.elapsedMilliseconds} ms');

      await client.logout();
      await dir.delete(recursive: true);
    },
    skip: url == null || password == null ? 'TRILIUM_URL / TRILIUM_PASSWORD not set' : false,
  );
}
