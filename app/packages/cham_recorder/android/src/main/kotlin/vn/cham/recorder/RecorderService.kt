package vn.cham.recorder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.io.File

/**
 * Dịch vụ nền (bắt buộc từ Android 10/14) giữ MediaProjection + MediaRecorder.
 * Ghi hình + tiếng micro (nếu đã cấp quyền RECORD_AUDIO); nếu không chuẩn bị được tiếng thì tự lui về chỉ ghi hình.
 * Lưu ý: Android KHÔNG cho ứng dụng thu tiếng của cuộc gọi WebRTC (usage VOICE_COMMUNICATION) qua AudioPlaybackCapture,
 * nên giọng người kia chỉ vào bản ghi khi bật loa ngoài (micro thu lại). Đó là giới hạn của hệ điều hành.
 */
class RecorderService : Service() {
    companion object {
        @Volatile var current: RecorderService? = null
        var onReady: ((Boolean) -> Unit)? = null
        private const val CH = "cham_recording"
        const val ACTION_STOP = "vn.cham.recorder.STOP"

        /** Dừng từ ngoài Dart (nút "Dừng" trong thông báo / hệ thống dừng chia sẻ màn hình): báo cho Flutter kèm đường dẫn clip. */
        @Volatile var onExternalStop: ((String?) -> Unit)? = null
    }

    private var projection: MediaProjection? = null
    private var recorder: MediaRecorder? = null
    private var display: VirtualDisplay? = null
    private var file: File? = null

    override fun onBind(i: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            val p = finish()
            onExternalStop?.invoke(p)
            return START_NOT_STICKY
        }
        val code = intent?.getIntExtra("code", 0) ?: 0
        @Suppress("DEPRECATION")
        val data = intent?.getParcelableExtra<Intent>("data")
        if (data == null) { fail(); return START_NOT_STICKY }
        try {
            val n = notification()
            val wantAudio = intent?.getBooleanExtra("audio", true) ?: true
            val micOk = wantAudio && checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (Build.VERSION.SDK_INT >= 30 && micOk) startForeground(7342, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            else if (Build.VERSION.SDK_INT >= 29) startForeground(7342, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            else startForeground(7342, n)
            val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val p = mpm.getMediaProjection(code, data) ?: throw IllegalStateException("MediaProjection null")
            projection = p
            p.registerCallback(object : MediaProjection.Callback() { override fun onStop() { val p = finish(); if (p != null) onExternalStop?.invoke(p) } }, Handler(Looper.getMainLooper()))
            val m = resources.displayMetrics
            val w = m.widthPixels / 2 * 2
            val h = m.heightPixels / 2 * 2
            val f = File(cacheDir, "cham_rec_${System.currentTimeMillis()}.mp4")
            file = f
            val r = buildRecorder(f, w, h, micOk)
            display = p.createVirtualDisplay("cham-rec", w, h, m.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, null)
            r.start()
            recorder = r
            current = this
            onReady?.invoke(true)
        } catch (e: Exception) {
            fail()
        }
        return START_NOT_STICKY
    }

    @Suppress("DEPRECATION")
    private fun newRecorder(): MediaRecorder = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(this) else MediaRecorder()

    /** Dựng MediaRecorder; có tiếng thì thử trước, hỏng thì dựng lại chỉ có hình. */
    private fun buildRecorder(f: File, w: Int, h: Int, withAudio: Boolean): MediaRecorder {
        fun make(audio: Boolean): MediaRecorder {
            val r = newRecorder()
            try {
                if (audio) r.setAudioSource(MediaRecorder.AudioSource.MIC)
                r.setVideoSource(MediaRecorder.VideoSource.SURFACE)
                r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                r.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
                if (audio) {
                    r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                    r.setAudioEncodingBitRate(128_000)
                    r.setAudioSamplingRate(44_100)
                }
                r.setVideoSize(w, h)
                r.setVideoFrameRate(30)
                r.setVideoEncodingBitRate(4_000_000)
                r.setOutputFile(f.absolutePath)
                r.prepare()
                return r
            } catch (e: Exception) {
                try { r.release() } catch (_: Exception) {}
                throw e
            }
        }
        return if (withAudio) try { make(true) } catch (_: Exception) { make(false) } else make(false)
    }

    private fun fail() {
        release(deleteFile = true)
        onReady?.invoke(false)
        stopSelf()
    }

    /** Dừng và trả đường dẫn tệp (null nếu lỗi). */
    @Synchronized
    fun finish(): String? {
        if (current == null && recorder == null) return null
        var path: String? = file?.absolutePath
        try { recorder?.stop() } catch (e: Exception) { path = null }
        release(deleteFile = path == null)
        stopForeground(true)
        stopSelf()
        return path
    }

    private fun release(deleteFile: Boolean) {
        try { recorder?.reset(); recorder?.release() } catch (_: Exception) {}
        try { display?.release() } catch (_: Exception) {}
        try { projection?.stop() } catch (_: Exception) {}
        recorder = null; display = null; projection = null; current = null
        if (deleteFile) file?.delete()
    }

    override fun onDestroy() { release(deleteFile = false); super.onDestroy() }

    private fun notification(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel(CH, "Ghi màn hình", NotificationManager.IMPORTANCE_LOW))
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CH) else Notification.Builder(this)
        val stop = android.app.PendingIntent.getService(
            this, 1, Intent(this, RecorderService::class.java).setAction(ACTION_STOP),
            android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT,
        )
        @Suppress("DEPRECATION")
        val action = Notification.Action.Builder(android.R.drawable.ic_media_pause, "Dừng ghi", stop).build()
        return b.setContentTitle("Chạm đang ghi màn hình").setContentText("Chạm \"Dừng ghi\" để kết thúc")
            .setSmallIcon(android.R.drawable.ic_media_play).setOngoing(true).addAction(action).build()
    }
}
