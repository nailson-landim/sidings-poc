import SwiftUI

struct HUDView: View {
    @Bindable var controller: ARSessionController

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                stat("planes", "\(controller.keptCount)/\(controller.rawCount)")
                stat("features", "\(controller.featurePointCount)")
                stat("tracking", controller.trackingName)
                stat("LiDAR", controller.isLiDARDevice ? "yes" : "no")
            }
            Picker("Detection", selection: $controller.mode) {
                ForEach(DetectionMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("Markers", isOn: $controller.showMarkers)
                Toggle("Hide dupes", isOn: $controller.hideSuppressed)
                Button("Reset", systemImage: "arrow.counterclockwise") { controller.restart() }
                    .buttonStyle(.borderedProminent)
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
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
