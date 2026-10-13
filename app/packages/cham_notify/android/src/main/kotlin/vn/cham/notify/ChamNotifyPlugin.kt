package vn.cham.notify

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.content.LocusIdCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Bong bóng tin nhắn kiểu Messenger trên Android 11+ (Notification Bubbles). Gọi được cả từ isolate nền của FCM.
 *  - "bubble" {peerId, name, text}: hiện thông báo hội thoại có bong bóng. Android < 11 vẫn hiện thông báo tin nhắn thường.
 *  - "takeLaunchPeer": peerId của lần mở app từ bong bóng/thông báo (dùng một lần).
 *  - Dart nhận "openChat" {peerId} khi app đang chạy và người dùng bấm bong bóng.
 * Người dùng cần bật bong bóng cho Chạm trong cài đặt hệ thống (Android 12+: Cài đặt > Ứng dụng > Chạm > Thông báo > Bong bóng).
 * CHƯA THỬ TRÊN MÁY THẬT.
 */
class ChamNotifyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware, PluginRegistry.NewIntentListener {
    companion object {
        const val EXTRA_PEER = "cham_peer"
        private const val CHANNEL = "cham_bubbles"
        @Volatile private var launchPeer: String? = null
    }

    private var channel: MethodChannel? = null
    private var ctx: Context? = null
    private var binding: ActivityPluginBinding? = null
    private var keepOn = false

    /** Giữ màn hình sáng bằng cờ cửa sổ (dự phòng cho wakelock_plus); chạy trên luồng UI. */
    private fun applyKeepOn() {
        val a = binding?.activity ?: return
        a.runOnUiThread {
            val flag = android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            if (keepOn) a.window.addFlags(flag) else a.window.clearFlags(flag)
        }
    }

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        ctx = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, "cham/notify").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null); channel = null; ctx = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "bubble" -> result.success(
                post(call.argument<String>("peerId") ?: "", call.argument<String>("name") ?: "", call.argument<String>("text") ?: "")
            )
            "keepScreenOn" -> { keepOn = call.argument<Boolean>("on") ?: false; applyKeepOn(); result.success(null) }
            "takeLaunchPeer" -> { result.success(launchPeer); launchPeer = null }
            else -> result.notImplemented()
        }
    }

    private fun post(peerId: String, name: String, text: String): Boolean {
        val c = ctx ?: return false
        if (peerId.isEmpty()) return false
        try {
            val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26) {
                val ch = NotificationChannel(CHANNEL, "Tin nhắn (bong bóng)", NotificationManager.IMPORTANCE_HIGH)
                if (Build.VERSION.SDK_INT >= 29) ch.setAllowBubbles(true)
                nm.createNotificationChannel(ch)
            }
            val label = name.ifEmpty { "Chạm" }
            val me = Person.Builder().setName("Bạn").build()
            val person = Person.Builder().setName(label).setKey("peer_$peerId").setImportant(true).build()
            val icon = IconCompat.createWithResource(c, c.applicationInfo.icon)
            val sid = "peer_$peerId"

            val bubbleIntent = Intent(c, BubbleActivity::class.java).setAction(Intent.ACTION_VIEW).putExtra(EXTRA_PEER, peerId)
            val mutable = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0 // bong bóng yêu cầu PendingIntent mutable
            val pi = PendingIntent.getActivity(c, peerId.hashCode(), bubbleIntent, PendingIntent.FLAG_UPDATE_CURRENT or mutable)

            ShortcutManagerCompat.pushDynamicShortcut(
                c,
                ShortcutInfoCompat.Builder(c, sid)
                    .setLongLived(true)
                    .setShortLabel(label)
                    .setPerson(person)
                    .setIcon(icon)
                    .setLocusId(LocusIdCompat(sid))
                    .setIntent(bubbleIntent)
                    .build()
            )

            val builder = NotificationCompat.Builder(c, CHANNEL)
                .setSmallIcon(c.applicationInfo.icon)
                .setContentTitle(label)
                .setContentText(text)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(pi)
                .setShortcutId(sid)
                .setLocusId(LocusIdCompat(sid))
                .addPerson(person)
                .setStyle(
                    NotificationCompat.MessagingStyle(me)
                        .addMessage(NotificationCompat.MessagingStyle.Message(text, System.currentTimeMillis(), person))
                )
            if (Build.VERSION.SDK_INT >= 30) {
                builder.setBubbleMetadata(
                    NotificationCompat.BubbleMetadata.Builder(pi, icon)
                        .setDesiredHeight(600)
                        .setAutoExpandBubble(false)
                        .setSuppressNotification(false)
                        .build()
                )
            }
            NotificationManagerCompat.from(c).notify(peerId.hashCode(), builder.build())
            return true
        } catch (e: Exception) {
            return false // thiếu quyền POST_NOTIFICATIONS, v.v.: bỏ qua, tin vẫn nằm trong hộp thư tạm
        }
    }

    // --- mở app từ bong bóng ---
    private fun take(intent: Intent?) {
        val p = intent?.getStringExtra(EXTRA_PEER) ?: return
        intent.removeExtra(EXTRA_PEER)
        launchPeer = p
        channel?.invokeMethod("openChat", mapOf("peerId" to p), object : MethodChannel.Result {
            override fun success(r: Any?) { launchPeer = null } // Dart đã nhận, không cần giữ lại cho lần khởi động nguội
            override fun error(code: String, msg: String?, details: Any?) {}
            override fun notImplemented() {}
        })
    }

    override fun onNewIntent(intent: Intent): Boolean { take(intent); return false }

    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        binding = b
        b.addOnNewIntentListener(this)
        take(b.activity.intent)
        applyKeepOn() // Activity dựng lại (xoay màn hình, hộp thoại quyền...) → cờ trên cửa sổ mới
    }
    override fun onDetachedFromActivityForConfigChanges() { onDetachedFromActivity() }
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) { onAttachedToActivity(b) }
    override fun onDetachedFromActivity() { binding?.removeOnNewIntentListener(this); binding = null }
}
