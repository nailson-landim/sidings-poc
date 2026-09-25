//
//  PreviewToggleButton.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

struct PreviewToggleButton: View {
    
    @Environment(AppState.self) private var state
    
    var body: some View {
        @Bindable var state = state
        Button {
            withAnimation {
                state.previewEnabled.toggle()
            }
        } label: {
            let height = UIFont.preferredFont(forTextStyle: .title1).pointSize
            Image("CurvSurfLogo")
                .resizable()
                .scaledToFit()
                .frame(height: height + 4)
                .grayscale(state.previewEnabled ? 0 : 1)
                .padding(16)
                .tryGlassEffect(Circle())
        }
    }
}

#Preview {
    PreviewToggleButton()
        .environment(AppState.preview)
}
