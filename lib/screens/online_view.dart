import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../app_state.dart';
import '../files.dart';
import '../sync.dart';

/// The Trilium server's own web UI. Nothing of it is built into the app, so every feature of
/// whatever version the server runs is available without an app update.
class OnlineView extends StatefulWidget {
  const OnlineView({super.key, required this.state, required this.onOffline});

  final AppState state;

  /// Called when the server stops answering while the UI is shown.
  final VoidCallback onOffline;

  @override
  State<OnlineView> createState() => _OnlineViewState();
}

class _OnlineViewState extends State<OnlineView> {
  late final WebViewController _controller;
  late final String _base;
  bool _ready = false;
  DateTime? _lastAutoLogin;
  Timer? _readyFallback;

  @override
  void initState() {
    super.initState();
    _base = widget.state.serverUrl!;

    final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const {},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }
    _controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('TriliumApp', onMessageReceived: _onAppMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: _onNavigation,
        onPageFinished: _onPageFinished,
        onWebResourceError: (e) {
          if (e.isForMainFrame ?? true) widget.onOffline();
        },
      ));

    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
      platform.setOnShowFileSelector(_pickFiles);
    } else if (platform is WebKitWebViewController) {
      platform.setAllowsBackForwardNavigationGestures(true);
    }

    // With a stored password the session is renewed before the UI shows a login screen.
    if (widget.state.password != null && widget.state.store.lastSync == null) {
      _login();
    } else {
      _controller.loadRequest(Uri.parse('$_base/'));
    }
    _readyFallback = Timer(const Duration(seconds: 8), _markReady);
  }

  @override
  void dispose() {
    _readyFallback?.cancel();
    super.dispose();
  }

  void _markReady() {
    if (mounted && !_ready) setState(() => _ready = true);
  }

  /// Logs the WebView in the way the login form does, so the server sets its own
  /// long-lived session cookie.
  void _login() {
    _lastAutoLogin = DateTime.now();
    final body = 'password=${Uri.encodeQueryComponent(widget.state.password!)}&rememberMe=1';
    _controller.loadRequest(
      Uri.parse('$_base/login'),
      method: LoadRequestMethod.post,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: Uint8List.fromList(utf8.encode(body)),
    );
  }

  Future<void> _onPageFinished(String url) async {
    if (!url.startsWith(_base)) return _markReady();
    // The web UI renders its login screen client-side, so ask the server directly.
    try {
      await _controller.runJavaScript('''
        fetch(${jsonEncode('$_base/bootstrap')}, {credentials: 'include'})
          .then(function (r) { return r.json(); })
          .then(function (j) { TriliumApp.postMessage(j.loggedIn ? 'in' : 'out'); })
          .catch(function () { TriliumApp.postMessage('err'); });
      ''');
    } catch (_) {
      _markReady();
    }
  }

  void _onAppMessage(JavaScriptMessage m) {
    if (m.message == 'out' && widget.state.password != null) {
      final last = _lastAutoLogin;
      // At most one attempt a minute, so a changed password does not loop.
      if (last == null || DateTime.now().difference(last) > const Duration(minutes: 1)) {
        _login();
        return;
      }
    }
    _markReady();
  }

  Future<NavigationDecision> _onNavigation(NavigationRequest request) async {
    final url = request.url;
    if (!request.isMainFrame) return NavigationDecision.navigate;

    final file = fileTarget(url);
    if (file != null && url.startsWith(_base)) {
      _openFile(file.id, file.attachment);
      return NavigationDecision.prevent;
    }
    if (url.startsWith(_base) || url.startsWith('about:') || url.startsWith('data:') || url.startsWith('blob:')) {
      return NavigationDecision.navigate;
    }
    // Links leaving the server open in the system browser or the matching app.
    final uri = Uri.tryParse(url);
    if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
    return NavigationDecision.prevent;
  }

  Future<void> _openFile(String id, bool attachment) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Datei wird geladen …'), duration: Duration(seconds: 2)));
    final client = widget.state.client();
    try {
      final error = await downloadAndOpen(client, id: id, attachment: attachment);
      if (error != null) messenger.showSnackBar(SnackBar(content: Text('Keine App zum Öffnen: $error')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Download fehlgeschlagen: ${describeError(e)}')));
    } finally {
      client.close();
    }
  }

  Future<List<String>> _pickFiles(FileSelectorParams params) async {
    final files = params.mode == FileSelectorMode.openMultiple
        ? await FilePicker.pickFiles()
        : [?await FilePicker.pickFile()];
    return [
      for (final f in files)
        if (f.path != null) Uri.file(f.path!).toString(),
    ];
  }

  Future<void> _back() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
    } else {
      await SystemNavigator.pop();
    }
  }

  /// On Android the WebView is drawn by the system itself (hybrid composition) instead of being
  /// copied into a Flutter texture every frame, so scrolling feels like in the browser.
  Widget _webView() {
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      return WebViewWidget.fromPlatformCreationParams(
        params: AndroidWebViewWidgetCreationParams(
          controller: platform,
          displayWithHybridComposition: true,
        ),
      );
    }
    return WebViewWidget(controller: _controller);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Stack(
        children: [
          _webView(),
          if (!_ready)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: const Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}
