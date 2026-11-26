import Foundation

// Geometry of the page curl (port of Android's yokai/pageturn/CurlGeometry.kt). The page is folded flat, like a sheet
// of paper whose corner is pulled across it: the corner K is moved to the touch point T, and the fold line is the
// perpendicular bisector of K and T. The part of the leaf on K's side of the fold is lifted; folded over, it is the
// flap, showing the back of the leaf. T moves from K to K's mirror image across the hinge, so at the end the fold line
// is the hinge itself and the whole leaf lies on the other side of it, as a turned page does.

/// A point or a vector, in points of the page view (x to the right, y down).
public struct Vec: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static func + (a: Vec, b: Vec) -> Vec { Vec(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec, b: Vec) -> Vec { Vec(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec, s: Double) -> Vec { Vec(a.x * s, a.y * s) }
    public func dot(_ o: Vec) -> Double { x * o.x + y * o.y }
    public var length: Double { (x * x + y * y).squareRoot() }
}

/// The affine map p -> (a·x + c·y + tx, b·x + d·y + ty), as CGAffineTransform(a, b, c, d, tx, ty).
public struct Affine: Equatable, Sendable {
    public var a, b, c, d, tx, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public func map(_ p: Vec) -> Vec { Vec(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty) }

    /// This map applied to the result of `first`.
    public func after(_ first: Affine) -> Affine {
        Affine(
            a: a * first.a + c * first.b,
            b: b * first.a + d * first.b,
            c: a * first.c + c * first.d,
            d: b * first.c + d * first.d,
            tx: a * first.tx + c * first.ty + tx,
            ty: b * first.tx + d * first.ty + ty
        )
    }

    public static let identity = Affine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    /// The reflection across the line through `point` whose unit normal is `normal`.
    public static func reflection(_ point: Vec, _ normal: Vec) -> Affine {
        let nx = normal.x, ny = normal.y
        let k = 2 * normal.dot(point)
        return Affine(a: 1 - 2 * nx * nx, b: -2 * nx * ny, c: -2 * nx * ny, d: 1 - 2 * ny * ny, tx: k * nx, ty: k * ny)
    }
}

/// The edge of the leaf that is lifted. The leaf turns about the opposite edge (or the centre line).
public enum CurlEdge: Sendable {
    /// Left-to-right reading: the right edge turns over to the left.
    case right
    /// Right-to-left reading: the left edge turns over to the right.
    case left
    /// The vertical pager: the bottom edge turns up, about the top edge.
    case bottom
}

/// The part of a page view that turns over. On a single page it is the whole view and turns about the edge opposite
/// `edge`; on a spread (two columns, double pages) it is the half on the `edge` side, and turns about the centre line.
public struct CurlLeaf: Sendable {
    public let left, top, right, bottom: Double
    public let edge: CurlEdge

    public init(left: Double, top: Double, right: Double, bottom: Double, edge: CurlEdge) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.edge = edge
    }

    public var width: Double { right - left }
    public var height: Double { bottom - top }

    /// Clockwise from the top left.
    public var corners: [Vec] { [Vec(left, top), Vec(right, top), Vec(right, bottom), Vec(left, bottom)] }

    /// The corner that is pulled (the bottom corner of the free edge).
    public var corner: Vec {
        switch edge {
        case .right, .bottom: return Vec(right, bottom)
        case .left: return Vec(left, bottom)
        }
    }

    /// A point on the hinge line.
    public var hingePoint: Vec {
        switch edge {
        case .right, .bottom: return Vec(left, top)
        case .left: return Vec(right, top)
        }
    }

    /// The hinge line's unit normal, pointing into the leaf.
    public var hingeNormal: Vec {
        switch edge {
        case .right: return Vec(1, 0)
        case .left: return Vec(-1, 0)
        case .bottom: return Vec(0, 1)
        }
    }

    /// Mirror image across the hinge: where the leaf (and each point of its back) lies once turned.
    public var acrossHinge: Affine { Affine.reflection(hingePoint, hingeNormal) }

    /// Where the pulled corner ends up.
    public var landing: Vec { acrossHinge.map(corner) }

    /// The touch point moves along the edge of the page and rises a little on the way (unit vector).
    private var rise: Vec { edge == .bottom ? Vec(-1, 0) : Vec(0, -1) }

    /// How far the touch point rises at the middle of the turn. Not more than the leaf's extent along the turn, so
    /// the hinge never comes off the flat part.
    private var riseAmount: Double { CurlLeaf.riseShare * min(width, height) }

    private static let riseShare = 0.3

    /// The touch point at time `t` (0 = before the turn, 1 = turned).
    public func touch(_ t: Double) -> Vec {
        corner + (landing - corner) * t + rise * (riseAmount * sin(Double.pi * t))
    }

    /// The leaf of a page view of `width` × `height`.
    public static func of(width: Double, height: Double, edge: CurlEdge, spread: Bool) -> CurlLeaf {
        if !spread || edge == .bottom { return CurlLeaf(left: 0, top: 0, right: width, bottom: height, edge: edge) }
        let middle = width / 2
        return edge == .right
            ? CurlLeaf(left: middle, top: 0, right: width, bottom: height, edge: edge)
            : CurlLeaf(left: 0, top: 0, right: middle, bottom: height, edge: edge)
    }
}

/// One moment of the turn, all in page view points.
public struct CurlFrame: Sendable {
    /// The part of the leaf still lying where it was, front side up.
    public let flat: [Vec]
    /// The part of the leaf that has been lifted: what is under the leaf shows here.
    public let lifted: [Vec]
    /// The lifted part folded over: the back of the leaf.
    public let flap: [Vec]
    /// A point on the fold line; nil while nothing is lifted.
    public let foldPoint: Vec?
    /// The fold line's unit normal, pointing to the lifted side; nil while nothing is lifted.
    public let foldNormal: Vec?
    /// Distance from the fold line to the far end of the flap (the pulled corner).
    public let depth: Double
    /// Maps a point of the leaf's back, as it lies once the page is turned (the other half of a spread), to where it
    /// is on the flap now. The identity at the end of the turn.
    public let backToFlap: Affine
}

public enum CurlGeometry {
    private static let epsilon = 1e-3

    /// The turn of `leaf` at time `t`, from 0 (not started) to 1 (turned).
    public static func frame(_ leaf: CurlLeaf, _ t: Double) -> CurlFrame {
        let corners = leaf.corners
        let touch = leaf.touch(min(max(t, 0), 1))
        let pull = leaf.corner - touch
        let length = pull.length
        if t <= 0 || length < epsilon {
            return CurlFrame(flat: corners, lifted: [], flap: [], foldPoint: nil, foldNormal: nil, depth: 0, backToFlap: .identity)
        }
        let normal = pull * (1 / length)
        let middle = (leaf.corner + touch) * 0.5
        let flat = clip(corners, middle, normal, keepPositive: false)
        let lifted = clip(corners, middle, normal, keepPositive: true)
        let fold = Affine.reflection(middle, normal)
        return CurlFrame(
            flat: flat,
            lifted: lifted,
            flap: lifted.map(fold.map),
            foldPoint: middle,
            foldNormal: normal,
            depth: length / 2,
            backToFlap: fold.after(leaf.acrossHinge)
        )
    }

    /// The part of the convex `polygon` on one side of the line through `point` with normal `normal`: the side the
    /// normal points to when `keepPositive`, the other side otherwise (Sutherland–Hodgman, one plane).
    static func clip(_ polygon: [Vec], _ point: Vec, _ normal: Vec, keepPositive: Bool) -> [Vec] {
        guard let last = polygon.last else { return polygon }
        let sign: Double = keepPositive ? 1 : -1
        var out = [Vec]()
        out.reserveCapacity(polygon.count + 2)
        var a = last
        var da = sign * (a - point).dot(normal)
        for b in polygon {
            let db = sign * (b - point).dot(normal)
            if (da >= 0) != (db >= 0) {
                let s = da / (da - db)
                out.append(a + (b - a) * s)
            }
            if db >= 0 { out.append(b) }
            a = b
            da = db
        }
        return out
    }

    /// Area of a simple polygon (shoelace formula).
    static func area(_ polygon: [Vec]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var sum = 0.0
        for i in polygon.indices {
            let p = polygon[i]
            let q = polygon[(i + 1) % polygon.count]
            sum += p.x * q.y - q.x * p.y
        }
        return abs(sum) / 2
    }
}

/// Easing of the page turns (Android's DecelerateInterpolator): 1 - (1 - t)^(2·factor).
public enum PageTurnTiming {
    public static let curlSeconds = 0.5
    public static let slideSeconds = 0.26

    public static func decelerate(_ t: Double, factor: Double) -> Double {
        let x = min(max(t, 0), 1)
        return 1 - pow(1 - x, 2 * factor)
    }

    public static func curl(_ t: Double) -> Double { decelerate(t, factor: 1.2) }
    public static func slide(_ t: Double) -> Double { decelerate(t, factor: 2) }
}
