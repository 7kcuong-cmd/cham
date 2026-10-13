import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/call_extras_controller.dart';
import '../theme/tokens.dart';

/// Bình luận nổi ở cột trái màn hình cuộc gọi (T-209): tối đa 70% chiều rộng, mỗi cái mờ dần
/// trong 300 ms cuối của 6 s. Bình luận của mình căn phải, nền `surfaceHigh`.
class CommentOverlay extends StatelessWidget {
  const CommentOverlay({super.key, this.maxHeight = 240});

  /// Chiều cao tối đa của cột (cái cũ nhất bị che khi tràn).
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final comments = context.select<CallExtrasController, List<ShownComment>>((c) => c.comments);
    if (comments.isEmpty) return const SizedBox.shrink();
    final maxWidth = MediaQuery.sizeOf(context).width * 0.7;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
      child: IgnorePointer(
        child: ListView(
          reverse: true,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (final shown in comments.reversed)
              Padding(
                key: ValueKey<String>(shown.comment.commentId),
                padding: const EdgeInsets.only(top: AppSpace.xs),
                child: Align(
                  alignment: shown.mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: CommentBubble(text: shown.comment.text, mine: shown.mine),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Một bong bóng bình luận; tự mờ dần ở cuối vòng đời [CallExtrasController.commentLifetime].
class CommentBubble extends StatefulWidget {
  const CommentBubble({super.key, required this.text, required this.mine});

  final String text;
  final bool mine;

  /// Thời gian mờ dần.
  static const Duration fade = Duration(milliseconds: 300);

  @override
  State<CommentBubble> createState() => _CommentBubbleState();
}

class _CommentBubbleState extends State<CommentBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _life;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    const total = CallExtrasController.commentLifetime;
    _life = AnimationController(vsync: this, duration: total)..forward();
    final fadeStart = (total - CommentBubble.fade).inMilliseconds / total.inMilliseconds;
    _opacity = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(parent: _life, curve: Interval(fadeStart, 1.0)),
    );
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
        decoration: BoxDecoration(
          color: widget.mine ? AppColors.surfaceHigh : AppColors.scrim,
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Text(widget.text, style: AppText.body.copyWith(color: AppColors.textPrimary)),
      ),
    );
  }
}
