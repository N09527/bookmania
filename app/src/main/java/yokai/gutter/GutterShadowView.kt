package yokai.gutter

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.view.View

/**
 * Shows [GutterShadow] over the text reader's page (Bookmania, stage 7), on the centre of the gap between the
 * two columns. Placed above the WebView in the same container, so the copies of the page that the page turn
 * animation makes carry the shadow too. Takes no touches.
 */
@SuppressLint("ViewConstructor")
class GutterShadowView(context: Context) : View(context) {

    private val shadow = GutterShadow(resources.displayMetrics.density)
    private var centerX: Float? = null

    init {
        isClickable = false
        isFocusable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** The centre line shown now (pixels in this view), or null when there is no shadow. */
    val shownAt get() = centerX

    /** Shows the shadow centred on [x] (pixels in this view), or hides it when [x] is null. */
    fun show(x: Float?) {
        if (x == centerX) return
        centerX = x
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val x = centerX ?: return
        shadow.draw(canvas, x, 0f, height.toFloat())
    }
}
