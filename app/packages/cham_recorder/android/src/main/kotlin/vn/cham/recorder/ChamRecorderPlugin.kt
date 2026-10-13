package vn.cham.recorder

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** Cầu Flutter <-> MediaProjection. CHƯA THỬ TRÊN MÁY THẬT. */
class ChamRecorderPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener {
    private var channel: MethodChannel? = null
    private var ctx: Context? = null
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null
    private var audioWanted = true

    companion object { const val REQ = 7341 }

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        ctx = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, "cham/recorder").also { it.setMethodCallHandler(this) }
        RecorderService.onExternalStop = { path ->
            android.os.Handler(android.os.Looper.getMainLooper()).post { channel?.invokeMethod("stopped", path) }
        }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        RecorderService.onExternalStop = null
        channel?.setMethodCallHandler(null); channel = null; ctx = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> { audioWanted = call.argument<Boolean>("audio") ?: true; start(result) }
            "stop" -> stop(result)
            else -> result.notImplemented()
        }
    }

    private fun start(result: MethodChannel.Result) {
        val act = activity
        if (act == null || pending != null || RecorderService.current != null) { result.success(false); return }
        try {
            val mpm = act.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            pending = result
            act.startActivityForResult(mpm.createScreenCaptureIntent(), REQ)
        } catch (e: Exception) {
            pending = null
            result.success(false)
        }
    }

    private fun stop(result: MethodChannel.Result) {
        val svc = RecorderService.current
        if (svc == null) { result.success(null); return }
        result.success(svc.finish())
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ) return false
        val res = pending ?: return true
        pending = null
        val c = ctx
        if (resultCode != Activity.RESULT_OK || data == null || c == null) { res.success(false); return true }
        RecorderService.onReady = { ok -> RecorderService.onReady = null; res.success(ok) }
        val i = Intent(c, RecorderService::class.java).putExtra("code", resultCode).putExtra("data", data).putExtra("audio", audioWanted)
        try {
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i) else c.startService(i)
        } catch (e: Exception) {
            RecorderService.onReady = null
            res.success(false)
        }
        return true
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) { activity = b.activity; binding = b; b.addActivityResultListener(this) }
    override fun onDetachedFromActivityForConfigChanges() { onDetachedFromActivity() }
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) { onAttachedToActivity(b) }
    override fun onDetachedFromActivity() { binding?.removeActivityResultListener(this); binding = null; activity = null }
}
