// RANSAC speed on a real cloud (EXPERIMENTS.md, X2, "Is RANSAC real-time?", 2026-10-01).
//   python export_cloud.py 20261001-142809.planelab cloud.f32
//   swiftc -O -o ransac_bench ransac_bench.swift && ./ransac_bench cloud.f32
import Foundation
import simd

// Sequential RANSAC with vertical (2-point) and horizontal (1-point) priors, like the probe, on the real cloud.
let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let floats = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
let n = floats.count / 4
var points = [SIMD3<Float>](); var tau = [Float]()
for i in 0..<n { points.append(SIMD3(floats[4*i], floats[4*i+1], floats[4*i+2])); tau.append(floats[4*i+3]) }

struct RNG: RandomNumberGenerator { var s: UInt64; mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }

func run(hHyps: Int, vHyps: Int, adaptive: Bool, local: Bool, maxPlanes: Int = 10) -> (planes: Int, tests: Int) {
    var rng = RNG(s: 7)
    var left = Array(0..<n)
    var planes = 0, tests = 0
    for _ in 0..<maxPlanes {
        guard left.count >= 150 else { break }
        let p = left.map { points[$0] }, t = left.map { tau[$0] }
        let m = p.count
        var best = 0, bestN = SIMD3<Float>(0, 1, 0), bestC = SIMD3<Float>.zero
        func score(_ nrm: SIMD3<Float>, _ c: SIMD3<Float>) -> Int {
            var count = 0
            p.withUnsafeBufferPointer { pp in t.withUnsafeBufferPointer { tt in
                for i in 0..<m where abs(simd_dot(nrm, pp[i] - c)) < tt[i] { count += 1 }
            } }
            tests += m
            return count
        }
        func budget(_ s: Int, _ tried: Int, _ cap: Int) -> Bool {
            guard adaptive, best > 0 else { return tried < cap }
            let w = Double(best) / Double(m)
            let k = log(0.01) / log(max(1e-12, 1 - pow(w, Double(s))))
            return tried < min(cap, Int(k.rounded(.up)))
        }
        var tried = 0
        while budget(1, tried, hHyps) {
            tried += 1
            let c = p[Int.random(in: 0..<m, using: &rng)]
            let s = score(SIMD3(0, 1, 0), c)
            if s > best { best = s; bestN = SIMD3(0, 1, 0); bestC = c }
        }
        tried = 0
        while budget(2, tried, vHyps) {
            tried += 1
            let i = Int.random(in: 0..<m, using: &rng)
            var j = Int.random(in: 0..<m, using: &rng)
            if local { // NAPSAC-ish: retry until the partner is within 2 m
                for _ in 0..<20 where simd_distance(p[i], p[j]) > 2 { j = Int.random(in: 0..<m, using: &rng) }
            }
            var d = p[j] - p[i]; d.y = 0
            guard simd_length(d) >= 0.3 else { continue }
            let nrm = simd_normalize(simd_cross(d, SIMD3(0, 1, 0)))
            let s = score(nrm, p[i])
            if s > best { best = s; bestN = nrm; bestC = p[i] }
        }
        guard best >= 150 else { break }
        planes += 1
        left = left.filter { abs(simd_dot(bestN, points[$0] - bestC)) >= tau[$0] }
    }
    return (planes, tests)
}

func time(_ label: String, _ body: () -> (planes: Int, tests: Int)) {
    var r = (planes: 0, tests: 0)
    let clock = ContinuousClock()
    var best = Duration.seconds(100)
    for _ in 0..<5 { let d = clock.measure { r = body() }; best = min(best, d) }
    let ms = Double(best.components.attoseconds) / 1e15 + Double(best.components.seconds) * 1000
    print(String(format: "%-58@ %7.1f ms  %2d planes  %6.1f M point tests", label as NSString, ms, r.planes, Double(r.tests) / 1e6))
}

print("cloud: \(n) points (20261001-142809, final), one core, -O")
time("probe as is: 400 H + 3000 V hypotheses per plane") { run(hHyps: 400, vHyps: 3000, adaptive: false, local: false) }
time("adaptive k (p = 0.99), capped at 400 / 3000") { run(hHyps: 400, vHyps: 3000, adaptive: true, local: false) }
time("adaptive k + local pairs (NAPSAC-ish, 2 m)") { run(hHyps: 400, vHyps: 3000, adaptive: true, local: true) }
time("adaptive + local, 3 planes only") { run(hHyps: 400, vHyps: 3000, adaptive: true, local: true, maxPlanes: 3) }
