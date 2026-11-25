import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'etapi.dart';
import 'store.dart';
import 'sync.dart';

/// Whether the server's own UI can be shown right now.
enum Connection { checking, online, offline }

/// Holds the server connection, the offline copy and the sync, for the whole app.
class AppState extends ChangeNotifier {
  AppState._(this._prefs, this.store) : sync = SyncService(store);

  static const _secure = FlutterSecureStorage();
  static const _kUrl = 'serverUrl';
  static const _kToken = 'etapiToken';
  static const _kPassword = 'password';
  static const _kRememberPassword = 'rememberPassword';

  final SharedPreferences _prefs;
  final OfflineStore store;
  final SyncService sync;

  String? serverUrl;
  String? token;

  /// Kept (in the platform keystore) only so the app can log the web UI in again by itself
  /// when the server session runs out. Sync never needs it.
  String? password;

  Connection connection = Connection.checking;

  static Future<AppState> load() async {
    final prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationSupportDirectory();
    final store = OfflineStore(Directory('${dir.path}/offline'));
    await store.load();
    final s = AppState._(prefs, store);
    s.serverUrl = prefs.getString(_kUrl);
    try {
      s.token = await _secure.read(key: _kToken);
      s.password = await _secure.read(key: _kPassword);
    } catch (_) {
      // Keystore entries can become unreadable after a backup restore; the user just logs in again.
    }
    return s;
  }

  bool get isConfigured => serverUrl != null && token != null;
  bool get rememberPassword => _prefs.getBool(_kRememberPassword) ?? true;

  EtapiClient client() => EtapiClient(serverUrl!, token: token);

  Future<void> configure({required String url, required String token, String? password}) async {
    serverUrl = EtapiClient.normalizeBaseUrl(url);
    this.token = token;
    await _prefs.setString(_kUrl, serverUrl!);
    await _secure.write(key: _kToken, value: token);
    // Always kept in memory for the first web login; written to the keystore only when allowed.
    this.password = password;
    if (password != null && rememberPassword) await _secure.write(key: _kPassword, value: password);
    notifyListeners();
  }

  Future<void> setRememberPassword(bool value, {String? password}) async {
    await _prefs.setBool(_kRememberPassword, value);
    if (!value) {
      this.password = null;
      await _secure.delete(key: _kPassword);
    } else if (password != null) {
      this.password = password;
      await _secure.write(key: _kPassword, value: password);
    }
    notifyListeners();
  }

  /// Disconnects from the server and deletes everything stored on the phone.
  Future<void> signOut() async {
    if (isConfigured) {
      try {
        await client().logout().timeout(const Duration(seconds: 5));
      } catch (_) {
        // Offline: the token stays valid on the server until removed under Options → ETAPI.
      }
    }
    serverUrl = null;
    token = null;
    password = null;
    await _prefs.remove(_kUrl);
    await _secure.delete(key: _kToken);
    await _secure.delete(key: _kPassword);
    await store.clear();
    connection = Connection.checking;
    notifyListeners();
  }

  /// Asks the server whether it is reachable and the token still valid.
  Future<Connection> checkConnection() async {
    if (!isConfigured) return connection;
    connection = Connection.checking;
    notifyListeners();
    final c = client();
    try {
      await c.appInfo(timeout: const Duration(seconds: 6));
      connection = Connection.online;
    } on EtapiException catch (e) {
      // A rejected token still means the server is there; the web UI has its own login.
      connection = e.isAuthError ? Connection.online : Connection.offline;
    } catch (_) {
      connection = Connection.offline;
    } finally {
      c.close();
    }
    notifyListeners();
    return connection;
  }

  void markOffline() {
    if (connection == Connection.offline) return;
    connection = Connection.offline;
    notifyListeners();
  }

  /// Syncs when the last sync is older than [maxAge]; errors only show in the status line.
  Future<void> syncIfDue({Duration maxAge = const Duration(minutes: 15)}) async {
    final last = store.lastSync;
    if (last != null && DateTime.now().difference(last) < maxAge) return;
    await syncNow();
  }

  Future<void> syncNow() async {
    if (!isConfigured) return;
    final c = client();
    try {
      await sync.sync(c);
    } catch (_) {
      // Shown through sync.status.
    } finally {
      c.close();
    }
    notifyListeners();
  }
}
