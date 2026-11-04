import SwiftUI

// The tokens and type scale are in MediaToolsShared/LedgerTheme.swift, because the
// extensions need them too. This file holds the app's reusable controls.

// MARK: - Motion

/// Runs a change animated, or plainly when Reduce Motion is on.
@MainActor
func withMotion<Result>(_ animation: Animation = Theme.settle, _ body: () throws -> Result) rethrows -> Result {
    if UIAccessibility.isReduceMotionEnabled {
        return try body()
    }
    return try withAnimation(animation, body)
}

// MARK: - Buttons

/// The filled action on a screen. Pills sit at the thumb, as the Record control does;
/// rounded rectangles sit in forms.
struct PrimaryButtonStyle: ButtonStyle {
    enum Shape {
        case pill
        case rounded
    }

    var shape: Shape = .rounded
    var fill: Color = Theme.accentFill
    var foreground: Color = Theme.onAccent

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        PrimaryButtonBody(configuration: configuration, shape: shape, fill: fill, foreground: foreground)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let shape: Shape
        let fill: Color
        let foreground: Color
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(shape == .pill ? .title3.weight(.semibold) : .headline)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: shape == .pill ? 56 : 52)
                .background {
                    switch shape {
                    case .pill: Capsule().fill(fill)
                    case .rounded: RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill)
                    }
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? nil : Theme.quick, value: configuration.isPressed)
        }
    }
}

/// A text action in the accent color, with a full-size target around it.
struct QuietButtonStyle: ButtonStyle {
    var color: Color = Theme.accent

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        QuietButtonBody(configuration: configuration, color: color)
    }

    private struct QuietButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let color: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isEnabled ? color : Theme.textSecondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.55 : 1)
        }
    }
}

/// Darkens a list row under the finger instead of moving it, so scrolling a long
/// list never shimmers.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Theme.fill : .clear)
    }
}

/// Press feedback for a custom round control.
struct PressFeedbackButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.94

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        PressBody(configuration: configuration, pressedScale: pressedScale)
    }

    private struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        let pressedScale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.85 : 1)
                .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
                .animation(reduceMotion ? nil : Theme.quick, value: configuration.isPressed)
        }
    }
}

// MARK: - Text

/// New York at a comfortable measure and line height, for summaries and transcripts.
struct ReadingTextModifier: ViewModifier {
    /// About half an extra line, for the mockup's 1.5 line height at Body.
    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .font(.ledgerReading)
            .lineSpacing(lineSpacing)
            .foregroundStyle(Theme.text)
    }
}

extension View {
    func readingText() -> some View {
        modifier(ReadingTextModifier())
    }

    /// Keeps long reading to roughly 70 characters a line on wide screens.
    func readingMeasure() -> some View {
        modifier(ReadingMeasureModifier())
    }
}

private struct ReadingMeasureModifier: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var measure: CGFloat = 600

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// An error stays in ink with an icon. Red means a recording is running.
struct InlineError: View {
    let message: String
    var identifier: String?

    init(_ message: String, identifier: String? = nil) {
        self.message = message
        self.identifier = identifier
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .accessibilityHidden(true)
            messageText
        }
        .font(.footnote)
        .foregroundStyle(Theme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var messageText: some View {
        let text = Text(message).fixedSize(horizontal: false, vertical: true)
        if let identifier {
            text.accessibilityIdentifier(identifier)
        } else {
            text
        }
    }
}

/// Something that needs attention, inline with the content rather than in a card.
struct NoticeRow<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension NoticeRow where Actions == EmptyView {
    init(systemImage: String, title: String, message: String? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// A plain progress line for work in the background.
struct ProgressNote: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(Theme.textSecondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Fields

extension View {
    /// A form field on the paper background.
    func ledgerField() -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 50)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 0.5)
            }
    }

    /// The standard page margin: 20 points on the largest iPhones, 16 elsewhere, the
    /// same as the system's large titles and search field.
    func ledgerPageMargin() -> some View {
        modifier(PageMarginModifier())
    }

    /// A bar over scrolling content: the system material, warmed to match the paper.
    func ledgerBarBackground() -> some View {
        self
            .background(Theme.bg.opacity(0.82))
            .background(.ultraThinMaterial)
    }

    /// A grouped native list on the paper background.
    func ledgerListBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
    }
}

private struct PageMarginModifier: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Theme.pageMargin(forWidth: width))
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }
}

/// A hairline, as used between rows and above bottom bars.
struct Hairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1 / max(displayScale, 1))
            .accessibilityHidden(true)
    }
}

extension Theme {
    static func pageMargin(forWidth width: CGFloat) -> CGFloat {
        width >= 414 ? 20 : 16
    }
}

// MARK: - Durations

enum LedgerFormat {
    /// "0:31" for short recordings and "42 min" once seconds stop mattering.
    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded(.down))
        if total < 600 {
            return "\(total / 60):\(String(format: "%02d", total % 60))"
        }
        let minutes = total / 60
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }
}
