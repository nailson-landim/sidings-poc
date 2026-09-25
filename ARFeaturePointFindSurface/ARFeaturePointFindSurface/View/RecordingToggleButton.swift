//
//  RecordingToggleButton.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

struct RecordingToggleButton: View {
    
    @Environment(AppState.self) private var state
    
    var body: some View {
        @Bindable var state = state
        Button {
            withAnimation {
                state.recording.toggle()
            }
        } label: {
            let imageOn = Image(systemName: "stop.fill")
                .font(.title)
            let imageOff = Image(systemName: "record.circle")
                .font(.title)
                .foregroundStyle(.red)
                
            ZStack(alignment: .center) {
                imageOn.hidden()
                imageOff.hidden()
                if state.recording {
                    imageOn
                } else {
                    imageOff
                }
            }
            .padding(16)
            .tryGlassEffect(Circle())
            .onLongPressGesture {
                state.toastMessage = "🗑️ Points cleared!"
                state.clearPoints()
            }
        }
    }
}

#Preview {
    RecordingToggleButton()
        .environment(AppState.preview)
}
