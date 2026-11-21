package yokai.pageturn

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.Shader
import kotlin.math.max
import kotlin.math.min

/**
 * Draws the frames of a page turn (Bookmania). [current] is a copy of the page before the turn; [next] a
 * copy of the page after it, when there is one. Parts of the frame left transparent show the reader's own
 * view, which already shows the new page.
 */
internal class PageTurnRenderer {

    private val bitmapPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val shadePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val path = Path()
    private val flapPath = Path()
    private val other = Path()
    private val matrix = Matrix()
    private val shaders = HashMap<Bitmap, BitmapShader>(4)

    /** Forgets the shaders of bitmaps that are no longer used. */
    fun forget() = shaders.clear()

    private fun shaderOf(bitmap: Bitmap) = shaders.getOrPut(bitmap) { BitmapShader(bitmap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP) }

    private fun clear(canvas: Canvas) = canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)

    /** The copy of the page before the turn, unchanged (while the reader changes the page under it). */
    fun drawStill(canvas: Canvas, current: Bitmap) {
        clear(canvas)
        canvas.drawBitmap(current, 0f, 0f, null)
    }

    /**
     * The pages move together, as in the image reader's pager: the old page leaves on one side and the new
     * one comes in from the other. Without a copy of the new page, the old one moves off the reader's view.
     */
    fun drawSlide(canvas: Canvas, edge: CurlEdge, forward: Boolean, progress: Float, current: Bitmap, next: Bitmap?) {
        clear(canvas)
        // The direction the old page leaves in: towards the hinge going forward, away from it going back.
        val sign = when (edge) {
            CurlEdge.RIGHT, CurlEdge.BOTTOM -> if (forward) -1f else 1f
            CurlEdge.LEFT -> if (forward) 1f else -1f
        }
        val vertical = edge == CurlEdge.BOTTOM
        val extent = if (vertical) current.height.toFloat() else current.width.toFloat()
        val offset = sign * extent * progress
        drawAt(canvas, current, offset, vertical)
        if (next != null) drawAt(canvas, next, offset - sign * extent, vertical)
    }

    private fun drawAt(canvas: Canvas, bitmap: Bitmap, offset: Float, vertical: Boolean) {
        if (vertical) canvas.drawBitmap(bitmap, 0f, offset, bitmapPaint) else canvas.drawBitmap(bitmap, offset, 0f, bitmapPaint)
    }

    /**
     * One moment of the curl. Going forward, the leaf of [current] is lifted at time `t` and the new page
     * shows under it. Going back, the turn runs backwards: the leaf of the previous page (the reader's view)
     * comes back over [current]. On a spread the back of the leaf carries the page that lies there once the
     * turn is over ([next] going forward, the other half of [current] going back); a single page shows the
     * back of the paper in [paper].
     */
    fun drawCurl(
        canvas: Canvas,
        leaf: CurlLeaf,
        frame: CurlFrame,
        spread: Boolean,
        forward: Boolean,
        current: Bitmap,
        next: Bitmap?,
        paper: Int,
    ) {
        clear(canvas)
        val pageWidth = current.width.toFloat()
        val pageHeight = current.height.toFloat()
        val flap = polygon(flapPath, frame.flap)
        if (forward) {
            if (spread) {
                // The other half of the spread, except where the flap covers it.
                other.reset()
                if (leaf.edge == CurlEdge.LEFT) other.addRect(leaf.right, 0f, pageWidth, pageHeight, Path.Direction.CW)
                else other.addRect(0f, 0f, leaf.left, pageHeight, Path.Direction.CW)
                if (!frame.flap.isEmpty()) other.op(flap, Path.Op.DIFFERENCE)
                drawBitmapIn(canvas, other, current, null)
            }
            drawBitmapIn(canvas, polygon(path, frame.flat), current, null)
        } else {
            drawBitmapIn(canvas, polygon(path, frame.lifted), current, null)
        }
        val foldPoint = frame.foldPoint ?: return
        val normal = frame.foldNormal ?: return

        // The shadow the curled paper casts on the page under it, along the fold.
        val shadowWidth = min(frame.depth, max(pageWidth, pageHeight) * SHADOW_SHARE)
        if (shadowWidth >= 1f && frame.lifted.isNotEmpty()) {
            shadePaint.shader = LinearGradient(
                foldPoint.x, foldPoint.y, foldPoint.x + normal.x * shadowWidth, foldPoint.y + normal.y * shadowWidth,
                SHADOW, Color.TRANSPARENT, Shader.TileMode.CLAMP,
            )
            canvas.drawPath(polygon(path, frame.lifted), shadePaint)
        }

        if (frame.flap.isEmpty()) return
        val back = when {
            !spread -> null
            forward -> next
            else -> current
        }
        when {
            back != null -> drawBitmapIn(canvas, flap, back, frame.backToFlap)
            !spread -> {
                fillPaint.color = paper
                canvas.drawPath(flap, fillPaint)
            }
            // A spread going forward without a copy of the new page: the reader's view shows through.
        }
        // The paper bends at the fold: darker there, lighter across the flap, a little darker at its end.
        val end = foldPoint - normal * frame.depth
        shadePaint.shader = LinearGradient(
            foldPoint.x, foldPoint.y, end.x, end.y,
            if (back != null) BACK_SHADE_PAGE else BACK_SHADE_PAPER, BACK_SHADE_STOPS, Shader.TileMode.CLAMP,
        )
        canvas.drawPath(flap, shadePaint)
    }

    private fun drawBitmapIn(canvas: Canvas, area: Path, bitmap: Bitmap, map: Affine?) {
        if (area.isEmpty) return
        val shader = shaderOf(bitmap)
        if (map == null) {
            matrix.reset()
        } else {
            matrix.setValues(map.toMatrixValues())
        }
        shader.setLocalMatrix(matrix)
        bitmapPaint.shader = shader
        canvas.drawPath(area, bitmapPaint)
        bitmapPaint.shader = null
    }

    private fun polygon(into: Path, points: List<Vec>): Path {
        into.reset()
        if (points.size < 3) return into
        into.moveTo(points[0].x, points[0].y)
        for (i in 1 until points.size) into.lineTo(points[i].x, points[i].y)
        into.close()
        return into
    }

    companion object {
        /** Width of the fold's shadow on the page under it, as a share of the page's longer side. */
        private const val SHADOW_SHARE = 0.05f
        private const val SHADOW = 0x55000000
        private val BACK_SHADE_STOPS = floatArrayOf(0f, 0.35f, 1f)
        private val BACK_SHADE_PAPER = intArrayOf(0x40000000, 0x0A000000, 0x22000000)
        private val BACK_SHADE_PAGE = intArrayOf(0x30000000, 0x06000000, 0x14000000)
    }
}
