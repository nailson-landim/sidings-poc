import Testing
@testable import PlaneKit

@Suite("Recorder constants")
struct RecorderConstantsTests {
    @Test func metaRowsCoverEveryProperty() {
        let constants = RecorderConstants()
        let rows = constants.metaRows
        #expect(rows.count == Mirror(reflecting: constants).children.count)
        #expect(Set(rows.map(\.key)).count == rows.count)
        #expect(rows.allSatisfy { $0.key.hasPrefix("const.") })
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.value) })
        #expect(byKey["const.videoFPS"] == "60")
        #expect(byKey["const.pixelPoolSize"] == "6")
        #expect(byKey["const.keyframeIntervalS"] == "0.5")
        #expect(byKey["const.lowDiskBytes"] == "1000000000")
        // Plane Lab parses these back into a LabConfig (P21).
        #expect(byKey["const.cloudGate"] == "off")
        #expect(byKey["const.cloudNearCutM"] == "0.25")
        #expect(byKey["const.cloudFarCutM"] == "0.0")
        #expect(byKey["const.cloudNormalTrackingOnly"] == "false")
        #expect(byKey["const.cloudMaxIds"] == "100000")
        #expect(byKey["const.cloudZScore"] == "2.0")
    }

    @Test func cloudSettingsFollowTheConstants() {
        var constants = RecorderConstants()
        #expect(constants.cloudSettings == CloudSettings())
        constants.cloudGate = .intended
        constants.cloudMinSamples = 3
        #expect(constants.cloudSettings.gate == .intended)
        #expect(constants.cloudSettings.minSamples == 3)
    }

    @Test func metaRowsFollowAModifiedCopy() {
        var constants = RecorderConstants()
        constants.pixelPoolSize = 1
        #expect(constants.metaRows.first { $0.key == "const.pixelPoolSize" }?.value == "1")
        #expect(RecorderConstants.current.pixelPoolSize == 6)
    }
}
