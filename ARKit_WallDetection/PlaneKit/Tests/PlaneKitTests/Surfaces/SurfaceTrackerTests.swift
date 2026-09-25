import Foundation
import simd
import Testing
@testable import PlaneKit

@Suite("X1 surface tracker")
struct SurfaceTrackerTests {
    /// A wall 2 m × 2 m at z = -3 (indices 0..<441) and a second patch, as one cloud.
    static func cloud(second: Patch) -> (points: [SIMD3<Float>], ids: [UInt64], wall: [Int], other: [Int]) {
        let wall = Patch(origin: SIMD3(-1, -1, -3), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 2, height: 2).lattice()
        let other = second.lattice()
        let points = wall + other
        return (points, (0..<points.count).map { UInt64($0 + 1) }, Array(wall.indices), Array(wall.count..<points.count))
    }

    static func fit(_ indices: [Int], _ points: [SIMD3<Float>], tilt: Float = 0) -> SurfaceFit {
        let axes = PrincipalAxes(indices.lazy.map { points[$0] })!
        let normal = simd_normalize(axes.normal + SIMD3(tilt, 0, 0))
        return SurfaceFit(normal: normal, center: axes.center, inliers: indices, rmsError: 0.01)
    }

    @Test func aRepeatedFitKeepsOneIdAndConfirms() throws {
        let window = Patch(origin: SIMD3(5, 5, -3), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.5, height: 0.5)
        let c = Self.cloud(second: window)
        let tracker = SurfaceTracker()
        var first: UUID?
        for round in 1...50 {
            tracker.beginRound(points: c.points, ids: c.ids)
            // ±1° of jitter in the fitted normal, flipped every other round.
            let tilt: Float = (round % 2 == 0 ? 1 : -1) * 0.0175
            var f = Self.fit(c.wall, c.points, tilt: tilt)
            if round % 2 == 0 { f.normal = -f.normal }
            let id = tracker.ingest(f, hint: first)!
            first = first ?? id
            #expect(id == first)
            let events = tracker.endRound()
            #expect(events == (round == 1 ? [.add(id)] : [.update(id)]))
        }
        let track = try #require(tracker.surfaces[first!])
        #expect(tracker.surfaces.count == 1)
        #expect(track.state == .confirmed)
        #expect(track.hits == 50)
        #expect(degrees(track.normal, SIMD3(0, 0, 1)) < 1.5)
        #expect(abs(track.center.z + 3) < 1e-3)
        #expect(abs(track.width - 2) < 1e-3 && abs(track.height - 2) < 1e-3)
        #expect(track.isVertical)
    }

    @Test func aTrackIsTentativeUntilConfirmHits() {
        let c = Self.cloud(second: Patch(origin: SIMD3(5, 5, -3), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.5, height: 0.5))
        let tracker = SurfaceTracker()
        var states: [TrackedSurface.State] = []
        for _ in 1...3 {
            tracker.beginRound(points: c.points, ids: c.ids)
            let id = tracker.ingest(Self.fit(c.wall, c.points))!
            _ = tracker.endRound()
            states.append(tracker.surfaces[id]!.state)
        }
        #expect(states == [.tentative, .tentative, .confirmed])
    }

    @Test func aRecessTenCentimetresBehindStaysSeparate() {
        let window = Patch(origin: SIMD3(-0.25, -0.25, -3.10), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.5, height: 0.5)
        let c = Self.cloud(second: window)
        let tracker = SurfaceTracker()
        tracker.beginRound(points: c.points, ids: c.ids)
        let wall = tracker.ingest(Self.fit(c.wall, c.points))!
        let recess = tracker.ingest(Self.fit(c.other, c.points))!
        _ = tracker.endRound()
        #expect(wall != recess)
        #expect(tracker.surfaces.count == 2)
    }

    @Test func aRecessFiveCentimetresBehindJoinsTheWallAtTheDefaultAndNotAtFour() {
        let window = Patch(origin: SIMD3(-0.25, -0.25, -3.05), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.5, height: 0.5)
        let c = Self.cloud(second: window)
        let tracker = SurfaceTracker()
        tracker.beginRound(points: c.points, ids: c.ids)
        let wall = tracker.ingest(Self.fit(c.wall, c.points))!
        #expect(tracker.ingest(Self.fit(c.other, c.points)) == wall)

        var tight = SurfaceSettings()
        tight.maxPlaneDistance = 0.04
        let strict = SurfaceTracker(settings: tight)
        strict.beginRound(points: c.points, ids: c.ids)
        let a = strict.ingest(Self.fit(c.wall, c.points))!
        let b = strict.ingest(Self.fit(c.other, c.points))!
        _ = strict.endRound()
        #expect(a != b)
    }

    @Test func twoHalvesMergeOnceTheyOverlapAndTheOlderSurvives() throws {
        let c = Self.cloud(second: Patch(origin: SIMD3(5, 5, -3), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.5, height: 0.5))
        let left = c.wall.filter { c.points[$0].x < -0.05 }
        let right = c.wall.filter { c.points[$0].x > 0.05 }
        var settings = SurfaceSettings()
        settings.mergeGap = 0 // the halves are 0.2 m apart; this case is about overlap
        let tracker = SurfaceTracker(settings: settings)
        tracker.beginRound(points: c.points, ids: c.ids)
        let older = tracker.ingest(Self.fit(left, c.points))!
        let younger = tracker.ingest(Self.fit(right, c.points))!
        #expect(older != younger)
        #expect(tracker.endRound() == [.add(older), .add(younger)])

        // The younger track grows over the whole wall, so the two overlap.
        tracker.beginRound(points: c.points, ids: c.ids)
        #expect(tracker.ingest(Self.fit(c.wall, c.points), hint: younger) == younger)
        let events = tracker.endRound()
        #expect(events == [.update(younger), .merge(survivor: older, absorbed: younger)])
        let survivor = try #require(tracker.surfaces[older])
        #expect(tracker.surfaces.count == 1)
        #expect(survivor.inlierIDs.count == c.wall.count)
        #expect(abs(survivor.width - 2) < 1e-3)
    }

    @Test func coplanarPiecesWithinTheGapJoinAndFartherOnesDoNot() {
        // Two 1 m patches of one wall at z = -3, 0.4 m apart; a third 1.5 m away.
        let left = Patch(origin: SIMD3(-1.4, 0, -3), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 1, height: 1).lattice()
        let near = Patch(origin: SIMD3(0, 0, -3), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 1, height: 1).lattice()
        let far = Patch(origin: SIMD3(2.5, 0, -3), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 1, height: 1).lattice()
        let points = left + near + far
        let ids = (0..<points.count).map { UInt64($0 + 1) }
        let a = Array(0..<left.count)
        let b = Array(left.count..<(left.count + near.count))
        let c = Array((left.count + near.count)..<points.count)
        let tracker = SurfaceTracker()
        tracker.beginRound(points: points, ids: ids)
        let first = tracker.ingest(Self.fit(a, points))!
        #expect(tracker.ingest(Self.fit(b, points)) == first)
        let third = tracker.ingest(Self.fit(c, points))!
        _ = tracker.endRound()
        #expect(third != first)
        #expect(tracker.surfaces.count == 2)
        #expect(abs(tracker.surfaces[first]!.width - 2.4) < 1e-3)

        var off = SurfaceSettings()
        off.mergeGap = 0
        let strict = SurfaceTracker(settings: off)
        strict.beginRound(points: points, ids: ids)
        let x = strict.ingest(Self.fit(a, points))!
        #expect(strict.ingest(Self.fit(b, points)) != x)
    }

    @Test func farApartPatchesOfOneTiltedWallAreStillCoplanar() {
        // 1° of disagreement between two normals 6 m apart reads as 10 cm off by each normal alone, 0 by their mean.
        let tilt = Float(1) * .pi / 180
        let na = SIMD3<Float>(sin(tilt), 0, cos(tilt))
        let nb = SIMD3<Float>(-sin(tilt), 0, cos(tilt))
        let ca = SIMD3<Float>(-3, 0, -3)
        let cb = SIMD3<Float>(3, 0, -3)
        #expect(abs(simd_dot(na, cb - ca)) > 0.1)
        #expect(SurfaceTracker.planeDistance(na, ca, nb, cb) < 1e-4)
        #expect(abs(SurfaceTracker.planeDistance(na, ca, -nb, cb + SIMD3(0, 0, 0.1)) - 0.1) < 1e-3)
    }

    @Test func gapIsZeroWhenOutlinesTouchAndTheDistanceOtherwise() {
        func square(_ x: Float) -> [SIMD3<Float>] {
            [SIMD3(x, 0, -3), SIMD3(x + 1, 0, -3), SIMD3(x + 1, 1, -3), SIMD3(x, 1, -3)]
        }
        let n = SIMD3<Float>(0, 0, 1)
        #expect(SurfaceTracker.gap(square(0), square(0.5), normal: n, origin: SIMD3(0, 0, -3)) == 0)
        #expect(abs(SurfaceTracker.gap(square(0), square(1.75), normal: n, origin: SIMD3(0, 0, -3)) - 0.75) < 1e-5)
        #expect(SurfaceTracker.gap(square(0), [], normal: n, origin: .zero) == .infinity)
    }

    @Test func aConfirmedTrackGoesStaleAfterMissesAndComesBack() throws {
        let c = Self.cloud(second: Patch(origin: SIMD3(5, 5, -3), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.5, height: 0.5))
        var settings = SurfaceSettings()
        settings.confirmHits = 1
        settings.staleMisses = 3
        let tracker = SurfaceTracker(settings: settings)
        tracker.beginRound(points: c.points, ids: c.ids)
        let id = tracker.ingest(Self.fit(c.wall, c.points))!
        _ = tracker.endRound()
        var all: [SurfaceEvent] = []
        for _ in 1...3 {
            tracker.beginRound(points: c.points, ids: c.ids)
            tracker.missed(id)
            all += tracker.endRound()
        }
        #expect(all == [.stale(id)])
        #expect(tracker.surfaces[id]?.state == .stale)

        tracker.beginRound(points: c.points, ids: c.ids)
        #expect(tracker.ingest(Self.fit(c.wall, c.points), hint: id) == id)
        _ = tracker.endRound()
        #expect(tracker.surfaces[id]?.state == .confirmed)
        #expect(tracker.surfaces[id]?.misses == 0)
    }

    @Test func aTentativeTrackThatKeepsMissingIsDropped() {
        let c = Self.cloud(second: Patch(origin: SIMD3(5, 5, -3), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.5, height: 0.5))
        let tracker = SurfaceTracker()
        tracker.beginRound(points: c.points, ids: c.ids)
        let id = tracker.ingest(Self.fit(c.wall, c.points))!
        _ = tracker.endRound()
        var all: [SurfaceEvent] = []
        for _ in 1...3 {
            tracker.beginRound(points: c.points, ids: c.ids)
            tracker.missed(id)
            all += tracker.endRound()
        }
        #expect(all == [.drop(id)])
        #expect(tracker.surfaces.isEmpty)
    }

    @Test func aRefitThatWanderedOffStartsNoTrack() {
        let window = Patch(origin: SIMD3(-0.25, -0.25, -3.50), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.5, height: 0.5)
        let c = Self.cloud(second: window)
        let tracker = SurfaceTracker()
        tracker.beginRound(points: c.points, ids: c.ids)
        let wall = tracker.ingest(Self.fit(c.wall, c.points))!
        #expect(tracker.ingest(Self.fit(c.other, c.points), hint: wall, create: false) == nil)
        _ = tracker.endRound()
        #expect(tracker.surfaces.count == 1)
    }

    @Test func aMissAfterAMatchInTheSameRoundDoesNotCount() {
        let c = Self.cloud(second: Patch(origin: SIMD3(5, 5, -3), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.5, height: 0.5))
        let tracker = SurfaceTracker()
        tracker.beginRound(points: c.points, ids: c.ids)
        let id = tracker.ingest(Self.fit(c.wall, c.points))!
        tracker.missed(id)
        _ = tracker.endRound()
        #expect(tracker.surfaces[id]?.misses == 0)
    }

    @Test func earlierInliersNearThePlaneStayWhenAFitCoversLess() throws {
        let c = Self.cloud(second: Patch(origin: SIMD3(5, 5, -3), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.5, height: 0.5))
        let tracker = SurfaceTracker()
        tracker.beginRound(points: c.points, ids: c.ids)
        let id = tracker.ingest(Self.fit(c.wall, c.points))!
        _ = tracker.endRound()
        tracker.beginRound(points: c.points, ids: c.ids)
        let half = c.wall.filter { c.points[$0].x < 0.05 }
        #expect(tracker.ingest(Self.fit(half, c.points), hint: id) == id)
        _ = tracker.endRound()
        let track = try #require(tracker.surfaces[id])
        #expect(track.inlierIDs.count == c.wall.count)
        #expect(abs(track.width - 2) < 1e-3)
    }

    @Test func idsThatLeaveTheCloudLeaveTheOutline() throws {
        let c = Self.cloud(second: Patch(origin: SIMD3(5, 5, -3), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.5, height: 0.5))
        let tracker = SurfaceTracker()
        tracker.beginRound(points: c.points, ids: c.ids)
        let id = tracker.ingest(Self.fit(c.wall, c.points))!
        _ = tracker.endRound()
        // The right half is evicted from the cloud; a fit on the left half updates the track.
        let keep = c.wall.filter { c.points[$0].x < 0.05 }
        let points = keep.map { c.points[$0] }
        let ids = keep.map { c.ids[$0] }
        tracker.beginRound(points: points, ids: ids)
        #expect(tracker.ingest(Self.fit(Array(points.indices), points), hint: id) == id)
        _ = tracker.endRound()
        let track = try #require(tracker.surfaces[id])
        #expect(abs(track.width - 1) < 1e-3)
        #expect(tracker.presentIndices(of: track).count == keep.count)
    }
}
