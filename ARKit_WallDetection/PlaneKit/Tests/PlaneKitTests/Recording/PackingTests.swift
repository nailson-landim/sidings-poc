import Foundation
import simd
import Testing
@testable import PlaneKit

@Suite("BLOB packing")
struct PackingTests {
    /// Distinct values everywhere, so a transposed or shifted layout can't pass.
    static let matrix4 = simd_float4x4(
        SIMD4(1, 2, 3, 4), SIMD4(5, 6, 7, 8), SIMD4(9, 10, 11, 12), SIMD4(13.5, -14.25, 15.125, 1)
    )

    @Test func matrix4IsColumnMajorLittleEndian() {
        let data = Packing.pack(Self.matrix4)
        #expect(data.count == 64)
        // First float is column 0, row 0; the fifth is column 1, row 0; floats 12–14 are the translation.
        #expect(Array(data.prefix(4)) == [0x00, 0x00, 0x80, 0x3F])
        #expect(floats(data)[4] == 5)
        #expect(Array(floats(data)[12...14]) == [13.5, -14.25, 15.125])
        #expect(Packing.matrix4(data) == Self.matrix4)
    }

    @Test func matrix3IsNineFloatsWithoutPadding() {
        let m = simd_float3x3(SIMD3(1500.5, 0, 0), SIMD3(0, 1500.5, 0), SIMD3(960.25, 720.75, 1))
        let data = Packing.pack(m)
        #expect(data.count == 36)
        #expect(Array(floats(data)[6...8]) == [960.25, 720.75, 1])
        #expect(Packing.matrix3(data) == m)
    }

    @Test func pointsAreTwelveBytesEach() {
        let points: [SIMD3<Float>] = [SIMD3(1, 2, 3), SIMD3(-0.5, 0.25, -3.5)]
        let data = Packing.pack(points)
        #expect(data.count == 24)
        #expect(floats(data) == [1, 2, 3, -0.5, 0.25, -3.5])
        #expect(Packing.points(data) == points)
        #expect(Packing.pack(SIMD3<Float>(7, 8, 9)).count == 12)
        #expect(Packing.vector3(Packing.pack(SIMD3<Float>(7, 8, 9))) == SIMD3(7, 8, 9))
    }

    @Test func idsAreLittleEndianUInt64() {
        let ids: [UInt64] = [1, 0xFEDC_BA98_7654_3210, UInt64.max]
        let data = Packing.pack(ids)
        #expect(data.count == 24)
        #expect(Array(data.prefix(8)) == [1, 0, 0, 0, 0, 0, 0, 0])
        #expect(Array(data[8..<16]) == [0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE])
        #expect(Packing.ids(data) == ids)
    }

    @Test func emptyArraysPackToEmptyData() {
        #expect(Packing.pack([SIMD3<Float>]()).isEmpty)
        #expect(Packing.pack([UInt64]()).isEmpty)
        #expect(Packing.points(Data()) == [])
        #expect(Packing.ids(Data()) == [])
    }

    @Test func wrongSizesAreRejected() {
        #expect(Packing.matrix4(Data(count: 60)) == nil)
        #expect(Packing.matrix3(Data(count: 48)) == nil)
        #expect(Packing.points(Data(count: 16)) == nil)
        #expect(Packing.ids(Data(count: 12)) == nil)
    }

    private func floats(_ data: Data) -> [Float] {
        stride(from: 0, to: data.count, by: 4).map { offset in
            let word = data[offset..<offset + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
            return Float(bitPattern: word)
        }
    }
}
