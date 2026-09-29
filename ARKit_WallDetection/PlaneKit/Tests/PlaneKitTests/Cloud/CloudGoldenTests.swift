import Foundation
import simd
import Testing
@testable import PlaneKit

/// The Swift accumulator against Plane Lab's (SPEC T27): `session-format/fixtures/cloud/golden.json` holds frames and
/// the cloud the Python accumulator builds from them under several settings. Regenerate it on the Python side with
/// `python scripts/cloud_golden.py`.
@Suite("Averaged cloud golden")
struct CloudGoldenTests {
    struct Golden: Decodable {
        struct Frame: Decodable {
            let idx: Int
            let tracking: Int
            let camera: [Float]
            let ids: [UInt64]
            let points: [Float]
        }

        struct Case: Decodable {
            struct Filter: Decodable {
                let near_cut_m: Double
                let far_cut_m: Double
                let normal_tracking_only: Bool
            }

            struct Gate: Decodable {
                let mode: String
                let move_m: Double
                let turn_deg: Double
            }

            struct Accumulate: Decodable {
                let max_samples: Int
                let min_samples: Int
                let zscore: Double
                let max_ids: Int
            }

            struct Checkpoint: Decodable {
                let after_frame: Int
                let ids: [UInt64]
                let points: [Double]
                let samples: [UInt16]
            }

            let name: String
            let filter: Filter
            let gate: Gate
            let accumulate: Accumulate
            let checkpoints: [Checkpoint]

            var settings: CloudSettings {
                CloudSettings(
                    nearCutM: filter.near_cut_m, farCutM: filter.far_cut_m,
                    normalTrackingOnly: filter.normal_tracking_only, gate: CloudGate(rawValue: gate.mode) ?? .off,
                    moveM: gate.move_m, turnDeg: gate.turn_deg, maxSamples: accumulate.max_samples,
                    minSamples: accumulate.min_samples, zScore: accumulate.zscore, maxIds: accumulate.max_ids
                )
            }
        }

        let frames: [Frame]
        let cases: [Case]
    }

    static let golden: Golden = {
        let url = repositoryRoot.appendingPathComponent("session-format/fixtures/cloud/golden.json")
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }()

    static func camera(_ values: [Float]) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        ))
    }

    static func points(_ flat: [Float]) -> [SIMD3<Float>] {
        stride(from: 0, to: flat.count, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }
    }

    @Test(arguments: golden.cases.map(\.name))
    func swiftGivesPlaneLabsCloud(caseName: String) throws {
        let golden = Self.golden
        let testCase = try #require(golden.cases.first { $0.name == caseName })
        #expect(CloudGate(rawValue: testCase.gate.mode) != nil)
        let pipeline = CloudPipeline(settings: testCase.settings)
        var checked = 0
        for frame in golden.frames {
            pipeline.ingest(
                camera: Self.camera(frame.camera), trackingNormal: frame.tracking == 2,
                points: Self.points(frame.points), ids: frame.ids
            )
            guard let expected = testCase.checkpoints.first(where: { $0.after_frame == frame.idx }) else { continue }
            let state = pipeline.accumulator.state()
            let order = state.ids.indices.sorted { state.ids[$0] < state.ids[$1] }
            #expect(order.map { state.ids[$0] } == expected.ids, "ids after frame \(frame.idx)")
            #expect(order.map { state.samples[$0] } == expected.samples, "samples after frame \(frame.idx)")
            let actual = order.flatMap { [Double(state.points[$0].x), Double(state.points[$0].y), Double(state.points[$0].z)] }
            let worst = zip(actual, expected.points).map { abs($0 - $1) }.max() ?? 0
            #expect(actual.count == expected.points.count)
            #expect(worst < 2e-6, "largest difference \(worst) m after frame \(frame.idx)")
            checked += 1
        }
        #expect(checked == testCase.checkpoints.count)
        #expect(testCase.checkpoints.last?.ids.isEmpty == false)
    }
}
