//
//  ContentView.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

struct ContentView: View {
    
    @Environment(\.scenePhase) private var scenePhase
    
    @Environment(AppState.self) private var state
    
    var body: some View {
        @Bindable var state = state
        ZStack {
            MetalView(delegate: state)
                .ignoresSafeArea(edges: .all)
            
            UserInterfaceView()
        }
        .trackingOrientation($state.orientation)
        .onChange(of: scenePhase, initial: true) {
            switch scenePhase {
            case .inactive, .background: state.viewDidDisappear()
            case .active:                state.viewDidAppear()
            @unknown default: break
            }
        }
    }
}

#Preview {
    ContentView()
}
