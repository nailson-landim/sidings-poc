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
        #expect(byKey["const.pixelPoolSize"] == "4")
        #expect(byKey["const.keyframeIntervalS"] == "0.5")
        #expect(byKey["const.lowDiskBytes"] == "1000000000")
    }

    @Test func metaRowsFollowAModifiedCopy() {
        var constants = RecorderConstants()
        constants.pixelPoolSize = 1
        #expect(constants.metaRows.first { $0.key == "const.pixelPoolSize" }?.value == "1")
        #expect(RecorderConstants.current.pixelPoolSize == 4)
    }
}
