import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../sync.dart';
import 'offline_browser.dart';
import 'online_view.dart';
import 'settings_screen.dart';

/// Shows the server's own UI while it is reachable and the offline copy otherwise,
/// with a thin status line on top for connection, sync and settings.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});

  final AppState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  AppState get state => widget.state;
  Timer? _retry;
  Timer? _periodicSync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
    _periodicSync = Timer.periodic(const Duration(minutes: 30), (_) {
      if (state.connection == Connection.online) state.syncIfDue(maxAge: const Duration(minutes: 25));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retry?.cancel();
    _periodicSync?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      if (state.connection == Connection.offline) {
        _start();
      } else {
        _recheck();
      }
    }
  }

  Future<void> _start() async {
    final c = await state.checkConnection();
    if (c == Connection.online) {
      _retry?.cancel();
      // The first sync always runs; later ones only when the last is stale.
      state.store.isEmpty ? state.syncNow() : state.syncIfDue();
    } else {
      _scheduleRetry();
    }
  }

  /// Back in the app while online: the server may have gone away in the meantime.
  Future<void> _recheck() async {
    if (await state.checkConnection(quiet: true) == Connection.online) {
      state.syncIfDue();
    } else {
      _scheduleRetry();
    }
  }

  /// While offline, look for the server every 30 s; going online again is announced but not
  /// forced, so a note being read offline is not pulled away.
  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (state.connection != Connection.offline) return;
      final probe = state.client();
      try {
        await probe.appInfo(timeout: const Duration(seconds: 5));
        _retry?.cancel();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Server wieder erreichbar'),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(label: 'Online gehen', onPressed: _start),
        ));
      } catch (_) {
        // still offline
      } finally {
        probe.close();
      }
    });
  }

  void _onWebOffline() {
    state.markOffline();
    _scheduleRetry();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Server nicht erreichbar – Offline-Kopie wird angezeigt')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([state, state.sync]),
      builder: (context, _) {
        final Widget body;
        switch (state.connection) {
          case Connection.online:
            body = OnlineView(state: state, onOffline: _onWebOffline);
          case Connection.offline:
            body = state.store.isEmpty
                ? _EmptyOffline(onRetry: _start)
                : OfflineBrowser(state: state, noteId: 'root', embedded: true);
          case Connection.checking:
            body = const Center(child: CircularProgressIndicator());
        }
        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                _StatusBar(state: state, onRetry: _start),
                Expanded(child: body),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.state, required this.onRetry});

  final AppState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sync = state.sync.status;
    final online = state.connection == Connection.online;
    final Color dot = switch (state.connection) {
      Connection.online => Colors.green,
      Connection.offline => Colors.orange,
      Connection.checking => scheme.outline,
    };
    final String text;
    if (sync.state == SyncState.running) {
      text = sync.message;
    } else if (state.connection == Connection.checking) {
      text = 'Verbinde …';
    } else {
      final last = state.store.lastSync;
      final stamp = last == null ? 'nie' : _formatTime(last);
      final failed = sync.state == SyncState.failed ? ' · ${sync.message}' : '';
      text = online ? 'Online · Offline-Kopie: $stamp$failed' : 'Offline · Stand: $stamp';
    }

    return Material(
      color: scheme.surfaceContainer,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(Icons.circle, size: 9, color: dot),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ),
            if (sync.state == SyncState.running)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (online)
              _barButton(Icons.sync, 'Jetzt synchronisieren', state.syncNow)
            else if (state.connection == Connection.offline)
              _barButton(Icons.refresh, 'Erneut verbinden', onRetry),
            if (online && !state.store.isEmpty)
              _barButton(Icons.offline_pin_outlined, 'Offline-Kopie ansehen', () {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => OfflineBrowser(state: state, noteId: 'root'),
                ));
              }),
            _barButton(Icons.settings_outlined, 'Einstellungen', () {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(state: state)));
            }),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _barButton(IconData icon, String tooltip, VoidCallback onPressed) => IconButton(
        icon: Icon(icon, size: 20),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
      );
}

String _formatTime(DateTime t) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final time = '${two(t.hour)}:${two(t.minute)}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return 'heute $time';
  return '${two(t.day)}.${two(t.month)}. $time';
}

class _EmptyOffline extends StatelessWidget {
  const _EmptyOffline({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            const Text('Server nicht erreichbar, und es gibt noch keine Offline-Kopie.', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Erneut versuchen')),
          ],
        ),
      ),
    );
  }
}
