import SwiftUI

struct HUDView: View {
    @Bindable var controller: ARSessionController

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                stat("planes", "\(controller.keptCount)/\(controller.rawCount)")
                stat("points", "\(controller.featurePointCount)")
                stat("mem MB", String(format: "%.0f", controller.memoryMB))
                stat("tracking", controller.trackingName)
                stat("LiDAR", controller.isLiDARDevice ? "yes" : "no")
            }
            Picker("Detection", selection: $controller.mode) {
                ForEach(DetectionMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Menu {
                    Toggle("Feature points", isOn: $controller.showFeaturePoints)
                    Toggle("Anchor markers", isOn: $controller.showMarkers)
                    Toggle("Hide duplicates", isOn: $controller.hideSuppressed)
                    Toggle("Render statistics", isOn: $controller.showStatistics)
                } label: {
                    Label("Debug", systemImage: "ladybug")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button("Reset", systemImage: "arrow.counterclockwise") { controller.restart() }
                    .buttonStyle(.borderedProminent)
            }
            .font(.caption)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
