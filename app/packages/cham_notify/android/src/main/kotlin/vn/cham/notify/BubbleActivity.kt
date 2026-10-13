package vn.cham.notify

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Activity mà Android hiển thị khi bấm bong bóng. Không dựng giao diện riêng (tránh chạy thêm một Flutter engine
 * và một phiên WebSocket thứ hai): chỉ mở Activity chính của app tới đúng cuộc trò chuyện rồi tự đóng.
 */
class BubbleActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val peer = intent?.getStringExtra(ChamNotifyPlugin.EXTRA_PEER)
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch != null) {
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            if (peer != null) launch.putExtra(ChamNotifyPlugin.EXTRA_PEER, peer)
            startActivity(launch)
        }
        finish()
    }
}
