package yokai.pageturn

import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import kotlin.math.abs

/**
 * Swipes in the image reader's paged modes while the page curl is on (Bookmania; decided by the user, stage
 * 5.5 report 6.3): the pages do not follow the finger; when it is lifted, the page turns with the curl, as a
 * swipe does in the text reader. A swipe is a move along the pager (left / right, or up / down in the
 * vertical pager) longer than [MIN_DISTANCE_DP], or shorter but fast enough to be a fling.
 *
 * A page that uses the move itself (a zoomed page being panned) asks the pager not to intercept, as it does
 * for the pager's own drags, so it keeps the move. Two fingers (zooming) are left to the page too.
 *
 * @param active whether the curl is used for this gesture (asked when the finger goes down)
 * @param turn turns the page: towards the end of the pager (the page at the right, or below) when true
 */
class PagerSwipeTurn(
    private val view: View,
    private val horizontal: Boolean,
    private val active: () -> Boolean,
    private val turn: (towardsEnd: Boolean) -> Unit,
) {
    private val config = ViewConfiguration.get(view.context)
    private val touchSlop = config.scaledTouchSlop
    private val minFling = config.scaledMinimumFlingVelocity
    private val minDistance = MIN_DISTANCE_DP * view.resources.displayMetrics.density

    private var handling = false
    private var swiping = false
    private var multiTouch = false
    private var downX = 0f
    private var downY = 0f
    private var velocity: VelocityTracker? = null

    /** Whether this gesture is handled here instead of by the pager (decided when the finger goes down). */
    fun handles(ev: MotionEvent): Boolean {
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) {
            handling = active()
            swiping = false
            multiTouch = false
            downX = ev.x
            downY = ev.y
            velocity?.recycle()
            velocity = if (handling) VelocityTracker.obtain() else null
        }
        return handling
    }

    /** The pager's onInterceptTouchEvent: takes over a move along the pager that the page leaves to it. */
    fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
        track(ev)
        when (ev.actionMasked) {
            MotionEvent.ACTION_POINTER_DOWN -> multiTouch = true
            MotionEvent.ACTION_MOVE -> if (!swiping && !multiTouch && startsSwipe(ev)) {
                swiping = true
                view.parent?.requestDisallowInterceptTouchEvent(true)
            }
            MotionEvent.ACTION_UP -> {
                // The finger was lifted far from where it went down although no move along the pager came
                // before (moves merged into the release, seen on a slow emulator): still a swipe.
                val swiped = !swiping && !multiTouch && startsSwipe(ev) && abs(along(ev)) >= minDistance
                finish()
                if (swiped) {
                    turn(along(ev) < 0)
                    return true // the page gets a cancel instead of the release
                }
            }
            MotionEvent.ACTION_CANCEL -> finish()
        }
        return swiping
    }

    /** The pager's onTouchEvent: follows the swipe and turns the page when the finger is lifted. */
    fun onTouchEvent(ev: MotionEvent): Boolean {
        track(ev)
        when (ev.actionMasked) {
            MotionEvent.ACTION_POINTER_DOWN -> multiTouch = true
            MotionEvent.ACTION_MOVE -> if (!swiping && !multiTouch && startsSwipe(ev)) swiping = true
            MotionEvent.ACTION_UP -> {
                if (swiping && !multiTouch) {
                    val distance = along(ev)
                    val tracker = velocity
                    tracker?.computeCurrentVelocity(1000)
                    val speed = if (tracker == null) 0f else if (horizontal) tracker.xVelocity else tracker.yVelocity
                    val fling = abs(speed) >= minFling && speed * distance > 0
                    // Moving the finger left (or up) brings in the page at the right (or below).
                    if (abs(distance) >= minDistance || fling) turn(distance < 0)
                }
                finish()
            }
            MotionEvent.ACTION_CANCEL -> finish()
        }
        return true
    }

    private fun startsSwipe(ev: MotionEvent): Boolean {
        val along = abs(along(ev))
        val across = abs(if (horizontal) ev.y - downY else ev.x - downX)
        return along > touchSlop && along > across
    }

    private fun along(ev: MotionEvent) = if (horizontal) ev.x - downX else ev.y - downY

    private fun track(ev: MotionEvent) {
        velocity?.addMovement(ev)
    }

    private fun finish() {
        swiping = false
        velocity?.recycle()
        velocity = null
    }

    companion object {
        private const val MIN_DISTANCE_DP = 48
    }
}
