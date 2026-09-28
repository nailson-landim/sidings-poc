import SwiftUI

struct HUDView: View {
    @Bindable var controller: ARSessionController

    var body: some View {
        VStack(spacing: 8) {
            if controller.video.isRecording {
                videoSpikeStats
            }
            HStack {
                stat("planes", "\(controller.keptCount)/\(controller.rawCount)")
                stat("points", "\(controller.featurePointCount)")
                stat("mem MB", String(format: "%.0f", controller.memoryMB))
                stat("fps", String(format: "%.0f", controller.fps))
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
                    Toggle("Rec video (R1 spike)", isOn: Binding(
                        get: { controller.video.isRecording },
                        set: { controller.setVideoSpike($0) }
                    ))
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

    /// Spike R1 readout (`../SPEC.md` §18 T3).
    private var videoSpikeStats: some View {
        let video = controller.video
        return HStack {
            stat("REC s", String(format: "%.0f", video.elapsed))
            stat("fps", String(format: "%.0f", video.fps))
            stat("dropped", "\(video.dropped)")
            stat("copy p95", String(format: "%.1f ms", video.copyP95Ms))
            stat("thermal", "\(video.thermal.rawValue)")
        }
        .foregroundStyle(.red)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
