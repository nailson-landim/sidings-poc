//
//  ARFeaturePointFindSurfaceApp.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

import FindSurface_iOS

fileprivate var isPreview: Bool {
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}

@main
struct ARFeaturePointFindSurfaceApp: App {
    
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var state = AppState(preview: isPreview)
    @State private var findSurface = FindSurface.instance
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onChange(of: scenePhase) {
                    if scenePhase == .active {
                        findSurface.measurementAccuracy = 0.10
                        findSurface.meanDistance = 0.50
                    }
                }
                .environment(state)
                .environment(findSurface)
                .environment(\.userInterfaceIdiom, UIDevice.current.userInterfaceIdiom)
        }
    }
}
