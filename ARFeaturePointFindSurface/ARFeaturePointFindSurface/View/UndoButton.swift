//
//  UndoButton.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

struct UndoButton: View {
    
    @Environment(AppState.self) private var state
    
    var body: some View {
        Button {
            state.undoDetectingGeometry()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.title)
                .padding(16)
                .tryGlassEffect(Circle())
                .onLongPressGesture {
                    state.toastMessage = "🗑️ Geometries cleared!"
                    state.clearGeometries()
                }
        }
        .disabled(state.transactions.isEmpty)
    }
}

#Preview {
    UndoButton()
        .environment(AppState.preview)
}
