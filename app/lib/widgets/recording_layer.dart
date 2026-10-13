import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/face_sample.dart';
import '../services/call_service.dart';
import '../services/face_tracker.dart';
import '../services/recording_privacy.dart';
import '../state/face_mask_controller.dart' show FaceDetectFn;
import '../state/recording_controller.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../theme/tokens.dart';
import 'brand_mark.dart';
import '../utils/tr.dart';

/// Lớp ghi hình trong màn cuộc gọi: chấm REC, hộp thoại xin phép, thông báo kết quả.
/// Nếu app không có [RecordingController] (test cũ) thì không hiện gì.
class RecordingLayer extends StatelessWidget {
  const RecordingLayer({super.key, required this.peerName});

  final String peerName;

  @override
  Widget build(BuildContext context) {
    RecordingController? rec;
    try {
      rec = context.watch<RecordingController>();
    } on Object {
      return const SizedBox.shrink();
    }
    final children = <Widget>[];
    if (rec.iAmRecording) {
      // Logo Chạm góc dưới phải: nằm trên màn hình nên được ghi vào clip.
      children.add(const Positioned(right: AppSpace.lg, bottom: AppSpace.lg, child: IgnorePointer(child: _Watermark())));
    }
    // Người ghi: giao diện bị ẩn để clip chỉ có cửa sổ gọi (dừng bằng thông báo hệ thống). Người BỊ ghi vẫn thấy chấm REC.
    if (rec.isRecording && !rec.iAmRecording) {
      children.add(Positioned(
        top: MediaQuery.paddingOf(context).top + 8,
        left: 0,
        right: 0,
        child: Center(child: _RecBadge(onStop: rec.stop)),
      ));
    }
    if (rec.state == RecState.asking) {
      children.add(Positioned.fill(child: _AskDialog(rec: rec, peerName: peerName)));
    }
    final clip = rec.lastClipPath;
    if (clip != null) {
      children.add(Positioned(
        bottom: 200,
        left: AppSpace.lg,
        right: AppSpace.lg,
        child: _ClipBar(
          shareable: rec.lastClipShareable,
          onShare: () => Share.shareXFiles([XFile(clip)]),
          onClose: rec.clearLastClip,
        ),
      ));
    }
    final notice = rec.notice;
    if (notice != null) {
      children.add(Positioned(
        bottom: 140,
        left: AppSpace.lg,
        right: AppSpace.lg,
        child: _Notice(text: _noticeText(context, notice), onClose: rec.clearNotice),
      ));
    }
    return Stack(children: children);
  }

  /// Chọn mục đích ghi (riêng tư: chỉ lưu; công khai: được chia sẻ) rồi xin phép người kia.
  static Future<void> choose(BuildContext context, RecordingController rec) async {
    final p = await showModalBottomSheet<RecPurpose>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(tr(c, 'Ghi để lưu riêng', 'Record for myself')),
            onTap: () => Navigator.pop(c, RecPurpose.private),
          ),
          ListTile(
            title: Text(tr(c, 'Ghi để chia sẻ công khai', 'Record to share publicly')),
            onTap: () => Navigator.pop(c, RecPurpose.public),
          ),
        ]),
      ),
    );
    if (p != null) rec.request(p);
  }

  static String _noticeText(BuildContext c, String code) => switch (code) {
        'rec_denied' => tr(c, 'Người kia không đồng ý ghi hình.', 'The other person declined recording.'),
        'rec_timeout' => tr(c, 'Người kia chưa trả lời.', 'No answer from the other person.'),
        'rec_ended' => tr(c, 'Đã dừng ghi hình.', 'Recording stopped.'),
        'rec_unsupported' => tr(c, 'Thiết bị chưa hỗ trợ ghi hình.', 'Recording is not supported on this device.'),
        _ => tr(c, 'Không ghi hình được.', 'Could not record.'),
      };
}

class _RecBadge extends StatelessWidget {
  const _RecBadge({required this.onStop});

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onStop,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: AppColors.scrim, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.fiber_manual_record, color: AppColors.danger, size: 14),
          const SizedBox(width: 6),
          Text(tr(context, 'Đang ghi hình – chạm để dừng', 'Recording – tap to stop'),
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 13)),
        ]),
      ),
    );
  }
}

class _AskDialog extends StatelessWidget {
  const _AskDialog({required this.rec, required this.peerName});

  final RecordingController rec;
  final String peerName;

  @override
  Widget build(BuildContext context) {
    final isPublic = rec.purpose == RecPurpose.public;
    final why = isPublic
        ? tr(context, 'chia sẻ công khai', 'share publicly')
        : tr(context, 'lưu riêng trên máy của họ', 'keep privately on their device');
    return ColoredBox(
      color: AppColors.scrim,
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(AppSpace.lg),
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(16)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              tr(
                context,
                '$peerName muốn ghi hình cuộc gọi này để $why. Chỉ ghi khi bạn đồng ý. Bạn có thể dừng bất cứ lúc nào.',
                '$peerName wants to record this call to $why. Recording only starts if you agree. You can stop any time.',
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 16),
            ),
            const SizedBox(height: AppSpace.lg),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => rec.respond(accept: false),
                  child: Text(tr(context, 'Từ chối', 'Decline')),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: FilledButton(
                  onPressed: () => rec.respond(accept: true),
                  child: Text(tr(context, 'Đồng ý', 'Agree')),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.onClose});

  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onClose,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(12)),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textPrimary)),
      ),
    );
  }
}

/// Nút ghi hình ở cột nút mép phải (dưới hàng tim). Ẩn khi chưa ghi được (hoặc app không có [RecordingController]).
class RecordEdgeButton extends StatelessWidget {
  const RecordEdgeButton({super.key});

  @override
  Widget build(BuildContext context) {
    RecordingController? rec;
    try {
      rec = context.watch<RecordingController>();
    } on Object {
      return const SizedBox.shrink();
    }
    if (!rec.canRequest) return const SizedBox.shrink();
    final r = rec;
    return Semantics(
      button: true,
      label: tr(context, 'Ghi hình', 'Record'),
      child: Tooltip(
        message: tr(context, 'Ghi hình', 'Record'),
        child: SizedBox(
          width: AppSize.minTouch,
          height: AppSize.minTouch,
          child: InkResponse(
            onTap: () => RecordingLayer.choose(context, r),
            radius: AppSize.minTouch / 2,
            child: Center(
              child: Container(
                width: AppSize.edgeButton,
                height: AppSize.edgeButton,
                decoration: BoxDecoration(
                  color: AppColors.scrim,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.danger.withValues(alpha: 0.7), width: 1.5),
                ),
                child: const Icon(Icons.fiber_manual_record, size: 20, color: AppColors.danger),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ClipBar extends StatelessWidget {
  const _ClipBar({required this.shareable, required this.onShare, required this.onClose});

  final bool shareable;
  final VoidCallback onShare;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
        child: Row(children: [
          Expanded(child: Text(tr(context, 'Đã lưu bản ghi', 'Recording saved'), style: AppText.caption)),
          if (shareable) TextButton(onPressed: onShare, child: Text(tr(context, 'Chia sẻ', 'Share'))),
          IconButton(onPressed: onClose, icon: const Icon(Icons.close), tooltip: tr(context, 'Đóng', 'Close')),
        ]),
      ),
    );
  }
}

/// Khi MÌNH đang ghi: che mặt người đối diện bằng ô pixel (mosaic) để bảo vệ danh tính họ trong clip.
/// Tùy chọn ở Cài đặt ([RecordingPrivacy.blurPeerFace], mặc định bật). Mặt được tìm trên máy (ML Kit) ~4 lần/giây.
/// AN TOÀN KHI LỖI: chưa thấy mặt, nhận diện lỗi hoặc dữ liệu cũ hơn [freshFor] → làm mờ TOÀN BỘ khung hình, không để lộ mặt.
/// Không có [RecordingController] (test cũ) thì giữ nguyên.
class RecordingBlur extends StatefulWidget {
  const RecordingBlur({super.key, required this.child, this.detect});

  final Widget child;

  /// Bộ nhận diện thay thế (test). Mặc định ML Kit qua [FaceTracker].
  final FaceDetectFn? detect;

  static const double sigma = 28;
  static const Duration every = Duration(milliseconds: 250);
  static const Duration freshFor = Duration(milliseconds: 900);

  /// Vùng che = cạnh hộp mặt nhân hệ số này (dư để khi quay đầu nhanh mặt vẫn nằm trong ô).
  static const double padding = 1.8;

  /// Số ô mỗi cạnh của mosaic.
  static const int cells = 8;

  @override
  State<RecordingBlur> createState() => _RecordingBlurState();
}

class _Mosaic {
  _Mosaic(this.tiny, this.center, this.w, this.h, this.aspect);
  final ui.Image tiny;
  final Offset center; // chuẩn hoá 0..1
  final double w; // chuẩn hoá theo bề rộng ảnh
  final double h; // chuẩn hoá theo chiều cao ảnh
  final double aspect;
}

class _RecordingBlurState extends State<RecordingBlur> {
  Timer? _timer;
  bool _busy = false;
  FaceTracker? _tracker;
  _Mosaic? _mosaic;
  DateTime? _at;

  bool get _fresh => _mosaic != null && _at != null && DateTime.now().difference(_at!) < RecordingBlur.freshFor;

  void _sync(bool shield) {
    if (!mounted) return;
    if (shield && _timer == null) {
      _timer = Timer.periodic(RecordingBlur.every, (_) => unawaited(_tick()));
      unawaited(_tick());
    } else if (!shield && _timer != null) {
      _timer!.cancel();
      _timer = null;
      _setMosaic(null);
    }
  }

  void _setMosaic(_Mosaic? m) {
    _mosaic?.tiny.dispose();
    _mosaic = m;
    _at = m == null ? null : DateTime.now();
  }

  Future<void> _tick() async {
    if (_busy || !mounted) return;
    _busy = true;
    try {
      FaceDetectFn? detect = widget.detect;
      final cam = context.read<CallService>();
      if (cam is! FrameCapturable) {
        _refresh(null);
        return;
      }
      final img = await (cam as FrameCapturable).captureRemoteFrame();
      if (img == null) {
        _refresh(null);
        return;
      }
      detect ??= (_tracker ??= FaceTracker()).detect;
      final face = await detect(img);
      _refresh(face == null ? null : await _buildMosaic(img, face));
    } on Object catch (e) {
      debugPrint('recording face shield: $e');
      _refresh(null);
    } finally {
      _busy = false;
    }
  }

  void _refresh(_Mosaic? m) {
    if (!mounted) {
      m?.tiny.dispose();
      return;
    }
    setState(() => _setMosaic(m));
  }

  /// Thu nhỏ vùng mặt qua vài bước (trung bình màu từng ô) rồi để painter phóng to không làm mượt → ô vuông pixel.
  static Future<_Mosaic> _buildMosaic(Uint8List png, FaceSample f) async {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    var img = frame.image;
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    final side = math.max(f.width * iw, f.height * ih) * RecordingBlur.padding;
    var src = Rect.fromCenter(center: Offset(f.center.dx * iw, f.center.dy * ih), width: side, height: side);
    for (final n in <int>[64, 16, RecordingBlur.cells]) {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawImageRect(img, src, Rect.fromLTWH(0, 0, n.toDouble(), n.toDouble()), Paint()..filterQuality = FilterQuality.medium);
      final next = await rec.endRecording().toImage(n, n);
      img.dispose();
      img = next;
      src = Rect.fromLTWH(0, 0, n.toDouble(), n.toDouble());
    }
    codec.dispose();
    return _Mosaic(img, f.center, side / iw, side / ih, iw / ih);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _mosaic?.tiny.dispose();
    unawaited(_tracker?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    RecordingController? rec;
    try {
      rec = context.watch<RecordingController>();
    } on Object {
      return widget.child;
    }
    final r = rec;
    return ListenableBuilder(
      listenable: RecordingPrivacy.instance,
      builder: (context, _) {
        final shield = r.iAmRecording && RecordingPrivacy.instance.blurPeerFace;
        WidgetsBinding.instance.addPostFrameCallback((_) => _sync(shield));
        if (!shield) return widget.child;
        final m = _mosaic;
        if (!_fresh || m == null) {
          // Chưa chắc vị trí mặt → che cả khung hình (an toàn).
          return ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: RecordingBlur.sigma, sigmaY: RecordingBlur.sigma, tileMode: TileMode.clamp),
            child: widget.child,
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            CustomPaint(painter: _MosaicPainter(m)),
          ],
        );
      },
    );
  }
}

class _MosaicPainter extends CustomPainter {
  _MosaicPainter(this.m);
  final _Mosaic m;

  @override
  void paint(Canvas canvas, Size size) {
    final cover = FaceSample.coverSize(size, m.aspect);
    final c = FaceSample.toView(m.center, size, m.aspect);
    final dst = Rect.fromCenter(center: c, width: m.w * cover.width, height: m.h * cover.height);
    canvas.save();
    canvas.clipPath(Path()..addOval(dst));
    canvas.drawImageRect(
      m.tiny,
      Rect.fromLTWH(0, 0, m.tiny.width.toDouble(), m.tiny.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.none,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MosaicPainter old) => old.m != m;
}

class _Watermark extends StatelessWidget {
  const _Watermark();

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.85,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const BrandMark(size: 32),
        const SizedBox(width: AppSpace.xs),
        Text('Chạm', style: AppText.label.copyWith(color: Colors.white, shadows: const [Shadow(blurRadius: 4)])),
      ]),
    );
  }
}
