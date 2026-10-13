import 'dart:async';

import 'package:flutter/material.dart';
import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import '../services/media_pick_guard.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:provider/provider.dart';

import '../models/chat_message.dart';
import '../state/chat_controller.dart';
import '../state/contacts_controller.dart';
import '../theme/tokens.dart';
import 'safety_number_screen.dart';
import '../utils/tr.dart';
import '../widgets/user_avatar.dart';

/// Màn hình nhắn tin với một người bạn. Lịch sử lưu trên máy; tin được mã hóa đầu cuối.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.peerId, required this.peerName});

  final String peerId;
  final String peerName;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  late final ChatController _chat;

  @override
  void initState() {
    super.initState();
    _chat = context.read<ChatController>();
    unawaited(_chat.open(widget.peerId));
  }

  @override
  void dispose() {
    _chat.close(widget.peerId);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    await _chat.send(widget.peerId, text);
    if (_scroll.hasClients) {
      unawaited(_scroll.animateTo(0, duration: const Duration(milliseconds: 150), curve: Curves.easeOut));
    }
  }

  void _onBubbleTap(ChatMessage m) {
    if (m.mine && m.status == ChatStatus.failed) {
      unawaited(_chat.retry(m.id, widget.peerId));
    } else {
      unawaited(_openFile(m));
    }
  }

  Future<void> _pickAndSend() async {
    final res = await MediaPickGuard.run(() => FilePicker.platform.pickFiles(withData: true));
    final f = res?.files.single;
    final bytes = f?.bytes;
    if (f == null || bytes == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(tr(context, 'Đang gửi "${f.name}"… người kia cần đồng ý.', 'Sending "${f.name}"… the other person must accept.'))));
    final err = await _chat.sendFile(widget.peerId, f.name, bytes);
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    final text = switch (err) {
      null => tr(context, 'Đã gửi tệp.', 'File sent.'),
      'too_big' => tr(context, 'Tệp quá lớn (tối đa 25 MB).', 'File too large (max 25 MB).'),
      'offline' => tr(context, 'Chỉ gửi tệp được khi cả hai cùng online (và không bật chế độ riêng tư).', 'Files can only be sent when both are online (and privacy mode is off).'),
      'declined' => tr(context, 'Người kia từ chối nhận tệp.', 'The other person declined the file.'),
      'timeout' => tr(context, 'Người kia chưa trả lời.', 'No response from the other person.'),
      _ => tr(context, 'Gửi tệp thất bại.', 'File transfer failed.'),
    };
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openFile(ChatMessage m) async {
    final path = await _chat.filePathOf(m);
    if (path == null || !mounted) return;
    if (!File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'Tệp không còn trên máy này.', 'The file is no longer on this device.'))));
      return;
    }
    await Share.shareXFiles([XFile(path)]);
  }

  /// Nhấn giữ một tin: sao chép hoặc chuyển tiếp cho bạn bè khác.
  Future<void> _actions(ChatMessage m) async {
    final act = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.copy),
            title: Text(tr(c, 'Sao chép', 'Copy')),
            onTap: () => Navigator.pop(c, 'copy'),
          ),
          ListTile(
            leading: const Icon(Icons.forward),
            title: Text(tr(c, 'Chuyển tiếp', 'Forward')),
            onTap: () => Navigator.pop(c, 'forward'),
          ),
        ]),
      ),
    );
    if (!mounted || act == null) return;
    if (act == 'copy') {
      await Clipboard.setData(ClipboardData(text: m.text));
      return;
    }
    List<dynamic> contacts;
    try {
      contacts = context.read<ContactsController>().contacts.where((c) => c.id != widget.peerId).toList();
    } on Object {
      contacts = const <dynamic>[];
    }
    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'Chưa có bạn bè khác để chuyển tiếp.', 'No other friends to forward to.'))));
      return;
    }
    final target = await showModalBottomSheet<dynamic>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final f in contacts)
            ListTile(
              leading: UserAvatar(userId: f.id as String, name: f.displayName as String, size: 32),
              title: Text(f.displayName as String),
              onTap: () => Navigator.pop(c, f),
            ),
        ]),
      ),
    );
    if (!mounted || target == null) return;
    await _chat.send(target.id as String, m.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'Đã chuyển tiếp cho ${target.displayName}', 'Forwarded to ${target.displayName}'))));
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final msgs = chat.thread(widget.peerId).reversed.toList();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        actions: [
          IconButton(
            tooltip: tr(context, 'Mã an toàn', 'Safety number'),
            icon: const Icon(Icons.verified_user_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => SafetyNumberScreen(peerId: widget.peerId, peerName: widget.peerName),
            )),
          ),
        ],
        title: Row(
          children: [
            UserAvatar(userId: widget.peerId, name: widget.peerName, size: 32),
            const SizedBox(width: AppSpace.md),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.peerName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
                  if (chat.isTyping(widget.peerId))
                    Text(tr(context, 'đang nhập…', 'typing…'), style: AppText.caption.copyWith(color: AppColors.primary)),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
            decoration: BoxDecoration(
              color: AppColors.surfaceHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.lock_rounded, size: 16, color: AppColors.textSecondary),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    tr(
                      context,
                      'Đã bật mã hóa đầu cuối giữa hai bạn. Tin chỉ lưu trên máy; người nhận offline sẽ nhận khi mở app (tối đa 7 ngày).',
                      'End-to-end encryption is on between you two. Messages are stored only on your device; an offline recipient gets them when they open the app (up to 7 days).',
                    ),
                    style: AppText.caption,
                  ),
                ),
              ],
            ),
          ),
          for (final o in chat.offersFrom(widget.peerId))
            Container(
              margin: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.xs),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
              decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(AppRadius.pill)),
              child: Row(children: [
                Expanded(child: Text('${o.name} (${(o.size / 1024).ceil()} KB)', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption)),
                TextButton(onPressed: () => _chat.declineOffer(o.id), child: Text(tr(context, 'Từ chối', 'Decline'))),
                TextButton(onPressed: () => _chat.acceptOffer(o.id), child: Text(tr(context, 'Nhận', 'Accept'))),
              ]),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              reverse: true,
              padding: const EdgeInsets.all(AppSpace.md),
              itemCount: msgs.length,
              itemBuilder: (_, i) => _Bubble(msg: msgs[i], onLongPress: () => unawaited(_actions(msgs[i])), onTap: () => _onBubbleTap(msgs[i])),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.sm, AppSpace.md, AppSpace.sm),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => unawaited(_pickAndSend()),
                    icon: const Icon(Icons.attach_file),
                    tooltip: tr(context, 'Gửi tệp', 'Send file'),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      maxLength: ChatController.maxChars,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => unawaited(_send()),
                      onChanged: (v) {
                        if (v.isNotEmpty) _chat.notifyTyping(widget.peerId);
                      },
                      style: AppText.body,
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: tr(context, 'Nhắn tin…', 'Message…'),
                        filled: true,
                        fillColor: AppColors.surfaceHigh,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.sm),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  IconButton.filled(
                    onPressed: () => unawaited(_send()),
                    icon: const Icon(Icons.send_rounded),
                    tooltip: tr(context, 'Gửi', 'Send'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.msg, required this.onLongPress, required this.onTap});

  final ChatMessage msg;
  final VoidCallback onLongPress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mine = msg.mine;
    final status = switch (msg.status) {
      ChatStatus.sending => tr(context, 'đang gửi…', 'sending…'),
      ChatStatus.sent => tr(context, 'đã gửi', 'sent'),
      ChatStatus.read => tr(context, 'đã đọc', 'read'),
      ChatStatus.failed => tr(context, 'chưa gửi được · chạm để gửi lại', 'not sent · tap to retry'),
      ChatStatus.received => '',
    };
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        onTap: onTap,
        child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          gradient: mine ? AppGradients.brand : null,
          color: mine ? null : AppColors.bubbleOther,
          // Góc phía người nói nhỏ lại để bong bóng có "đuôi" như ứng dụng nhắn tin quen thuộc.
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(AppRadius.sheet),
            topRight: const Radius.circular(AppRadius.sheet),
            bottomLeft: Radius.circular(mine ? AppRadius.sheet : 4),
            bottomRight: Radius.circular(mine ? 4 : AppRadius.sheet),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(msg.text, style: AppText.body.copyWith(color: mine ? AppColors.onPrimary : AppColors.textPrimary)),
            if (mine && status.isNotEmpty)
              Text(status, style: AppText.caption.copyWith(color: AppColors.onPrimary.withValues(alpha: 0.7))),
          ],
        ),
      ),
      ),
    );
  }
}
