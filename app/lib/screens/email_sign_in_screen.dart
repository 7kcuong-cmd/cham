import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n_errors.dart';
import '../models/api_error.dart';
import '../state/session_controller.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';

/// Đăng ký / đăng nhập bằng email: nhập email -> nhận mã 6 số -> nhập mã. Chưa có tài khoản thì tự tạo.
class EmailSignInScreen extends StatefulWidget {
  const EmailSignInScreen({super.key});

  @override
  State<EmailSignInScreen> createState() => _EmailSignInScreenState();
}

class _EmailSignInScreenState extends State<EmailSignInScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _emailOk => RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(_email.text.trim());

  Future<void> _send() async {
    if (!_emailOk) {
      setState(() => _error = tr(context, 'Email không hợp lệ.', 'Invalid email.'));
      return;
    }
    final session = context.read<SessionController>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.requestEmailCode(_email.text.trim());
      if (mounted) setState(() => _sent = true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = errorText(AppLocalizations.of(context), e.code));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    final session = context.read<SessionController>();
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await session.signInEmail(_email.text.trim(), _code.text.trim());
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    } else {
      setState(() {
        _busy = false;
        _error = tr(context, 'Mã sai hoặc đã hết hạn.', 'Wrong or expired code.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(backgroundColor: AppColors.bg, title: Text(tr(context, 'Đăng nhập bằng email', 'Sign in with email'))),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _email,
                enabled: !_busy && !_sent,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                style: AppText.body,
                decoration: InputDecoration(hintText: 'email@example.com'),
              ),
              const SizedBox(height: AppSpace.md),
              if (!_sent)
                FilledButton(onPressed: _busy ? null : _send, child: Text(tr(context, 'Gửi mã', 'Send code')))
              else ...[
                Text(
                  tr(context, 'Đã gửi mã 6 số tới email của bạn (kiểm tra cả thư rác).', 'We sent a 6-digit code to your email (check spam too).'),
                  style: AppText.caption,
                ),
                const SizedBox(height: AppSpace.sm),
                TextField(
                  controller: _code,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  style: AppText.body,
                  decoration: InputDecoration(hintText: tr(context, 'Mã 6 số', '6-digit code'), counterText: ''),
                ),
                const SizedBox(height: AppSpace.md),
                FilledButton(onPressed: _busy ? null : _verify, child: Text(tr(context, 'Xác nhận', 'Confirm'))),
                TextButton(
                  onPressed: _busy ? null : () => setState(() => _sent = false),
                  child: Text(tr(context, 'Đổi email / gửi lại mã', 'Change email / resend')),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: AppSpace.md),
                Text(_error!, style: AppText.caption.copyWith(color: AppColors.danger)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
