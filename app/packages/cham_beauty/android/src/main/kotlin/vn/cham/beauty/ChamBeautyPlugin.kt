package vn.cham.beauty

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicInteger

/**
 * Làm mịn da cho camera cuộc gọi: đăng ký bộ xử lý khung hình tên "cham_beauty" với flutter_webrtc.
 * Dart bật bằng `track.setVideoEffects(['cham_beauty'])` và chỉnh mức bằng MethodChannel "cham/beauty" -> setLevel(0..100).
 * Mức 0 trả nguyên khung (không tốn gì). CHƯA THỬ TRÊN MÁY THẬT: tên lớp/phương thức của flutter_webrtc cần đối chiếu
 * theo phiên bản (ProcessorProvider.addProcessor, LocalVideoTrack.ExternalVideoFrameProcessing.onFrame).
 */
class ChamBeautyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        const val EFFECT = "cham_beauty"
        private const val CHANNEL = "cham/beauty"
        val level = AtomicInteger(0)
    }

    private var channel: MethodChannel? = null
    private var voiceChannel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
        voiceChannel = MethodChannel(binding.binaryMessenger, "cham/voice").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    // setPreset(preset: 0..4) -> {ok: Boolean, status: String}
                    "setPreset" -> {
                        val p = (call.argument<Int>("preset") ?: 0).coerceIn(0, 4)
                        val err = if (p == VoiceChanger.OFF && !VoiceChanger.status().contains("cài=rồi")) null else VoiceChanger.install()
                        VoiceChanger.preset = if (err == null) p else VoiceChanger.OFF
                        result.success(mapOf("ok" to (err == null), "status" to VoiceChanger.status()))
                    }
                    "status" -> result.success(VoiceChanger.status())
                    else -> result.notImplemented()
                }
            }
        }
        // TẠM TẮT: flutter_webrtc 1.x không còn ProcessorProvider/LocalVideoTrack.ExternalVideoFrameProcessing
        // nên không gắn được bộ xử lý khung hình. Giữ kênh setLevel để Dart không lỗi; chưa làm mịn thật.
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        voiceChannel?.setMethodCallHandler(null)
        voiceChannel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setLevel" -> {
                level.set((call.argument<Int>("level") ?: 0).coerceIn(0, 100))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
