import simd

/// Principal axes of a point set: its least-squares plane and how the points spread within it (Experiment X1).
public struct PrincipalAxes: Sendable, Equatable {
    public var center: SIMD3<Float>
    /// Variances along `normal`, `middle` and `major`, smallest first.
    public var variances: SIMD3<Float>
    /// Unit axes; `normal` is the least-squares plane's normal (sign arbitrary).
    public var normal: SIMD3<Float>
    public var middle: SIMD3<Float>
    public var major: SIMD3<Float>

    /// RMS distance of the points to their plane.
    public var thickness: Float { max(variances.x, 0).squareRoot() }
    /// The narrower in-plane spread, as the width of a uniform strip with that variance (`w² / 12`).
    public var spread: Float { (12 * max(variances.y, 0)).squareRoot() }

    /// Nil for fewer than 3 points.
    public init?<C: Collection>(_ points: C) where C.Element == SIMD3<Float> {
        guard points.count >= 3 else { return nil }
        var sum = SIMD3<Double>.zero
        for p in points { sum += SIMD3<Double>(p) }
        let mean = sum / Double(points.count)
        var c = [Double](repeating: 0, count: 9)
        for p in points {
            let d = SIMD3<Double>(p) - mean
            c[0] += d.x * d.x; c[1] += d.x * d.y; c[2] += d.x * d.z
            c[4] += d.y * d.y; c[5] += d.y * d.z; c[8] += d.z * d.z
        }
        let n = Double(points.count)
        for i in [0, 1, 2, 4, 5, 8] { c[i] /= n }
        c[3] = c[1]; c[6] = c[2]; c[7] = c[5]
        let (values, vectors) = Self.symmetricEigen(c)
        let order = [0, 1, 2].sorted { values[$0] < values[$1] }
        func axis(_ k: Int) -> SIMD3<Float> {
            simd_normalize(SIMD3<Float>(Float(vectors[k]), Float(vectors[3 + k]), Float(vectors[6 + k])))
        }
        center = SIMD3<Float>(mean)
        variances = SIMD3(Float(values[order[0]]), Float(values[order[1]]), Float(values[order[2]]))
        normal = axis(order[0])
        middle = axis(order[1])
        major = axis(order[2])
    }

    /// Cyclic Jacobi on a row-major symmetric 3 × 3. Returns the eigenvalues and the eigenvectors as columns.
    static func symmetricEigen(_ m: [Double]) -> (values: [Double], vectors: [Double]) {
        var a = m
        var v: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        for _ in 0..<50 {
            let off = a[1] * a[1] + a[2] * a[2] + a[5] * a[5]
            if off < 1e-30 { break }
            for (p, q) in [(0, 1), (0, 2), (1, 2)] {
                let apq = a[3 * p + q]
                guard abs(apq) > 1e-300 else { continue }
                let theta = (a[3 * q + q] - a[3 * p + p]) / (2 * apq)
                let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot()
                let s = t * c
                for k in 0..<3 {
                    let akp = a[3 * k + p], akq = a[3 * k + q]
                    a[3 * k + p] = c * akp - s * akq
                    a[3 * k + q] = s * akp + c * akq
                }
                for k in 0..<3 {
                    let apk = a[3 * p + k], aqk = a[3 * q + k]
                    a[3 * p + k] = c * apk - s * aqk
                    a[3 * q + k] = s * apk + c * aqk
                }
                for k in 0..<3 {
                    let vkp = v[3 * k + p], vkq = v[3 * k + q]
                    v[3 * k + p] = c * vkp - s * vkq
                    v[3 * k + q] = s * vkp + c * vkq
                }
            }
        }
        return ([a[0], a[4], a[8]], v)
    }
}
