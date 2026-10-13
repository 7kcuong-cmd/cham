import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../l10n_errors.dart';
import '../models/api_error.dart';
import '../services/api_client.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';

/// Xác minh số điện thoại kiểu "nhắn ngược" (XAC-MINH-SO-DIEN-THOAI.md): người dùng tự nhắn mã tới số của bạn,
/// server khớp mã rồi ghi nhận. App chỉ hiện hướng dẫn, mở ứng dụng nhắn tin và hỏi lại trạng thái. CHƯA THỬ TRÊN MÁY THẬT.
class PhoneVerifyScreen extends StatefulWidget {
  const PhoneVerifyScreen({super.key, this.pollInterval = const Duration(seconds: 4)});

  final Duration pollInterval;

  @override
  State<PhoneVerifyScreen> createState() => _PhoneVerifyScreenState();
}

class _PhoneVerifyScreenState extends State<PhoneVerifyScreen> {
  bool _loading = true;
  bool _enabled = false;
  bool _verified = false;
  String? _error;
  ({String destNumber, String text, DateTime expiresAt})? _challenge;
  Timer? _poll;

  ApiClient get _api => context.read<ApiClient>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final st = await _api.getPhoneStatus();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _enabled = st.enabled;
        _verified = st.verified;
        _error = null;
      });
      if (st.verified) _poll?.cancel();
    } on ApiException catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.code; });
    } on Object {
      if (mounted) setState(() { _loading = false; _error = 'INTERNAL'; });
    }
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      final c = await _api.startPhoneChallenge();
      if (!mounted) return;
      setState(() => _challenge = c);
      _poll?.cancel();
      _poll = Timer.periodic(widget.pollInterval, (_) {
        final ch = _challenge;
        if (ch != null && DateTime.now().isAfter(ch.expiresAt)) {
          _poll?.cancel();
          if (mounted) setState(() => _challenge = null);
          return;
        }
        unawaited(_refresh());
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.code);
    } on Object {
      if (mounted) setState(() => _error = 'INTERNAL');
    }
  }

  Future<void> _openSms() async {
    final c = _challenge;
    if (c == null) return;
    final uri = Uri(scheme: 'sms', path: c.destNumber, queryParameters: {'body': c.text});
    // Một số máy nhận "&body=" thay vì "?body="; nếu mở không được, người dùng vẫn có nút sao chép.
    try {
      await launchUrl(uri);
    } on Object {
      // bỏ qua
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Xác minh số điện thoại', 'Verify phone number'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                if (_verified) ...[
                  const Icon(Icons.verified_rounded, size: 64),
                  const SizedBox(height: AppSpace.md),
                  Text(tr(context, 'Số điện thoại của bạn đã được xác minh.', 'Your phone number is verified.'),
                      style: AppText.title, textAlign: TextAlign.center),
                ] else if (!_enabled) ...[
                  Text(tr(context, 'Tính năng này chưa được bật trên máy chủ.', 'This feature is not enabled on the server.')),
                ] else ...[
                  Text(
                    tr(
                      context,
                      'Để nhận điểm thưởng không giới hạn, hãy xác minh số điện thoại. Bạn tự nhắn một tin tới số bên dưới bằng chính SIM của mình (có thể tốn cước SMS thường). Chúng tôi chỉ lưu bản mã hóa của số, không lưu số thật.',
                      'To keep earning rewards, verify your phone number. Send one text from your own SIM to the number below (standard SMS rates may apply). We store only a hash of your number, never the number itself.',
                    ),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  if (_challenge == null)
                    FilledButton(onPressed: _start, child: Text(tr(context, 'Bắt đầu', 'Start')))
                  else ...[
                    _Field(label: tr(context, 'Gửi tới số', 'Send to'), value: _challenge!.destNumber),
                    const SizedBox(height: AppSpace.sm),
                    _Field(label: tr(context, 'Nội dung tin nhắn', 'Message text'), value: _challenge!.text),
                    const SizedBox(height: AppSpace.md),
                    FilledButton.icon(
                      onPressed: _openSms,
                      icon: const Icon(Icons.sms_rounded),
                      label: Text(tr(context, 'Mở ứng dụng nhắn tin', 'Open messages app')),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      tr(context, 'Đang chờ tin nhắn của bạn… Mã hết hạn sau ít phút.', 'Waiting for your message… The code expires in a few minutes.'),
                      style: AppText.label,
                    ),
                  ],
                ],
                if (_error != null) ...[
                  const SizedBox(height: AppSpace.md),
                  Text(errorText(l10n, _error!), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      child: Row(
        children: [
          Expanded(child: SelectableText(value, style: AppText.body)),
          IconButton(
            tooltip: tr(context, 'Sao chép', 'Copy'),
            icon: const Icon(Icons.copy_rounded),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
            },
          ),
        ],
      ),
    );
  }
}
