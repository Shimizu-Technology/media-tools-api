import SwiftUI
import UIKit

/// Sunrise Home, Studio Library: warm surfaces, an amber to coral accent, rounded
/// display type, and monospaced numbers.
///
/// The token names match `docs/plans/v1-design-plan.md` and the web app, so keep them
/// in step. Values live in `Theme.xcassets`, with light, dark, and Increase Contrast
/// variants, and this file compiles into the app and both extensions.
///
/// Destructive actions use `danger`, a distinct red, never `accentFill`.
enum Theme {
    static let background = Color("Sunrise/background")
    static let surface = Color("Sunrise/surface")
    static let surface2 = Color("Sunrise/surface-2")
    static let text = Color("Sunrise/text")
    static let textSecondary = Color("Sunrise/text-secondary")
    static let separator = Color("Sunrise/separator")
    static let accentFill = Color("Sunrise/accent-fill")
    static let onAccent = Color("Sunrise/on-accent")
    static let accentText = Color("Sunrise/accent-text")
    static let tabBar = Color("Sunrise/tab-bar")
    static let warning = Color("Sunrise/warning")
    static let warningSurface = Color("Sunrise/warning-surface")
    static let waveformStart = Color("Sunrise/waveform-start")
    static let waveformEnd = Color("Sunrise/waveform-end")
    static let waveformUnplayed = Color("Sunrise/waveform-unplayed")
    static let danger = Color("Sunrise/danger")
    static let onDanger = Color("Sunrise/on-danger")

    /// White text sits on the hero gradient in both appearances, always at full
    /// opacity. Dimmed lines on it fall below 4.5:1, and every stop clears it at full.
    static let onHero = Color.white
    /// The icon inside the white circle on the Record card and the Stop button.
    static let heroIcon = Color(red: 0xB5 / 255, green: 0x35 / 255, blue: 0x2A / 255)

    private static let heroStart = Color(red: 0xCB / 255, green: 0x4B / 255, blue: 0x1C / 255)
    /// White on the hero's stops, for the contrast test. Light end, then dark end.
    static let heroStopHexes = ["CB4B1C", "AE2733", "9E2230"]

    private static let heroEndLight = UIColor(red: 0xAE / 255, green: 0x27 / 255, blue: 0x33 / 255, alpha: 1)
    private static let heroEndDark = UIColor(red: 0x9E / 255, green: 0x22 / 255, blue: 0x30 / 255, alpha: 1)
    private static let heroEnd = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? heroEndDark : heroEndLight
    })

    /// The Record card, the Record button, and the full recording screen.
    static let heroGradient = LinearGradient(
        colors: [heroStart, heroEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Three radii. Pills use Capsule.
    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 18

    /// Press feedback and small state changes: fast enough to stay out of the way.
    static let quick = Animation.easeOut(duration: 0.14)
    /// A reveal or a swap on screen. A strong ease-out, because the eye should land
    /// on the result rather than watch the trip.
    static let settle = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
}

/// SF Rounded carries titles; the system font carries reading and controls. Numbers
/// use monospaced digits. Everything here follows Dynamic Type.
extension Font {
    static let displayLargeTitle = Font.system(.largeTitle, design: .rounded, weight: .heavy)
    static let displayTitle = Font.system(.title, design: .rounded, weight: .heavy)
    static let displayTitle2 = Font.system(.title2, design: .rounded, weight: .heavy)
    static let displayTitle3 = Font.system(.title3, design: .rounded, weight: .bold)
    static let displayHeadline = Font.system(.headline, design: .rounded, weight: .bold)
    static let rowTitle = Font.system(.body, weight: .semibold)
    static let reading = Font.system(.body)
    /// "Needs you", "Recent", and other small section labels.
    static let sectionLabel = Font.system(.footnote, weight: .semibold)
    /// Durations, timers, and counts in rows.
    static let number = Font.system(.footnote, design: .monospaced)
}

/// For the places that are UIKit underneath: bar appearances and the share card.
extension UIColor {
    static func theme(_ name: String) -> UIColor {
        UIColor(named: "Sunrise/\(name)") ?? .label
    }
}

extension UIFont {
    /// SF Rounded at a text style. The metrics wrapper keeps it scaling with Dynamic Type.
    static func displayRounded(_ style: UIFont.TextStyle, weight: UIFont.Weight = .bold) -> UIFont {
        let base = UIFont.preferredFont(
            forTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        )
        let weighted = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        let descriptor = weighted.withDesign(.rounded) ?? weighted
        return UIFontMetrics(forTextStyle: style)
            .scaledFont(for: UIFont(descriptor: descriptor, size: base.pointSize))
    }
}
