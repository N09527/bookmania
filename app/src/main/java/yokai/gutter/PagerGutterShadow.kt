package yokai.gutter

import android.content.SharedPreferences
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.PixelFormat
import android.graphics.PointF
import android.graphics.drawable.Drawable
import android.view.View
import androidx.preference.PreferenceManager
import com.davemorrissey.labs.subscaleview.SubsamplingScaleImageView
import eu.kanade.tachiyomi.R
import eu.kanade.tachiyomi.core.preference.PreferenceStore
import kotlin.math.max
import kotlin.math.min
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

/**
 * The gutter shadow of the image reader's double pages (Bookmania, stage 7). Two pages shown side by side are
 * one merged image (`ImageUtil.mergeBitmaps`) made of two halves of the same width, so the pages meet on the
 * middle of the image. The shadow is drawn there, for the height of the image, and follows it when it is zoomed
 * or moved. A page shown alone (a cover, a wide spread) gets none.
 *
 * It is drawn on the image view's own overlay, so in the same pass as the image: the image view moves on its
 * zoom and fling animations while it draws, and a separate view drawn from its state before the pass would lag a
 * frame behind.
 *
 * With "crop borders" on, the image view shows the merged image without its outer margins; when the two pages
 * have margins of different widths, the middle of what is shown is not exactly the seam (inferred from the
 * code, not measured).
 */
object PagerGutterShadow {

    /** Shows or hides the shadow on [image], the image view of a page of the pager. [twoPages]: two merged pages. */
    fun update(image: View?, twoPages: Boolean) {
        val scaleImage = image as? SubsamplingScaleImageView ?: return
        val seam = scaleImage.getTag(R.id.bookmania_gutter_shadow) as? SeamShadow
        when {
            twoPages && seam == null -> SeamShadow(scaleImage).attach()
            !twoPages && seam != null -> seam.detach()
        }
        scaleImage.invalidate()
    }
}

/** The shadow on the seam of [image], drawn on its overlay; it follows the setting while it is shown. */
internal class SeamShadow(private val image: SubsamplingScaleImageView) : Drawable() {

    private val shadow = GutterShadow(image.resources.displayMetrics.density)
    private val enabled = GutterPreferences(Injekt.get<PreferenceStore>()).pager()
    private val sharedPreferences = PreferenceManager.getDefaultSharedPreferences(image.context)
    private val point = PointF()

    /** The setting changed in the reader's settings: the image is drawn again (kept here: the store holds it weakly). */
    private val settingChanged = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == GutterPreferences.KEY_PAGER) image.invalidate()
    }

    fun attach() {
        setBounds(0, 0, max(1, image.width), max(1, image.height))
        image.overlay.add(this)
        image.setTag(R.id.bookmania_gutter_shadow, this)
        sharedPreferences.registerOnSharedPreferenceChangeListener(settingChanged)
    }

    fun detach() {
        sharedPreferences.unregisterOnSharedPreferenceChangeListener(settingChanged)
        image.setTag(R.id.bookmania_gutter_shadow, null)
        image.overlay.remove(this)
    }

    override fun draw(canvas: Canvas) {
        if (!enabled.get() || !image.isReady || image.sWidth <= 0 || image.sHeight <= 0) return
        val middle = image.sWidth / 2f
        val start = image.sourceToViewCoord(middle, 0f, point) ?: return
        val x = start.x
        val top = max(start.y, 0f)
        val bottom = min(image.sourceToViewCoord(middle, image.sHeight.toFloat(), point)?.y ?: return, image.height.toFloat())
        shadow.draw(canvas, x, top, bottom)
    }

    override fun setAlpha(alpha: Int) = Unit

    override fun setColorFilter(colorFilter: ColorFilter?) = Unit

    @Deprecated("Deprecated in Java")
    override fun getOpacity() = PixelFormat.TRANSLUCENT
}
