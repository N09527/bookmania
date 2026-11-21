package yokai.pageturn

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.PixelFormat
import android.view.SurfaceHolder
import android.view.SurfaceView
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Shows the frames of a page turn above the window (Bookmania). It is a surface of its own, placed over
 * the window, so it is not part of what PixelCopy copies from the window: the new page can be copied while
 * the copy of the old one is still shown here. Takes no touches and is hidden (no surface) between turns.
 */
@SuppressLint("ViewConstructor")
internal class PageTurnOverlay(context: Context) : SurfaceView(context), SurfaceHolder.Callback {

    private var ready = false
    private var waiting: CancellableContinuation<Boolean>? = null

    init {
        // Both must be set before the view is attached.
        setZOrderOnTop(true)
        holder.setFormat(PixelFormat.TRANSLUCENT)
        holder.addCallback(this)
        visibility = INVISIBLE
        isClickable = false
        isFocusable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    }

    /** Shows the overlay; true once its surface can be drawn on, false if it did not come in time. */
    suspend fun open(): Boolean {
        if (!isAttachedToWindow) return false
        if (visibility == VISIBLE && ready) return true
        visibility = VISIBLE
        val opened = withTimeoutOrNull(OPEN_TIMEOUT_MS) {
            suspendCancellableCoroutine { cont ->
                if (ready) {
                    cont.resume(true)
                } else {
                    waiting = cont
                    cont.invokeOnCancellation { if (waiting === cont) waiting = null }
                }
            }
        }
        if (opened != true) close()
        return opened == true
    }

    /** Hides the overlay; its surface goes away, so what is under it shows again. */
    fun close() {
        waiting = null
        if (visibility != INVISIBLE) visibility = INVISIBLE
    }

    /** Draws one frame; false when there is no surface. */
    fun draw(block: (Canvas) -> Unit): Boolean {
        if (!ready || visibility != VISIBLE) return false
        val canvas = try {
            holder.lockHardwareCanvas()
        } catch (e: RuntimeException) {
            null
        } ?: return false
        try {
            block(canvas)
        } finally {
            holder.unlockCanvasAndPost(canvas)
        }
        return true
    }

    override fun surfaceCreated(holder: SurfaceHolder) = Unit

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        ready = true
        waiting?.let {
            waiting = null
            if (it.isActive) it.resume(true)
        }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        ready = false
    }

    companion object {
        private const val OPEN_TIMEOUT_MS = 1_000L
    }
}
