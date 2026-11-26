import Foundation
import Testing
@testable import BookmaniaCore

/// The cases of Android's CurlGeometryTest, with the same sizes and tolerances.
@Suite struct CurlGeometryTests {
    private let width = 1080.0
    private let height = 1920.0

    /// Single pages in portrait, spreads in landscape, every edge.
    private func leaves() -> [CurlLeaf] {
        [
            CurlLeaf.of(width: width, height: height, edge: .right, spread: false),
            CurlLeaf.of(width: width, height: height, edge: .left, spread: false),
            CurlLeaf.of(width: width, height: height, edge: .bottom, spread: false),
            CurlLeaf.of(width: height, height: width, edge: .right, spread: true),
            CurlLeaf.of(width: height, height: width, edge: .left, spread: true),
            CurlLeaf.of(width: height, height: width, edge: .bottom, spread: true), // the vertical pager has no spreads
        ]
    }

    private func times() -> [Double] { (1 ... 99).map { Double($0) / 100 } }
    private func area(_ p: [Vec]) -> Double { CurlGeometry.area(p) }
    private func leafArea(_ leaf: CurlLeaf) -> Double { leaf.width * leaf.height }

    private struct Box { var left, top, right, bottom: Double }

    private func bounds(_ points: [Vec]) -> Box {
        Box(left: points.map(\.x).min()!, top: points.map(\.y).min()!, right: points.map(\.x).max()!, bottom: points.map(\.y).max()!)
    }

    private func expectBox(_ e: Box, _ a: Box, _ message: String) {
        #expect(abs(e.left - a.left) <= 0.5, "\(message): left")
        #expect(abs(e.top - a.top) <= 0.5, "\(message): top")
        #expect(abs(e.right - a.right) <= 0.5, "\(message): right")
        #expect(abs(e.bottom - a.bottom) <= 0.5, "\(message): bottom")
    }

    private func expectVec(_ e: Vec, _ a: Vec, _ message: String = "") {
        #expect(abs(e.x - a.x) <= 0.05, "\(message) x")
        #expect(abs(e.y - a.y) <= 0.05, "\(message) y")
    }

    private func expectIdentity(_ m: Affine, _ message: String) {
        for p in [Vec(0, 0), Vec(1000, 0), Vec(0, 1000), Vec(733, 1211)] { expectVec(p, m.map(p), message) }
    }

    private func side(_ frame: CurlFrame, _ p: Vec) -> Double { (p - frame.foldPoint!).dot(frame.foldNormal!) }

    @Test func beforeTheTurnTheWholeLeafLiesFlat() {
        for leaf in leaves() {
            let frame = CurlGeometry.frame(leaf, 0)
            #expect(abs(leafArea(leaf) - area(frame.flat)) <= 1)
            #expect(frame.lifted.isEmpty)
            #expect(frame.flap.isEmpty)
        }
    }

    @Test func onceTurnedTheLeafLiesMirroredAcrossTheHinge() {
        for leaf in leaves() {
            let frame = CurlGeometry.frame(leaf, 1)
            let message = "\(leaf.edge) \(leaf.left)-\(leaf.right)"
            #expect(area(frame.flat) <= leafArea(leaf) * 1e-4, "\(message)")
            #expect(abs(leafArea(leaf) - area(frame.flap)) <= leafArea(leaf) * 1e-4, "\(message)")
            expectBox(bounds(leaf.corners.map(leaf.acrossHinge.map)), bounds(frame.flap), message)
            expectIdentity(frame.backToFlap, message)
        }
    }

    @Test func aSpreadTurnsOnePageAboutTheCentreLine() {
        let ltr = CurlLeaf.of(width: 1920, height: 1080, edge: .right, spread: true)
        #expect(ltr.left == 960)
        expectBox(Box(left: 0, top: 0, right: 960, bottom: 1080), bounds(CurlGeometry.frame(ltr, 1).flap), "left to right")
        let rtl = CurlLeaf.of(width: 1920, height: 1080, edge: .left, spread: true)
        #expect(rtl.right == 960)
        expectBox(Box(left: 960, top: 0, right: 1920, bottom: 1080), bounds(CurlGeometry.frame(rtl, 1).flap), "right to left")
        // a single page goes off the view entirely
        let single = CurlLeaf.of(width: 1080, height: 1920, edge: .right, spread: false)
        expectBox(Box(left: -1080, top: 0, right: 0, bottom: 1920), bounds(CurlGeometry.frame(single, 1).flap), "single page")
        let vertical = CurlLeaf.of(width: 1080, height: 1920, edge: .bottom, spread: false)
        expectBox(Box(left: 0, top: -1920, right: 1080, bottom: 0), bounds(CurlGeometry.frame(vertical, 1).flap), "vertical pager")
    }

    @Test func thePaperNeitherStretchesNorComesOffTheHinge() {
        for leaf in leaves() {
            let hingeEnds = leaf.corners.filter { abs(($0 - leaf.hingePoint).dot(leaf.hingeNormal)) < 0.01 }
            #expect(hingeEnds.count == 2)
            for t in times() {
                let frame = CurlGeometry.frame(leaf, t)
                let message = "\(leaf.edge) \(leaf.left)-\(leaf.right) t=\(t)"
                #expect(abs(leafArea(leaf) - (area(frame.flat) + area(frame.lifted))) <= leafArea(leaf) * 1e-4, "\(message)")
                #expect(abs(area(frame.lifted) - area(frame.flap)) <= leafArea(leaf) * 1e-4, "\(message)")
                for end in hingeEnds { #expect(side(frame, end) <= 0.5, "\(message): the hinge is lifted") }
                // the pulled corner is under the finger
                let fold = Affine.reflection(frame.foldPoint!, frame.foldNormal!)
                expectVec(leaf.touch(t), fold.map(leaf.corner), message)
            }
        }
    }

    @Test func theTurnStartsAtThePulledCorner() {
        for leaf in leaves() {
            let frame = CurlGeometry.frame(leaf, 0.05)
            #expect(side(frame, leaf.corner) > 0)
            for c in leaf.corners where c != leaf.corner { #expect(side(frame, c) < 0) }
            #expect(area(frame.lifted) < leafArea(leaf) * 0.05)
        }
        #expect(CurlLeaf.of(width: width, height: height, edge: .right, spread: false).corner == Vec(1080, 1920))
        #expect(CurlLeaf.of(width: width, height: height, edge: .left, spread: false).corner == Vec(0, 1920))
        #expect(CurlLeaf.of(width: width, height: height, edge: .bottom, spread: false).corner == Vec(1080, 1920))
    }

    @Test func theTouchPointGoesFromTheCornerToItsMirrorImage() {
        for leaf in leaves() {
            expectVec(leaf.corner, leaf.touch(0))
            expectVec(leaf.landing, leaf.touch(1))
        }
        expectVec(Vec(-1080, 1920), CurlLeaf.of(width: width, height: height, edge: .right, spread: false).landing)
        expectVec(Vec(2160, 1920), CurlLeaf.of(width: width, height: height, edge: .left, spread: false).landing)
        expectVec(Vec(1080, -1920), CurlLeaf.of(width: width, height: height, edge: .bottom, spread: false).landing)
    }

    @Test func theBackOfTheLeafTravelsWithTheFlap() {
        for leaf in leaves() {
            for t in [0.2, 0.5, 0.8] {
                let frame = CurlGeometry.frame(leaf, t)
                let fold = Affine.reflection(frame.foldPoint!, frame.foldNormal!)
                let lifted = frame.lifted
                let point = Vec(lifted.map(\.x).reduce(0, +) / Double(lifted.count), lifted.map(\.y).reduce(0, +) / Double(lifted.count))
                expectVec(fold.map(point), frame.backToFlap.map(leaf.acrossHinge.map(point)), "\(leaf.edge) t=\(t)")
            }
        }
    }

    @Test func turningFromTheLeftMirrorsTurningFromTheRight() {
        let right = CurlLeaf.of(width: width, height: height, edge: .right, spread: false)
        let left = CurlLeaf.of(width: width, height: height, edge: .left, spread: false)
        for t in times() {
            let r = CurlGeometry.frame(right, t)
            let l = CurlGeometry.frame(left, t)
            #expect(abs(area(r.flap) - area(l.flap)) <= 1)
            expectBox(bounds(r.flap), bounds(l.flap.map { Vec(width - $0.x, $0.y) }), "t=\(t)")
        }
    }

    @Test func reflectionsAndTheirComposition() {
        let acrossX10 = Affine.reflection(Vec(10, 0), Vec(1, 0))
        expectVec(Vec(20, 5), acrossX10.map(Vec(0, 5)))
        expectIdentity(acrossX10.after(acrossX10), "a reflection twice")
        let diagonal = Affine.reflection(Vec(0, 0), Vec(0.70710677, -0.70710677)) // the line y = x
        expectVec(Vec(3, 7), diagonal.map(Vec(7, 3)))
        let acrossX0 = Affine.reflection(Vec(0, 0), Vec(1, 0))
        expectVec(Vec(25, 4), acrossX10.after(acrossX0).map(Vec(5, 4)))
    }

    @Test func clippingKeepsTheRightPart() {
        let square = [Vec(0, 0), Vec(10, 0), Vec(10, 10), Vec(0, 10)]
        let right = CurlGeometry.clip(square, Vec(4, 0), Vec(1, 0), keepPositive: true)
        let left = CurlGeometry.clip(square, Vec(4, 0), Vec(1, 0), keepPositive: false)
        #expect(abs(area(right) - 60) <= 0.01)
        #expect(abs(area(left) - 40) <= 0.01)
        expectBox(Box(left: 4, top: 0, right: 10, bottom: 10), bounds(right), "right")
        #expect(CurlGeometry.clip(square, Vec(20, 0), Vec(1, 0), keepPositive: true).isEmpty)
    }

    @Test func easing() {
        #expect(PageTurnTiming.curl(0) == 0)
        #expect(PageTurnTiming.curl(1) == 1)
        #expect(abs(PageTurnTiming.slide(0.5) - (1 - pow(0.5, 4))) < 1e-12)
        #expect(PageTurnTiming.curl(0.5) > 0.5) // decelerates
    }
}
