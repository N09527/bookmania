package yokai.pageturn

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class CurlGeometryTest {

    private val width = 1080f
    private val height = 1920f

    /** Single pages in portrait, spreads in landscape, every edge. */
    private fun leaves() = listOf(
        CurlLeaf.of(width, height, CurlEdge.RIGHT, spread = false),
        CurlLeaf.of(width, height, CurlEdge.LEFT, spread = false),
        CurlLeaf.of(width, height, CurlEdge.BOTTOM, spread = false),
        CurlLeaf.of(height, width, CurlEdge.RIGHT, spread = true),
        CurlLeaf.of(height, width, CurlEdge.LEFT, spread = true),
        CurlLeaf.of(height, width, CurlEdge.BOTTOM, spread = true), // the vertical pager has no spreads
    )

    private fun times() = (1..99).map { it / 100f }

    private fun area(polygon: List<Vec>) = CurlGeometry.area(polygon)

    private fun leafArea(leaf: CurlLeaf) = leaf.width * leaf.height

    private class Box(val left: Float, val top: Float, val right: Float, val bottom: Float)

    private fun bounds(points: List<Vec>) =
        Box(points.minOf { it.x }, points.minOf { it.y }, points.maxOf { it.x }, points.maxOf { it.y })

    private fun assertBox(expected: Box, actual: Box, message: String) {
        assertEquals(expected.left, actual.left, 0.5f, "$message: left")
        assertEquals(expected.top, actual.top, 0.5f, "$message: top")
        assertEquals(expected.right, actual.right, 0.5f, "$message: right")
        assertEquals(expected.bottom, actual.bottom, 0.5f, "$message: bottom")
    }

    private fun assertVec(expected: Vec, actual: Vec, message: String = "") {
        assertEquals(expected.x, actual.x, 0.05f, "$message x")
        assertEquals(expected.y, actual.y, 0.05f, "$message y")
    }

    private fun assertIdentity(m: Affine, message: String) {
        listOf(Vec(0f, 0f), Vec(1000f, 0f), Vec(0f, 1000f), Vec(733f, 1211f)).forEach { assertVec(it, m.map(it), message) }
    }

    private fun side(frame: CurlFrame, p: Vec) = (p - frame.foldPoint!!) dot frame.foldNormal!!

    @Test
    fun `before the turn the whole leaf lies flat`() {
        for (leaf in leaves()) {
            val frame = CurlGeometry.frame(leaf, 0f)
            assertEquals(leafArea(leaf), area(frame.flat), 1f)
            assertTrue(frame.lifted.isEmpty())
            assertTrue(frame.flap.isEmpty())
        }
    }

    @Test
    fun `once turned the leaf lies mirrored across the hinge, and its back is where the page shows it`() {
        for (leaf in leaves()) {
            val frame = CurlGeometry.frame(leaf, 1f)
            val message = "${leaf.edge} ${leaf.left}-${leaf.right}"
            assertEquals(0f, area(frame.flat), leafArea(leaf) * 1e-4f, message)
            assertEquals(leafArea(leaf), area(frame.flap), leafArea(leaf) * 1e-4f, message)
            assertBox(bounds(leaf.corners.map(leaf.acrossHinge::map)), bounds(frame.flap), message)
            assertIdentity(frame.backToFlap, message)
        }
    }

    @Test
    fun `a spread turns one page about the centre line, onto the other half`() {
        val ltr = CurlLeaf.of(1920f, 1080f, CurlEdge.RIGHT, spread = true)
        assertEquals(960f, ltr.left)
        assertBox(Box(0f, 0f, 960f, 1080f), bounds(CurlGeometry.frame(ltr, 1f).flap), "left to right")

        val rtl = CurlLeaf.of(1920f, 1080f, CurlEdge.LEFT, spread = true)
        assertEquals(960f, rtl.right)
        assertBox(Box(960f, 0f, 1920f, 1080f), bounds(CurlGeometry.frame(rtl, 1f).flap), "right to left")

        // a single page goes off the view entirely
        val single = CurlLeaf.of(1080f, 1920f, CurlEdge.RIGHT, spread = false)
        assertBox(Box(-1080f, 0f, 0f, 1920f), bounds(CurlGeometry.frame(single, 1f).flap), "single page")
        val vertical = CurlLeaf.of(1080f, 1920f, CurlEdge.BOTTOM, spread = false)
        assertBox(Box(0f, -1920f, 1080f, 0f), bounds(CurlGeometry.frame(vertical, 1f).flap), "vertical pager")
    }

    @Test
    fun `the paper neither stretches nor comes off the hinge during the turn`() {
        for (leaf in leaves()) {
            val hingeEnds = leaf.corners.filter { kotlin.math.abs((it - leaf.hingePoint) dot leaf.hingeNormal) < 0.01f }
            assertEquals(2, hingeEnds.size)
            for (t in times()) {
                val frame = CurlGeometry.frame(leaf, t)
                val message = "${leaf.edge} ${leaf.left}-${leaf.right} t=$t"
                assertEquals(leafArea(leaf), area(frame.flat) + area(frame.lifted), leafArea(leaf) * 1e-4f, message)
                assertEquals(area(frame.lifted), area(frame.flap), leafArea(leaf) * 1e-4f, message)
                hingeEnds.forEach { assertTrue(side(frame, it) <= 0.5f, "$message: the hinge at $it is lifted") }
                // the pulled corner is under the finger
                val fold = Affine.reflection(frame.foldPoint!!, frame.foldNormal!!)
                assertVec(leaf.touch(t), fold.map(leaf.corner), message)
            }
        }
    }

    @Test
    fun `the turn starts at the pulled corner`() {
        for (leaf in leaves()) {
            val frame = CurlGeometry.frame(leaf, 0.05f)
            val message = "${leaf.edge} ${leaf.left}-${leaf.right}"
            assertTrue(side(frame, leaf.corner) > 0f, "$message: the corner is lifted")
            leaf.corners.filter { it != leaf.corner }.forEach {
                assertTrue(side(frame, it) < 0f, "$message: $it is still flat")
            }
            assertTrue(area(frame.lifted) < leafArea(leaf) * 0.05f, message)
        }
        assertEquals(Vec(1080f, 1920f), CurlLeaf.of(width, height, CurlEdge.RIGHT, spread = false).corner)
        assertEquals(Vec(0f, 1920f), CurlLeaf.of(width, height, CurlEdge.LEFT, spread = false).corner)
        assertEquals(Vec(1080f, 1920f), CurlLeaf.of(width, height, CurlEdge.BOTTOM, spread = false).corner)
    }

    @Test
    fun `the touch point goes from the corner to the corner's mirror image`() {
        for (leaf in leaves()) {
            assertVec(leaf.corner, leaf.touch(0f))
            assertVec(leaf.landing, leaf.touch(1f))
        }
        assertVec(Vec(-1080f, 1920f), CurlLeaf.of(width, height, CurlEdge.RIGHT, spread = false).landing)
        assertVec(Vec(2160f, 1920f), CurlLeaf.of(width, height, CurlEdge.LEFT, spread = false).landing)
        assertVec(Vec(1080f, -1920f), CurlLeaf.of(width, height, CurlEdge.BOTTOM, spread = false).landing)
    }

    @Test
    fun `the back of the leaf travels with the flap`() {
        for (leaf in leaves()) {
            for (t in listOf(0.2f, 0.5f, 0.8f)) {
                val frame = CurlGeometry.frame(leaf, t)
                val fold = Affine.reflection(frame.foldPoint!!, frame.foldNormal!!)
                val lifted = frame.lifted
                val point = Vec(lifted.sumOf { it.x.toDouble() }.toFloat() / lifted.size, lifted.sumOf { it.y.toDouble() }.toFloat() / lifted.size)
                // that point of the leaf, seen from the back once the page is turned, is shown on the flap
                // where the fold puts it now
                assertVec(fold.map(point), frame.backToFlap.map(leaf.acrossHinge.map(point)), "${leaf.edge} t=$t")
            }
        }
    }

    @Test
    fun `turning from the left is the mirror image of turning from the right`() {
        val right = CurlLeaf.of(width, height, CurlEdge.RIGHT, spread = false)
        val left = CurlLeaf.of(width, height, CurlEdge.LEFT, spread = false)
        for (t in times()) {
            val r = CurlGeometry.frame(right, t)
            val l = CurlGeometry.frame(left, t)
            assertEquals(area(r.flap), area(l.flap), 1f)
            val mirrored = bounds(l.flap.map { Vec(width - it.x, it.y) })
            assertBox(bounds(r.flap), mirrored, "t=$t")
        }
    }

    @Test
    fun `reflections and their composition`() {
        val acrossX10 = Affine.reflection(Vec(10f, 0f), Vec(1f, 0f))
        assertVec(Vec(20f, 5f), acrossX10.map(Vec(0f, 5f)))
        assertIdentity(acrossX10.after(acrossX10), "a reflection twice")
        val diagonal = Affine.reflection(Vec(0f, 0f), Vec(0.70710677f, -0.70710677f)) // the line y = x
        assertVec(Vec(3f, 7f), diagonal.map(Vec(7f, 3f)))
        // reflecting across two parallel lines moves by twice their distance
        val acrossX0 = Affine.reflection(Vec(0f, 0f), Vec(1f, 0f))
        assertVec(Vec(25f, 4f), acrossX10.after(acrossX0).map(Vec(5f, 4f)))
        // android.graphics.Matrix order: scaleX, skewX, transX, skewY, scaleY, transY, persp
        assertEquals(listOf(-1f, 0f, 20f, 0f, 1f, 0f, 0f, 0f, 1f), acrossX10.toMatrixValues().map { it + 0f }) // -0 is 0
    }

    @Test
    fun `clipping keeps the right part of the polygon`() {
        val square = listOf(Vec(0f, 0f), Vec(10f, 0f), Vec(10f, 10f), Vec(0f, 10f))
        val right = CurlGeometry.clip(square, Vec(4f, 0f), Vec(1f, 0f), keepPositive = true)
        val left = CurlGeometry.clip(square, Vec(4f, 0f), Vec(1f, 0f), keepPositive = false)
        assertEquals(60f, area(right), 0.01f)
        assertEquals(40f, area(left), 0.01f)
        assertBox(Box(4f, 0f, 10f, 10f), bounds(right), "right")
        assertTrue(CurlGeometry.clip(square, Vec(20f, 0f), Vec(1f, 0f), keepPositive = true).isEmpty())
    }
}
