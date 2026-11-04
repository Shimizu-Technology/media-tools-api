import SwiftUI
import UIKit

/// Ledger: paper and ink. A reading-first notebook that happens to record.
///
/// The color names match the web app's tokens in `frontend/src/index.css`, so keep
/// the two in step. Values live in `Ledger.xcassets`, with light, dark, and Increase
/// Contrast variants, and this file compiles into the app and both extensions.
///
/// Red is for active recording. `danger` shares the value but not the meaning, and
/// errors stay in ink with an icon.
enum Theme {
    static let bg = Color("Ledger/bg")
    static let surface = Color("Ledger/surface")
    static let text = Color("Ledger/text")
    static let textSecondary = Color("Ledger/text-secondary")
    static let separator = Color("Ledger/separator")
    static let accent = Color("Ledger/accent")
    static let accentFill = Color("Ledger/accent-fill")
    static let onAccent = Color("Ledger/on-accent")
    static let record = Color("Ledger/record")
    static let onRecord = Color("Ledger/on-record")
    static let danger = Color("Ledger/danger")
    static let onDanger = Color("Ledger/on-danger")
    static let fill = Color("Ledger/fill")
    static let accentTint = Color("Ledger/accent-tint")

    // Three radii. Pills use Capsule.
    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 16

    /// Press feedback and small state changes: fast enough to stay out of the way.
    static let quick = Animation.easeOut(duration: 0.14)
    /// A reveal or a swap on screen. A strong ease-out, because the eye should land
    /// on the result rather than watch the trip.
    static let settle = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
}

/// New York carries titles and reading; SF carries controls and metadata, which are
/// the plain system text styles. Everything here follows Dynamic Type.
extension Font {
    static let ledgerLargeTitle = Font.system(.largeTitle, design: .serif, weight: .bold)
    static let ledgerTitle = Font.system(.title, design: .serif, weight: .bold)
    static let ledgerTitle2 = Font.system(.title2, design: .serif, weight: .bold)
    static let ledgerTitle3 = Font.system(.title3, design: .serif, weight: .semibold)
    static let ledgerHeadline = Font.system(.headline, design: .serif, weight: .semibold)
    static let ledgerRowTitle = Font.system(.body, design: .serif, weight: .semibold)
    static let ledgerReading = Font.system(.body, design: .serif)
    /// Day headers in the Library and other small section labels.
    static let ledgerSectionLabel = Font.system(.subheadline, design: .serif, weight: .semibold).italic()
}

/// For the places that are UIKit underneath: bar appearances and the share card.
extension UIColor {
    static func ledger(_ name: String) -> UIColor {
        UIColor(named: "Ledger/\(name)") ?? .label
    }
}

extension UIFont {
    /// New York at a text style. The metrics wrapper keeps it scaling with Dynamic Type.
    static func ledgerSerif(_ style: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.preferredFont(
            forTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        )
        let weighted = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        let descriptor = weighted.withDesign(.serif) ?? weighted
        return UIFontMetrics(forTextStyle: style)
            .scaledFont(for: UIFont(descriptor: descriptor, size: base.pointSize))
    }
}
