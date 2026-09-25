import PlaneKit
import SwiftUI

/// *Debug › RANSAC dials* (`../EXPERIMENTS.md` *X2*): the search's band and budget, the pieces and extents, and the
/// tracker's merge limits, changed live. Each change applies from the next round on and keeps the tracks; *Restart*
/// forgets them so the walls are found afresh. While recording, each change is a `surface_dial` event.
struct RansacDialsMenu: View {
    @Bindable var controller: ARSessionController

    var body: some View {
        Menu {
            Section("Inlier band τ = base + k·range²") {
                Picker("Base", selection: $controller.surfaceSettings.tauBase) {
                    ForEach([0.02, 0.04, 0.06, 0.08] as [Float], id: \.self) { Text(Self.cm($0)).tag($0) }
                }
                Picker("k (per m²)", selection: $controller.surfaceSettings.tauPerSquareMetre) {
                    ForEach([0.003, 0.006, 0.010] as [Float], id: \.self) { Text(Self.cm($0) + "/m²").tag($0) }
                }
                Picker("Max band", selection: $controller.surfaceSettings.tauMax) {
                    ForEach([0.20, 0.35, 0.50] as [Float], id: \.self) { Text(Self.cm($0)).tag($0) }
                }
            }
            Section("Search") {
                Picker("Vertical hypotheses", selection: $controller.surfaceSettings.maxVerticalHypotheses) {
                    ForEach([500, 1500, 4000], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Confidence", selection: $controller.surfaceSettings.ransacConfidence) {
                    ForEach([0.95, 0.99, 0.999] as [Float], id: \.self) { Text(String(format: "%.1f %%", $0 * 100)).tag($0) }
                }
                Picker("Planes per search", selection: $controller.surfaceSettings.maxPlanesPerSearch) {
                    ForEach([2, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Search every", selection: $controller.surfaceSettings.discoveryEvery) {
                    ForEach([1, 2, 4, 8], id: \.self) { Text("\($0) rounds").tag($0) }
                }
                Picker("Round interval", selection: $controller.surfaceSettings.roundInterval) {
                    ForEach([0.1, 0.25, 0.5, 1.0] as [TimeInterval], id: \.self) { Text(String(format: "%.2f s", $0)).tag($0) }
                }
            }
            Section("Pieces and extents") {
                Picker("Piece cell", selection: $controller.surfaceSettings.pieceCell) {
                    ForEach([0.2, 0.4, 0.8] as [Float], id: \.self) { Text(Self.m($0)).tag($0) }
                }
                Picker("Piece link", selection: $controller.surfaceSettings.pieceLink) {
                    ForEach([1, 2, 3], id: \.self) { Text("\($0) cells").tag($0) }
                }
                Picker("Extent trim", selection: $controller.surfaceSettings.extentTrim) {
                    ForEach([0, 0.01, 0.02, 0.05] as [Float], id: \.self) {
                        Text($0 == 0 ? "off (hull)" : String(format: "%.0f %%", $0 * 100)).tag($0)
                    }
                }
                Picker("Refit margin", selection: $controller.surfaceSettings.refitMargin) {
                    ForEach([0.5, 1.0, 2.0] as [Float], id: \.self) { Text(Self.m($0)).tag($0) }
                }
            }
            Section("Tracking") {
                Picker("Slice merge distance", selection: $controller.surfaceSettings.maxPlaneDistance) {
                    ForEach([0.08, 0.15, 0.25, 0.40, 0.60, 1.0] as [Float], id: \.self) { Text(Self.cm($0)).tag($0) }
                }
                Picker("Merge gap", selection: $controller.surfaceSettings.mergeGap) {
                    ForEach([0, 0.25, 0.5, 1.0] as [Float], id: \.self) { Text($0 == 0 ? "off" : Self.m($0)).tag($0) }
                }
                Picker("Keep band", selection: $controller.surfaceSettings.keepBand) {
                    ForEach([0.10, 0.15, 0.25, 0.40] as [Float], id: \.self) { Text(Self.cm($0)).tag($0) }
                }
            }
            Section {
                Button("Benchmark on live cloud", systemImage: "stopwatch") { controller.benchmarkSurfaces() }
                Button("Restore defaults", systemImage: "arrow.uturn.backward") {
                    controller.surfaceSettings = .ransac
                }
                Button("Restart (forget planes)", systemImage: "arrow.counterclockwise") {
                    controller.restartSurfaces()
                }
            }
        } label: {
            Label("RANSAC dials", systemImage: "slider.horizontal.3")
        }
    }

    private static func cm(_ metres: Float) -> String { String(format: metres < 0.1 ? "%.1f cm" : "%.0f cm", metres * 100) }
    private static func m(_ metres: Float) -> String { String(format: metres < 1 ? "%.2f m" : "%.0f m", metres) }
}
