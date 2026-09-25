//
//  AskUserToScanMoreTexturedEnvironmentView.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

struct AskUserToScanMoreTexturedEnvironmentView: View {
    
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.shield.exclamationmark")
                .font(.system(size: 44))
            
            Text("Keep moving your device and aim at surfaces that are textured or have details on them.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 280)
        .padding()
        .tryGlassEffect()
    }
}

#Preview {
    AskUserToScanMoreTexturedEnvironmentView()
}
