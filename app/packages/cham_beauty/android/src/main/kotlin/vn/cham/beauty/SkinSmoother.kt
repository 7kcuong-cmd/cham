package vn.cham.beauty

import java.nio.ByteBuffer

/**
 * Làm mịn da trên mặt phẳng độ sáng (Y) của khung I420, không cần nhận diện khuôn mặt:
 *  - vùng "da" = sắc độ (U,V) nằm trong khoảng da người (Cb 77..127, Cr 133..173) và không quá tối/sáng;
 *  - trong vùng da, trộn điểm ảnh với bản làm mờ hộp (box blur, dùng ảnh tích phân);
 *  - giữ cạnh: chỗ chênh lệch lớn giữa gốc và bản mờ (mắt, môi, viền tóc) được trộn ít hơn.
 * Thuần Kotlin/JVM (chỉ ByteBuffer) nên đọc/thử độc lập với WebRTC.
 */
class SkinSmoother {
    private var integral = IntArray(0)
    private var iw = 0
    private var ih = 0

    /**
     * Ghi kết quả vào [outY] (đã chứa bản sao của [srcY]). [level] 0..100.
     * Các stride tính theo byte; U/V có kích thước một nửa theo mỗi chiều.
     */
    fun smooth(
        srcY: ByteBuffer, strideY: Int,
        srcU: ByteBuffer, strideU: Int,
        srcV: ByteBuffer, strideV: Int,
        w: Int, h: Int, level: Int,
        outY: ByteBuffer, outStrideY: Int,
    ) {
        if (level <= 0 || w < 16 || h < 16) return
        buildIntegral(srcY, strideY, w, h)
        val radius = maxOf(2, w / 120)
        val strength = (level.coerceIn(0, 100) / 100f) * 0.85f
        val edge = 28f
        for (y in 0 until h) {
            val y0 = maxOf(0, y - radius)
            val y1 = minOf(h - 1, y + radius)
            val uvRow = (y shr 1)
            for (x in 0 until w) {
                val luma = srcY.get(y * strideY + x).toInt() and 0xFF
                val cb = srcU.get(uvRow * strideU + (x shr 1)).toInt() and 0xFF
                val cr = srcV.get(uvRow * strideV + (x shr 1)).toInt() and 0xFF
                if (!isSkin(luma, cb, cr)) continue
                val x0 = maxOf(0, x - radius)
                val x1 = minOf(w - 1, x + radius)
                val area = (x1 - x0 + 1) * (y1 - y0 + 1)
                val sum = box(x0, y0, x1, y1)
                val blur = sum.toFloat() / area
                val diff = kotlin.math.abs(luma - blur)
                val keep = 1f - minOf(1f, diff / edge) // 1 = vùng phẳng (da), 0 = cạnh
                val a = strength * keep
                val v = luma + a * (blur - luma)
                outY.put(y * outStrideY + x, v.toInt().coerceIn(0, 255).toByte())
            }
        }
    }

    private fun buildIntegral(src: ByteBuffer, stride: Int, w: Int, h: Int) {
        iw = w + 1
        ih = h + 1
        if (integral.size < iw * ih) integral = IntArray(iw * ih)
        for (x in 0 until iw) integral[x] = 0
        for (y in 1..h) {
            var row = 0
            integral[y * iw] = 0
            for (x in 1..w) {
                row += src.get((y - 1) * stride + (x - 1)).toInt() and 0xFF
                integral[y * iw + x] = integral[(y - 1) * iw + x] + row
            }
        }
    }

    private fun box(x0: Int, y0: Int, x1: Int, y1: Int): Int =
        integral[(y1 + 1) * iw + (x1 + 1)] - integral[y0 * iw + (x1 + 1)] -
            integral[(y1 + 1) * iw + x0] + integral[y0 * iw + x0]

    companion object {
        fun isSkin(y: Int, cb: Int, cr: Int): Boolean = y in 40..240 && cb in 77..127 && cr in 133..173
    }
}
