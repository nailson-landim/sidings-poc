//
//  FeatureTypePicker.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

import FindSurface_iOS

struct FeatureTypePicker: View {
    
    @Environment(FindSurface.self) private var findSurface
    
    private let items: [FeatureType] = [.plane, .sphere, .cylinder]
    
    var body: some View {
        @Bindable var findSurface = findSurface
        ItemPicker(selection: $findSurface.targetFeature,
                   items: items,
                   axis: .vertical) { item in
            switch item {
            case .plane:
                Image(systemName: "square")
                    .font(.title)
                    .foregroundStyle(Color.planeUI)
                    .padding(8)
                
            case .sphere:
                Image(systemName: "basketball")
                    .font(.title)
                    .foregroundStyle(Color.sphereUI)
                    .padding(8)
                
            case .cylinder:
                Image(systemName: "cylinder")
                    .font(.title)
                    .foregroundStyle(Color.cylinderUI)
                    .padding(8)
                
            default: EmptyView()
            }
        }
        .padding(.leading, 16)
    }
}

#Preview {
    FeatureTypePicker()
        .environment(FindSurface.instance)
}
