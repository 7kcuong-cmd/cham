import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../config/env.dart';
import '../link/chat_link_port.dart';
import '../link/link_session.dart';
import '../services/chat_store.dart';
import '../services/link_channel.dart';
import '../services/link_sync.dart';
import '../state/chat_controller.dart';
import '../state/contacts_controller.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';

enum _Step { scanning, connecting, confirm, linked, failed }

/// Quét mã QR trên trang web để liên kết: web đọc/nhắn tin QUA điện thoại này, không đăng nhập riêng.
class LinkScanScreen extends StatefulWidget {
  const LinkScanScreen({super.key});

  @override
  State<LinkScanScreen> createState() => _LinkScanScreenState();
}

class _LinkScanScreenState extends State<LinkScanScreen> {
  _Step _step = _Step.scanning;
  LinkSession? _session;
  LinkHost? _host;
  String? _error;
  bool _handling = false;

  Uri get _linkUrl => Uri.parse(Env.wsUrl.replaceFirst(RegExp(r'/v1/ws/?$'), '/v1/link'));

  Future<void> _onCode(String raw) async {
    if (_handling) return;
    final pairing = LinkPairing.parse(raw);
    if (pairing == null) return;
    _handling = true;
    setState(() => _step = _Step.connecting);
    try {
      final s = await LinkSession.openPhone(_linkUrl, pairing);
      _session = s;
      await s.paired.timeout(const Duration(seconds: 15));
      await s.channel.ready.timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() => _step = _Step.confirm);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.failed;
        _error = e is StateError
            ? tr(context, 'Mã QR không khớp hoặc đã hết hạn. Tải lại trang web và quét lại.',
                'The QR code does not match or has expired. Reload the web page and scan again.')
            : tr(context, 'Không kết nối được. Thử lại.', 'Could not connect. Try again.');
      });
    }
  }

  void _allow() {
    final s = _session;
    if (s == null) return;
    final port = ChatControllerLinkPort(
      store: context.read<ChatStore>(),
      chat: context.read<ChatController>(),
      contacts: context.read<ContactsController>(),
    );
    _host = LinkHost(channel: s.channel, chat: port)..approve();
    setState(() => _step = _Step.linked);
  }

  Future<void> _disconnect() async {
    await _host?.dispose();
    await _session?.close();
    _host = null;
    _session = null;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    unawaited(_host?.dispose());
    unawaited(_session?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Liên kết với web', 'Link with web'))),
      body: switch (_step) {
        _Step.scanning => MobileScanner(
            onDetect: (capture) {
              for (final b in capture.barcodes) {
                final v = b.rawValue;
                if (v != null) {
                  unawaited(_onCode(v));
                  break;
                }
              }
            },
          ),
        _Step.connecting => const Center(child: CircularProgressIndicator()),
        _Step.confirm => _msg(
            tr(context, 'Cho phép trang web này đọc và gửi tin nhắn của bạn?\nChỉ đồng ý nếu chính bạn vừa mở trang web.',
                'Allow this web page to read and send your messages?\nOnly agree if you just opened the page yourself.'),
            [
              OutlinedButton(onPressed: _disconnect, child: Text(tr(context, 'Từ chối', 'Decline'))),
              FilledButton(onPressed: _allow, child: Text(tr(context, 'Cho phép', 'Allow'))),
            ],
          ),
        _Step.linked => _msg(
            tr(context, 'Đã liên kết. Giữ ứng dụng mở để web hoạt động. Đóng tab web là dữ liệu trên web biến mất.',
                'Linked. Keep the app open for the web page to work. Closing the web tab erases its data.'),
            [FilledButton(onPressed: _disconnect, child: Text(tr(context, 'Ngắt kết nối', 'Disconnect')))],
          ),
        _Step.failed => _msg(_error ?? '', [FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr(context, 'Đóng', 'Close')))]),
      },
    );
  }

  Widget _msg(String text, List<Widget> actions) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textPrimary, fontSize: 16)),
            const SizedBox(height: AppSpace.lg),
            Wrap(spacing: AppSpace.md, children: actions),
          ]),
        ),
      );
}
