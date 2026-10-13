import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state/call_extras_controller.dart';
import '../theme/tokens.dart';

/// Mở ô nhập bình luận dạng bottom sheet nổi (video phía sau không co lại, T-209).
Future<void> showCommentInput(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    barrierColor: Colors.transparent,
    builder: (_) => const CommentInput(),
  );
}

/// Thanh nhập bình luận: tối đa 200 ký tự (đếm theo `TextField.maxLength`), nút gửi `primary`.
class CommentInput extends StatefulWidget {
  const CommentInput({super.key});

  /// Khớp `COMMENT_MAX_CHARS` mặc định của server (API-GD2-4 §7); server vẫn là nơi kiểm.
  static const int maxLength = 200;

  @override
  State<CommentInput> createState() => _CommentInputState();
}

class _CommentInputState extends State<CommentInput> {
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _send() {
    final sent = context.read<CallExtrasController>().sendComment(_text.text);
    if (sent) {
      _text.clear();
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.sm, AppSpace.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  autofocus: true,
                  maxLength: CommentInput.maxLength,
                  maxLines: 1,
                  style: AppText.body,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(hintText: l10n.commentHint),
                ),
              ),
              const SizedBox(width: AppSpace.xs),
              SizedBox(
                width: AppSize.minTouch,
                height: AppSize.minTouch,
                child: IconButton(
                  tooltip: l10n.commentSend,
                  onPressed: _send,
                  icon: const Icon(Icons.send_rounded, color: AppColors.primary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
