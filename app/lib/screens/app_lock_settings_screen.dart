import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_lock_service.dart';
import '../state/app_lock_controller.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';

/// Bật/tắt khóa ứng dụng. Mặc định TẮT; mọi tính năng khóa chỉ có hiệu lực sau khi người dùng bật ở đây.
class AppLockSettingsScreen extends StatefulWidget {
  const AppLockSettingsScreen({super.key});

  @override
  State<AppLockSettingsScreen> createState() => _AppLockSettingsScreenState();
}

class _AppLockSettingsScreenState extends State<AppLockSettingsScreen> {
  final TextEditingController _pin1 = TextEditingController();
  final TextEditingController _pin2 = TextEditingController();
  int _attempts = 3;
  int _after = 30;
  bool _ack = false;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pin1.dispose();
    _pin2.dispose();
    super.dispose();
  }

  Future<void> _enable() async {
    final lock = context.read<AppLockController>();
    if (!AppLockService.pinFormat.hasMatch(_pin1.text)) {
      return setState(() => _error = tr(context, 'Mã phải gồm đúng 6 chữ số.', 'The code must be exactly 6 digits.'));
    }
    if (_pin1.text != _pin2.text) {
      return setState(() => _error = tr(context, 'Hai lần nhập chưa khớp.', 'The two entries do not match.'));
    }
    if (!_ack) {
      return setState(() => _error = tr(context, 'Hãy xác nhận bạn hiểu cảnh báo.', 'Please confirm you understand the warning.'));
    }
    setState(() => _busy = true);
    await lock.service.enable(_pin1.text, maxAttempts: _attempts, lockAfterSeconds: _after);
    await lock.refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _disable() async {
    final lock = context.read<AppLockController>();
    final pin = _pin1.text;
    setState(() => _busy = true);
    final r = await lock.service.disable(pin);
    await lock.refresh();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pin1.clear();
      _error = r.status == UnlockStatus.wrong
          ? tr(context, 'Sai mã. Còn ${r.remaining} lần thử.', 'Wrong code. ${r.remaining} tries left.')
          : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = context.watch<AppLockController>().enabled;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Khóa ứng dụng', 'App lock'))),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          if (!enabled) ...[
            Text(
              tr(
                context,
                'Khi bật, mỗi lần mở app (hoặc quay lại sau một lúc) bạn phải nhập mã 6 số. '
                    'Nhập sai quá số lần cho phép, TOÀN BỘ dữ liệu của app trên máy này sẽ bị xóa '
                    '(tin nhắn, khóa chat, cài đặt) và bạn bị đăng xuất. Quên mã thì không khôi phục được, '
                    'trừ khi bạn đã sao lưu có mật khẩu.',
                'When on, you must enter a 6-digit code each time you open the app (or return after a while). '
                    'Too many wrong tries ERASE ALL app data on this device (messages, chat keys, settings) and sign you out. '
                    'A forgotten code cannot be recovered unless you made a password-protected backup.',
              ),
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _pin1,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              decoration: InputDecoration(labelText: tr(context, 'Mã 6 số', '6-digit code')),
            ),
            TextField(
              controller: _pin2,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              decoration: InputDecoration(labelText: tr(context, 'Nhập lại mã', 'Repeat the code')),
            ),
            const SizedBox(height: AppSpace.md),
            DropdownButtonFormField<int>(
              initialValue: _attempts,
              decoration: InputDecoration(labelText: tr(context, 'Số lần sai trước khi xóa', 'Wrong tries before erase')),
              items: [for (final n in AppLockService.allowedAttempts) DropdownMenuItem(value: n, child: Text('$n'))],
              onChanged: (v) => setState(() => _attempts = v ?? 3),
            ),
            DropdownButtonFormField<int>(
              initialValue: _after,
              decoration: InputDecoration(labelText: tr(context, 'Khóa lại sau khi ra nền', 'Lock after leaving the app')),
              items: [
                for (final s in const [0, 30, 60, 300])
                  DropdownMenuItem(value: s, child: Text(s == 0 ? tr(context, 'Ngay lập tức', 'Immediately') : '$s s')),
              ],
              onChanged: (v) => setState(() => _after = v ?? 30),
            ),
            CheckboxListTile(
              value: _ack,
              onChanged: (v) => setState(() => _ack = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: Text(tr(context, 'Tôi hiểu dữ liệu sẽ bị xóa vĩnh viễn nếu nhập sai.',
                  'I understand data is erased permanently after too many wrong tries.')),
            ),
            if (_error != null) Text(_error!, style: const TextStyle(color: AppColors.danger)),
            const SizedBox(height: AppSpace.md),
            FilledButton(
              onPressed: _busy ? null : _enable,
              child: Text(tr(context, 'Bật khóa ứng dụng', 'Turn on app lock')),
            ),
          ] else ...[
            Text(tr(context, 'Khóa ứng dụng đang BẬT. Nhập mã để tắt.', 'App lock is ON. Enter your code to turn it off.'),
                style: const TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: AppSpace.md),
            TextField(
              controller: _pin1,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              decoration: InputDecoration(labelText: tr(context, 'Mã hiện tại', 'Current code')),
            ),
            if (_error != null) Text(_error!, style: const TextStyle(color: AppColors.danger)),
            FutureBuilder<bool>(
              future: context.read<AppLockController>().biometricAvailable,
              builder: (context, snap) => snap.data == true
                  ? SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: context.watch<AppLockController>().biometricOn,
                      onChanged: (v) => context.read<AppLockController>().setBiometric(v),
                      title: Text(tr(context, 'Mở khóa bằng vân tay / khuôn mặt', 'Unlock with fingerprint / face')),
                      subtitle: Text(tr(context, 'PIN vẫn là đường dự phòng.', 'PIN remains the fallback.')),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: AppSpace.md),
            OutlinedButton(
              onPressed: _busy ? null : _disable,
              child: Text(tr(context, 'Tắt khóa ứng dụng', 'Turn off app lock')),
            ),
          ],
        ],
      ),
    );
  }
}
