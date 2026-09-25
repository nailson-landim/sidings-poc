//
//  UserInterfaceIdiom.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/2/25.
//

import SwiftUI

private struct UserInterfaceIdiomEnvironmentKey: EnvironmentKey {
    static let defaultValue = UIUserInterfaceIdiom.unspecified
}

extension EnvironmentValues {
    var userInterfaceIdiom: UIUserInterfaceIdiom {
        get {
            self[UserInterfaceIdiomEnvironmentKey.self]
        } set {
            self[UserInterfaceIdiomEnvironmentKey.self] = newValue
        }
    }
}
