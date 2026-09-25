import Foundation

/// Experiment X1 (`../../EXPERIMENTS.md`): FindSurface rounds, automatic seeds and the surface tracker.
///
/// Defaults are **v2** (2026-10-01, `../../EXPERIMENTS.md` *X1 dials*), tuned from the facade recording
/// 20261001-115808, where the wall stopped growing at 7.7 × 5.4 m about 7 m away. v1 values are noted where they
/// differ. The app's *Debug › X1 dials* changes the main ones live.
public struct SurfaceSettings: Sendable, Equatable {
    // MARK: FindSurface (read by the app's fitter)

    /// A priori RMS error of the points (m). CurvSurf's demo: 0.10 (about twice the 3–7 cm seen on the facade).
    public var measurementAccuracy: Float = 0.10
    /// Mean distance between points (m); FindSurface rejects inlier regions sparser than this allows.
    /// v1 0.50 (CurvSurf's demo); v2 1.0, because a plain painted wall 7 m away gives sparse points.
    public var meanDistance: Float = 1.0
    /// How far a fit spreads along the surface, 0–10. v1 5 (CurvSurf's default); v2 7, for whole facades.
    public var lateralExtension = 7
    /// How thick a fit's inlier band is, 0–10. CurvSurf's default: 5.
    public var radialExpansion = 5

    // MARK: Rounds

    /// Frame-time seconds between rounds.
    public var roundInterval: TimeInterval = 0.25
    /// Tracked planes refitted per round: those in view, least recently tried first.
    public var maxRefitsPerRound = 6
    /// New planes accepted per round.
    public var maxNewPerRound = 3
    /// Discovery fits tried per round, accepted or not.
    public var maxSeedAttemptsPerRound = 8

    // MARK: Accepting a fit

    public var minInliers = 30
    /// A fit is kept when its RMS error is at most this × `measurementAccuracy` (CurvSurf's rule of thumb).
    public var maxRMSFactor: Float = 1.5
    /// The inliers' narrower in-plane spread (m), as the width of a uniform strip. Rejects fits along one edge.
    public var minSpread: Float = 0.3

    // MARK: Seeds

    /// Seeds come only from points with at least this many samples (the magenta band and up).
    public var minSeedSamples: UInt16 = 10
    /// Grid cell (m) for seed density.
    public var seedCell: Float = 0.5
    /// Unclaimed seedable points a cell needs.
    public var minSeedCellPoints = 8
    /// A cell is a seed candidate only when its points are this flat (RMS distance to their plane, m). Keeps seeds
    /// off corners and edges, where two surfaces meet.
    public var maxSeedThickness: Float = 0.06
    /// Seed radius = this × range, clamped. 0.2 ≈ CurvSurf's default on-screen circle (`tan(fovy/2) × 0.5`).
    public var seedRadiusPerMetre: Float = 0.2
    public var seedRadiusMin: Float = 0.15
    /// Also caps a refit's radius (half the plane's size). v1 3 m; v2 6 m, so a 7.7 m wall is reseeded across half
    /// its width.
    public var seedRadiusMax: Float = 6.0
    /// Points farther than this from the camera are never seeds (m).
    public var maxSeedRange: Float = 20
    /// Rounds before a cell that gave no plane is tried again.
    public var seedCooldownRounds = 8

    // MARK: Tracking

    /// Shared inlier feature ids over the smaller inlier set, for a fit to match a track (XD5).
    public var minSharedRatio: Float = 0.3
    /// Geometry gates for matching and merging: PlaneKit's NMS terms.
    public var maxNormalAngleDegrees: Float = 10
    public var maxPlaneDistance: Float = 0.08
    /// Outline overlap over the smaller outline; matches or merges tracks that share few ids.
    public var minOverlapRatio: Float = 0.3
    /// Coplanar pieces whose outlines are at most this far apart (m) match or merge too, so a wall seen in patches
    /// grows into one plane. v1 had no gap rule (0); v2 0.5 m.
    public var mergeGap: Float = 0.5
    /// EMA weight of a new fit for the normal and the plane's position along it.
    public var emaAlpha: Float = 0.3
    /// Matches before a track is confirmed.
    public var confirmHits = 3
    /// In-view refits in a row that find nothing before a confirmed track goes stale.
    public var staleMisses = 8
    /// In-view refits in a row that find nothing before a tentative track is dropped.
    public var dropTentativeMisses = 3
    /// A track keeps earlier inliers while they stay this close to its plane (m), so its outline doesn't shrink
    /// when one fit happens to cover less of the surface. v1 0.05; v2 0.15: the facade's RMS was 6.6 cm at 7 m, so
    /// 5 cm shed real wall points, while the AC units 30–60 cm in front still stay out.
    public var keepBand: Float = 0.15
    /// Half-angle (degrees) of the cone around the view direction that counts as "in view".
    public var viewHalfAngleDegrees: Float = 40

    // MARK: RANSAC (Experiment X2, `../../EXPERIMENTS.md`)

    /// A point's inlier band is `tauBase + tauPerSquareMetre × range²`, capped at `tauMax` (m), with the range taken
    /// from the camera at the round. At 6 m the defaults give 0.26 m: about the 30–40 cm slab every surface forms at
    /// 4–7 m (*X1 verdict*), three times SPEC's 3 cm starting value at that range.
    public var tauBase: Float = 0.04
    public var tauPerSquareMetre: Float = 0.006
    public var tauMax: Float = 0.35
    /// Chance that the search finds the best plane it can (adaptive hypothesis count).
    public var ransacConfidence: Float = 0.99
    /// Hypothesis caps per plane: vertical (2-point) and horizontal (1-point).
    public var maxVerticalHypotheses = 1500
    public var maxHorizontalHypotheses = 300
    /// Cell (m) of the grid the second sample point comes from (NAPSAC): walls are local.
    public var napsacCell: Float = 2.0
    /// A vertical sample's two points must be this far apart horizontally (m); else the pair is collinear in effect.
    public var minSampleSeparation: Float = 0.3
    /// Points a hypothesis is first scored on; the whole cloud only when that could still beat the best (lazy scoring).
    public var lazySubset = 256
    /// Least-squares refits of the winner (LO-RANSAC).
    public var loIterations = 3
    /// Planes the search may find per round.
    public var maxPlanesPerSearch = 4
    /// Grid cell (m) and link radius (cells) that split a plane's inliers into connected pieces.
    public var pieceCell: Float = 0.4
    public var pieceLink = 2
    /// Fraction trimmed from each end of a track's in-plane extent before its outline is drawn; 0 keeps the raw hull
    /// (X1's behavior, and the default). A strayed coplanar point then doesn't inflate the outline; `.ransac` trims 2 %.
    public var extentTrim: Float = 0
    /// A refit looks for points this far (m) beyond the track's current extent, so a wall can grow.
    public var refitMargin: Float = 1.0
    /// Discovery runs when this fraction of the cloud is unclaimed and has changed since the last search, or
    /// every `discoveryEvery` rounds.
    public var discoveryEvery = 4
    public var discoveryMinUnclaimedFraction: Float = 0.05

    public init() {}

    /// The starting values for the RANSAC engine (X2): the tracker merges the slices a thick surface gives (0.25 m)
    /// and outlines are trimmed.
    public static var ransac: SurfaceSettings {
        var s = SurfaceSettings()
        s.maxPlaneDistance = 0.25
        s.mergeGap = 0.5
        s.keepBand = 0.25
        s.minSpread = 0.3
        s.extentTrim = 0.02
        s.maxRMSFactor = 3
        s.maxNewPerRound = 4
        s.roundInterval = 0.25
        return s
    }

    /// Band (m) for a point `range` metres from the camera.
    public func band(range: Float) -> Float {
        min(tauBase + tauPerSquareMetre * range * range, tauMax)
    }

    public var maxRMS: Float { maxRMSFactor * measurementAccuracy }

    /// Seed radius for a seed `range` metres from the camera.
    public func seedRadius(range: Float) -> Float {
        min(max(seedRadiusPerMetre * range, seedRadiusMin), seedRadiusMax)
    }
}
