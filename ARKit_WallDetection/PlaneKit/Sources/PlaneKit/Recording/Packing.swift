import Foundation
import simd

/// BLOB layouts of the session format (SPEC §3.2, §3.3): little-endian, packed, no padding. simd types are padded in
/// memory (a `SIMD3<Float>` takes 16 bytes), so every value is written component by component.
public enum Packing {
    /// 16 × f32, column-major.
    public static func pack(_ m: simd_float4x4) -> Data {
        floats([m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] })
    }

    /// 9 × f32, column-major.
    public static func pack(_ m: simd_float3x3) -> Data {
        floats([m.columns.0, m.columns.1, m.columns.2].flatMap { [$0.x, $0.y, $0.z] })
    }

    /// 3 × f32.
    public static func pack(_ v: SIMD3<Float>) -> Data {
        floats([v.x, v.y, v.z])
    }

    /// N × 3 × f32.
    public static func pack(_ points: [SIMD3<Float>]) -> Data {
        var values: [Float] = []
        values.reserveCapacity(points.count * 3)
        for p in points {
            values.append(p.x)
            values.append(p.y)
            values.append(p.z)
        }
        return floats(values)
    }

    /// N × u64.
    public static func pack(_ ids: [UInt64]) -> Data {
        let words = ids.map(\.littleEndian)
        return words.withUnsafeBytes { Data($0) }
    }

    /// N × u16 (averaged-cloud sample counts).
    public static func pack(_ samples: [UInt16]) -> Data {
        let words = samples.map(\.littleEndian)
        return words.withUnsafeBytes { Data($0) }
    }

    public static func samples(_ data: Data) -> [UInt16]? {
        guard data.count % 2 == 0 else { return nil }
        var words = [UInt16](repeating: 0, count: data.count / 2)
        _ = words.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return words.map { UInt16(littleEndian: $0) }
    }

    public static func matrix4(_ data: Data) -> simd_float4x4? {
        guard let f = readFloats(data), f.count == 16 else { return nil }
        return simd_float4x4(
            SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]),
            SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15])
        )
    }

    public static func matrix3(_ data: Data) -> simd_float3x3? {
        guard let f = readFloats(data), f.count == 9 else { return nil }
        return simd_float3x3(SIMD3(f[0], f[1], f[2]), SIMD3(f[3], f[4], f[5]), SIMD3(f[6], f[7], f[8]))
    }

    public static func vector3(_ data: Data) -> SIMD3<Float>? {
        guard let f = readFloats(data), f.count == 3 else { return nil }
        return SIMD3(f[0], f[1], f[2])
    }

    public static func points(_ data: Data) -> [SIMD3<Float>]? {
        guard let f = readFloats(data), f.count % 3 == 0 else { return nil }
        return stride(from: 0, to: f.count, by: 3).map { SIMD3(f[$0], f[$0 + 1], f[$0 + 2]) }
    }

    public static func ids(_ data: Data) -> [UInt64]? {
        guard data.count % 8 == 0 else { return nil }
        var words = [UInt64](repeating: 0, count: data.count / 8)
        _ = words.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return words.map { UInt64(littleEndian: $0) }
    }

    private static func floats(_ values: [Float]) -> Data {
        let words = values.map(\.bitPattern.littleEndian)
        return words.withUnsafeBytes { Data($0) }
    }

    private static func readFloats(_ data: Data) -> [Float]? {
        guard data.count % 4 == 0 else { return nil }
        var words = [UInt32](repeating: 0, count: data.count / 4)
        _ = words.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return words.map { Float(bitPattern: UInt32(littleEndian: $0)) }
    }
}
