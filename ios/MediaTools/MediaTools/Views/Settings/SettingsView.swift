import SwiftUI
import ClerkKit
import ClerkKitUI

struct SettingsView: View {
    @Environment(Clerk.self) private var clerk
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var health: HealthResponse?
    @State private var healthError: String?
    @State private var isCheckingHealth = false
    @State private var showAdvanced = false
    @State private var notificationState: NotificationPermissionState = .notRequested
    @State private var isSigningOut = false
    @State private var signOutError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                accountSection
                preferencesSection
                quickCaptureSection
                helpSection
                advancedSection
                signOutSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.surface)
        .navigationTitle("Settings")
        .task { await refreshNotificationState() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshNotificationState() }
        }
    }

    private var quickCaptureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "Quick Capture", icon: "button.programmable")

            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text("Record from the Action Button, Back Tap, Control Center, or a widget without keeping Media Tools open.")
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textPrimary)
                } icon: {
                    Image(systemName: "mic.badge.plus")
                        .foregroundStyle(Theme.brand400)
                }

                VStack(alignment: .leading, spacing: 8) {
                    setupStep(number: 1, text: "Open Shortcuts and find Media Tools → Quick Record.")
                    setupStep(number: 2, text: "In Settings → Action Button, choose Shortcut and select Quick Record.")
                    setupStep(number: 3, text: "Press once to start; press again or use the Live Activity to stop.")
                }

                Button {
                    guard let shortcutsURL = URL(string: "shortcuts://") else { return }
                    openURL(shortcutsURL)
                } label: {
                    Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.brand400)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.brand50)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
                }
                .accessibilityHint("Opens the Shortcuts app to configure Quick Record")
            }
            .cardStyle(padding: 14)
        }
    }

    private func setupStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(Theme.caption(11, weight: .bold))
                .foregroundStyle(Theme.surface)
                .frame(width: 22, height: 22)
                .background(Theme.brand400, in: Circle())
                .accessibilityHidden(true)

            Text(text)
                .font(Theme.caption(13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var accountSection: some View {
        if let user = clerk.user {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(text: "Account", icon: "person.circle")

                HStack(spacing: 12) {
                    UserButton()
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName(for: user))
                            .font(Theme.body(16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)

                        if let email = user.primaryEmailAddress?.emailAddress {
                            Text(email)
                                .font(Theme.caption(13))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
                .cardStyle()
            }
        }
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "Preferences", icon: "slider.horizontal.3")

            VStack(spacing: 0) {
                Button(action: handleNotificationAction) {
                    SettingsActionRow(
                        icon: notificationIcon,
                        label: "Completion alerts",
                        detail: notificationDetail,
                        trailing: notificationTrailing
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Notification settings")

                Divider().overlay(Theme.borderSubtle)

                SettingsActionRow(
                    icon: "lock.shield.fill",
                    label: "Private workspace",
                    detail: "Media stays connected to your account.",
                    trailing: "On"
                )
            }
            .cardStyle(padding: 12)
        }
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "Help & information", icon: "questionmark.circle")

            VStack(spacing: 0) {
                settingsLink(
                    title: "Privacy",
                    detail: "How Media Tools handles your content",
                    systemImage: "hand.raised.fill",
                    destination: URL(string: "https://media-tools-gu.netlify.app/privacy")!
                )

                Divider().overlay(Theme.borderSubtle)

                settingsLink(
                    title: "Shimizu Technology",
                    detail: "Product support and company information",
                    systemImage: "safari.fill",
                    destination: URL(string: "https://shimizu-technology.com")!
                )

                Divider().overlay(Theme.borderSubtle)

                SettingsRow(label: "Version") {
                    Text(appVersion)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .cardStyle(padding: 12)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(spacing: 0) {
                    Divider().overlay(Theme.borderSubtle)

                    if isCheckingHealth {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(Theme.brand400)
                            Text("Checking service…")
                                .font(Theme.body(14))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                        }
                        .padding(.vertical, 12)
                    } else if let health {
                        SettingsRow(label: "Service") {
                            Label(
                                health.status == "ok" ? "Available" : "Degraded",
                                systemImage: health.status == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .font(Theme.body(14))
                            .foregroundStyle(health.status == "ok" ? Theme.success : Theme.warning)
                        }
                        Divider().overlay(Theme.borderSubtle)
                        SettingsRow(label: "Workers") {
                            Text("\(health.workers)")
                                .font(Theme.body(14))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else if let healthError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(healthError)
                                .font(Theme.caption(13))
                                .foregroundStyle(Theme.textSecondary)
                            Button("Try again") {
                                Task { await checkHealth() }
                            }
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(Theme.brand400)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                    }

                    Divider().overlay(Theme.borderSubtle)

                    SettingsRow(label: "API") {
                        Text(Configuration.apiBaseURL)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
            } label: {
                Label("Advanced", systemImage: "wrench.and.screwdriver")
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minHeight: 44)
            }
            .tint(Theme.textMuted)
            .cardStyle(padding: 12)
            .onChange(of: showAdvanced) { _, isExpanded in
                guard isExpanded, health == nil else { return }
                Task { await checkHealth() }
            }
        }
    }

    private var signOutSection: some View {
        VStack(spacing: 8) {
            Button(role: .destructive) {
                Task { await signOut() }
            } label: {
                HStack(spacing: 8) {
                    if isSigningOut {
                        ProgressView()
                            .tint(Theme.error)
                    } else {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    Text(isSigningOut ? "Signing out…" : "Sign out")
                }
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.error)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Theme.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radiusMedium)
                        .stroke(Theme.error.opacity(0.35), lineWidth: 1)
                }
            }
            .disabled(isSigningOut)

            if let signOutError {
                Text(signOutError)
                    .font(Theme.caption(12))
                    .foregroundStyle(Theme.error)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var notificationIcon: String {
        switch notificationState {
        case .enabled: "bell.badge.fill"
        case .denied: "bell.slash.fill"
        case .notRequested: "bell.fill"
        }
    }

    private var notificationDetail: String {
        switch notificationState {
        case .enabled: "Alert me when a transcription finishes."
        case .denied: "Turn alerts on in device settings."
        case .notRequested: "Alert me when a transcription finishes."
        }
    }

    private var notificationTrailing: String {
        switch notificationState {
        case .enabled: "On"
        case .denied: "Settings"
        case .notRequested: "Enable"
        }
    }

    private func displayName(for user: User) -> String {
        let name = [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? "Media Tools account" : name
    }

    private func settingsLink(
        title: String,
        detail: String,
        systemImage: String,
        destination: URL
    ) -> some View {
        Link(destination: destination) {
            SettingsActionRow(
                icon: systemImage,
                label: title,
                detail: detail,
                trailing: ""
            )
        }
    }

    private func handleNotificationAction() {
        switch notificationState {
        case .enabled:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(url)
        case .denied:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(url)
        case .notRequested:
            Task {
                _ = await NotificationService.requestPermission()
                await refreshNotificationState()
            }
        }
    }

    private func refreshNotificationState() async {
        notificationState = await NotificationService.permissionState()
    }

    private func checkHealth() async {
        isCheckingHealth = true
        healthError = nil
        defer { isCheckingHealth = false }

        do {
            health = try await APIClient.shared.get("/ready")
        } catch {
            health = nil
            healthError = "Service status is unavailable right now."
        }
    }

    private func signOut() async {
        isSigningOut = true
        signOutError = nil
        defer { isSigningOut = false }

        do {
            try await clerk.auth.signOut()
        } catch {
            signOutError = "Couldn’t sign out. Please try again."
        }
    }
}

private struct SettingsActionRow: View {
    let icon: String
    let label: String
    let detail: String
    let trailing: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.brand400)
                .frame(width: 32, height: 32)
                .background(Theme.brand50)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.caption(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if !trailing.isEmpty {
                Text(trailing)
                    .font(Theme.caption(12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize()
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(minHeight: 56)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label)
                .font(Theme.body(14))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            content
        }
        .padding(.vertical, 8)
    }
}
