import SwiftUI

// MARK: - Waveforms

/// Real peaks from the server, drawn as bars. The caller decides what shows when
/// there are no peaks, which is a type icon: this view never invents a shape.
struct WaveformBars: View {
    let peaks: [Int]
    /// How much has played, from 0 to 1. Nil draws the whole recording in played colors.
    var progress: CGFloat?
    var barWidth: CGFloat = 2
    var spacing: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            let count = WaveformDisplay.barCount(width: size.width, barWidth: barWidth, spacing: spacing)
            let levels = WaveformDisplay.levels(from: peaks, barCount: count)
            guard !levels.isEmpty else { return }
            let minimum = max(barWidth, 2)
            var bars = Path()
            for (index, level) in levels.enumerated() {
                let height = max(minimum, level * size.height)
                bars.addRoundedRect(
                    in: CGRect(
                        x: CGFloat(index) * (barWidth + spacing),
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    ),
                    cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2)
                )
            }
            let played = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Theme.waveformStart, Theme.waveformEnd]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            )
            guard let progress else {
                context.fill(bars, with: played)
                return
            }
            let edge = min(1, max(0, progress)) * size.width
            var playedPart = context
            playedPart.clip(to: Path(CGRect(x: 0, y: 0, width: edge, height: size.height)))
            playedPart.fill(bars, with: played)
            var rest = context
            rest.clip(to: Path(CGRect(x: edge, y: 0, width: size.width - edge, height: size.height)))
            rest.fill(bars, with: .color(Theme.waveformUnplayed))
        }
        .accessibilityHidden(true)
    }
}

/// The microphone's level over the last few seconds, newest at the right. Moves only
/// because the recorder's meter did, one step per reading, with nothing animated.
struct LiveLevelBars: View {
    let levels: [CGFloat]

    var body: some View {
        Canvas { context, size in
            let barWidth: CGFloat = 3
            let spacing: CGFloat = 3
            let count = WaveformDisplay.barCount(width: size.width, barWidth: barWidth, spacing: spacing)
            let recent = levels.suffix(count)
            let inset = CGFloat(count - recent.count) * (barWidth + spacing)
            var bars = Path()
            // The floor bars before the first reading show that nothing has been heard yet.
            for index in 0..<(count - recent.count) {
                bars.addRoundedRect(
                    in: CGRect(x: CGFloat(index) * (barWidth + spacing), y: (size.height - 4) / 2, width: barWidth, height: 4),
                    cornerSize: CGSize(width: 1.5, height: 1.5)
                )
            }
            for (index, level) in recent.enumerated() {
                let height = max(4, level * size.height)
                bars.addRoundedRect(
                    in: CGRect(
                        x: inset + CGFloat(index) * (barWidth + spacing),
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    ),
                    cornerSize: CGSize(width: 1.5, height: 1.5)
                )
            }
            context.fill(bars, with: .color(Theme.onHero))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Type icons

/// What a row shows when it has no waveform: audio that has not been measured yet, a
/// link, or a PDF. The microphone keeps it from reading as a tiny waveform.
struct TypeTile: View {
    let itemType: String
    var width: CGFloat = 64
    var height: CGFloat = 44

    var body: some View {
        Image(systemName: Self.systemImage(for: itemType))
            .font(.body.weight(.medium))
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .foregroundStyle(Theme.accentText)
            .frame(width: width, height: height)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous))
            .accessibilityHidden(true)
    }

    static func systemImage(for itemType: String) -> String {
        switch itemType {
        case "pdf": "doc.text"
        case "youtube", "transcript": "link"
        default: "mic"
        }
    }
}

/// A row's leading visual: real peaks when the item has them, otherwise its type.
struct RowLeadingVisual: View {
    let item: LibraryListItem
    var width: CGFloat = 64
    var height: CGFloat = 44

    var body: some View {
        if let peaks = item.waveform, WaveformDisplay.hasData(peaks) {
            // Colored only once there is something to open.
            WaveformBars(peaks: peaks, progress: item.status == "completed" ? nil : 0)
                .frame(width: width, height: height)
        } else {
            TypeTile(itemType: item.itemType, width: width, height: height)
        }
    }
}

// MARK: - Collection colors

/// Keys the server stores by name; clients map them. White icons on all of them. An
/// absent or unknown key falls back to coral.
enum CollectionColor: String, CaseIterable {
    case coral, teal, violet, amber, blue, rose

    init(key: String?) {
        self = key.flatMap(CollectionColor.init(rawValue:)) ?? .coral
    }

    var color: Color {
        switch self {
        case .coral: Self.rgb(0xD9542E)
        case .teal: Self.rgb(0x0A7C86)
        case .violet: Self.rgb(0x8A5AB5)
        case .amber: Self.rgb(0xB8780A)
        case .blue: Self.rgb(0x2F6DB5)
        case .rose: Self.rgb(0xC2416C)
        }
    }

    private static func rgb(_ hex: Int) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct CollectionDot: View {
    let colorKey: String?

    var body: some View {
        Circle()
            .fill(CollectionColor(key: colorKey).color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

// MARK: - Screen titles

/// A tab's title, in the page rather than a bar, with its actions on the same line.
struct ScreenHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions

    init(_ title: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.displayLargeTitle)
                .tracking(-0.4)
                .foregroundStyle(Theme.text)
                // One word, so shrinking reads better than breaking it across lines.
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("screen.title")
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .frame(minHeight: 44)
    }
}

/// A round action beside a screen title, in the accent color.
struct HeaderIconLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.medium))
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .foregroundStyle(Theme.accentText)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

/// "Needs you", "Recent".
struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.sectionLabel)
            .foregroundStyle(Theme.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Record types

/// Optional and out of the way: most recordings never need a type.
struct RecordAsMenu: View {
    let onSelect: (String) -> Void

    var body: some View {
        Section("Record as") {
            ForEach(RecordingContentType.all) { type in
                Button {
                    onSelect(type.value)
                } label: {
                    Label(type.title, systemImage: type.systemImage)
                }
            }
        }
    }
}

// MARK: - Empty states

/// A plain placeholder that stays in the warm palette, for an empty section or a
/// failed load. The actions, when there are any, carry the next step.
struct QuietPlaceholder<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String?
    @ViewBuilder var actions: Actions

    init(
        systemImage: String,
        title: String,
        message: String? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Theme.accentText)
                .frame(width: 56, height: 56)
                .background(Theme.surface2, in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(.displayHeadline)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }
}
