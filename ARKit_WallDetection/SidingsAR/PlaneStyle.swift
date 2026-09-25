import PlaneKit
import UIKit

enum PlaneStyle {
    static let fillOpacity: Float = 0.35
    static let suppressedOpacity: Float = 0.15
    static let markerColor = UIColor.magenta

    static func color(for observation: PlaneObservation) -> UIColor {
        switch observation.classification {
        case .wall: .cyan
        case .floor: .green
        case .ceiling: .yellow
        case .table, .seat: .orange
        case .door, .window: .purple
        case .none: observation.alignment == .vertical ? .cyan : .white
        }
    }

    /// `W" × H"  (A ft²)  class`, inches like the original tutorial.
    static func label(for observation: PlaneObservation, width: Float, height: Float) -> String {
        let inches: Float = 39.3701
        let sqft = observation.area * 10.7639
        var text = String(format: "%.0f\" × %.0f\"  (%.1f ft²)", width * inches, height * inches, sqft)
        if observation.classification != .none {
            text += "\n\(observation.classification.rawValue)"
        }
        return text
    }
}
