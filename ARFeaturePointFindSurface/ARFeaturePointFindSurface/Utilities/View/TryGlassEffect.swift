//
//  TryGlassEffect.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/16/25.
//

import SwiftUI

fileprivate struct DisableGlassEffectEnvironmentKey: EnvironmentKey {
    static var defaultValue: Bool = false
}

extension EnvironmentValues {
    var disableGlassEffect: Bool {
        get {
            self[DisableGlassEffectEnvironmentKey.self]
        } set {
            self[DisableGlassEffectEnvironmentKey.self] = newValue
        }
    }
}

extension View {
    func disableGlassEffect(_ disable: Bool = true) -> some View {
        environment(\.disableGlassEffect, disable)
    }
}

struct TryGlassEffectViewModifier<ClipShape: Shape>: ViewModifier {
    
    @Environment(\.disableGlassEffect) private var disableGlassEffect
    
    let shape: ClipShape
    let color: Color
    let tint: Color?
    
    func body(content: Content) -> some View {
        if disableGlassEffect {
            content
                .clipShape(shape)
                .background(shape.fill(color))
                .overlay(shape.stroke(.white, lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint), in: shape)
        } else {
            content
                .clipShape(shape)
                .background(shape.fill(color))
                .overlay(shape.stroke(.white, lineWidth: 1))
        }
    }
}

extension View {
    func tryGlassEffect<S: Shape>(_ shape: S, color: Color = .blue.opacity(0.4), tint: Color? = nil) -> some View {
        modifier(TryGlassEffectViewModifier(shape: shape, color: color, tint: tint))
    }
    
    func tryGlassEffect(color: Color = .blue.opacity(0.4),
                        tint: Color? = nil) -> some View {
        modifier(TryGlassEffectViewModifier(shape: RoundedRectangle(cornerRadius: 8, style: .continuous), color: color, tint: tint))
    }
}
