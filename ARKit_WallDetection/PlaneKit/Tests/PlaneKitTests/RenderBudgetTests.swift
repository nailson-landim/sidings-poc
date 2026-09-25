import Testing
import simd
@testable import PlaneKit

@Suite("Render budget")
struct RenderBudgetTests {
    @Test func throttleFiresOncePerInterval() {
        var t = Throttle(interval: 0.1)
        let r1 = t.fire(now: 10.0)
        #expect(r1)
        let r2 = t.fire(now: 10.05)
        #expect(!r2)
        let r3 = t.fire(now: 10.15)
        #expect(r3)
        t.reset()
        let r4 = t.fire(now: 10.16)
        #expect(r4)
    }

    @Test func gateAlwaysBuildsFirstTime() {
        var g = RebuildGate()
        let r5 = g.shouldRebuild(now: 0, vertexCount: 4, area: 1, minInterval: 10)
        #expect(r5)
    }

    @Test func gateSkipsUnchangedGeometry() {
        var g = RebuildGate()
        _ = g.shouldRebuild(now: 0, vertexCount: 4, area: 1, minInterval: 0.25)
        let r6 = g.shouldRebuild(now: 5, vertexCount: 4, area: 1.01, minInterval: 0.25)
        #expect(!r6)
    }

    @Test func gateRespectsIntervalButKeepsChangePending() {
        var g = RebuildGate()
        _ = g.shouldRebuild(now: 0, vertexCount: 4, area: 1, minInterval: 0.25)
        let r7 = g.shouldRebuild(now: 0.1, vertexCount: 8, area: 2, minInterval: 0.25)
        #expect(!r7)
        // The change is still reported so the caller can retry on a later tick.
        #expect(g.hasChanged(vertexCount: 8, area: 2))
        let r8 = g.shouldRebuild(now: 0.3, vertexCount: 8, area: 2, minInterval: 0.25)
        #expect(r8)
        #expect(!g.hasChanged(vertexCount: 8, area: 2))
    }

    @Test func gateTriggersOnAreaDelta() {
        var g = RebuildGate(areaDelta: 0.05)
        _ = g.shouldRebuild(now: 0, vertexCount: 4, area: 1, minInterval: 0)
        let r9 = g.shouldRebuild(now: 1, vertexCount: 4, area: 1.04, minInterval: 0)
        #expect(!r9)
        let r10 = g.shouldRebuild(now: 2, vertexCount: 4, area: 1.06, minInterval: 0)
        #expect(r10)
    }

    @Test func octahedraCountsAndIndexRange() {
        let centers: [SIMD3<Float>] = [.zero, SIMD3(1, 0, 0), SIMD3(0, 2, 0)]
        let (positions, indices) = PointMarkerMesh.octahedra(centers: centers, radius: 0.01)
        #expect(positions.count == 3 * PointMarkerMesh.verticesPerPoint)
        #expect(indices.count == 3 * PointMarkerMesh.indicesPerPoint)
        #expect(indices.allSatisfy { Int($0) < positions.count })
    }

    @Test func octahedronTipsAtRadiusAndOutwardWinding() {
        let c = SIMD3<Float>(1, 2, 3)
        let (positions, indices) = PointMarkerMesh.octahedra(centers: [c], radius: 0.5)
        #expect(positions.allSatisfy { abs(simd_distance($0, c) - 0.5) < 1e-6 })
        for f in stride(from: 0, to: indices.count, by: 3) {
            let a = positions[Int(indices[f])]
            let b = positions[Int(indices[f + 1])]
            let d = positions[Int(indices[f + 2])]
            let normal = simd_cross(b - a, d - a)
            let centroid = (a + b + d) / 3
            #expect(simd_dot(normal, centroid - c) > 0)
        }
    }

    @Test func emptyCentersGiveEmptyMesh() {
        let (positions, indices) = PointMarkerMesh.octahedra(centers: [], radius: 0.01)
        #expect(positions.isEmpty && indices.isEmpty)
    }

    @Test func subsampleCapsCount() {
        let pts = Array(0..<200)
        let s = PointMarkerMesh.subsample(pts, limit: 64)
        #expect(s.count <= 64)
        #expect(s.first == 0)
        #expect(PointMarkerMesh.subsample(Array(0..<10), limit: 64).count == 10)
        #expect(PointMarkerMesh.subsample(pts, limit: 0).isEmpty)
    }
}
