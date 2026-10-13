import Flutter
import ReplayKit

/// Ghi lại màn hình CỦA CHÍNH APP bằng RPScreenRecorder (iOS 14+ để lưu thẳng ra tệp). CHƯA THỬ TRÊN MÁY THẬT.
public class ChamRecorderPlugin: NSObject, FlutterPlugin {
  private var url: URL?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "cham/recorder", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ChamRecorderPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let rec = RPScreenRecorder.shared()
    switch call.method {
    case "start":
      guard rec.isAvailable, !rec.isRecording else { result(false); return }
      // Tiếng: ReplayKit ghi cả âm thanh phát ra từ app và micro (iOS hỏi quyền micro nếu cần). Mặc định bật.
      let audio = (call.arguments as? [String: Any])?["audio"] as? Bool ?? true
      rec.isMicrophoneEnabled = audio
      rec.startRecording { err in result(err == nil) }
    case "stop":
      guard rec.isRecording else { result(nil); return }
      guard #available(iOS 14.0, *) else {
        rec.stopRecording { _, _ in result(nil) }
        return
      }
      let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cham_rec_\(Int(Date().timeIntervalSince1970)).mp4")
      rec.stopRecording(withOutput: out) { err in result(err == nil ? out.path : nil) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
