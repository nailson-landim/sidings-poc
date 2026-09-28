import SwiftUI

struct HUDView: View {
    @Bindable var controller: ARSessionController

    var body: some View {
        VStack(spacing: 8) {
            if controller.recorder.isRecording {
                recordingStats
            } else if let result = controller.recorder.lastResult {
                Text(result).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
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
                } label: {
                    Label("Debug", systemImage: "ladybug")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                recordButton
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

    private var recordButton: some View {
        let recording = controller.recorder.isRecording
        return Button(recording ? "Stop" : "Record", systemImage: recording ? "stop.circle.fill" : "record.circle") {
            controller.toggleRecording()
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    /// Plane Lab recording readout (`../SPEC.md` §4 R2).
    private var recordingStats: some View {
        let recorder = controller.recorder
        return HStack {
            stat("REC s", String(format: "%.0f", recorder.elapsed))
            stat("frames", "\(recorder.frames)")
            stat("dropped", "\(recorder.framesDropped)")
            stat("no image", "\(recorder.imagesDropped)")
            stat("MB", String(format: "%.0f", recorder.megabytes))
            stat("free GB", String(format: "%.1f", recorder.freeGB))
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
