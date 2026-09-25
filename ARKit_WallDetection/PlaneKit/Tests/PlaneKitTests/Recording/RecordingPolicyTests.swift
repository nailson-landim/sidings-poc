import Testing
@testable import PlaneKit

@Suite("Recording policy")
struct RecordingPolicyTests {
    @Test func stopReasonsMatchTheSpec() {
        let raw = StopReason.allCases.map(\.rawValue)
        #expect(raw == ["user", "reset", "mode_change", "pause", "background", "interruption", "error", "low_disk"])
    }

    @Test func diskGuardStopsOnlyBelowTheMinimum() {
        let guardRail = DiskGuard(constants: RecorderConstants())
        #expect(guardRail.minimumFreeBytes == 1_000_000_000)
        #expect(guardRail.shouldStop(freeBytes: 999_999_999))
        #expect(!guardRail.shouldStop(freeBytes: 1_000_000_000))
        #expect(!guardRail.shouldStop(freeBytes: 50_000_000_000))
        #expect(!guardRail.shouldStop(freeBytes: nil))
    }

    @Test func trackingEventsOnStartAndOnChangeOnly() {
        var detector = TrackingChangeDetector()
        let first = detector.observe(.limited, .initializing)
        #expect(first == "limited/initializing")
        let same = detector.observe(.limited, .initializing)
        #expect(same == nil)
        let normal = detector.observe(.normal, .none)
        #expect(normal == "normal")
        let relocalizing = detector.observe(.limited, .relocalizing)
        #expect(relocalizing == "limited/relocalizing")
        let lost = detector.observe(.notAvailable, .none)
        #expect(lost == "not_available")
    }

    @Test func everyTrackingStateHasADistinctDetail() {
        let reasons: [TrackingReason] = [.none, .initializing, .excessiveMotion, .insufficientFeatures, .relocalizing]
        let limited = Set(reasons.map { TrackingChangeDetector.detail(.limited, $0) })
        #expect(limited.count == reasons.count)
        #expect(TrackingChangeDetector.detail(.normal, .relocalizing) == "normal")
    }

    @Test func imageSkipsCountEveryFrameAndReportEachBurstOnce() {
        var log = ImageSkipLog()
        var bursts: [String] = []
        let outcomes: [String?] = [nil, "no_buffer", "no_buffer", "no_buffer", nil, nil, "notReady", nil, "no_buffer"]
        for outcome in outcomes {
            let started = log.record(missing: outcome)
            if let started { bursts.append(started) }
        }
        #expect(bursts == ["no_buffer", "notReady", "no_buffer"])
        #expect(log.counts == ["no_buffer": 4, "notReady": 1])
        #expect(log.metaRows.map(\.key) == ["image_skip.no_buffer", "image_skip.notReady"])
        #expect(log.metaRows.map(\.value) == ["4", "1"])
    }
}
