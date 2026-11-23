package yokai.gutter

import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Shader

/**
 * The shadow in the fold between two facing pages (Bookmania, stage 7): a vertical band, darkest on the
 * centre line and fading out to both sides, like the pages of a printed book curving into the binding.
 * It is drawn over the pages and darkens whatever lies there; on a black background it does not show.
 */
class GutterShadow(density: Float) {

    /** Half the width of the band, in pixels. */
    val halfWidth = HALF_WIDTH_DP * density

    private val shader = LinearGradient(-halfWidth, 0f, halfWidth, 0f, COLORS, STOPS, Shader.TileMode.CLAMP)
    private val paint = Paint(Paint.DITHER_FLAG).apply { shader = this@GutterShadow.shader }
    private val matrix = Matrix()

    /** Draws the band centred on [centerX], from [top] to [bottom]. */
    fun draw(canvas: Canvas, centerX: Float, top: Float, bottom: Float) {
        if (bottom <= top) return
        matrix.setTranslate(centerX, 0f)
        shader.setLocalMatrix(matrix)
        canvas.drawRect(centerX - halfWidth, top, centerX + halfWidth, bottom, paint)
    }

    companion object {
        /**
         * Half the width of the band. The two columns of the text reader are 40 dp apart, so the darker part
         * stays between them and only the faint ends reach the text.
         */
        const val HALF_WIDTH_DP = 32f

        /** Positions across the band (0.5 is the centre line); symmetric. */
        private val STOPS = floatArrayOf(0f, 0.15f, 0.3f, 0.4f, 0.47f, 0.5f, 0.53f, 0.6f, 0.7f, 0.85f, 1f)

        /** Black with these alphas at [STOPS]: 0, 2 %, 7 %, 15 %, 25 %, 30 % at the centre, and back. */
        private val COLORS = intArrayOf(
            0x00000000, 0x05000000, 0x12000000, 0x26000000, 0x40000000, 0x4D000000,
            0x40000000, 0x26000000, 0x12000000, 0x05000000, 0x00000000,
        )
    }
}
