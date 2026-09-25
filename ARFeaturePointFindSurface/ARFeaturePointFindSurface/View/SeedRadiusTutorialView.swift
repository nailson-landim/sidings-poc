//
//  SeedRadiusTutorialView.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

struct SeedRadiusTutorialView: View {
    
    @AppStorage("show-tutorial-on-launch") private var showTutorialOnLaunch: Bool = true
    
    @Binding var show: Bool
    @State private var scale: CGFloat = 0.2
    @State private var neverShowAgain: Bool = false
    
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "hand.pinch.fill")
                    .font(.system(size: 44))
                Image(systemName: "arrowshape.right.fill")
                    .font(.system(size: 44))
                
                ZStack {
                    let size: CGFloat = 44 * scale
                    Image(systemName: "basketball.fill")
                        .font(.system(size: 44))
                    
                    Circle()
                        .stroke(.green.opacity(1.0), style: .init(lineWidth: 2, lineCap: .round, dash: [2.5, 5]))
                        .frame(width: size, height: size)
                        .offset(x: 10, y: 10)
                        .opacity(1.0)
                }
                .compositingGroup()
            }
            
            Text("Pinch the screen to adjust the green circle to be slightly smaller than the object's size.")
                .font(.body)
                .foregroundStyle(.secondary)
            
            HStack {
                Button {
                    neverShowAgain.toggle()
                } label: {
                    Label("Don't show again", systemImage: neverShowAgain ? "checkmark.square.fill" : "square")
                }
                Spacer()
                if #available(iOS 26.0, *) {
                    Button("Dismiss", role: .close) {
                        showTutorialOnLaunch = !neverShowAgain
                        show = false
                    }
                    .buttonStyle(.glass)
                } else {
                    Button("Dismiss", role: .cancel) {
                        showTutorialOnLaunch = !neverShowAgain
                        show = false
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: 280)
        .onAppear {
            withAnimation(.spring(duration: 2.0).repeatForever(autoreverses: false)) {
                scale = 0.8
            }
        }
        .padding(16)
        .tryGlassEffect()
    }
}

#Preview {
    SeedRadiusTutorialView(show: .constant(true))
}
