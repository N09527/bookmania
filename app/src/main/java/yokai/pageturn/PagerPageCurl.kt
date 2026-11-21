package yokai.pageturn

import android.animation.ValueAnimator
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.view.ViewGroup
import co.touchlab.kermit.Logger
import eu.kanade.tachiyomi.core.preference.PreferenceStore
import eu.kanade.tachiyomi.ui.reader.viewer.pager.PagerViewer
import eu.kanade.tachiyomi.ui.reader.viewer.pager.R2LPagerViewer
import eu.kanade.tachiyomi.ui.reader.viewer.pager.VerticalPagerViewer
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

/**
 * The page curl of the image reader's paged modes (Bookmania), for taps and keys when
 * [PageTurnPreferences.pagerCurl] is on: left to right by the right edge, right to left by the left
 * edge, the vertical pager by the bottom edge; double pages turn one page about the centre line.
 * Swipes still drag the pager as before, and the long strip (webtoon) viewer is not affected.
 */
class PagerPageCurl(private val viewer: PagerViewer) {

    private val preferences = PageTurnPreferences(Injekt.get<PreferenceStore>())
    private var turner: PageTurner? = null
    private var job: Job? = null

    /** The item a turn goes to while the page has not been changed yet (the copy is being made). */
    private var pendingItem: Int? = null

    /** Turns to [item] with the curl; false when the curl is off or cannot be shown (turn as before). */
    fun turnTo(item: Int): Boolean {
        if (!preferences.pagerCurl().get()) return false
        finishNow()
        val pager = viewer.pager
        val parent = pager.parent as? ViewGroup ?: return false
        if (viewer.activity.menuVisible || !ValueAnimator.areAnimatorsEnabled() || pager.width == 0 || pager.height == 0) {
            Logger.d { "page curl: not used (menu shown ${viewer.activity.menuVisible}, animations ${ValueAnimator.areAnimatorsEnabled()})" }
            return false
        }
        val current = pager.currentItem
        if (item == current) return false
        val turn = PageTurner.Turn(
            style = PageTurner.Style.CURL,
            edge = when (viewer) {
                is R2LPagerViewer -> CurlEdge.LEFT
                is VerticalPagerViewer -> CurlEdge.BOTTOM
                else -> CurlEdge.RIGHT
            },
            spread = viewer.config.doublePages && viewer !is VerticalPagerViewer,
            // R2L pagers hold their items in reverse: the next page is the one at the left.
            forward = if (viewer is R2LPagerViewer) item < current else item > current,
            paper = ((parent.background as? ColorDrawable)?.color ?: Color.WHITE).let { if (Color.alpha(it) == 0) Color.WHITE else it },
        )
        // One per viewer: the reader makes a new viewer (and pager) when the reading mode changes.
        val pageTurner = turner ?: PageTurner(viewer.activity.window, pager, parent).also { turner = it }
        pendingItem = item
        job = viewer.scope.launch {
            val held = pageTurner.hold()
            pendingItem = null
            pager.setCurrentItem(item, false)
            if (held) pageTurner.play(turn)
        }
        return true
    }

    /** Ends a turn in progress at once; a page change it had not made yet is made now. */
    fun finishNow() {
        val item = pendingItem
        pendingItem = null
        job?.cancel()
        job = null
        turner?.end()
        if (item != null) viewer.pager.setCurrentItem(item, false)
    }
}
