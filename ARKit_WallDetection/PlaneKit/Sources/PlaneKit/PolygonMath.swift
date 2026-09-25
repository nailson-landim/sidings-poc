import simd

/// Small 2D/3D polygon helpers used by plane arbitration.
public enum PolygonMath {
    /// Absolute shoelace area.
    public static func area(_ pts: [SIMD2<Float>]) -> Float {
        guard pts.count >= 3 else { return 0 }
        var sum: Float = 0
        for i in pts.indices {
            let a = pts[i]
            let b = pts[(i + 1) % pts.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Andrew's monotone chain, counter-clockwise, no collinear points.
    public static func convexHull(_ input: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let pts = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard pts.count >= 3 else { return pts }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Float>] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [SIMD2<Float>] = []
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Sutherland–Hodgman intersection of two convex CCW polygons.
    public static func intersectConvex(_ subject: [SIMD2<Float>], _ clip: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard subject.count >= 3, clip.count >= 3 else { return [] }
        var output = subject
        for i in clip.indices {
            let a = clip[i]
            let b = clip[(i + 1) % clip.count]
            let input = output
            output.removeAll(keepingCapacity: true)
            guard !input.isEmpty else { break }
            func inside(_ p: SIMD2<Float>) -> Bool { (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= 0 }
            func intersection(_ p: SIMD2<Float>, _ q: SIMD2<Float>) -> SIMD2<Float> {
                let r = q - p
                let s = b - a
                let denom = r.x * s.y - r.y * s.x
                guard abs(denom) > 1e-9 else { return p }
                let t = ((a.x - p.x) * s.y - (a.y - p.y) * s.x) / denom
                return p + t * r
            }
            var prev = input[input.count - 1]
            for curr in input {
                if inside(curr) {
                    if !inside(prev) { output.append(intersection(prev, curr)) }
                    output.append(curr)
                } else if inside(prev) {
                    output.append(intersection(prev, curr))
                }
                prev = curr
            }
        }
        return output
    }

    /// Orthonormal in-plane basis for a unit normal.
    public static func basis(for normal: SIMD3<Float>) -> (u: SIMD3<Float>, v: SIMD3<Float>) {
        let helper: SIMD3<Float> = abs(normal.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(helper, normal))
        let v = simd_cross(normal, u)
        return (u, v)
    }

    public static func project(
        _ pts: [SIMD3<Float>],
        origin: SIMD3<Float>,
        u: SIMD3<Float>,
        v: SIMD3<Float>
    ) -> [SIMD2<Float>] {
        pts.map { p in
            let d = p - origin
            return SIMD2(simd_dot(d, u), simd_dot(d, v))
        }
    }

    /// Angle between two plane normals in degrees, ignoring facing direction (0...90).
    public static func normalAngleDegrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let c = min(1, abs(simd_dot(simd_normalize(a), simd_normalize(b))))
        return acos(c) * 180 / .pi
    }

    /// Symmetric plane separation: max distance of each center to the other's plane.
    public static func planeDistance(_ a: PlaneObservation, _ b: PlaneObservation) -> Float {
        let da = abs(simd_dot(a.worldNormal, b.worldCenter - a.worldCenter))
        let db = abs(simd_dot(b.worldNormal, a.worldCenter - b.worldCenter))
        return max(da, db)
    }

    /// Overlap area / smaller area, with both boundaries projected onto `a`'s plane (convex hulls).
    public static func overlapRatio(_ a: PlaneObservation, _ b: PlaneObservation) -> Float {
        let (u, v) = basis(for: a.worldNormal)
        let origin = a.worldCenter
        let ha = convexHull(project(a.worldBoundary, origin: origin, u: u, v: v))
        let hb = convexHull(project(b.worldBoundary, origin: origin, u: u, v: v))
        let smaller = min(area(ha), area(hb))
        guard smaller > 1e-6 else { return 0 }
        return area(intersectConvex(ha, hb)) / smaller
    }
}
