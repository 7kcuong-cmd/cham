import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/safety_number.dart';
import '../state/chat_controller.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';

/// So khớp mã an toàn với một người bạn để chắc chắn không ai chen giữa tin nhắn mã hóa.
class SafetyNumberScreen extends StatefulWidget {
  const SafetyNumberScreen({super.key, required this.peerId, required this.peerName});

  final String peerId;
  final String peerName;

  @override
  State<SafetyNumberScreen> createState() => _SafetyNumberScreenState();
}

class _SafetyNumberScreenState extends State<SafetyNumberScreen> {
  String? _number;
  String? _peerKey;
  String? _verifiedKey;
  bool _failed = false;

  String get _prefKey => 'verified:${widget.peerId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final chat = context.read<ChatController>();
    final keys = await chat.keysFor(widget.peerId);
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    if (keys.peer == null) {
      return setState(() => _failed = true);
    }
    final n = await safetyNumber(keys.mine, keys.peer!);
    if (!mounted) return;
    setState(() {
      _number = n;
      _peerKey = keys.peer;
      _verifiedKey = prefs.getString(_prefKey);
    });
  }

  Future<void> _mark() async {
    final key = _peerKey;
    if (key == null) return;
    await (await SharedPreferences.getInstance()).setString(_prefKey, key);
    if (mounted) setState(() => _verifiedKey = key);
  }

  @override
  Widget build(BuildContext context) {
    final changed = _verifiedKey != null && _verifiedKey != _peerKey;
    final verified = _verifiedKey != null && _verifiedKey == _peerKey;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Mã an toàn', 'Safety number'))),
      body: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: _failed
            ? Text(tr(context, 'Chưa lấy được khóa của ${widget.peerName}. Thử lại khi có mạng.',
                'Could not get ${widget.peerName}\'s key. Try again when online.'))
            : _number == null
                ? const Center(child: CircularProgressIndicator())
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      tr(
                        context,
                        'Đọc dãy số này cho ${widget.peerName} (qua điện thoại hoặc gặp trực tiếp). Nếu hai bên giống hệt nhau, tin nhắn của hai bạn không bị ai chen giữa.',
                        'Read this number to ${widget.peerName} (by phone or in person). If both match exactly, nobody is intercepting your messages.',
                      ),
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    SelectableText(
                      _number!,
                      style: const TextStyle(color: AppColors.textPrimary, fontSize: 22, height: 1.6),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    if (changed)
                      Text(
                        tr(context, 'Khóa của người này đã THAY ĐỔI so với lần bạn xác minh. Hãy so khớp lại.',
                            'This person\'s key has CHANGED since you verified. Compare again.'),
                        style: const TextStyle(color: AppColors.danger),
                      ),
                    if (verified)
                      Text(tr(context, 'Đã xác minh.', 'Verified.'), style: const TextStyle(color: AppColors.primary)),
                    const SizedBox(height: AppSpace.md),
                    FilledButton(
                      onPressed: verified ? null : _mark,
                      child: Text(tr(context, 'Hai dãy số khớp nhau', 'The numbers match')),
                    ),
                  ]),
      ),
    );
  }
}
