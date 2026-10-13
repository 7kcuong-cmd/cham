import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'game_host.dart';
import 'game_session.dart';

/// Khung chơi game: WebView chỉ tải từ máy chủ cục bộ, không cho điều hướng ra ngoài.
class GameView extends StatefulWidget {
  const GameView({super.key});

  @override
  State<GameView> createState() => _GameViewState();
}

class _GameViewState extends State<GameView> {
  GameHost? _host;
  WebViewController? _web;
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final s = context.read<GameSessionController>();
    final inst = s.installed;
    if (inst == null) return;
    final host = GameHost(dir: inst.dir);
    final url = await host.start('index.html');
    if (!mounted) {
      await host.stop();
      return;
    }
    final origin = url.origin;
    final web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF10131A))
      ..addJavaScriptChannel('ChamHost', onMessageReceived: (m) => s.fromGame(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (r) => Uri.parse(r.url).origin == origin ? NavigationDecision.navigate : NavigationDecision.prevent,
      ));
    _sub = s.toGame.listen((ev) {
      final js = StringBuffer('window.ChamBridge&&ChamBridge._recv(')
        ..write(_jsString(ev))
        ..write(')');
      unawaited(web.runJavaScript(js.toString()));
    });
    await web.loadRequest(url);
    setState(() {
      _host = host;
      _web = web;
    });
  }

  static String _jsString(Object? v) => jsonEncode(jsonEncode(v));

  @override
  void dispose() {
    _sub?.cancel();
    unawaited(_host?.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: ColoredBox(
        color: const Color(0xFF10131A),
        child: Stack(children: [
          if (web != null) WebViewWidget(controller: web) else const Center(child: CircularProgressIndicator()),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => context.read<GameSessionController>().close(),
            ),
          ),
        ]),
      ),
    );
  }
}
