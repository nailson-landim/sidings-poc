import simd

/// One plane from a `SurfaceFitter` (Experiment X1).
public struct SurfaceFit: Sendable, Equatable {
    /// Unit normal; its sign is arbitrary.
    public var normal: SIMD3<Float>
    public var center: SIMD3<Float>
    /// FindSurface's bounded rectangle as it gave it (lower left, lower right, upper right, upper left); may be empty.
    public var corners: [SIMD3<Float>]
    /// Indices into the round's points.
    public var inliers: [Int]
    public var rmsError: Float

    public init(
        normal: SIMD3<Float>, center: SIMD3<Float>, corners: [SIMD3<Float>] = [], inliers: [Int], rmsError: Float
    ) {
        self.normal = normal
        self.center = center
        self.corners = corners
        self.inliers = inliers
        self.rmsError = rmsError
    }
}

/// Fits one plane around a seed point. X1 uses CurvSurf's FindSurface (`SidingsAR/FindSurfaceFitter.swift`, iOS only);
/// the tests use a least-squares stand-in.
///
/// Called from one queue only: `setPoints` once per round, then any number of fits on those points.
public protocol SurfaceFitter: AnyObject {
    /// Applies the fitter's own parameters (FindSurface's four); called at start and whenever the settings change.
    func configure(_ settings: SurfaceSettings)
    func setPoints(_ points: [SIMD3<Float>]) throws
    /// The plane around `points[seed]`, or nil when there is none.
    func fitPlane(seed: Int, radius: Float) throws -> SurfaceFit?
}
