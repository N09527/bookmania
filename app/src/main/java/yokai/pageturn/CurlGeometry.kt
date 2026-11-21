package yokai.pageturn

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.sin

/*
 * Geometry of the page curl (Bookmania). The page is folded flat, like a sheet of paper whose corner is
 * pulled across it: the corner K is moved to the touch point T, and the fold line is the perpendicular
 * bisector of K and T. The part of the leaf on K's side of the fold is lifted; folded over, it is the flap,
 * showing the back of the leaf. T moves from K to K's mirror image across the hinge, so at the end the fold
 * line is the hinge itself and the whole leaf lies on the other side of it, as a turned page does.
 *
 * Plain Kotlin without Android classes, so that it can be tested on the JVM.
 */

/** A point or a vector, in pixels of the page view (x to the right, y down). */
data class Vec(val x: Float, val y: Float) {
    operator fun plus(o: Vec) = Vec(x + o.x, y + o.y)
    operator fun minus(o: Vec) = Vec(x - o.x, y - o.y)
    operator fun times(s: Float) = Vec(x * s, y * s)
    infix fun dot(o: Vec) = x * o.x + y * o.y
    val length get() = hypot(x, y)
}

/**
 * The affine map p -> (a·x + c·y + tx, b·x + d·y + ty). The values are in the order of
 * android.graphics.Matrix: MSCALE_X = a, MSKEW_X = c, MTRANS_X = tx, MSKEW_Y = b, MSCALE_Y = d, MTRANS_Y = ty.
 */
data class Affine(val a: Float, val b: Float, val c: Float, val d: Float, val tx: Float, val ty: Float) {
    fun map(p: Vec) = Vec(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty)

    /** This map applied to the result of [first]. */
    fun after(first: Affine) = Affine(
        a = a * first.a + c * first.b,
        b = b * first.a + d * first.b,
        c = a * first.c + c * first.d,
        d = b * first.c + d * first.d,
        tx = a * first.tx + c * first.ty + tx,
        ty = b * first.tx + d * first.ty + ty,
    )

    /** For android.graphics.Matrix.setValues. */
    fun toMatrixValues() = floatArrayOf(a, c, tx, b, d, ty, 0f, 0f, 1f)

    companion object {
        val IDENTITY = Affine(1f, 0f, 0f, 1f, 0f, 0f)

        /** The reflection across the line through [point] whose unit normal is [normal]. */
        fun reflection(point: Vec, normal: Vec): Affine {
            val nx = normal.x
            val ny = normal.y
            val k = 2 * (normal dot point)
            return Affine(1 - 2 * nx * nx, -2 * nx * ny, -2 * nx * ny, 1 - 2 * ny * ny, k * nx, k * ny)
        }
    }
}

/** The edge of the leaf that is lifted. The leaf turns about the opposite edge (or the centre line). */
enum class CurlEdge {
    /** Left-to-right reading: the right edge turns over to the left. */
    RIGHT,

    /** Right-to-left reading: the left edge turns over to the right. */
    LEFT,

    /** The vertical pager: the bottom edge turns up, about the top edge. */
    BOTTOM,
}

/**
 * The part of a page view that turns over. On a single page it is the whole view and turns about the edge
 * opposite [edge]; on a spread (two columns, double pages) it is the half on the [edge] side, and turns
 * about the centre line.
 */
class CurlLeaf(val left: Float, val top: Float, val right: Float, val bottom: Float, val edge: CurlEdge) {
    val width get() = right - left
    val height get() = bottom - top

    /** Clockwise from the top left. */
    val corners = listOf(Vec(left, top), Vec(right, top), Vec(right, bottom), Vec(left, bottom))

    /** The corner that is pulled (the bottom corner of the free edge). */
    val corner = when (edge) {
        CurlEdge.RIGHT, CurlEdge.BOTTOM -> Vec(right, bottom)
        CurlEdge.LEFT -> Vec(left, bottom)
    }

    /** A point on the hinge line. */
    val hingePoint = when (edge) {
        CurlEdge.RIGHT -> Vec(left, top)
        CurlEdge.LEFT -> Vec(right, top)
        CurlEdge.BOTTOM -> Vec(left, top)
    }

    /** The hinge line's unit normal, pointing into the leaf. */
    val hingeNormal = when (edge) {
        CurlEdge.RIGHT -> Vec(1f, 0f)
        CurlEdge.LEFT -> Vec(-1f, 0f)
        CurlEdge.BOTTOM -> Vec(0f, 1f)
    }

    /** Mirror image across the hinge: where the leaf (and each point of its back) lies once turned. */
    val acrossHinge = Affine.reflection(hingePoint, hingeNormal)

    /** Where the pulled corner ends up. */
    val landing = acrossHinge.map(corner)

    /** The touch point moves along the edge of the page and rises a little on the way (unit vector). */
    private val rise = if (edge == CurlEdge.BOTTOM) Vec(-1f, 0f) else Vec(0f, -1f)

    /**
     * How far the touch point rises at the middle of the turn. Not more than the leaf's extent along the
     * turn, so the hinge never comes off the flat part (checked in the tests).
     */
    private val riseAmount = RISE * min(width, height)

    /** The touch point at time [t] (0 = before the turn, 1 = turned). */
    fun touch(t: Float): Vec = corner + (landing - corner) * t + rise * (riseAmount * sin(PI * t).toFloat())

    companion object {
        private const val RISE = 0.3f

        /** The leaf of a page view of [width] × [height]. */
        fun of(width: Float, height: Float, edge: CurlEdge, spread: Boolean): CurlLeaf {
            if (!spread || edge == CurlEdge.BOTTOM) return CurlLeaf(0f, 0f, width, height, edge)
            val middle = width / 2
            return if (edge == CurlEdge.RIGHT) {
                CurlLeaf(middle, 0f, width, height, edge)
            } else {
                CurlLeaf(0f, 0f, middle, height, edge)
            }
        }
    }
}

/** One moment of the turn, all in page view pixels. */
class CurlFrame(
    /** The part of the leaf still lying where it was, front side up. */
    val flat: List<Vec>,
    /** The part of the leaf that has been lifted: what is under the leaf shows here. */
    val lifted: List<Vec>,
    /** The lifted part folded over: the back of the leaf. */
    val flap: List<Vec>,
    /** A point on the fold line; null while nothing is lifted. */
    val foldPoint: Vec?,
    /** The fold line's unit normal, pointing to the lifted side; null while nothing is lifted. */
    val foldNormal: Vec?,
    /** Distance from the fold line to the far end of the flap (the pulled corner). */
    val depth: Float,
    /**
     * Maps a point of the leaf's back, as it lies once the page is turned (the other half of a spread), to
     * where it is on the flap now. The identity at the end of the turn.
     */
    val backToFlap: Affine,
)

object CurlGeometry {

    private const val EPSILON = 1e-3f

    /** The turn of [leaf] at time [t], from 0 (not started) to 1 (turned). */
    fun frame(leaf: CurlLeaf, t: Float): CurlFrame {
        val corners = leaf.corners
        val touch = leaf.touch(t.coerceIn(0f, 1f))
        val pull = leaf.corner - touch
        val length = pull.length
        if (t <= 0f || length < EPSILON) {
            return CurlFrame(corners, emptyList(), emptyList(), null, null, 0f, Affine.IDENTITY)
        }
        val normal = pull * (1f / length)
        val middle = (leaf.corner + touch) * 0.5f
        val flat = clip(corners, middle, normal, keepPositive = false)
        val lifted = clip(corners, middle, normal, keepPositive = true)
        val fold = Affine.reflection(middle, normal)
        return CurlFrame(
            flat = flat,
            lifted = lifted,
            flap = lifted.map(fold::map),
            foldPoint = middle,
            foldNormal = normal,
            depth = length / 2,
            backToFlap = fold.after(leaf.acrossHinge),
        )
    }

    /**
     * The part of the convex [polygon] on one side of the line through [point] with normal [normal]: the side
     * the normal points to when [keepPositive], the other side otherwise (Sutherland–Hodgman, one plane).
     */
    internal fun clip(polygon: List<Vec>, point: Vec, normal: Vec, keepPositive: Boolean): List<Vec> {
        if (polygon.isEmpty()) return polygon
        val sign = if (keepPositive) 1f else -1f
        val out = ArrayList<Vec>(polygon.size + 2)
        var a = polygon.last()
        var da = sign * ((a - point) dot normal)
        for (b in polygon) {
            val db = sign * ((b - point) dot normal)
            if ((da >= 0f) != (db >= 0f)) {
                val s = da / (da - db)
                out += a + (b - a) * s
            }
            if (db >= 0f) out += b
            a = b
            da = db
        }
        return out
    }

    /** Area of a simple polygon (shoelace formula). */
    internal fun area(polygon: List<Vec>): Float {
        if (polygon.size < 3) return 0f
        var sum = 0f
        for (i in polygon.indices) {
            val p = polygon[i]
            val q = polygon[(i + 1) % polygon.size]
            sum += p.x * q.y - q.x * p.y
        }
        return abs(sum) / 2
    }
}
