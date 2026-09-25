//
//  UserInterfaceView.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

struct UserInterfaceView: View {
    
    @Environment(\.userInterfaceIdiom) private var userInterfaceIdiom
    
    @Environment(AppState.self) private var state
    
    @AppStorage("show-tutorial-on-launch") private var showTutorialOnLaunch: Bool = true
    
    @State private var showTutorial: Bool = true
    
    var body: some View {
        let isiPad = userInterfaceIdiom == .pad
        @Bindable var state = state
        ZStack {
            if state.hasMotionTrackingStabilized {
                RadiusControlView()
                
                HStack(alignment: .top, spacing: 16) {
                    StatusView()
                        
                    if !isiPad && showTutorial && showTutorialOnLaunch {
                        SeedRadiusTutorialView(show: $showTutorial)
                    }
                }
                .padding(16)
                .aligned(horizontal: .leading,
                         vertical: .top)
                
                if isiPad && showTutorial && showTutorialOnLaunch {
                    SeedRadiusTutorialView(show: $showTutorial)
                        .padding(16)
                        .aligned(horizontal: .trailing,
                                 vertical: .top)
                }
                
                FeatureTypePicker()
                    .aligned(horizontal: .leading)
                
                VStack(alignment: .trailing, spacing: 16) {
                    RecordingToggleButton()
                    PreviewToggleButton()
                    CaptureButton()
                    UndoButton()
                }
                .padding(.trailing, isiPad ? 16 : nil)
                .aligned(horizontal: .trailing,
                         vertical: .bottom)
                
            } else {
                if !state.enoughFeaturesDetected && state.motionTrackingStabilizationStarted {
                     AskUserToScanMoreTexturedEnvironmentView()
                } else {
                     AskUserToScanEnvironmentView()
                }
            }
        }
        .toast(message: $state.toastMessage,
               alignment: .bottom)
        .sheet(isPresented: state.exportBinding) {
            if let url = state.exportURL {
                ShareSheet(activityItems: [url])
            }
        }
    }
}

import FindSurface_iOS

#Preview {
    UserInterfaceView()
        .environment(AppState.preview)
        .environment(FindSurface.instance)
}
