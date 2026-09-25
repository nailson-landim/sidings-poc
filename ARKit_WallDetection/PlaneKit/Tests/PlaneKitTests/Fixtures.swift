import Foundation
import simd
@testable import PlaneKit

/// Builds a vertical plane facing +Z (a wall at depth `z`), centered at (x, y).
func wall(
    id: UUID = UUID(),
    x: Float = 0,
    y: Float = 0,
    z: Float = 0,
    width: Float = 1,
    height: Float = 1,
    yawDegrees: Float = 0,
    updates: Int = 30
) -> PlaneObservation {
    // Anchor local +Y must map to the world normal: rotate +90° about X so local Y -> world +Z,
    // then optionally yaw the whole wall about world Y.
    let tilt = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0)))
    let turn = simd_float4x4(simd_quatf(angle: yawDegrees * .pi / 180, axis: SIMD3(0, 1, 0)))
    var t = turn * tilt
    t.columns.3 = SIMD4(x, y, z, 1)
    return PlaneObservation(
        id: id, alignment: .vertical, classification: .wall, transform: t,
        center: .zero, width: width, height: height, updateCount: updates
    )
}

/// Builds a horizontal plane (floor/table) at height `y`.
func flat(
    id: UUID = UUID(),
    x: Float = 0,
    y: Float = 0,
    z: Float = 0,
    width: Float = 1,
    height: Float = 1,
    classification: PlaneClass = .floor,
    updates: Int = 30
) -> PlaneObservation {
    var t = matrix_identity_float4x4
    t.columns.3 = SIMD4(x, y, z, 1)
    return PlaneObservation(
        id: id, alignment: .horizontal, classification: classification, transform: t,
        center: .zero, width: width, height: height, updateCount: updates
    )
}
