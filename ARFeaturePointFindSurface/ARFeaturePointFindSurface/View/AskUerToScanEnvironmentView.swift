//
//  AskUerToScanEnvironmentView.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

struct AskUserToScanEnvironmentView: View {
    
    @Environment(\.userInterfaceIdiom) private var userInterfaceIdiom
    
    @Environment(AppState.self) private var state
    
    @State private var tilt: Double = 15
    @State private var movingAngle: Double = 0
    
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: userInterfaceIdiom == .pad ? "ipad.gen2.landscape" : "iphone.gen2.landscape")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 44))
                .rotation3DEffect(.degrees(tilt), axis: (x: 0, y: 1, z: 0))
                .offset(x: cos(movingAngle * .pi / 180) * 16,
                        y: sin(movingAngle * .pi / 180) * 8)

            Text("Scan your surroundings using the device.")
                .font(.body)
                .foregroundStyle(.secondary)
            
            ProgressView(value: state.stabilizationHelper.progress)
                .progressViewStyle(.linear)
        }
        .frame(maxWidth: 280)
        .padding()
        .tryGlassEffect()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                tilt = -15
            }
        }
        .overlay {
            TimelineView(.animation) { timeline in
                Color.clear
                    .onChange(of: timeline.date) { _, _ in
                        movingAngle = (movingAngle + 2).truncatingRemainder(dividingBy: 360)
                    }
            }
        }
    }
}

#Preview {
    AskUserToScanEnvironmentView()
        .environment(AppState.preview)
}
