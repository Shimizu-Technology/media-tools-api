import SwiftUI

// The tokens and type scale are in MediaToolsShared/AppTheme.swift, because the
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

/// The filled action on a screen. Every one is a pill, at the height of the thumb
/// target; `pill` is the larger size used beside the Record control.
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
                .background(fill, in: Capsule())
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? nil : Theme.quick, value: configuration.isPressed)
        }
    }
}

/// A text action in the accent color, with a full-size target around it.
struct QuietButtonStyle: ButtonStyle {
    var color: Color = Theme.accentText

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
            .background(configuration.isPressed ? Theme.surface2 : .clear)
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

/// The system font at a comfortable measure and line height, for summaries and transcripts.
struct ReadingTextModifier: ViewModifier {
    /// About half an extra line, for the mockup's 1.5 line height at Body.
    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .font(.reading)
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

/// An error is plain text with an icon. Red is kept for destructive actions.
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
    /// A form field on the page background.
    func themedField() -> some View {
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
    func pageMargin() -> some View {
        modifier(PageMarginModifier())
    }

    /// A bar over scrolling content: the system material, warmed to match the page.
    func barBackground() -> some View {
        self
            .background(Theme.background.opacity(0.82))
            .background(.ultraThinMaterial)
    }

    /// A grouped native list on the page background.
    func themedListBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.background)
    }
}

extension View {
    /// A tab's title lives in its page, so there is no bar to stop content scrolling
    /// under the clock. This paints the status bar's area in the page color instead.
    func statusBarBackdrop() -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            Color.clear
                .frame(height: 0)
                .background(Theme.background)
        }
    }

    /// Keeps a list or scroll view at a deliberate width on iPad, with the scroll
    /// indicator still at the screen's edge. Phones are narrower than the limit.
    func readableContentWidth(_ limit: CGFloat = Theme.readableWidth, minimumMargin: CGFloat = 0) -> some View {
        modifier(ReadableContentWidthModifier(limit: limit, minimumMargin: minimumMargin))
    }
}

private struct ReadableContentWidthModifier: ViewModifier {
    let limit: CGFloat
    let minimumMargin: CGFloat
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, max(minimumMargin, (width - limit) / 2), for: .scrollContent)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
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
    /// The widest a list runs on iPad, about where a row's excerpt stays readable.
    static let readableWidth: CGFloat = 720

    static func pageMargin(forWidth width: CGFloat) -> CGFloat {
        width >= 414 ? 20 : 16
    }
}

// MARK: - Durations

enum MediaFormat {
    /// "0:31", "42:10", and "1:29:12": the digits a person sees on any audio player.
    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    /// The date a row shows: the time today, then "Yesterday", then "Oct 19".
    static func rowDate(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        if calendar.isDate(date, inSameDayAs: now) {
            var style = Date.FormatStyle(date: .omitted, time: .shortened)
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
        return dayTitle(for: date, now: now, calendar: calendar)
    }

    /// The day alone: "Today", "Yesterday", then "Oct 19", with the year once it differs.
    static func dayTitle(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var format = Date.FormatStyle(date: .omitted, time: .omitted).month(.abbreviated).day()
        format.timeZone = calendar.timeZone
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            format = format.year()
        }
        return date.formatted(format)
    }
}
