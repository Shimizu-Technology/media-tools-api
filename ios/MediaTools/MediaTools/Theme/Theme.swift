import SwiftUI

/// Media Tools design system — matches the web frontend.
/// Font: Satoshi (Fontshare) — falls back to system rounded on iOS.
/// Colors: Dark-first with teal brand accent.
enum Theme {
    // MARK: - Brand Colors
    static let brand50 = Color(red: 47/255, green: 158/255, blue: 143/255).opacity(0.12)
    static let brand400 = Color(red: 103/255, green: 215/255, blue: 199/255)
    static let brand500 = Color(red: 47/255, green: 158/255, blue: 143/255)
    static let brand600 = Color(red: 31/255, green: 123/255, blue: 112/255)

    // MARK: - Surfaces (dark mode)
    static let surface = Color(red: 11/255, green: 13/255, blue: 16/255)         // #0b0d10
    static let surfaceElevated = Color(red: 21/255, green: 24/255, blue: 28/255)  // #15181c
    static let surfaceCard = Color(red: 27/255, green: 31/255, blue: 36/255)      // #1b1f24
    static let surfaceOverlay = Color(red: 32/255, green: 37/255, blue: 43/255)   // #20252b

    // MARK: - Text
    static let textPrimary = Color(red: 231/255, green: 233/255, blue: 238/255)   // #e7e9ee
    static let textSecondary = Color(red: 166/255, green: 173/255, blue: 184/255) // #a6adb8
    static let textMuted = Color(red: 122/255, green: 131/255, blue: 145/255)     // #7a8391

    // MARK: - Borders
    static let border = Color(red: 42/255, green: 48/255, blue: 56/255)           // #2a3038
    static let borderSubtle = Color(red: 31/255, green: 35/255, blue: 42/255)     // #1f232a

    // MARK: - Status
    static let success = Color(red: 24/255, green: 185/255, blue: 133/255)        // #18b985
    static let error = Color(red: 239/255, green: 68/255, blue: 68/255)           // #ef4444
    static let warning = Color(red: 245/255, green: 158/255, blue: 11/255)        // #f59e0b

    // MARK: - Type icons
    static let videoColor = brand500
    static let audioColor = Color(red: 249/255, green: 115/255, blue: 22/255)     // orange-500
    static let pdfColor = Color(red: 239/255, green: 68/255, blue: 68/255)        // red-500
    static let collectionColor = brand500

    // MARK: - Corner Radii (intentional, not uniform)
    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 10
    static let radiusLarge: CGFloat = 16
    static let radiusXL: CGFloat = 20

    // MARK: - Fonts
    static func heading(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func body(_ size: CGFloat = 16, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func caption(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func mono(_ size: CGFloat = 14) -> Font {
        .system(size: size, design: .monospaced)
    }

    // MARK: - Gradients

    static let brandGradient = LinearGradient(
        colors: [brand600, brand500],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let subtleGlow = LinearGradient(
        colors: [brand500.opacity(0.08), Color.clear],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Animation Presets

    static let springSnappy = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let springGentle = Animation.spring(response: 0.5, dampingFraction: 0.75)
}

// MARK: - Themed Text Field Style

struct ThemedTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMedium)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}

extension TextFieldStyle where Self == ThemedTextFieldStyle {
    static var themed: ThemedTextFieldStyle { ThemedTextFieldStyle() }
}

// MARK: - Section Header

struct SectionHeader: View {
    let text: String
    var icon: String?

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(Theme.caption(11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            Text(text.uppercased())
                .font(Theme.caption(11, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .tracking(0.6)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
}

// MARK: - Tab Chip

struct TabChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.caption(13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? Theme.brand500 : Theme.surfaceCard)
                )
                .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Theme.borderSubtle, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - View Extensions

extension View {
    /// Apply the dark surface background.
    func surfaceBackground() -> some View {
        self.background(Theme.surface)
    }

    /// Card style with elevated surface.
    func cardStyle(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Theme.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMedium)
                    .stroke(Theme.borderSubtle, lineWidth: 1)
            )
    }

    /// Elevated card (modals, popovers).
    func elevatedCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusLarge)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }

    /// Card with brand accent border.
    func accentCardStyle(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Theme.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMedium)
                    .stroke(Theme.brand500.opacity(0.4), lineWidth: 1)
            )
    }
}

// MARK: - Themed Button Modifiers

extension View {
    func brandButtonStyle(isDestructive: Bool = false) -> some View {
        self
            .font(Theme.body(16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMedium)
                    .fill(isDestructive ? Theme.error : Theme.brand500)
            )
    }

    func secondaryButtonStyle() -> some View {
        self
            .font(Theme.body(14, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMedium)
                    .fill(Theme.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMedium)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }

    func chipStyle(isSelected: Bool = false) -> some View {
        self
            .font(Theme.caption(12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Theme.brand500 : Theme.surfaceCard)
            )
            .foregroundStyle(isSelected ? .white : Theme.textSecondary)
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.clear : Theme.borderSubtle, lineWidth: 1)
            )
    }
}
