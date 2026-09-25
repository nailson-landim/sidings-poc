//
//  TrackingUIInterfaceOrientation.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

// An observer and view to track UI interface orientation changes.
private class OrientationObserver: UIViewController {
    var onOrientationChange: ((UIInterfaceOrientation) -> Void)?
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        onOrientationChange?(view.window?.windowScene?.interfaceOrientation ?? .currentValue)
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in
            let newOrientation = self.view.window?.windowScene?.interfaceOrientation ?? .currentValue
            self.onOrientationChange?(newOrientation)
        }
    }
}

private struct OrientationView: UIViewControllerRepresentable {
    @Binding var orientation: UIInterfaceOrientation
    
    func makeUIViewController(context: Context) -> OrientationObserver {
        let viewController = OrientationObserver()
        viewController.onOrientationChange = { newOrientation in
            DispatchQueue.main.async {
                self.orientation = newOrientation
            }
        }
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: OrientationObserver, context: Context) {}
}

private struct OrientationModifier: ViewModifier {
    @Binding var orientation: UIInterfaceOrientation
    func body(content: Content) -> some View {
        content
            .background(OrientationView(orientation: $orientation))
            .environment(\.interfaceOrientation, orientation)
    }
}

extension View {
    public func trackingOrientation(_ orientation: Binding<UIInterfaceOrientation>) -> some View {
        modifier(OrientationModifier(orientation: orientation))
    }
}

private struct UIInterfaceOrientationEnvironmentKey: EnvironmentKey {
    static let defaultValue = UIInterfaceOrientation.currentValue
}

extension EnvironmentValues {
    public var interfaceOrientation: UIInterfaceOrientation {
        get {
            self[UIInterfaceOrientationEnvironmentKey.self]
        } set {
            self[UIInterfaceOrientationEnvironmentKey.self] = newValue
        }
    }
}
