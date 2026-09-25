//
//  ViewAligner.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/2/25.
//

import SwiftUI

private struct ViewAligner: ViewModifier {
    let horizontalAlignment: HorizontalAlignment?
    let verticalAlignment: VerticalAlignment?
    
    init(horizontal horizontalAlignment: HorizontalAlignment?,
         vertical verticalAlignment: VerticalAlignment?) {
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
    }
    
    func body(content: Content) -> some View {
        let hLayout = if horizontalAlignment != nil {
            AnyLayout(HStackLayout(alignment: verticalAlignment ?? .center))
        } else {
            AnyLayout(ZStackLayout())
        }
        
        let vLayout = if verticalAlignment != nil {
            AnyLayout(VStackLayout(alignment: horizontalAlignment ?? .center))
        } else {
            AnyLayout(ZStackLayout())
        }
        
        hLayout {
            if horizontalAlignment != .leading { Spacer() }
            vLayout {
                if verticalAlignment != .top { Spacer() }
                content
                if verticalAlignment != .bottom { Spacer() }
            }
            if horizontalAlignment != .trailing { Spacer() }
        }
    }
}

extension View {
    func aligned(horizontal horizontalAlignment: HorizontalAlignment? = nil,
                 vertical verticalAlignment: VerticalAlignment? = nil) -> some View {
        modifier(ViewAligner(horizontal: horizontalAlignment,
                                    vertical: verticalAlignment))
    }
}
