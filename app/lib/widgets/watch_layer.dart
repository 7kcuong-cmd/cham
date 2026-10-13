import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/watch_controller.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';
import 'media_picker_sheet.dart';

String watchNoticeText(BuildContext context, String code) => switch (code) {
      'WATCH_DECLINED' => tr(context, 'Bạn kia không muốn xem lúc này.', 'They declined to watch.'),
      'WATCH_NO_ANSWER' => tr(context, 'Bạn kia chưa trả lời.', 'No answer.'),
      'WATCH_STOPPED_BY_PEER' => tr(context, 'Bạn kia đã dừng xem chung.', 'They stopped watching together.'),
      'WATCH_ERROR' => tr(context, 'Không phát được. Thử tệp khác hoặc kiểm tra mạng.', 'Could not play. Try another file or check your network.'),
      'WATCH_PRIVACY' => tr(context, 'Đang bật chế độ riêng tư nên không chia sẻ tệp trực tiếp được.', 'Privacy mode is on, so direct sharing is unavailable.'),
      'WATCH_NO_CHANNEL' => tr(context, 'Chưa có kênh trực tiếp tới bạn kia (cuộc gọi đang đi vòng qua máy chủ).', 'No direct channel to your friend (the call is relayed).'),
      'WATCH_INCOMING' => tr(context, 'Bạn kia mời xem/nghe cùng. Chạm "Cùng xem" để đồng ý.', 'Invitation to watch/listen together. Tap Join to accept.'),
      'WATCH_BUSY' => tr(context, 'Đang xem chung rồi.', 'Already watching together.'),
      _ => tr(context, 'Có lỗi xảy ra.', 'Something went wrong.'),
    };

String _fmt(int ms) {
  final s = (ms ~/ 1000).clamp(0, 359999).toInt();
  final m = s ~/ 60;
  final r = s % 60;
  return '$m:${r.toString().padLeft(2, '0')}';
}

/// Hộp thoại lời mời nổi trên cùng mọi lớp (không bị video/nút che). Tự đóng khi lời mời kết thúc.
Future<void> showWatchInviteDialog(BuildContext context, String peerName) {
  final c = context.read<WatchTogetherController>();
  if (c.phase != WatchPhase.incoming) return Future<void>.value();
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => ChangeNotifierProvider<WatchTogetherController>.value(value: c, child: _InviteDialog(peerName: peerName)),
  );
}

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.peerName});
  final String peerName;

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  late final WatchTogetherController _c;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _c = context.read<WatchTogetherController>();
    _c.addListener(_check);
  }

  void _check() {
    if (_c.phase != WatchPhase.incoming) _close();
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  void dispose() {
    _c.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final o = _c.offer;
    final audio = o != null && o.audioOnly;
    return AlertDialog(
      title: Text(audio
          ? tr(context, '${widget.peerName} muốn nghe nhạc cùng bạn', '${widget.peerName} wants to listen with you')
          : tr(context, '${widget.peerName} muốn xem phim cùng bạn', '${widget.peerName} wants to watch with you')),
      content: Text(o?.name ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
      actions: [
        TextButton(
          onPressed: () {
            _c.decline();
            _close();
          },
          child: Text(tr(context, 'Từ chối', 'Decline')),
        ),
        FilledButton(
          onPressed: () {
            unawaited(_c.accept());
            _close();
          },
          child: Text(tr(context, 'Cùng xem', 'Join')),
        ),
      ],
    );
  }
}

/// Nút "Xem/nghe cùng nhau" (chỉ hiện trong cuộc gọi danh bạ).
class WatchStartButton extends StatelessWidget {
  const WatchStartButton({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<WatchTogetherController>();
    if (c.phase != WatchPhase.idle) return const SizedBox.shrink();
    return IconButton.filledTonal(
      tooltip: tr(context, 'Xem phim / nghe nhạc cùng nhau', 'Watch or listen together'),
      icon: const Icon(Icons.movie_filter_rounded),
      onPressed: () async {
        final err = await c.startOffer();
        if (err != null && context.mounted) {
          final m = ScaffoldMessenger.of(context);
          m.hideCurrentSnackBar();
          m.showSnackBar(SnackBar(content: Text(watchNoticeText(context, err))));
        }
      },
    );
  }
}

/// Lời mời, chờ trả lời và bảng phát chung. Không chặn thao tác khác khi không có phiên.
class WatchLayer extends StatelessWidget {
  const WatchLayer({super.key, required this.peerName});

  final String peerName;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<WatchTogetherController>();
    final top = MediaQuery.paddingOf(context).top + AppSpace.sm + AppSize.minTouch;
    final o = c.offer;
    Widget? child;
    switch (c.phase) {
      case WatchPhase.idle:
        break;
      case WatchPhase.offering:
        child = _Card(
          child: Row(children: [
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: AppSpace.md),
            Expanded(child: Text(tr(context, 'Đang chờ $peerName đồng ý…', 'Waiting for $peerName…'), style: AppText.label)),
            TextButton(onPressed: c.stop, child: Text(tr(context, 'Hủy', 'Cancel'))),
          ]),
        );
      case WatchPhase.incoming:
        child = _Card(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              o != null && o.audioOnly
                  ? tr(context, '$peerName muốn nghe nhạc cùng bạn', '$peerName wants to listen with you')
                  : tr(context, '$peerName muốn xem phim cùng bạn', '$peerName wants to watch with you'),
              style: AppText.label,
            ),
            const SizedBox(height: AppSpace.xs),
            Text(o?.name ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: AppSpace.sm),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: c.decline, child: Text(tr(context, 'Từ chối', 'Decline'))),
              FilledButton(onPressed: () => unawaited(c.accept()), child: Text(tr(context, 'Cùng xem', 'Join'))),
            ]),
          ]),
        );
      case WatchPhase.preparing:
        child = const _Card(child: Center(child: CircularProgressIndicator()));
      case WatchPhase.watching:
        if (o != null && !o.audioOnly) {
          // Video: hình phủ cả màn hình (WatchStage); ở đây chỉ còn thanh điều khiển ở dưới.
          return Positioned(
            left: AppSpace.lg,
            right: AppSpace.lg + AppSize.minTouch + AppSpace.sm,
            bottom: AppSpace.lg + AppSize.minTouch + AppSpace.sm,
            child: GestureDetector(
              onVerticalDragStart: (_) {},
              onVerticalDragUpdate: (_) {},
              child: _Bar(controller: c, showTitle: true),
            ),
          );
        }
        child = _Bar(controller: c, showTitle: true, music: true);
    }
    if (child == null) return const SizedBox.shrink();
    return Positioned(
      top: top + AppSpace.sm,
      left: AppSpace.lg,
      right: AppSpace.lg,
      // Nuốt kéo dọc để thao tác trên bảng không bị tính là vuốt đổi người / cúp máy.
      child: GestureDetector(onVerticalDragStart: (_) {}, onVerticalDragUpdate: (_) {}, child: child),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: child,
      );
}

/// Thanh điều khiển gọn: phát/dừng, thanh trượt thời gian, đóng. [music] = dạng máy nghe nhạc (có biểu tượng và tên bài).
class _Bar extends StatelessWidget {
  const _Bar({required this.controller, this.showTitle = true, this.music = false});

  final WatchTogetherController controller;
  final bool showTitle;
  final bool music;

  @override
  Widget build(BuildContext context) {
    final p = controller.player;
    final o = controller.offer;
    if (p == null || o == null) return const SizedBox.shrink();
    final dur = p.durationMs <= 0 ? 1 : p.durationMs;
    final pos = p.positionMs.clamp(0, dur).toInt();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs, vertical: AppSpace.xs),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (showTitle)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.sm, AppSpace.xs, AppSpace.sm, 0),
            child: Row(children: [
              if (music) const Icon(Icons.music_note_rounded, size: 16, color: Colors.white70),
              if (music) const SizedBox(width: AppSpace.xs),
              Expanded(
                child: Text(o.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: Colors.white70)),
              ),
            ]),
          ),
        Row(children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
            onPressed: () => unawaited(controller.togglePlay()),
          ),
          Text(_fmt(pos), style: AppText.caption.copyWith(color: Colors.white70)),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(trackHeight: 3, overlayShape: SliderComponentShape.noOverlay),
              child: Slider(
                value: pos.toDouble(),
                max: dur.toDouble(),
                onChanged: (v) => unawaited(controller.seekTo(v.round())),
              ),
            ),
          ),
          Text(_fmt(dur), style: AppText.caption.copyWith(color: Colors.white70)),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            tooltip: tr(context, 'Dừng', 'Stop'),
            onPressed: controller.stop,
          ),
        ]),
      ]),
    );
  }
}

/// Nền của màn gọi: bình thường là hình đối phương; khi đang xem VIDEO chung thì video phủ cả màn hình còn hình
/// đối phương thu nhỏ cạnh khung camera của mình. Khi nghe nhạc vẫn giữ hình đối phương (thanh nhạc nằm ở [WatchLayer]).
class WatchStage extends StatelessWidget {
  const WatchStage({super.key, required this.remote});

  /// Dựng hình đối phương (`CallService.remoteView`); chỉ dựng đúng một lần mỗi khung.
  final Widget Function() remote;

  @override
  Widget build(BuildContext context) {
    WatchTogetherController? c;
    try {
      c = context.watch<WatchTogetherController>();
    } on Object {
      return remote();
    }
    final o = c.offer;
    final p = c.player;
    if (c.phase != WatchPhase.watching || o == null || o.audioOnly || p == null) return remote();
    final padding = MediaQuery.paddingOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Colors.black, child: p.view(audioOnly: false)),
        Positioned(
          top: padding.top + AppSpace.sm + AppSize.minTouch + AppSpace.sm,
          right: AppSpace.lg + AppSize.selfViewWidth + AppSpace.sm,
          width: AppSize.selfViewWidth,
          height: AppSize.selfViewHeight,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: AppColors.outline),
            ),
            clipBehavior: Clip.antiAlias,
            child: remote(),
          ),
        ),
      ],
    );
  }
}

/// Hỏi chọn video hay nhạc rồi mở bộ chọn media của hệ thống (không cần duyệt cả thư mục).
Future<void> showWatchStartSheet(BuildContext context) async {
  final c = context.read<WatchTogetherController>();
  if (c.phase != WatchPhase.idle) return;
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: AppColors.surfaceHigh,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.movie_rounded),
          title: Text(tr(ctx, 'Xem video cùng nhau', 'Watch a video together')),
          subtitle: Text(tr(ctx, 'Chọn từ thư viện video', 'Pick from your videos')),
          onTap: () => Navigator.of(ctx).pop(false),
        ),
        ListTile(
          leading: const Icon(Icons.music_note_rounded),
          title: Text(tr(ctx, 'Nghe nhạc cùng nhau', 'Listen to music together')),
          subtitle: Text(tr(ctx, 'Chọn bài hát trên máy', 'Pick a song on your phone')),
          onTap: () => Navigator.of(ctx).pop(true),
        ),
      ]),
    ),
  );
  if (choice == null) return;
  // Bộ chọn trong app: không đưa app ra nền nên không rớt cuộc gọi. Không có quyền đọc media → dùng bộ chọn hệ thống (đã có cờ bảo vệ).
  if (!context.mounted) return;
  final res = await showMediaPicker(context, audio: choice);
  if (res is MediaPickCancelled) return;
  final err = await c.startOffer(audio: choice, picked: res is MediaPicked ? res.media : null);
  if (err != null && context.mounted) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(watchNoticeText(context, err))));
  }
}
