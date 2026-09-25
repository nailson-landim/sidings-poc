import Testing
@testable import PlaneKit

@Suite("Exposure cap")
struct ExposureCapTests {
    @Test func nearestCapFromSeconds() {
        #expect(ExposureCap(seconds: 0) == .auto)
        #expect(ExposureCap(seconds: -1) == .auto)
        #expect(ExposureCap(seconds: 0.001) == .ms1)
        #expect(ExposureCap(seconds: 0.0019) == .ms2)
        #expect(ExposureCap(seconds: 0.0004) == .ms05)
        #expect(ExposureCap(seconds: RecorderConstants().maxExposureS) == .ms1)
    }

    @Test func capStaysInsideTheFormatRange() {
        #expect(ExposureCap.ms1.seconds(formatMin: 0.000_014, formatMax: 0.25) == 0.001)
        #expect(ExposureCap.ms05.seconds(formatMin: 0.000_8, formatMax: 0.25) == 0.000_8)
        #expect(ExposureCap.ms2.seconds(formatMin: 0.000_014, formatMax: 0.0015) == 0.0015)
        #expect(ExposureCap.auto.seconds(formatMin: 0.000_014, formatMax: 0.25) == nil)
    }

    @Test func reapplyOnlyWhenTheCameraDrifted() {
        #expect(!ExposureCap.needsReapply(current: 0.001, target: 0.001))
        #expect(!ExposureCap.needsReapply(current: 0.001_05, target: 0.001))
        #expect(ExposureCap.needsReapply(current: 0.033, target: 0.001))
        #expect(ExposureCap.needsReapply(current: .nan, target: 0.001))
        #expect(!ExposureCap.needsReapply(current: 0.033, target: 0))
    }

    @Test func labelsAreDistinct() {
        #expect(Set(ExposureCap.allCases.map(\.label)).count == ExposureCap.allCases.count)
    }
}
