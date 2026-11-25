import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../etapi.dart';
import '../sync.dart';

/// First start: server address and password. The password is traded for an ETAPI token.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.state});

  final AppState state;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _url = TextEditingController();
  final _password = TextEditingController();
  final _totp = TextEditingController();
  final _token = TextEditingController();
  bool _useToken = false;
  bool _needsTotp = false;
  bool _busy = false;
  bool _remember = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _url.text = widget.state.serverUrl ?? '';
    _remember = widget.state.rememberPassword;
  }

  @override
  void dispose() {
    for (final c in [_url, _password, _totp, _token]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    final url = EtapiClient.normalizeBaseUrl(_url.text);
    if (url.isEmpty) {
      setState(() => _error = 'Bitte die Server-Adresse eingeben.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    var client = EtapiClient(url);
    try {
      String token;
      if (_useToken) {
        token = _token.text.trim();
        client.close();
        client = EtapiClient(url, token: token);
        await client.appInfo();
      } else {
        token = await client.login(
          _password.text,
          totpToken: _needsTotp ? _totp.text.trim() : null,
          tokenName: 'Trilium Mobile (${Platform.isIOS ? 'iOS' : 'Android'})',
        );
      }
      await widget.state.setRememberPassword(_remember);
      await widget.state.configure(url: url, token: token, password: _useToken ? null : _password.text);
      // The main screen takes over from here and runs the first sync.
    } on EtapiException catch (e) {
      setState(() {
        if (e.code == 'TOTP_REQUIRED' || e.code == 'WRONG_TOTP') _needsTotp = true;
        _error = describeError(e);
      });
    } catch (e) {
      setState(() => _error = '${describeError(e)}\nAdresse prüfen (inkl. http:// oder https:// und Port).');
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.account_tree_outlined, size: 56, color: theme.colorScheme.primary),
                    const SizedBox(height: 12),
                    Text('Mit Trilium verbinden', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    Text(
                      'Online zeigt die App die Oberfläche deines Servers – immer in dessen neuester Version. '
                      'Zusätzlich wird eine Kopie deiner Notizen zum Offline-Lesen gespeichert.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 28),
                    TextField(
                      controller: _url,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.url],
                      decoration: const InputDecoration(
                        labelText: 'Server-Adresse',
                        hintText: 'https://notes.example.com',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (!_useToken) ...[
                      TextField(
                        controller: _password,
                        obscureText: true,
                        autofillHints: const [AutofillHints.password],
                        onSubmitted: (_) => _connect(),
                        decoration: const InputDecoration(
                          labelText: 'Trilium-Passwort',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.lock_outline),
                        ),
                      ),
                      if (_needsTotp) ...[
                        const SizedBox(height: 16),
                        TextField(
                          controller: _totp,
                          keyboardType: TextInputType.number,
                          autofillHints: const [AutofillHints.oneTimeCode],
                          decoration: const InputDecoration(
                            labelText: 'Zwei-Faktor-Code',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.pin_outlined),
                          ),
                        ),
                      ],
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _remember,
                        onChanged: (v) => setState(() => _remember = v),
                        title: const Text('Automatisch anmelden'),
                        subtitle: const Text('Passwort verschlüsselt auf dem Gerät speichern, '
                            'um die Web-Sitzung bei Ablauf zu erneuern.'),
                      ),
                    ] else
                      TextField(
                        controller: _token,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'ETAPI-Token',
                          helperText: 'Trilium → Optionen → ETAPI → Neues Token erstellen',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.key_outlined),
                        ),
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                    ],
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _busy ? null : _connect,
                      icon: _busy
                          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.login),
                      label: const Text('Verbinden'),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => setState(() => _useToken = !_useToken),
                      child: Text(_useToken ? 'Mit Passwort anmelden' : 'Stattdessen ETAPI-Token verwenden'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
