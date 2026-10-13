import 'dart:math' as math;
import 'dart:ui';

/// Một lần đo khuôn mặt, toạ độ CHUẨN HOÁ 0..1 theo khung hình gốc ([imageAspect] = rộng/cao của khung đó).
/// Thuần Dart (không phụ thuộc ML Kit) nên gửi qua DataChannel và test được.
class FaceSample {
  const FaceSample({
    required this.center,
    required this.width,
    required this.height,
    required this.rollDeg,
    required this.imageAspect,
    this.leftEye,
    this.rightEye,
    this.nose,
    this.mouth,
  });

  /// Tâm hộp mặt.
  final Offset center;
  final double width;
  final double height;

  /// Nghiêng đầu (độ, dương = nghiêng ngược chiều kim đồng hồ khi nhìn ảnh).
  final double rollDeg;
  final double imageAspect;
  final Offset? leftEye;
  final Offset? rightEye;
  final Offset? nose;
  final Offset? mouth;

  static double _c(num v) => v.toDouble().clamp(0.0, 1.0);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'c': <double>[center.dx, center.dy],
        'w': width,
        'h': height,
        'r': rollDeg,
        'a': imageAspect,
        if (leftEye != null) 'le': <double>[leftEye!.dx, leftEye!.dy],
        if (rightEye != null) 're': <double>[rightEye!.dx, rightEye!.dy],
        if (nose != null) 'n': <double>[nose!.dx, nose!.dy],
        if (mouth != null) 'm': <double>[mouth!.dx, mouth!.dy],
      };

  static Offset? _pt(Object? v) {
    if (v is List && v.length == 2 && v[0] is num && v[1] is num) {
      return Offset(_c(v[0] as num), _c(v[1] as num));
    }
    return null;
  }

  /// Đọc dữ liệu từ đối phương: mọi giá trị bị chặn trong khoảng hợp lý; sai dạng → null.
  static FaceSample? fromJson(Object? j) {
    if (j is! Map) return null;
    final c = _pt(j['c']);
    final w = j['w'];
    final h = j['h'];
    final r = j['r'];
    final a = j['a'];
    if (c == null || w is! num || h is! num || r is! num || a is! num) return null;
    if (w.isNaN || h.isNaN || r.isNaN || a.isNaN) return null;
    return FaceSample(
      center: c,
      width: _c(w).clamp(0.02, 1.0).toDouble(),
      height: _c(h).clamp(0.02, 1.0).toDouble(),
      rollDeg: r.toDouble().clamp(-90.0, 90.0).toDouble(),
      imageAspect: a.toDouble().clamp(0.2, 5.0).toDouble(),
      leftEye: _pt(j['le']),
      rightEye: _pt(j['re']),
      nose: _pt(j['n']),
      mouth: _pt(j['m']),
    );
  }

  /// Nội suy (làm mượt giữa hai lần đo cách nhau vài trăm ms).
  static FaceSample lerp(FaceSample a, FaceSample b, double t) {
    Offset? o(Offset? x, Offset? y) => (x != null && y != null) ? Offset.lerp(x, y, t) : (y ?? x);
    return FaceSample(
      center: Offset.lerp(a.center, b.center, t)!,
      width: lerpDouble(a.width, b.width, t)!,
      height: lerpDouble(a.height, b.height, t)!,
      rollDeg: lerpDouble(a.rollDeg, b.rollDeg, t)!,
      imageAspect: b.imageAspect,
      leftEye: o(a.leftEye, b.leftEye),
      rightEye: o(a.rightEye, b.rightEye),
      nose: o(a.nose, b.nose),
      mouth: o(a.mouth, b.mouth),
    );
  }

  /// Lật ngang (xem trước camera trước được hiển thị đối xứng gương).
  FaceSample mirrored() {
    Offset? f(Offset? p) => p == null ? null : Offset(1 - p.dx, p.dy);
    return FaceSample(
      center: f(center)!,
      width: width,
      height: height,
      rollDeg: -rollDeg,
      imageAspect: imageAspect,
      leftEye: f(rightEye),
      rightEye: f(leftEye),
      nose: f(nose),
      mouth: f(mouth),
    );
  }

  /// Đổi toạ độ chuẩn hoá của khung hình sang toạ độ trong ô [view] khi video hiển thị kiểu `cover`.
  static Offset toView(Offset norm, Size view, double imageAspect) {
    final viewAspect = view.width / view.height;
    double sw, sh; // kích thước ảnh sau khi phóng
    if (viewAspect > imageAspect) {
      sw = view.width;
      sh = view.width / imageAspect;
    } else {
      sh = view.height;
      sw = view.height * imageAspect;
    }
    final dx = (view.width - sw) / 2;
    final dy = (view.height - sh) / 2;
    return Offset(dx + norm.dx * sw, dy + norm.dy * sh);
  }

  /// Kích thước ảnh phóng theo `cover` (để đổi độ rộng mặt chuẩn hoá ra điểm ảnh).
  static Size coverSize(Size view, double imageAspect) {
    final viewAspect = view.width / view.height;
    return viewAspect > imageAspect
        ? Size(view.width, view.width / imageAspect)
        : Size(view.height * imageAspect, view.height);
  }

  double get rollRad => rollDeg * math.pi / 180;
}
