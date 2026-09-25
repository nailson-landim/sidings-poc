//
//  RadiusControlView.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

struct RadiusControlView: View {
    
    @Environment(\.scenePhase) private var scenePhase
    
    @Environment(AppState.self) private var state
    
    @State private var oldRatio: CGFloat = .zero
    
    @GestureState private var magnifying: Bool = false
    
    @AppStorage("seed-radius-ratio") private var seedRadiusRatio: Double = 0.5
    
    var body: some View {
        GeometryReader { geometry in
            let diameter = state.orientation.isLandscape ? geometry.size.height : geometry.size.width
            ZStack(alignment: .center) {
                RadiusView(ratio: state.probeRadiusRatio,
                           diameter: diameter,
                           lineColor: .purple,
                           strokeStyle: .init(lineWidth: 1,
                                              lineCap: .round,
                                              dash: [5, 10]))
                
                RadiusView(ratio: state.seedRadiusRatio,
                           diameter: diameter,
                           lineColor: .green,
                           strokeStyle: .init(lineWidth: 2,
                                              lineCap: .square,
                                              dash: [2, 4]))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.00001))
            .onChange(of: scenePhase, initial: true) {
                switch scenePhase {
                case .inactive, .background:
                    seedRadiusRatio = state.seedRadiusRatio
                case .active:
                    let diameter = state.orientation.isLandscape ? geometry.size.height : geometry.size.width
                    state.probeRadiusRatio = 50 / diameter
                    state.seedRadiusRatio = seedRadiusRatio
                default: break
                }
            }
        }
        .ignoresSafeArea(.all)
        .gesture(magnifyGesture)
        
    }
    
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { event in
                if !magnifying {
                    oldRatio = state.seedRadiusRatio
                }
                let magnification = pow(event.magnification, 1.1)
                state.seedRadiusRatio = min(max(oldRatio * magnification, 0.01), 1.0)
            }
            .updating($magnifying) { _, state, _ in
                state = true
            }
            .onEnded { event in
                let magnification = pow(event.magnification, 1.1)
                state.seedRadiusRatio = min(max(oldRatio * magnification, 0.01), 1.0)
            }
    }
}

private struct RadiusView: View {
    
    public var ratio: CGFloat
    public let diameter: CGFloat
    public let lineColor: Color
    public let strokeStyle: StrokeStyle
    
    public init(ratio: CGFloat,
                diameter: CGFloat,
                lineColor: Color,
                strokeStyle: StrokeStyle) {
        self.ratio = ratio
        self.diameter = diameter
        self.lineColor = lineColor
        self.strokeStyle = strokeStyle
    }
    
    var body: some View {
        let size = max(0.0, ratio * diameter - 1)
        Group {
            if size > 1 {
                Circle()
                    .stroke(lineColor, style: strokeStyle)
                    .frame(width: size, height: size)
            }
            else {
                EmptyView()
            }
        }
    }
}

extension RadiusView {
    init(ratio: CGFloat,
                diameter: CGFloat,
                lineColor: Color,
                lineWidth: CGFloat = 2.0) {
        self.init(ratio: ratio, diameter: diameter, lineColor: lineColor, strokeStyle: .init(lineWidth: lineWidth))
    }
}

#Preview {
    RadiusControlView()
        .environment(AppState.preview)
}
