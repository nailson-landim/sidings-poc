//
//  CaptureButton.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

struct CaptureButton: View {
    
    @Environment(AppState.self) private var state
    
    var body: some View {
        Button {
            state.hasToSaveOne = true
        } label: {
            Image(systemName: "camera.aperture")
                .font(.title)
                .padding(16)
                .tryGlassEffect(Circle())
        }
        .disabled(state.pointcloud.isEmpty)
    }
}

#Preview {
    CaptureButton()
        .environment(AppState.preview)
}
