//
//  UIInterfaceOrientation.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 8/27/25.
//

import SwiftUI
import UIKit

extension UIInterfaceOrientation {
    static var currentValue: UIInterfaceOrientation {
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?.windowScene?.effectiveGeometry
            .interfaceOrientation ?? UIApplication.shared.statusBarOrientation
    }
}
