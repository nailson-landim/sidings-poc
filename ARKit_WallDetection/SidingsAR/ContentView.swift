import ARKit
import RealityKit
import SwiftUI

struct ContentView: View {
    @Bindable var controller: ARSessionController

    var body: some View {
        ARViewContainer(controller: controller)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                if let banner = controller.banner {
                    Text(banner)
                        .font(.footnote.weight(.semibold))
                        .padding(8)
                        .background(.orange.opacity(0.9), in: .rect(cornerRadius: 8))
                        .padding(.top, 8)
                }
            }
            .overlay(alignment: .bottom) {
                HUDView(controller: controller)
            }
            .onAppear { controller.start() }
            .onDisappear { controller.pause() }
            .alert(
                "AR session error",
                isPresented: Binding(
                    get: { controller.errorMessage != nil },
                    set: { if !$0 { controller.errorMessage = nil } }
                )
            ) {
                Button("Reset") { controller.restart() }
                Button("OK", role: .cancel) {}
            } message: {
                Text(controller.errorMessage ?? "")
            }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let controller: ARSessionController

    func makeUIView(context: Context) -> ARView {
        let arView = controller.arView
        // Labels sit above the 3D content but below the coaching overlay.
        let labels = controller.labelView
        labels.frame = arView.bounds
        arView.addSubview(labels)
        let coaching = ARCoachingOverlayView()
        coaching.session = arView.session
        coaching.goal = .anyPlane
        coaching.activatesAutomatically = true
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(coaching)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
