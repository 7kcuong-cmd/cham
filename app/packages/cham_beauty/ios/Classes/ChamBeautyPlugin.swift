import Flutter
import UIKit
import CoreVideo
import flutter_webrtc
import WebRTC

/// Làm mịn da trên iOS: đăng ký bộ xử lý khung hình "cham_beauty" với flutter_webrtc (cùng tên và kênh với bản Android).
/// Dart bật bằng track.setVideoEffects(["cham_beauty"]) và chỉnh mức bằng MethodChannel "cham/beauty" -> setLevel.
/// Thuật toán giống SkinSmoother.kt: trộn mặt phẳng sáng (Y) với bản làm mờ hộp ở vùng có sắc độ giống da, giữ cạnh.
/// CHƯA THỬ TRÊN MÁY THẬT: tên giao thức/phương thức của flutter_webrtc (ExternalVideoProcessingDelegate.onFrameReceived,
/// ProcessorProvider.addProcessor) cần đối chiếu theo phiên bản.
public class ChamBeautyPlugin: NSObject, FlutterPlugin {
  static var level: Int = 0
  static let effect = "cham_beauty"
  static let processor = BeautyProcessor()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "cham/beauty", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ChamBeautyPlugin(), channel: channel)
    ProcessorProvider.addProcessor(processor, forName: effect)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "setLevel" {
      let args = call.arguments as? [String: Any]
      ChamBeautyPlugin.level = max(0, min(100, (args?["level"] as? Int) ?? 0))
      result(nil)
    } else {
      result(FlutterMethodNotImplemented)
    }
  }
}

public class BeautyProcessor: NSObject, ExternalVideoProcessingDelegate {
  private var integral = [UInt32]()

  public func onFrameReceived(_ frame: RTCVideoFrame!) -> RTCVideoFrame! {
    let lv = ChamBeautyPlugin.level
    guard lv > 0, let frame = frame,
          let buf = frame.buffer as? RTCCVPixelBuffer else { return frame }
    let src = buf.pixelBuffer
    let fmt = CVPixelBufferGetPixelFormatType(src)
    guard fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
       || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return frame }

    let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
    if w < 16 || h < 16 { return frame }
    var dstOpt: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
    guard CVPixelBufferCreate(nil, w, h, fmt, attrs as CFDictionary, &dstOpt) == kCVReturnSuccess,
          let dst = dstOpt else { return frame }

    CVPixelBufferLockBaseAddress(src, .readOnly)
    CVPixelBufferLockBaseAddress(dst, [])
    defer {
      CVPixelBufferUnlockBaseAddress(dst, [])
      CVPixelBufferUnlockBaseAddress(src, .readOnly)
    }
    // Chép nguyên hai mặt phẳng rồi chỉ sửa Y.
    for p in 0..<2 {
      guard let s = CVPixelBufferGetBaseAddressOfPlane(src, p),
            let d = CVPixelBufferGetBaseAddressOfPlane(dst, p) else { return frame }
      let rows = CVPixelBufferGetHeightOfPlane(src, p)
      let sStride = CVPixelBufferGetBytesPerRowOfPlane(src, p)
      let dStride = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
      let n = min(sStride, dStride)
      for r in 0..<rows { memcpy(d + r * dStride, s + r * sStride, n) }
    }
    guard let yS = CVPixelBufferGetBaseAddressOfPlane(src, 0)?.assumingMemoryBound(to: UInt8.self),
          let cS = CVPixelBufferGetBaseAddressOfPlane(src, 1)?.assumingMemoryBound(to: UInt8.self),
          let yD = CVPixelBufferGetBaseAddressOfPlane(dst, 0)?.assumingMemoryBound(to: UInt8.self)
    else { return frame }
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(src, 0)
    let cStride = CVPixelBufferGetBytesPerRowOfPlane(src, 1)
    let yDStride = CVPixelBufferGetBytesPerRowOfPlane(dst, 0)

    // Ảnh tích phân của Y.
    let iw = w + 1
    if integral.count < iw * (h + 1) { integral = [UInt32](repeating: 0, count: iw * (h + 1)) }
    for x in 0..<iw { integral[x] = 0 }
    for y in 1...h {
      var row: UInt32 = 0
      integral[y * iw] = 0
      for x in 1...w {
        row += UInt32(yS[(y - 1) * yStride + (x - 1)])
        integral[y * iw + x] = integral[(y - 1) * iw + x] + row
      }
    }
    let radius = max(2, w / 120)
    let strength = Float(lv) / 100.0 * 0.85
    let edge: Float = 28
    for y in 0..<h {
      let y0 = max(0, y - radius), y1 = min(h - 1, y + radius)
      let cRow = (y >> 1) * cStride
      for x in 0..<w {
        let luma = Int(yS[y * yStride + x])
        let cb = Int(cS[cRow + (x >> 1) * 2])
        let cr = Int(cS[cRow + (x >> 1) * 2 + 1])
        if !(luma >= 40 && luma <= 240 && cb >= 77 && cb <= 127 && cr >= 133 && cr <= 173) { continue }
        let x0 = max(0, x - radius), x1 = min(w - 1, x + radius)
        let area = Float((x1 - x0 + 1) * (y1 - y0 + 1))
        let sum = Int64(integral[(y1 + 1) * iw + (x1 + 1)]) - Int64(integral[y0 * iw + (x1 + 1)])
          - Int64(integral[(y1 + 1) * iw + x0]) + Int64(integral[y0 * iw + x0])
        let blur = Float(sum) / area
        let diff = abs(Float(luma) - blur)
        let keep = 1 - min(1, diff / edge)
        let v = Float(luma) + strength * keep * (blur - Float(luma))
        yD[y * yDStride + x] = UInt8(max(0, min(255, v)))
      }
    }
    return RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: dst), rotation: frame.rotation, timeStampNs: frame.timeStampNs)
  }
}
