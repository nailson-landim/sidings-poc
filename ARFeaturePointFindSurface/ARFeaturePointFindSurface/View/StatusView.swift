//
//  StatusView.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

struct StatusView: View {
    
    @Environment(AppState.self) private var state
    
    var body: some View {
        ZStack(alignment: .leading) {
            Text("Points: 100000 pts.")
                .monospaced()
                .hidden()
            
            Text("Points: ")
                .monospaced()
            + Text("\(state.pointcloud.count, specifier: "%6d")")
                .bold()
                .monospaced()
            + Text(" pts.")
                .monospaced()
        }
        .fixedSize()
        .padding()
        .tryGlassEffect()
    }
}

#Preview {
    StatusView()
        .environment(AppState.preview)
}
