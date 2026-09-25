import Foundation
import Testing
import simd
@testable import PlaneKit

@Suite("Smoothing & hysteresis")
struct SmoothingTests {
    @Test func emaConverges() {
        var s = PlaneSmoother(center: .zero, width: 1, height: 1)
        for _ in 0..<40 {
            s.update(center: SIMD3(0.1, 0, 0), width: 2, height: 1.5, alpha: 0.3, resetDistance: 0.2)
        }
        #expect(abs(s.center.x - 0.1) < 1e-4)
        #expect(abs(s.width - 2) < 1e-4)
        #expect(abs(s.height - 1.5) < 1e-4)
    }

    @Test func emaBlendsSmallSteps() {
        var s = PlaneSmoother(center: .zero, width: 1, height: 1)
        s.update(center: SIMD3(0.1, 0, 0), width: 1, height: 1, alpha: 0.3, resetDistance: 0.2)
        #expect(abs(s.center.x - 0.03) < 1e-6)
    }

    @Test func emaResetsOnJump() {
        var s = PlaneSmoother(center: .zero, width: 1, height: 1)
        s.update(center: SIMD3(1, 0, 0), width: 3, height: 3, alpha: 0.3, resetDistance: 0.2)
        #expect(s.center.x == 1)
        #expect(s.width == 3)
    }

    /// Two duplicates whose areas oscillate ±5% around each other must not flip the winner.
    @Test func winnerStableUnderJitter() {
        let t = PlaneTracker()
        let a = UUID()
        let b = UUID()
        t.upsert(wall(id: a, width: 1, height: 1))
        t.upsert(wall(id: b, x: 0.1, z: 0.01, width: 0.98, height: 1))
        t.resolve()
        let firstWinner = t.states.values.first { !$0.isSuppressed }!.id
        for i in 0..<30 {
            let up: Float = i.isMultiple(of: 2) ? 1.05 : 0.95
            t.upsert(wall(id: a, width: up, height: 1))
            t.upsert(wall(id: b, x: 0.1, z: 0.01, width: 2 - up, height: 1))
            t.resolve()
            #expect(t.states[firstWinner]?.isSuppressed == false)
        }
    }

    /// A challenger that is clearly and persistently larger takes over, but only after N resolves.
    @Test func challengerTakesOverAfterStreak() {
        var cfg = PlaneTrackerConfig()
        cfg.challengerFrames = 5
        let t = PlaneTracker(config: cfg)
        let incumbent = UUID()
        let challenger = UUID()
        t.upsert(wall(id: incumbent, width: 1, height: 1))
        t.resolve()
        t.upsert(wall(id: challenger, x: 0.05, z: 0.01, width: 1.3, height: 1.3))
        for round in 1...4 {
            t.resolve()
            #expect(t.states[incumbent]?.isSuppressed == false, "round \(round)")
            #expect(t.states[challenger]?.isSuppressed == true, "round \(round)")
        }
        t.resolve()
        #expect(t.states[challenger]?.isSuppressed == false)
        #expect(t.states[incumbent]?.isSuppressed == true)
    }

    @Test func smallChallengerNeverTakesOver() {
        let t = PlaneTracker()
        let incumbent = UUID()
        let challenger = UUID()
        t.upsert(wall(id: incumbent, width: 1, height: 1))
        t.resolve()
        // 1.15x area: above raw score but below the 1.2 incumbent margin.
        t.upsert(wall(id: challenger, x: 0.02, z: 0.01, width: 1.15, height: 1))
        for _ in 0..<20 { t.resolve() }
        #expect(t.states[incumbent]?.isSuppressed == false)
        #expect(t.states[challenger]?.isSuppressed == true)
    }

    @Test func stateCarriesSmoothedValues() {
        let t = PlaneTracker()
        let id = UUID()
        t.upsert(wall(id: id, x: 0))
        t.upsert(wall(id: id, x: 0.1))
        let s = t.resolve()[id]!
        #expect(abs(s.smoothed.center.x - 0.03) < 1e-5)
    }
}
