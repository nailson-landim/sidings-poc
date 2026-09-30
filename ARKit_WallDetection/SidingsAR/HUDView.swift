import PlaneKit
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
                stat("cloud", "\(controller.cloudCount)")
                stat("mem MB", String(format: "%.0f", controller.memoryMB))
                stat("fps", String(format: "%.0f", controller.fps))
                stat("exp ms", String(format: controller.exposureMS < 1 ? "%.2f" : "%.1f", controller.exposureMS))
                stat("ISO", controller.iso.map { String(format: "%.0f", $0) } ?? "–")
                stat("tracking", controller.trackingName)
                stat("LiDAR", controller.isLiDARDevice ? "yes" : "no")
            }
            // One control row: the app is locked to Landscape Right, where height is scarce.
            HStack {
                Picker("Detection", selection: $controller.mode) {
                    ForEach(DetectionMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Menu {
                    Toggle("Averaged cloud", isOn: $controller.showCloud)
                    Toggle("Feature points", isOn: $controller.showFeaturePoints)
                    Toggle("Anchor markers", isOn: $controller.showMarkers)
                    Toggle("Hide duplicates", isOn: $controller.hideSuppressed)
                    Toggle("Render statistics", isOn: $controller.showStatistics)
                    if controller.exposureControlAvailable == false {
                        Text("Exposure: ARKit won't share the camera")
                    } else {
                        Picker("Max exposure", selection: $controller.exposureCap) {
                            ForEach(ExposureCap.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                } label: {
                    Label("Debug", systemImage: "ladybug")
                }
                .buttonStyle(.bordered)
                recordButton
                if controller.recorder.isRecording {
                    Button("Mark", systemImage: "flag.fill") { controller.recorder.mark() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                }
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
            stat("marks", "\(recorder.marks)")
            stat("stills", recorder.stillsFailed > 0 ? "\(recorder.stills) (\(recorder.stillsFailed)✗)" : "\(recorder.stills)")
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
