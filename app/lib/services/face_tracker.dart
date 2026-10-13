import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../models/face_sample.dart';

/// Đọc kích thước ảnh PNG/JPEG từ phần đầu tệp (rẻ hơn giải mã cả ảnh). null nếu không nhận ra định dạng.
Size? imageSizeOf(Uint8List b) {
  if (b.length > 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    final bd = ByteData.sublistView(b);
    return Size(bd.getUint32(16).toDouble(), bd.getUint32(20).toDouble());
  }
  if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final m = b[i + 1];
      if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
        return Size(((b[i + 7] << 8) | b[i + 8]).toDouble(), ((b[i + 5] << 8) | b[i + 6]).toDouble());
      }
      i += 2 + ((b[i + 2] << 8) | b[i + 3]);
    }
  }
  return null;
}

/// Tìm khuôn mặt (Google ML Kit, chạy trên máy) trong ảnh chụp từ camera cuộc gọi.
class FaceTracker {
  FaceTracker()
      : _detector = FaceDetector(
          options: FaceDetectorOptions(
            performanceMode: FaceDetectorMode.fast,
            enableLandmarks: true,
            enableClassification: false,
            enableTracking: false,
            minFaceSize: 0.15,
          ),
        );

  final FaceDetector _detector;
  File? _tmp;

  /// [image] = PNG/JPEG. Trả mặt lớn nhất, hoặc null nếu không thấy / lỗi.
  Future<FaceSample?> detect(Uint8List image) async {
    final size = imageSizeOf(image);
    if (size == null || size.width <= 0 || size.height <= 0) return null;
    try {
      final f = _tmp ??= File('${Directory.systemTemp.path}/cham_face_probe.img');
      await f.writeAsBytes(image, flush: false);
      final faces = await _detector.processImage(InputImage.fromFilePath(f.path));
      if (faces.isEmpty) return null;
      faces.sort((a, b) => (b.boundingBox.width * b.boundingBox.height).compareTo(a.boundingBox.width * a.boundingBox.height));
      final face = faces.first;
      Offset? lm(FaceLandmarkType t) {
        final p = face.landmarks[t]?.position;
        return p == null ? null : Offset((p.x / size.width).clamp(0.0, 1.0).toDouble(), (p.y / size.height).clamp(0.0, 1.0).toDouble());
      }

      final r = face.boundingBox;
      return FaceSample(
        center: Offset((r.center.dx / size.width).clamp(0.0, 1.0).toDouble(), (r.center.dy / size.height).clamp(0.0, 1.0).toDouble()),
        width: (r.width / size.width).clamp(0.02, 1.0).toDouble(),
        height: (r.height / size.height).clamp(0.02, 1.0).toDouble(),
        rollDeg: (face.headEulerAngleZ ?? 0).clamp(-90.0, 90.0).toDouble(),
        imageAspect: size.width / size.height,
        leftEye: lm(FaceLandmarkType.leftEye),
        rightEye: lm(FaceLandmarkType.rightEye),
        nose: lm(FaceLandmarkType.noseBase),
        mouth: lm(FaceLandmarkType.bottomMouth),
      );
    } on Object catch (e) {
      debugPrint('face detect ignored: $e');
      return null;
    }
  }

  Future<void> dispose() async {
    try {
      await _detector.close();
    } on Object {
      // bỏ qua
    }
  }
}
