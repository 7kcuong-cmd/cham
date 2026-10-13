// Điểm vào BẢN WEB liên kết (chỉ nhắn tin qua điện thoại). Không nhập gì khỏi lib/ dùng `dart:io`.
// Build: flutter build web -t lib/main_web.dart --base-href /web/ --release
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'link/link_session.dart';
import 'models/chat_message.dart';
import 'services/link_channel.dart';
import 'services/link_sync.dart';

const _linkWsOverride = String.fromEnvironment('LINK_WS_URL');

Uri _linkUrl() {
  if (_linkWsOverride.isNotEmpty) return Uri.parse(_linkWsOverride);
  final b = Uri.base;
  return Uri(scheme: b.scheme == 'https' ? 'wss' : 'ws', host: b.host, port: b.hasPort ? b.port : null, path: '/v1/link');
}

void main() => runApp(const ChamWebApp());

class ChamWebApp extends StatelessWidget {
  const ChamWebApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Chạm Web',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: const Color(0xFF0B0B0F),
          colorScheme: const ColorScheme.dark(primary: Color(0xFFFF4D73)),
        ),
        home: const _WebHome(),
      );
}

enum _Phase { connecting, qr, waitingApproval, ready, closed, error }

class _WebHome extends StatefulWidget {
  const _WebHome();

  @override
  State<_WebHome> createState() => _WebHomeState();
}

class _WebHomeState extends State<_WebHome> {
  _Phase _phase = _Phase.connecting;
  LinkSession? _session;
  LinkClient? _client;
  String? _qr;
  String? _peer;
  String? _error;
  final TextEditingController _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    setState(() => _phase = _Phase.connecting);
    try {
      final s = await LinkSession.openWeb(_linkUrl());
      _session = s;
      final code = await s.code.timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        _qr = LinkPairing(code, s.channel.localFingerprint!).qrPayload;
        _phase = _Phase.qr;
      });
      await s.paired;
      if (!mounted) return;
      setState(() => _phase = _Phase.waitingApproval);
      await s.channel.ready;
      final c = LinkClient(s.channel);
      _client = c;
      c.changed.listen((_) => mounted ? setState(() {}) : null);
      await c.approved;
      await c.sync();
      if (mounted) setState(() => _phase = _Phase.ready);
    } on Object {
      if (!mounted) return;
      setState(() {
        _phase = _phase == _Phase.ready ? _Phase.closed : _Phase.error;
        _error = 'Không kết nối được hoặc phiên đã hết hạn.';
      });
    }
  }

  @override
  void dispose() {
    _input.dispose();
    unawaited(_client?.dispose());
    unawaited(_session?.close());
    super.dispose();
  }

  Future<void> _send() async {
    final c = _client;
    final p = _peer;
    final t = _input.text.trim();
    if (c == null || p == null || t.isEmpty) return;
    _input.clear();
    await c.send(p, t);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chạm – Web')),
      body: switch (_phase) {
        _Phase.connecting => const Center(child: CircularProgressIndicator()),
        _Phase.qr => Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: _qr!, size: 240),
              ),
              const SizedBox(height: 16),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'Mở Chạm trên điện thoại → Cài đặt → "Liên kết với web" rồi quét mã này. Mã hết hạn sau 2 phút.',
                  textAlign: TextAlign.center,
                ),
              ),
            ]),
          ),
        _Phase.waitingApproval => const Center(child: Text('Đang chờ bạn bấm "Cho phép" trên điện thoại…')),
        _Phase.ready => _chat(),
        _Phase.closed => _retry('Điện thoại đã ngắt kết nối. Dữ liệu trên trang này đã được xóa.'),
        _Phase.error => _retry(_error ?? 'Lỗi'),
      },
    );
  }

  Widget _retry(String msg) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(msg, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const _WebHome())), child: const Text('Liên kết lại')),
        ]),
      );

  Widget _chat() {
    final c = _client!;
    final peers = c.peers;
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 700;
      final list = ListView(children: [
        for (final p in peers)
          ListTile(
            selected: p == _peer,
            title: Text(c.nameOf(p)),
            subtitle: Text(c.messages(p).isEmpty ? '' : c.messages(p).last.text, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => setState(() => _peer = p),
          ),
        if (peers.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Chưa có tin nhắn nào trên điện thoại.')),
      ]);
      final thread = _peer == null ? const Center(child: Text('Chọn một cuộc trò chuyện')) : _thread();
      if (wide) {
        return Row(children: [SizedBox(width: 300, child: list), const VerticalDivider(width: 1), Expanded(child: thread)]);
      }
      return _peer == null ? list : thread;
    });
  }

  Widget _thread() {
    final c = _client!;
    final msgs = c.messages(_peer!).reversed.toList();
    return Column(children: [
      if (MediaQuery.sizeOf(context).width < 700)
        Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: () => setState(() => _peer = null), icon: const Icon(Icons.arrow_back), label: Text(c.nameOf(_peer!)))),
      Expanded(
        child: ListView.builder(
          reverse: true,
          padding: const EdgeInsets.all(12),
          itemCount: msgs.length,
          itemBuilder: (_, i) => _bubble(msgs[i]),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          Expanded(child: TextField(controller: _input, onSubmitted: (_) => _send(), decoration: const InputDecoration(hintText: 'Nhắn tin…', border: OutlineInputBorder()))),
          const SizedBox(width: 8),
          IconButton.filled(onPressed: _send, icon: const Icon(Icons.send)),
        ]),
      ),
    ]);
  }

  Widget _bubble(ChatMessage m) => Align(
        alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: const BoxConstraints(maxWidth: 420),
          decoration: BoxDecoration(
            color: m.mine ? const Color(0xFFFF4D73) : const Color(0xFF1F1F29),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(m.text, style: TextStyle(color: m.mine ? const Color(0xFF0B0B0F) : Colors.white)),
        ),
      );
}
