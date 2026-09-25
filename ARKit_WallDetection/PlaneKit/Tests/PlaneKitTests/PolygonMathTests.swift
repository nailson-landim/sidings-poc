import Testing
import simd
@testable import PlaneKit

@Suite("PolygonMath")
struct PolygonMathTests {
    let unitSquare: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]

    @Test func areaOfUnitSquare() {
        #expect(abs(PolygonMath.area(unitSquare) - 1) < 1e-6)
        #expect(abs(PolygonMath.area(unitSquare.reversed()) - 1) < 1e-6)
        #expect(PolygonMath.area([SIMD2(0, 0), SIMD2(1, 1)]) == 0)
    }

    @Test func hullDropsInteriorPoints() {
        let hull = PolygonMath.convexHull(unitSquare + [SIMD2(0.5, 0.5), SIMD2(0.2, 0.7)])
        #expect(hull.count == 4)
        #expect(abs(PolygonMath.area(hull) - 1) < 1e-6)
    }

    @Test func intersectionNone() {
        let far = unitSquare.map { $0 + SIMD2(5, 5) }
        #expect(PolygonMath.area(PolygonMath.intersectConvex(unitSquare, far)) == 0)
    }

    @Test func intersectionPartial() {
        let shifted = unitSquare.map { $0 + SIMD2(0.5, 0) }
        #expect(abs(PolygonMath.area(PolygonMath.intersectConvex(unitSquare, shifted)) - 0.5) < 1e-5)
    }

    @Test func intersectionContainment() {
        let small = unitSquare.map { $0 * 0.5 + SIMD2(0.25, 0.25) }
        #expect(abs(PolygonMath.area(PolygonMath.intersectConvex(unitSquare, small)) - 0.25) < 1e-5)
    }

    @Test func normalAngleIgnoresFacing() {
        #expect(PolygonMath.normalAngleDegrees(SIMD3(0, 0, 1), SIMD3(0, 0, -1)) < 1e-3)
        #expect(abs(PolygonMath.normalAngleDegrees(SIMD3(0, 0, 1), SIMD3(1, 0, 0)) - 90) < 1e-3)
    }

    @Test func wallFixtureNormalAndArea() {
        let w = wall(width: 2, height: 3)
        #expect(simd_distance(w.worldNormal, SIMD3(0, 0, 1)) < 1e-5 || simd_distance(w.worldNormal, SIMD3(0, 0, -1)) < 1e-5)
        #expect(abs(w.area - 6) < 1e-5)
    }

    @Test func planeDistanceBetweenParallelWalls() {
        let a = wall(z: 0)
        let b = wall(z: 0.3)
        #expect(abs(PolygonMath.planeDistance(a, b) - 0.3) < 1e-5)
    }

    @Test func overlapRatioOfCoplanarWalls() {
        let a = wall(x: 0, width: 1, height: 1)
        let b = wall(x: 0.5, width: 1, height: 1)
        #expect(abs(PolygonMath.overlapRatio(a, b) - 0.5) < 1e-4)
        let inside = wall(x: 0, width: 0.4, height: 0.4)
        #expect(abs(PolygonMath.overlapRatio(a, inside) - 1) < 1e-4)
    }

    @Test func boundaryPolygonPreferredOverExtent() {
        var w = wall(width: 10, height: 10)
        w.boundaryLocal = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)]
        #expect(abs(w.area - 0.5) < 1e-6)
    }

    @Test func yawRotatesExtentRectangle() {
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4(0, 0, 0, 1)
        let p = PlaneObservation(
            id: .init(), alignment: .horizontal, transform: t,
            center: .zero, width: 2, height: 0.001, yaw: .pi / 2
        )
        // Width now lies along Z instead of X.
        let zs = p.worldBoundary.map(\.z)
        #expect(abs((zs.max()! - zs.min()!) - 2) < 1e-4)
    }
}
