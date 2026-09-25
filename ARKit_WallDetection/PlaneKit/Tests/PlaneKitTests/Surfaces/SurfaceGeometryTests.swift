import Foundation
import simd
import Testing
@testable import PlaneKit

@Suite("X1 geometry: principal axes, seeds, mesh")
struct SurfaceGeometryTests {
    @Test func eigenOfADiagonalMatrixIsItsDiagonal() {
        let (values, _) = PrincipalAxes.symmetricEigen([3, 0, 0, 0, 1, 0, 0, 0, 2])
        #expect(values.sorted() == [1, 2, 3])
    }

    @Test func eigenVectorsSatisfyTheDefinition() {
        let m: [Double] = [4, 1, 0.5, 1, 3, 0.2, 0.5, 0.2, 1]
        let (values, vectors) = PrincipalAxes.symmetricEigen(m)
        for k in 0..<3 {
            let v = SIMD3(vectors[k], vectors[3 + k], vectors[6 + k])
            let mv = SIMD3(
                m[0] * v.x + m[1] * v.y + m[2] * v.z,
                m[3] * v.x + m[4] * v.y + m[5] * v.z,
                m[6] * v.x + m[7] * v.y + m[8] * v.z
            )
            #expect(simd_length(mv - values[k] * v) < 1e-9)
        }
    }

    @Test func aFlatPatchHasItsNormalNoThicknessAndItsWidthAsSpread() throws {
        let patch = Patch(origin: SIMD3(0, 0, -3), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 2, height: 1, spacing: 0.05)
        let axes = try #require(PrincipalAxes(patch.lattice()))
        #expect(degrees(axes.normal, SIMD3(0, 0, 1)) < 0.01)
        #expect(axes.thickness < 1e-4)
        #expect(abs(axes.spread - 1.05) < 0.03) // a lattice of n points spans n × spacing as a uniform strip
        #expect(simd_distance(axes.center, SIMD3(1, 0.5, -3)) < 1e-4)
    }

    @Test func fewerThanThreePointsHaveNoAxes() {
        #expect(PrincipalAxes([SIMD3<Float>(0, 0, 0), SIMD3(1, 0, 0)]) == nil)
    }

    @Test func seedRadiusScalesWithRangeAndIsClamped() {
        let s = SurfaceSettings()
        #expect(s.seedRadius(range: 0.1) == s.seedRadiusMin)
        #expect(abs(s.seedRadius(range: 5) - 1.0) < 1e-6)
        #expect(s.seedRadius(range: 100) == s.seedRadiusMax)
    }

    @Test func seedCellsAreFlattestThenDensestThenNearest() {
        // Equally flat: a dense cell, a sparse one, and a dense one farther away.
        var points: [SIMD3<Float>] = []
        let dense = Patch(origin: SIMD3(-0.95, 0.05, -2.25), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.4, height: 0.4)
        let sparse = Patch(
            origin: SIMD3(0.05, 0.05, -2.25), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.4, height: 0.4, spacing: 0.2
        )
        let far = Patch(origin: SIMD3(-0.95, 0.05, -6.25), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.4, height: 0.4)
        points = dense.lattice() + sparse.lattice() + far.lattice()
        var settings = SurfaceSettings()
        settings.minSeedCellPoints = 8
        let cells = SeedPicker.cells(
            points: points, samples: .init(repeating: 20, count: points.count),
            claimed: .init(repeating: false, count: points.count), eye: .zero, settings: settings
        )
        // The sparse cell (9 points) passes; dense and far have 25 each, the nearer one first.
        #expect(cells.map(\.indices.count) == [25, 25, 9])
        #expect(cells[0].range < cells[1].range)

        // A denser cell that is less flat comes after all three.
        var rng = SplitMix64(state: 1)
        let rough = Patch(origin: SIMD3(1.05, 0.05, -2.25), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.4, height: 0.4, spacing: 0.05)
            .lattice().map { $0 + SIMD3(0, 0, 0.01 * rng.gaussian()) }
        let withRough = points + rough
        let ordered = SeedPicker.cells(
            points: withRough, samples: .init(repeating: 20, count: withRough.count),
            claimed: .init(repeating: false, count: withRough.count), eye: .zero, settings: settings
        )
        #expect(ordered.map(\.indices.count) == [25, 25, 9, 81])
    }

    @Test func seedCellsSkipClaimedYoungFarAndThickPoints() {
        let wall = Patch(origin: SIMD3(-0.2, 0.05, -2.25), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.4, height: 0.4)
        let points = wall.lattice()
        let n = points.count
        var settings = SurfaceSettings()
        let all = SeedPicker.cells(
            points: points, samples: .init(repeating: 20, count: n), claimed: .init(repeating: false, count: n),
            eye: .zero, settings: settings
        )
        #expect(!all.isEmpty)
        #expect(SeedPicker.cells(
            points: points, samples: .init(repeating: 20, count: n), claimed: .init(repeating: true, count: n),
            eye: .zero, settings: settings
        ).isEmpty)
        #expect(SeedPicker.cells(
            points: points, samples: .init(repeating: 9, count: n), claimed: .init(repeating: false, count: n),
            eye: .zero, settings: settings
        ).isEmpty)
        settings.maxSeedRange = 1
        #expect(SeedPicker.cells(
            points: points, samples: .init(repeating: 20, count: n), claimed: .init(repeating: false, count: n),
            eye: .zero, settings: settings
        ).isEmpty)

        // A corner inside one cell is too thick to seed.
        let corner = Patch(origin: SIMD3(0.05, 0.05, -2.45), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.4, height: 0.4)
            .lattice()
            + Patch(origin: SIMD3(0.05, 0.05, -2.45), u: SIMD3(0, 0, 1), v: SIMD3(0, 1, 0), width: 0.4, height: 0.4).lattice()
        #expect(SeedPicker.cells(
            points: corner, samples: .init(repeating: 20, count: corner.count),
            claimed: .init(repeating: false, count: corner.count), eye: .zero, settings: SurfaceSettings()
        ).isEmpty)
    }

    @Test func aSeedIsTheFreePointNearestTheCentroidUntilTheCellIsTaken() throws {
        let wall = Patch(origin: SIMD3(0.05, 0.05, -2.25), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), width: 0.4, height: 0.4)
        let points = wall.lattice()
        var claimed = [Bool](repeating: false, count: points.count)
        let settings = SurfaceSettings()
        let cell = try #require(SeedPicker.cells(
            points: points, samples: .init(repeating: 20, count: points.count), claimed: claimed, eye: .zero,
            settings: settings
        ).first)
        let seed = try #require(SeedPicker.seed(in: cell, points: points, claimed: claimed, eye: .zero, settings: settings))
        #expect(simd_distance(points[seed.index], SIMD3(0.25, 0.25, -2.25)) < 1e-4)
        #expect(seed.radius == settings.seedRadius(range: simd_length(points[seed.index])))
        for i in claimed.indices.dropLast(settings.minSeedCellPoints - 1) { claimed[i] = true }
        #expect(SeedPicker.seed(in: cell, points: points, claimed: claimed, eye: .zero, settings: settings) == nil)
    }

    @Test func anOutlineFansIntoTriangles() {
        let square: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)]
        let mesh = SurfaceMesh.fan(square)
        #expect(mesh.positions == square)
        #expect(mesh.indices == [0, 1, 2, 0, 2, 3])
        #expect(SurfaceMesh.fan(Array(square.prefix(2))).indices.isEmpty)
    }
}
