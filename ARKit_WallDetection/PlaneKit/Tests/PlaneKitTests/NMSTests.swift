import Foundation
import Testing
import simd
@testable import PlaneKit

@Suite("Non-Maximum Suppression")
struct NMSTests {
    @Test func coplanarOverlappingKeepsLargest() {
        let t = PlaneTracker()
        let big = wall(width: 2, height: 2)
        let small = wall(x: 0.3, z: 0.02, width: 1, height: 1)
        t.upsert(big)
        t.upsert(small)
        let s = t.resolve()
        #expect(t.keptCount == 1)
        #expect(s[big.id]?.isSuppressed == false)
        #expect(s[small.id]?.isSuppressed == true)
        #expect(s[small.id]?.suppressedBy == big.id)
    }

    @Test func perpendicularWallsBothKept() {
        let t = PlaneTracker()
        t.upsert(wall(width: 2, height: 2))
        t.upsert(wall(width: 2, height: 2, yawDegrees: 90))
        t.resolve()
        #expect(t.keptCount == 2)
    }

    @Test func parallelWallsFarApartBothKept() {
        let t = PlaneTracker()
        t.upsert(wall(z: 0))
        t.upsert(wall(z: 0.3))
        t.resolve()
        #expect(t.keptCount == 2)
    }

    @Test func coplanarButDisjointBothKept() {
        let t = PlaneTracker()
        t.upsert(wall(x: 0))
        t.upsert(wall(x: 3))
        t.resolve()
        #expect(t.keptCount == 2)
    }

    @Test func floorAndTableBothKept() {
        let t = PlaneTracker()
        t.upsert(flat(y: 0, width: 3, height: 3, classification: .floor))
        t.upsert(flat(y: 0.75, width: 1, height: 0.6, classification: .table))
        t.resolve()
        #expect(t.keptCount == 2)
    }

    @Test func horizontalNeverSuppressesVertical() {
        let t = PlaneTracker()
        t.upsert(flat(width: 3, height: 3))
        t.upsert(wall(width: 3, height: 3))
        t.resolve()
        #expect(t.keptCount == 2)
    }

    @Test func chainOfDuplicatesCollapses() {
        let t = PlaneTracker()
        t.upsert(wall(x: 0, width: 2, height: 2))
        t.upsert(wall(x: 0.2, z: 0.03, width: 1, height: 1))
        t.upsert(wall(x: -0.2, z: -0.03, width: 1, height: 1))
        t.resolve()
        #expect(t.keptCount == 1)
    }

    @Test func removeDropsState() {
        let t = PlaneTracker()
        let w = wall()
        t.upsert(w)
        t.resolve()
        t.remove(id: w.id)
        #expect(t.resolve().isEmpty)
    }

    @Test func resolveFiftyPlanesIsFast() {
        let t = PlaneTracker()
        for i in 0..<50 {
            t.upsert(wall(x: Float(i % 10) * 0.4, y: Float(i / 10) * 0.4, z: Float(i % 3) * 0.02, width: 1, height: 1, yawDegrees: Float(i % 4) * 3))
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure { t.resolve() }
        // Budget is 1 ms in release; debug test builds get 10x headroom.
        #expect(elapsed < .milliseconds(10))
    }
}
