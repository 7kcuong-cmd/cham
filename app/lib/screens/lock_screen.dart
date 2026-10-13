import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/app_lock_service.dart';
import '../state/app_lock_controller.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';

/// Màn nhập PIN che toàn bộ app khi khóa. Chỉ xuất hiện nếu người dùng đã bật khóa ứng dụng.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  bool _busy = false;
  String? _error;

  Future<void> _digit(String d) async {
    if (_busy || _pin.length >= 6) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == 6) {
      setState(() => _busy = true);
      final lock = context.read<AppLockController>();
      final r = await lock.unlock(_pin);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _pin = '';
        if (r.status == UnlockStatus.wrong) {
          _error = tr(
            context,
            'Sai mã. Còn ${r.remaining} lần thử, sai hết sẽ xóa toàn bộ dữ liệu trên máy.',
            'Wrong code. ${r.remaining} tries left before all data on this device is erased.',
          );
        }
      });
    }
  }

  void _back() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.bg,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock_rounded, color: AppColors.primary, size: 40),
                const SizedBox(height: AppSpace.lg),
                Text(tr(context, 'Nhập mã khóa ứng dụng', 'Enter app lock code'),
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 18)),
                const SizedBox(height: AppSpace.lg),
                if (context.watch<AppLockController>().biometricOn)
                  TextButton.icon(
                    onPressed: () => context.read<AppLockController>().tryBiometric(tr(context, 'Mở khóa Chạm', 'Unlock Chạm')),
                    icon: const Icon(Icons.fingerprint, color: AppColors.primary),
                    label: Text(tr(context, 'Dùng vân tay / khuôn mặt', 'Use fingerprint / face')),
                  ),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (var i = 0; i < 6; i++)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _pin.length ? AppColors.primary : AppColors.outline,
                      ),
                    ),
                ]),
                SizedBox(
                  height: 56,
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.md),
                    child: Text(_error ?? '',
                        textAlign: TextAlign.center, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
                  ),
                ),
                for (final row in const [
                  ['1', '2', '3'],
                  ['4', '5', '6'],
                  ['7', '8', '9'],
                  ['', '0', '<'],
                ])
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    for (final k in row)
                      Padding(
                        padding: const EdgeInsets.all(6),
                        child: SizedBox(
                          width: 72,
                          height: 72,
                          child: k.isEmpty
                              ? null
                              : TextButton(
                                  style: TextButton.styleFrom(
                                    shape: const CircleBorder(),
                                    backgroundColor: AppColors.surface,
                                  ),
                                  onPressed: () => k == '<' ? _back() : _digit(k),
                                  child: k == '<'
                                      ? const Icon(Icons.backspace_outlined, color: AppColors.textPrimary)
                                      : Text(k, style: const TextStyle(color: AppColors.textPrimary, fontSize: 24)),
                                ),
                        ),
                      ),
                  ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
