import SwiftUI
import ClerkKit

struct SettingsView: View {
    @Environment(Clerk.self) private var clerk
    @Environment(RecordingUploadCoordinator.self) private var uploadCoordinator
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true

    private let tokenSync = TokenSyncService.shared

    @State private var health: HealthResponse?
    @State private var healthError: String?
    @State private var isCheckingHealth = false
    @State private var showAdvanced = false
    @State private var notificationState: NotificationPermissionState = .notRequested
    @State private var isSigningOut = false
    @State private var signOutError: String?
    @State private var showDeleteAccount = false
    @State private var deletionConfirmation = ""
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                accountSection
                preferencesSection
                quickCaptureSection
                helpSection
                advancedSection
                deleteAccountSection
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
        .sheet(isPresented: $showDeleteAccount) {
            deleteAccountConfirmationSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var quickCaptureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "Quick Capture", icon: "button.programmable")

            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text("One press opens Media Tools and begins recording. After capture starts, you can lock your phone or use another app.")
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

                Button {
                    hasCompletedOnboarding = false
                } label: {
                    Label("Review setup", systemImage: "checklist")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityHint(
                    "Shows microphone, alert, privacy, and Quick Record guidance again"
                )
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
                    Text(initials(for: user))
                        .font(Theme.body(16, weight: .bold))
                        .foregroundStyle(Theme.surface)
                        .frame(width: 48, height: 48)
                        .background(Theme.brand400, in: Circle())

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

    private var deleteAccountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "Danger zone", icon: "exclamationmark.triangle")

            VStack(alignment: .leading, spacing: 12) {
                Text("Delete account")
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Permanently removes your recordings, transcripts, PDFs, chats, collections, developer keys, and account. Device recordings owned by this account are also removed.")
                    .font(Theme.caption(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(role: .destructive) {
                    deletionConfirmation = ""
                    deleteAccountError = nil
                    showDeleteAccount = true
                } label: {
                    Label("Delete account and data", systemImage: "trash")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.error)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.radiusMedium)
                                .stroke(Theme.error.opacity(0.45), lineWidth: 1)
                        }
                }
                .disabled(isDeletingAccount)
            }
            .cardStyle(padding: 14)
        }
    }

    private var deleteAccountConfirmationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.error)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Permanently delete your account?")
                            .font(Theme.heading(24))
                            .foregroundStyle(Theme.textPrimary)
                        Text("This cannot be undone. Export any device recordings you want to keep before continuing. Server data is purged immediately; secure provider cleanup continues in the background.")
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Type DELETE to confirm")
                            .font(Theme.caption(12, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        TextField("DELETE", text: $deletionConfirmation)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(Theme.mono(16))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 48)
                            .background(Theme.surfaceCard)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.radiusMedium)
                                    .stroke(Theme.borderSubtle, lineWidth: 1)
                            }
                    }

                    if let deleteAccountError {
                        Text(deleteAccountError)
                            .font(Theme.caption(13))
                            .foregroundStyle(Theme.error)
                    }

                    Button(role: .destructive) {
                        Task { await deleteAccount() }
                    } label: {
                        HStack(spacing: 8) {
                            if isDeletingAccount { ProgressView().tint(.white) }
                            Text(isDeletingAccount ? "Deleting…" : "Permanently delete account")
                        }
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(
                            deletionConfirmation == "DELETE" ? Theme.error : Theme.textMuted,
                            in: RoundedRectangle(cornerRadius: Theme.radiusMedium)
                        )
                    }
                    .disabled(deletionConfirmation != "DELETE" || isDeletingAccount)
                }
                .padding(20)
            }
            .background(Theme.surface)
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showDeleteAccount = false }
                        .disabled(isDeletingAccount)
                }
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
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
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

    private func initials(for user: User) -> String {
        let characters = [user.firstName, user.lastName]
            .compactMap { $0?.first }
        return characters.isEmpty ? "MT" : String(characters.prefix(2))
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
            await uploadCoordinator.setActiveOwnerID(nil)
        } catch {
            signOutError = "Couldn’t sign out. Please try again."
        }
    }

    private func deleteAccount() async {
        guard deletionConfirmation == "DELETE", let ownerID = clerk.user?.id else { return }
        isDeletingAccount = true
        deleteAccountError = nil
        defer { isDeletingAccount = false }

        do {
            try await APIClient.shared.delete(
                "/account",
                body: DeleteAccountRequest(confirmation: deletionConfirmation)
            )
        } catch {
            deleteAccountError = error.localizedDescription
            return
        }

        try? await uploadCoordinator.removeLocalAccountData(ownerID: ownerID)
        // The server has accepted an irreversible deletion request. Stop the
        // share-extension sync before clearing its token so a still-present
        // Clerk session cannot write the credential back if sign-out fails.
        tokenSync.stopSyncing()
        tokenSync.clearToken()
        do {
            try await clerk.auth.signOut()
            showDeleteAccount = false
        } catch {
            deleteAccountError = "Your account deletion is underway, but this device could not finish signing out. Close and reopen Media Tools."
        }
    }
}

private struct DeleteAccountRequest: Encodable {
    let confirmation: String
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
