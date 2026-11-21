package yokai.pageturn

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.view.Choreographer
import android.view.FrameMetrics
import android.view.PixelCopy
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.animation.DecelerateInterpolator
import androidx.annotation.ColorInt
import kotlin.coroutines.resume
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Plays page turns over a reader's page view (Bookmania), for every reader:
 *
 * 1. [hold] copies the page shown now from the window (PixelCopy) and shows the copy on the overlay, a
 *    surface above the window.
 * 2. The reader changes the page in its own view, under the copy.
 * 3. [play] waits until the window has drawn the new page, then the copy curls or slides away and reveals
 *    it. The new page is copied too when the turn needs it: for slides, and for the back of the leaf of a
 *    spread going forward.
 *
 * Nothing in the page is run or read other than its pixels. Main thread only.
 *
 * @param page the reader's page view; the overlay is added to [parent] over it, so [page] must fill
 *   [parent].
 */
class PageTurner(private val window: Window, private val page: View, parent: ViewGroup) {

    enum class Style { SLIDE, CURL }

    /**
     * @param edge the edge the page turns by: [CurlEdge.RIGHT] for left-to-right reading, [CurlEdge.LEFT]
     *   for right-to-left reading, [CurlEdge.BOTTOM] for the vertical pager.
     * @param spread two pages side by side: one page turns about the centre line.
     * @param forward to the next page (backwards, the turn runs in reverse).
     * @param paper the colour of the back of a single page.
     */
    class Turn(val style: Style, val edge: CurlEdge, val spread: Boolean, val forward: Boolean, @ColorInt val paper: Int)

    private val overlay = PageTurnOverlay(page.context)
    private val renderer = PageTurnRenderer()
    private val handler = Handler(Looper.getMainLooper())
    private var before: Bitmap? = null
    private var after: Bitmap? = null
    private var animator: ValueAnimator? = null

    /** Counts turns, so that a turn ended early leaves the overlay of the next one alone. */
    private var generation = 0
    private var holding = false

    init {
        parent.addView(
            overlay,
            parent.indexOfChild(page) + 1,
            ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
        )
        overlay.addOnAttachStateChangeListener(
            object : View.OnAttachStateChangeListener {
                override fun onViewAttachedToWindow(v: View) = Unit
                override fun onViewDetachedFromWindow(v: View) = release()
            },
        )
    }

    /** Whether a turn is being prepared or played. */
    val isTurning get() = holding

    /**
     * Copies the page shown now and covers the page view with the copy. True once the copy is on the
     * screen: the reader then changes the page and calls [play]. False to turn without animation (nothing
     * is covered then).
     */
    suspend fun hold(): Boolean {
        end()
        val width = page.width
        val height = page.height
        if (width <= 0 || height <= 0 || !page.isAttachedToWindow || !overlay.isAttachedToWindow) return false
        val bitmap = bitmap(before, width, height)?.also { before = it } ?: return false
        val id = ++generation
        val ok = coroutineScope {
            val copied = async { copy(bitmap) }
            val opened = overlay.open()
            copied.await() && opened
        }
        if (id != generation) return false
        if (!ok || !overlay.draw { renderer.drawStill(it, bitmap) }) {
            overlay.close()
            return false
        }
        holding = true
        awaitFrames(FRAMES_BEFORE_CHANGE) // the copy is on the screen before the page changes under it
        return id == generation && holding
    }

    /**
     * Plays [turn] once the reader has changed the page under the copy. Returns when the turn is over or
     * was ended by [end].
     */
    suspend fun play(turn: Turn) {
        val id = generation
        if (!holding) return
        try {
            awaitWindowFrame()
            val current = before
            if (id != generation || current == null || current.isRecycled) return
            if (page.width != current.width || page.height != current.height) return // resized meanwhile
            val needsNext = turn.style == Style.SLIDE || (turn.spread && turn.forward)
            val next = if (needsNext) {
                bitmap(after, current.width, current.height)?.also { after = it }?.takeIf { copy(it) }
            } else {
                null
            }
            if (id != generation) return
            animate(turn, current, next)
        } finally {
            if (id == generation) close()
        }
    }

    /** Ends the turn in progress at once, showing the reader's view as it is (also when the page did not change). */
    fun end() {
        generation++
        animator?.let {
            animator = null
            it.cancel()
        }
        close()
    }

    /** Frees the copies; the next turn makes new ones. */
    fun release() {
        end()
        renderer.forget()
        before?.recycle()
        after?.recycle()
        before = null
        after = null
    }

    private fun close() {
        holding = false
        overlay.close()
    }

    private suspend fun animate(turn: Turn, current: Bitmap, next: Bitmap?) {
        val leaf = CurlLeaf.of(current.width.toFloat(), current.height.toFloat(), turn.edge, turn.spread)
        suspendCancellableCoroutine { cont ->
            val animation = ValueAnimator.ofFloat(0f, 1f).apply {
                duration = if (turn.style == Style.CURL) CURL_MS else SLIDE_MS
                interpolator = DecelerateInterpolator(if (turn.style == Style.CURL) 1.2f else 2f)
                addUpdateListener { a ->
                    val progress = a.animatedValue as Float
                    overlay.draw { canvas ->
                        if (turn.style == Style.SLIDE) {
                            renderer.drawSlide(canvas, turn.edge, turn.forward, progress, current, next)
                        } else {
                            val t = if (turn.forward) progress else 1f - progress
                            renderer.drawCurl(canvas, leaf, CurlGeometry.frame(leaf, t), turn.spread, turn.forward, current, next, turn.paper)
                        }
                    }
                }
                addListener(
                    object : AnimatorListenerAdapter() {
                        override fun onAnimationEnd(animation: Animator) {
                            if (animator === animation) animator = null
                            if (cont.isActive) cont.resume(Unit)
                        }
                    },
                )
            }
            animator = animation
            cont.invokeOnCancellation { handler.post { animation.cancel() } }
            animation.start()
        }
    }

    private fun bitmap(reuse: Bitmap?, width: Int, height: Int): Bitmap? {
        if (reuse != null && !reuse.isRecycled && reuse.width == width && reuse.height == height) return reuse
        if (reuse != null) {
            renderer.forget()
            reuse.recycle()
        }
        return try {
            Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        } catch (e: OutOfMemoryError) {
            null
        }
    }

    /** Copies what the window shows in the page view's bounds. */
    private suspend fun copy(into: Bitmap): Boolean {
        if (!page.isAttachedToWindow) return false
        val location = IntArray(2)
        page.getLocationInWindow(location)
        val rect = Rect(location[0], location[1], location[0] + into.width, location[1] + into.height)
        return suspendCancellableCoroutine { cont ->
            try {
                PixelCopy.request(window, rect, into, { result -> if (cont.isActive) cont.resume(result == PixelCopy.SUCCESS) }, handler)
            } catch (e: IllegalArgumentException) {
                cont.resume(false) // the window has no surface (yet)
            }
        }
    }

    private suspend fun awaitFrames(count: Int) = repeat(count) {
        suspendCancellableCoroutine { cont ->
            val callback = Choreographer.FrameCallback { if (cont.isActive) cont.resume(Unit) }
            Choreographer.getInstance().postFrameCallback(callback)
            cont.invokeOnCancellation { handler.post { Choreographer.getInstance().removeFrameCallback(callback) } }
        }
    }

    /**
     * Waits until the window has drawn a frame begun after now: its picture is then in the window's surface,
     * where PixelCopy reads it. Gives up after a while (when nothing in the window changed, no frame comes).
     */
    private suspend fun awaitWindowFrame() {
        val since = System.nanoTime()
        var listener: Window.OnFrameMetricsAvailableListener? = null
        try {
            withTimeoutOrNull(WINDOW_FRAME_TIMEOUT_MS) {
                suspendCancellableCoroutine { cont ->
                    val l = Window.OnFrameMetricsAvailableListener { _, metrics, _ ->
                        if (metrics.getMetric(FrameMetrics.INTENDED_VSYNC_TIMESTAMP) >= since && cont.isActive) cont.resume(Unit)
                    }
                    listener = l
                    window.addOnFrameMetricsAvailableListener(l, handler)
                }
            }
        } finally {
            listener?.let { runCatching { window.removeOnFrameMetricsAvailableListener(it) } }
        }
    }

    companion object {
        private const val CURL_MS = 500L
        private const val SLIDE_MS = 260L
        private const val FRAMES_BEFORE_CHANGE = 2
        private const val WINDOW_FRAME_TIMEOUT_MS = 400L
    }
}
