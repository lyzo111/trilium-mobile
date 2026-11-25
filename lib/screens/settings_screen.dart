import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app_state.dart';
import '../etapi.dart';
import '../sync.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int? _bytes;
  String? _appVersion;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _refreshSize();
    PackageInfo.fromPlatform().then((p) {
      if (mounted) setState(() => _appVersion = '${p.version} (${p.buildNumber})');
    });
  }

  Future<void> _refreshSize() async {
    final b = await state.store.sizeOnDisk();
    if (mounted) setState(() => _bytes = b);
  }

  Future<void> _toggleRemember(bool value) async {
    if (!value) {
      await state.setRememberPassword(false);
      return;
    }
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Trilium-Passwort'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Passwort'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Speichern')),
        ],
      ),
    );
    controller.dispose();
    if (password == null || password.isEmpty) return;
    // Checked against the server so a typo does not lock the auto-login into failing.
    final client = state.client();
    try {
      final token = await client.login(password, tokenName: 'Trilium Mobile (Prüfung)');
      await state.setRememberPassword(true, password: password);
      // The check created a token; remove it again.
      final check = EtapiClient(client.baseUrl, token: token);
      await check.logout();
      check.close();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(describeError(e))));
    } finally {
      client.close();
    }
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Abmelden?'),
        content: const Text('Die Verbindung zum Server wird getrennt und die Offline-Kopie '
            'auf diesem Gerät gelöscht. Auf dem Server bleibt alles erhalten.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Abmelden')),
        ],
      ),
    );
    if (ok != true) return;
    await WebViewCookieManager().clearCookies();
    await state.signOut();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([state, state.sync]),
      builder: (context, _) {
        final store = state.store;
        final sync = state.sync.status;
        final last = store.lastSync;
        return Scaffold(
          appBar: AppBar(title: const Text('Einstellungen')),
          body: SafeArea(
            top: false,
            child: ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Server'),
                  subtitle: Text([state.serverUrl ?? '', if (store.serverVersion != null) 'Trilium ${store.serverVersion}'].join('\n')),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.offline_pin_outlined),
                  title: const Text('Offline-Kopie'),
                  subtitle: Text([
                    '${store.notes.length} Notizen'
                        '${_bytes == null ? '' : ' · ${(_bytes! / 1024 / 1024).toStringAsFixed(1)} MB'}',
                    'Letzte Synchronisation: ${last == null ? 'nie' : last.toLocal().toString().substring(0, 16)}',
                    if (sync.state != SyncState.idle) sync.message,
                  ].join('\n')),
                  isThreeLine: true,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: FilledButton.tonalIcon(
                    onPressed: state.sync.isRunning
                        ? null
                        : () async {
                            await state.syncNow();
                            _refreshSize();
                          },
                    icon: const Icon(Icons.sync),
                    label: Text(state.sync.isRunning ? 'Synchronisiere …' : 'Jetzt synchronisieren'),
                  ),
                ),
                const Divider(),
                SwitchListTile(
                  secondary: const Icon(Icons.key_outlined),
                  title: const Text('Automatisch anmelden'),
                  subtitle: const Text('Passwort verschlüsselt speichern und die Web-Sitzung bei Ablauf selbst erneuern'),
                  value: state.rememberPassword && state.password != null,
                  onChanged: _toggleRemember,
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('Abmelden und lokale Daten löschen'),
                  onTap: _signOut,
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('App-Version'),
                  subtitle: Text('${_appVersion ?? '…'}\nOnline-Funktionen kommen direkt vom Server '
                      'und sind immer auf dessen Stand.'),
                  isThreeLine: true,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
