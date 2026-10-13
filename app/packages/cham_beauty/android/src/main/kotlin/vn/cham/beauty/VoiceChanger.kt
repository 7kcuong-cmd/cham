package vn.cham.beauty

import java.lang.reflect.InvocationHandler
import java.lang.reflect.Modifier
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.IdentityHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.PI
import kotlin.math.floor
import kotlin.math.sin

/**
 * Đổi giọng: gắn một bộ xử lý vào `AudioProcessingController.capturePostProcessing` của flutter_webrtc (âm thanh micro
 * đi qua đây trước khi mã hóa và gửi), nên người kia nghe giọng đã đổi còn mình vẫn nghe giọng thật.
 *
 * Mọi truy cập vào lớp của flutter_webrtc đều qua reflection (không biên dịch phụ thuộc): nếu phiên bản thư viện đổi
 * tên lớp thì app KHÔNG hỏng build, chỉ báo "không bật được" kèm lý do trong [status].
 * Lớp đã đối chiếu với flutter_webrtc 1.6.2: com.cloudwebrtc.webrtc.audio.AudioProcessingController
 * (trường capturePostProcessing: AudioProcessingAdapter, hàm addProcessor(ExternalAudioFrameProcessing)).
 */
object VoiceChanger {
    const val OFF = 0
    const val DEEP = 1
    const val HIGH = 2
    const val ROBOT = 3
    const val MONSTER = 4

    @Volatile
    var preset: Int = OFF

    @Volatile
    private var installed = false

    @Volatile
    private var lastError = ""

    @Volatile
    private var format = "chưa có dữ liệu"

    private val frames = AtomicLong(0)

    @Volatile
    private var dsp: Dsp = Dsp(48000)

    private const val ADAPTER_PKG = "com.cloudwebrtc.webrtc.audio"

    /** Cài bộ xử lý (một lần). Trả `null` nếu ổn, ngược lại là lý do. */
    @Synchronized
    fun install(): String? {
        if (installed) return null
        return try {
            val controller = findController() ?: return fail("không tìm thấy AudioProcessingController")
            val adapter = fieldValue(controller.javaClass, controller, "capturePostProcessing")
                ?: return fail("không có capturePostProcessing")
            val iface = Class.forName("$ADAPTER_PKG.AudioProcessingAdapter\$ExternalAudioFrameProcessing")
            val handler = InvocationHandler { proxy, method, args ->
                when (method.name) {
                    "initialize" -> onInit(args!![0] as Int)
                    "reset" -> onInit(args!![0] as Int)
                    "process" -> onProcess(args!![0] as Int, args[1] as Int, args[2] as ByteBuffer)
                    "hashCode" -> return@InvocationHandler System.identityHashCode(proxy)
                    "equals" -> return@InvocationHandler proxy === args!![0]
                    "toString" -> return@InvocationHandler "ChamVoiceChanger"
                }
                null
            }
            val proxy = Proxy.newProxyInstance(iface.classLoader, arrayOf(iface), handler)
            adapter.javaClass.getMethod("addProcessor", iface).invoke(adapter, proxy)
            installed = true
            lastError = ""
            null
        } catch (t: Throwable) {
            fail("${t.javaClass.simpleName}: ${t.message}")
        }
    }

    private fun fail(msg: String): String {
        lastError = msg
        return msg
    }

    /** Mô tả ngắn để hiện trên màn hình và gửi lại cho nhà phát triển khi không nghe thấy hiệu ứng. */
    fun status(): String =
        "cài=${if (installed) "rồi" else "chưa"}; mức=$preset; khung đã xử lý=${frames.get()}; định dạng=$format" +
            if (lastError.isEmpty()) "" else "; lỗi=$lastError"

    // --- tìm AudioProcessingController qua reflection -------------------------------------------

    private fun isSystem(c: Class<*>): Boolean {
        val n = c.name
        return n.startsWith("java.") || n.startsWith("javax.") || n.startsWith("android.") ||
            n.startsWith("androidx.") || n.startsWith("kotlin.") || n.startsWith("io.flutter.")
    }

    private fun fieldValue(cls: Class<*>, obj: Any?, name: String): Any? {
        var c: Class<*>? = cls
        while (c != null) {
            try {
                val f = c.getDeclaredField(name)
                f.isAccessible = true
                return f.get(obj)
            } catch (_: NoSuchFieldException) {
                c = c.superclass
            }
        }
        return null
    }

    private fun findController(): Any? {
        val pluginCls = Class.forName("com.cloudwebrtc.webrtc.FlutterWebRTCPlugin")
        val inst = fieldValue(pluginCls, null, "sharedSingleton") ?: return null
        try {
            pluginCls.getMethod("getAudioProcessingController").invoke(inst)?.let { return it }
        } catch (_: Throwable) {
            // không có hàm này: duyệt các trường
        }
        val target = "$ADAPTER_PKG.AudioProcessingController"
        val seen = IdentityHashMap<Any, Boolean>()
        var level: List<Any> = listOf(inst)
        for (depth in 0..4) {
            val next = ArrayList<Any>()
            for (o in level) {
                if (seen.put(o, true) != null) continue
                if (o.javaClass.name == target) return o
                var c: Class<*>? = o.javaClass
                while (c != null && !isSystem(c)) {
                    for (f in c.declaredFields) {
                        if (f.type.isPrimitive || Modifier.isStatic(f.modifiers) || isSystem(f.type)) continue
                        val v = try {
                            f.isAccessible = true
                            f.get(o)
                        } catch (_: Throwable) {
                            null
                        } ?: continue
                        next.add(v)
                    }
                    c = c.superclass
                }
            }
            level = next
        }
        return level.firstOrNull { it.javaClass.name == target }
    }

    // --- xử lý âm thanh ------------------------------------------------------------------------

    private fun onInit(rate: Int) {
        if (rate > 0) dsp = Dsp(rate)
    }

    private fun onProcess(numBands: Int, numFrames: Int, buf: ByteBuffer) {
        frames.incrementAndGet()
        val p = preset
        if (p == OFF || numFrames <= 0) return
        val bytes = buf.capacity()
        val d = dsp
        buf.order(ByteOrder.nativeOrder())
        when {
            // Một kênh, dải đầy đủ, số thực 32-bit.
            bytes >= numFrames * 4 && bytes < numFrames * 8 -> {
                format = "float32 x$numFrames (bands=$numBands)"
                for (i in 0 until numFrames) {
                    val y = d.process(p, buf.getFloat(i * 4).toDouble())
                    buf.putFloat(i * 4, if (y.isNaN()) 0f else y.toFloat())
                }
            }
            // Một kênh, số nguyên 16-bit.
            bytes >= numFrames * 2 && bytes < numFrames * 4 -> {
                format = "int16 x$numFrames (bands=$numBands)"
                for (i in 0 until numFrames) {
                    val y = d.process(p, buf.getShort(i * 2).toDouble())
                    buf.putShort(i * 2, y.coerceIn(-32768.0, 32767.0).toInt().toShort())
                }
            }
            else -> format = "lạ: bytes=$bytes frames=$numFrames bands=$numBands (bỏ qua, giữ giọng thật)"
        }
    }

    /** Hiệu ứng theo mẫu: dịch cao độ bằng đường trễ hai đầu đọc + (tùy chọn) điều biên vòng. */
    private class Dsp(private val fs: Int) {
        private val win = (fs * 0.03).toInt().coerceAtLeast(64)
        private val ring = DoubleArray(win + 8)
        private var w = 0
        private var d1 = 0.0
        private var phase = 0.0

        private fun read(delay: Double): Double {
            val pos = w - delay
            val base = floor(pos)
            val frac = pos - base
            val n = ring.size
            val i0 = ((base.toInt() % n) + n) % n
            val i1 = (i0 + 1) % n
            return ring[i0] * (1 - frac) + ring[i1] * frac
        }

        private fun pitch(x: Double, r: Double): Double {
            ring[w] = x
            w = (w + 1) % ring.size
            d1 += 1.0 - r
            val wd = win.toDouble()
            if (d1 >= wd) d1 -= wd
            if (d1 < 0) d1 += wd
            var d2 = d1 + wd / 2
            if (d2 >= wd) d2 -= wd
            val g1 = sin(PI * d1 / wd).let { it * it }
            val g2 = sin(PI * d2 / wd).let { it * it }
            return g1 * read(d1 + 1) + g2 * read(d2 + 1)
        }

        private fun ringMod(x: Double, hz: Double, depth: Double): Double {
            phase += 2 * PI * hz / fs
            if (phase > 2 * PI) phase -= 2 * PI
            return x * ((1 - depth) + depth * sin(phase))
        }

        fun process(preset: Int, x: Double): Double = when (preset) {
            DEEP -> pitch(x, 0.76)
            HIGH -> pitch(x, 1.45)
            ROBOT -> ringMod(x, 60.0, 0.9) * 1.5
            MONSTER -> ringMod(pitch(x, 0.60), 22.0, 0.4) * 1.2
            else -> x
        }
    }
}
