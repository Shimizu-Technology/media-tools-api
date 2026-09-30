import SwiftUI
import ClerkKit
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(Clerk.self) private var clerk
    @Environment(RecordingUploadCoordinator.self) private var uploadCoordinator
    @Environment(AIProcessingConsentManager.self) private var aiProcessingConsent
    @Environment(DeviceSessionController.self) private var deviceSession
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
    @State private var deviceAccount: DeviceAccount?
    @State private var isLoadingDeviceAccount = false
    @State private var deviceAccountError: String?
    @State private var deviceAccountRetry = 0
    @State private var passkeyStatus: PasskeyStatus?
    @State private var recoveryStatus: RecoveryCodeStatus?
    @State private var isLoadingRecoveryStatus = false
    @State private var isEnrollingPasskey = false
    @State private var isGeneratingRecoveryCodes = false
    @State private var isConfirmingRecoveryCodes = false
    @State private var recoveryCodesSaveError: String?
    @State private var securityMessage: String?
    @State private var securityError: String?
    @State private var securityStatusError: String?
    @State private var showReplaceRecoveryCodesConfirmation = false
    @State private var showRecoveryCodesSheet = false
    @State private var oneTimeRecoveryCodes: [String] = []
    @State private var clerkDetachmentStatus: ClerkDetachmentStatus?
    @State private var clerkDetachmentError: String?
    @State private var isLoadingClerkDetachment = false
    @State private var isDisconnectingClerk = false
    @State private var showDisconnectClerkConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                accountSection
                accountSecuritySection
                preferencesSection
                quickCaptureSection
                aiProcessingSection
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
        .task(id: "\(deviceSession.activeUserID ?? "")|\(clerk.user?.id ?? "")|\(deviceAccountRetry)") {
            deviceAccount = nil
            deviceAccountError = nil
            guard Configuration.firstPartyIOSAuthEnabled,
                  deviceSession.activeUserID != nil,
                  clerk.user == nil else { return }
            isLoadingDeviceAccount = true
            do {
                let account: DeviceAccount = try await APIClient.shared.get("/auth/me")
                guard !Task.isCancelled else { return }
                deviceAccount = account
            } catch {
                guard !Task.isCancelled else { return }
                deviceAccountError = "Could not load your account details."
            }
            isLoadingDeviceAccount = false
        }
        .task(id: "security|\(deviceSession.activeUserID ?? "")|\(clerk.user?.id ?? "")") {
            async let security: Void = loadRecoveryStatus()
            async let migration: Void = loadClerkDetachmentStatus()
            _ = await (security, migration)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshNotificationState() }
        }
        .sheet(isPresented: $showDeleteAccount) {
            deleteAccountConfirmationSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showRecoveryCodesSheet) {
            RecoveryCodesOneTimeSheet(
                codes: oneTimeRecoveryCodes,
                isSaving: isConfirmingRecoveryCodes,
                errorMessage: recoveryCodesSaveError
            ) {
                Task { await confirmRecoveryCodesSaved() }
            }
            .interactiveDismissDisabled()
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            recoveryStatus?.remaining ?? 0 > 0 ? "Replace recovery codes?" : "Create recovery codes?",
            isPresented: $showReplaceRecoveryCodesConfirmation,
            titleVisibility: .visible
        ) {
            Button(recoveryStatus?.remaining ?? 0 > 0 ? "Replace codes" : "Create codes") {
                Task { await generateRecoveryCodes() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if recoveryStatus?.remaining ?? 0 > 0 {
                Text("Old recovery codes keep working until you save and confirm the new codes on the next screen.")
            } else {
                Text("Save these codes somewhere private. They are shown once and each code can be used one time.")
            }
        }
        .confirmationDialog(
            "Finish moving off Clerk?",
            isPresented: $showDisconnectClerkConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect Clerk", role: .destructive) {
                Task { await disconnectClerk() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your recordings and current device session stay in Media Tools. Future sign-ins will use your passkey or a recovery code.")
        }
    }

    private var quickCaptureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "Quick Capture", icon: "button.programmable")

            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text("One press opens Media Tools and begins recording. Use it only when everyone who must consent has done so. After capture starts, you can lock your phone or use another app.")
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
        } else if Configuration.firstPartyIOSAuthEnabled,
                  deviceSession.activeUserID != nil {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(text: "Account", icon: "person.circle")
                VStack(alignment: .leading, spacing: 8) {
                    if let deviceAccount {
                        Text(deviceAccount.name.isEmpty ? "Media Tools account" : deviceAccount.name)
                            .font(Theme.body(16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(deviceAccount.email)
                            .font(Theme.caption(13))
                            .foregroundStyle(Theme.textSecondary)
                    } else if isLoadingDeviceAccount {
                        ProgressView("Loading account…")
                    } else if let deviceAccountError {
                        Text(deviceAccountError)
                            .font(Theme.caption(13))
                            .foregroundStyle(Theme.error)
                        Button("Try again") { deviceAccountRetry += 1 }
                            .frame(minHeight: 44)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private var accountSecuritySection: some View {
        if Configuration.firstPartyIOSAuthEnabled, (deviceSession.activeUserID != nil || clerk.user != nil) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(text: "Sign-in security", icon: "key.fill")

                VStack(alignment: .leading, spacing: 14) {
                    Button {
                        Task { await enrollPasskey() }
                    } label: {
                        HStack(spacing: 10) {
                            if isEnrollingPasskey {
                                ProgressView().tint(Theme.brand400)
                            } else {
                                Image(systemName: "person.badge.key.fill")
                                    .foregroundStyle(Theme.brand400)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(isEnrollingPasskey ? "Opening passkey setup…" : "Add a passkey")
                                    .font(Theme.body(14, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(passkeyDetail)
                                    .font(Theme.caption(12))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isEnrollingPasskey || isGeneratingRecoveryCodes)

                    Divider().overlay(Theme.borderSubtle)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lifepreserver")
                                .foregroundStyle(Theme.brand400)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Recovery codes")
                                    .font(Theme.body(14, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(recoveryDetail)
                                    .font(Theme.caption(12))
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if isLoadingRecoveryStatus {
                                ProgressView().tint(Theme.brand400)
                            } else if let remaining = recoveryStatus?.remaining {
                                Text("\(remaining) left")
                                    .font(Theme.caption(12, weight: .semibold))
                                    .foregroundStyle(Theme.textMuted)
                                    .fixedSize()
                            }
                        }

                        Button {
                            showReplaceRecoveryCodesConfirmation = true
                        } label: {
                            HStack(spacing: 8) {
                                if isGeneratingRecoveryCodes { ProgressView().tint(.white) }
                                Text(recoveryStatus?.remaining ?? 0 > 0 ? "Replace recovery codes" : "Create recovery codes")
                            }
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Theme.brand500, in: RoundedRectangle(cornerRadius: Theme.radiusMedium))
                        }
                        .disabled(isGeneratingRecoveryCodes || isEnrollingPasskey)
                    }

                    if let securityStatusError {
                        SecurityStatusRetryBanner(
                            message: securityStatusError,
                            isRetrying: isLoadingRecoveryStatus
                        ) {
                            Task { await loadRecoveryStatus() }
                        }
                    }

                    if let securityMessage {
                        Text(securityMessage)
                            .font(Theme.caption(12))
                            .foregroundStyle(Theme.success)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let securityError {
                        Text(securityError)
                            .font(Theme.caption(12))
                            .foregroundStyle(Theme.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let status = clerkDetachmentStatus {
                        Divider().overlay(Theme.borderSubtle)
                        ClerkMigrationCard(
                            status: status,
                            isDisconnecting: isDisconnectingClerk,
                            errorMessage: clerkDetachmentError,
                            onDisconnect: { showDisconnectClerkConfirmation = true },
                            onRetry: { Task { await loadClerkDetachmentStatus() } }
                        )
                    } else if let clerkDetachmentError {
                        SecurityStatusRetryBanner(
                            message: clerkDetachmentError,
                            isRetrying: isLoadingClerkDetachment
                        ) {
                            Task { await loadClerkDetachmentStatus() }
                        }
                    }
                }
                .cardStyle(padding: 14)
            }
        }
    }

    private var passkeyDetail: String {
        guard let count = passkeyStatus?.count else {
            return securityStatusError == nil
                ? "Use Face ID or your device passcode next time."
                : "Last passkey count is unavailable."
        }
        if count == 0 {
            return "No passkeys are set up yet."
        }
        return count == 1 ? "1 passkey is set up." : "\(count) passkeys are set up."
    }

    private var recoveryDetail: String {
        if isLoadingRecoveryStatus { return "Checking saved codes…" }
        guard let remaining = recoveryStatus?.remaining else {
            return securityStatusError == nil
                ? "Create backup codes so you can sign in if your passkey is unavailable."
                : "Last recovery-code count is unavailable."
        }
        if remaining == 0 {
            return "No saved codes are available. Create a new set and save it now."
        }
        return "Each code works once. Replacing codes disables the old set."
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

    private var aiProcessingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "AI processing", icon: "brain.head.profile")

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(aiProcessingConsent.hasConsent
                         ? "Allowed for this account on this iPhone."
                         : "Not allowed. Media Tools will ask before sharing content with third-party AI providers.")
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textPrimary)
                } icon: {
                    Image(systemName: aiProcessingConsent.hasConsent ? "checkmark.shield.fill" : "hand.raised.fill")
                        .foregroundStyle(aiProcessingConsent.hasConsent ? Theme.success : Theme.brand400)
                }

                Text("This controls future transcription, readable formatting, summary, and chat requests. Processing already started may finish.")
                    .font(Theme.caption(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    if aiProcessingConsent.hasConsent {
                        aiProcessingConsent.revoke()
                    } else {
                        Task { _ = await aiProcessingConsent.requestPermission() }
                    }
                } label: {
                    Label(
                        aiProcessingConsent.hasConsent ? "Revoke permission" : "Review and allow",
                        systemImage: aiProcessingConsent.hasConsent ? "xmark.shield" : "info.circle"
                    )
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(aiProcessingConsent.hasConsent ? Theme.error : Theme.brand400)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .cardStyle(padding: 14)
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
                    destination: Configuration.privacyURL
                )

                Divider().overlay(Theme.borderSubtle)

                settingsLink(
                    title: "Terms of use",
                    detail: "Rules for recording, uploads, and AI features",
                    systemImage: "doc.text.fill",
                    destination: Configuration.termsURL
                )

                Divider().overlay(Theme.borderSubtle)

                settingsLink(
                    title: "Support & safety",
                    detail: "Get help or report a content concern",
                    systemImage: "lifepreserver.fill",
                    destination: Configuration.supportURL
                )

                Divider().overlay(Theme.borderSubtle)

                settingsLink(
                    title: "Account deletion help",
                    detail: "Public instructions available without signing in",
                    systemImage: "person.crop.circle.badge.minus",
                    destination: Configuration.accountDeletionURL
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

    private func loadRecoveryStatus() async {
        guard Configuration.firstPartyIOSAuthEnabled,
              (deviceSession.activeUserID != nil || clerk.user != nil) else {
            recoveryStatus = nil
            return
        }
        isLoadingRecoveryStatus = true
        defer { isLoadingRecoveryStatus = false }
        do {
            async let loadedPasskeys = FirstPartyAuthService.shared.passkeyStatus()
            async let loadedRecovery = FirstPartyAuthService.shared.recoveryStatus()
            let (passkeys, recovery) = try await (loadedPasskeys, loadedRecovery)
            guard !Task.isCancelled else { return }
            passkeyStatus = passkeys
            recoveryStatus = recovery
            securityStatusError = nil
        } catch {
            guard !Task.isCancelled else { return }
            securityStatusError = "Could not check sign-in security."
        }
    }

    private func loadClerkDetachmentStatus() async {
        guard Configuration.firstPartyIOSAuthEnabled,
              let ownerID = deviceSession.activeUserID else {
            clerkDetachmentStatus = nil
            clerkDetachmentError = nil
            return
        }
        isLoadingClerkDetachment = true
        defer { isLoadingClerkDetachment = false }
        do {
            let status = try await FirstPartyAuthService.shared.clerkDetachmentStatus(
                expectedOwnerID: ownerID
            )
            if !status.linked {
                try await finishLocalClerkDetachment(expectedOwnerID: ownerID)
            }
            clerkDetachmentStatus = status
            clerkDetachmentError = nil
        } catch {
            guard !Task.isCancelled else { return }
            clerkDetachmentError = "Could not check the Clerk migration status."
        }
    }

    private func disconnectClerk() async {
        guard !isDisconnectingClerk,
              let ownerID = deviceSession.activeUserID else { return }
        isDisconnectingClerk = true
        clerkDetachmentError = nil
        securityMessage = nil
        defer { isDisconnectingClerk = false }

        do {
            let status = try await FirstPartyAuthService.shared.detachClerk(
                expectedOwnerID: ownerID
            )
            guard !status.linked else { throw APIError.invalidResponse }
            securityMessage = "Media Tools sign-in is ready. Clerk is disconnected."
            try await finishLocalClerkDetachment(expectedOwnerID: ownerID)
            clerkDetachmentStatus = status
        } catch {
            clerkDetachmentError = error.localizedDescription.isEmpty
                ? "Could not disconnect Clerk. Please try again."
                : error.localizedDescription
            await loadClerkDetachmentStatus()
        }
    }

    private func finishLocalClerkDetachment(expectedOwnerID: String) async throws {
        // Validate and commit against the initiating stable account before
        // touching Share Extension auth for whichever account is now active.
        try deviceSession.markClerkDetached(expectedOwnerID: expectedOwnerID)
        tokenSync.stopSyncing()
        tokenSync.clearToken()
        if clerk.user != nil {
            do {
                try await clerk.auth.signOut()
            } catch {
                securityMessage = "Clerk is disconnected. Media Tools will finish clearing the old local sign-in automatically."
            }
        }
    }

    private func enrollPasskey() async {
        isEnrollingPasskey = true
        securityMessage = nil
        securityError = nil
        defer { isEnrollingPasskey = false }
        do {
            try await FirstPartyAuthService.shared.enrollPasskey()
            passkeyStatus = try? await FirstPartyAuthService.shared.passkeyStatus()
            await loadClerkDetachmentStatus()
            securityStatusError = nil
            securityMessage = "Passkey added. You can use it the next time you sign in."
        } catch {
            guard !FirstPartyAuthService.isCancellation(error) else { return }
            securityError = error.localizedDescription.isEmpty
                ? "Could not add a passkey. Please try again."
                : error.localizedDescription
        }
    }

    private func generateRecoveryCodes() async {
        isGeneratingRecoveryCodes = true
        securityMessage = nil
        securityError = nil
        recoveryCodesSaveError = nil
        defer { isGeneratingRecoveryCodes = false }
        do {
            let codes = try await FirstPartyAuthService.shared.beginRecoveryCodeRotation()
            oneTimeRecoveryCodes = codes
            showRecoveryCodesSheet = true
        } catch {
            securityError = error.localizedDescription.isEmpty
                ? "Could not create recovery codes. Please try again."
                : error.localizedDescription
        }
    }

    private func confirmRecoveryCodesSaved() async {
        guard !isConfirmingRecoveryCodes else { return }
        isConfirmingRecoveryCodes = true
        recoveryCodesSaveError = nil
        defer { isConfirmingRecoveryCodes = false }
        do {
            let status = try await FirstPartyAuthService.shared.confirmRecoveryCodeRotation()
            recoveryStatus = status
            await loadClerkDetachmentStatus()
            securityMessage = "Recovery codes saved. The old set no longer works."
            securityStatusError = nil
            showRecoveryCodesSheet = false
            oneTimeRecoveryCodes = []
        } catch APIError.authenticationRequired(let message) {
            showRecoveryCodesSheet = false
            oneTimeRecoveryCodes = []
            securityError = message
            await loadRecoveryStatus()
        } catch {
            recoveryCodesSaveError = error.localizedDescription.isEmpty
                ? "Could not confirm these codes. Keep this screen open and try again."
                : error.localizedDescription
        }
    }

    private func signOut() async {
        isSigningOut = true
        signOutError = nil
        defer { isSigningOut = false }

        do {
            try await deviceSession.revokeOrSuspend()
            FirstPartyAuthService.shared.clearSessionScopedJournals()
            if clerk.user != nil {
                try await clerk.auth.signOut()
            }
            await uploadCoordinator.setActiveOwnerID(nil)
        } catch {
            signOutError = "Couldn’t sign out. Please try again."
        }
    }

    private func deleteAccount() async {
        guard deletionConfirmation == "DELETE",
              let ownerID = deviceSession.activeUserID ?? clerk.user?.id else { return }
        isDeletingAccount = true
        deleteAccountError = nil
        defer { isDeletingAccount = false }

        do {
            let pending = try await AccountDeletionRecoveryService.shared.requestDeletion(
                ownerID: ownerID
            )
            try await AccountDeletionRecoveryService.shared.finishLocalDeletion(
                pending,
                uploadCoordinator: uploadCoordinator,
                consent: aiProcessingConsent,
                deviceSession: deviceSession,
                tokenSync: tokenSync,
                clerk: clerk
            )
        } catch {
            deleteAccountError = error.localizedDescription
            return
        }
        showDeleteAccount = false
    }

}

private struct ClerkMigrationCard: View {
    let status: ClerkDetachmentStatus
    let isDisconnecting: Bool
    let errorMessage: String?
    let onDisconnect: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                status.linked ? "Finish moving off Clerk" : "Media Tools sign-in active",
                systemImage: status.linked ? "arrow.right.circle.fill" : "checkmark.shield.fill"
            )
            .font(Theme.body(14, weight: .semibold))
            .foregroundStyle(status.linked ? Theme.textPrimary : Theme.success)

            if status.linked {
                Text("Disconnect Clerk after both backup sign-in methods are ready. Your account, recordings, and this device session stay in Media Tools.")
                    .font(Theme.caption(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                readinessRow(
                    title: "Passkey",
                    isReady: status.passkeyCount > 0,
                    detail: status.passkeyCount > 0 ? "Ready" : "Add one above"
                )
                readinessRow(
                    title: "Recovery codes",
                    isReady: status.unusedRecoveryCodes > 0,
                    detail: status.unusedRecoveryCodes > 0
                        ? "\(status.unusedRecoveryCodes) available"
                        : "Create and save them above"
                )

                if status.ready {
                    Button(role: .destructive, action: onDisconnect) {
                        HStack(spacing: 8) {
                            if isDisconnecting { ProgressView().tint(.white) }
                            Text(isDisconnecting ? "Disconnecting…" : "Disconnect Clerk")
                        }
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Theme.error, in: RoundedRectangle(cornerRadius: Theme.radiusMedium))
                    }
                    .disabled(isDisconnecting)
                    .accessibilityIdentifier("clerk-migration.disconnect")
                }
            } else {
                Text("Use your passkey or a recovery code whenever you need to sign in again.")
                    .font(Theme.caption(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.caption(12))
                    .foregroundStyle(Theme.error)
                Button("Check again", action: onRetry)
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.brand400)
                    .frame(minHeight: 44)
            }
        }
        .accessibilityIdentifier("clerk-migration.card")
    }

    private func readinessRow(title: String, isReady: Bool, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isReady ? Theme.success : Theme.textMuted)
            Text(title)
                .font(Theme.caption(12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(detail)
                .font(Theme.caption(12))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct SecurityStatusRetryBanner: View {
    let message: String
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(Theme.caption(12))
                .foregroundStyle(Theme.error)
                .fixedSize(horizontal: false, vertical: true)
            Button { onRetry() } label: {
                HStack(spacing: 8) {
                    if isRetrying { ProgressView().tint(Theme.brand400) }
                    Text(isRetrying ? "Checking…" : "Retry")
                }
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.brand400)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.brand50)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
            }
            .disabled(isRetrying)
            .accessibilityIdentifier("sign-in-security.retry")
        }
    }
}

enum RecoveryCodeClipboard {
    static let expirationSeconds: TimeInterval = 60

    static func payload(for text: String, now: Date = Date()) -> ([[String: Any]], [UIPasteboard.OptionsKey: Any]) {
        (
            [[UTType.utf8PlainText.identifier: text]],
            [
                .localOnly: true,
                .expirationDate: now.addingTimeInterval(expirationSeconds),
            ]
        )
    }

    @MainActor
    static func copy(_ text: String, pasteboard: UIPasteboard = .general, now: Date = Date()) {
        let (items, options) = payload(for: text, now: now)
        pasteboard.setItems(items, options: options)
    }
}

struct SignInSecurityStatusFailurePreviewHost: View {
    @State private var message: String? = "Could not check sign-in security."
    @State private var didRetry = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign-in security")
                .font(Theme.heading(24))
                .foregroundStyle(Theme.textPrimary)
            Text("1 passkey is set up.")
                .font(Theme.body(14))
                .foregroundStyle(Theme.textSecondary)
            Text("2 recovery codes left")
                .font(Theme.body(14))
                .foregroundStyle(Theme.textSecondary)
            if let message {
                SecurityStatusRetryBanner(message: message, isRetrying: false) {
                    didRetry = true
                    self.message = nil
                }
            }
            if didRetry {
                Text("Security status refreshed")
                    .font(Theme.caption(12))
                    .foregroundStyle(Theme.success)
            }
            Spacer()
        }
        .padding(20)
        .background(Theme.surface)
    }
}

private struct RecoveryCodesOneTimeSheet: View {
    let codes: [String]
    let isSaving: Bool
    let errorMessage: String?
    let onDone: () -> Void
    @State private var didCopy = false

    private var joinedCodes: String {
        codes.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Save recovery codes")
                            .font(Theme.heading(24))
                            .foregroundStyle(Theme.textPrimary)
                        Text("These codes are shown once. Copy or share them now, then keep them somewhere private.")
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(codes, id: \.self) { code in
                            Text(code)
                                .font(Theme.mono(15))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .background(Theme.surfaceCard)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            RecoveryCodeClipboard.copy(joinedCodes)
                            didCopy = true
                        } label: {
                            Label(didCopy ? "Copied" : "Copy for 60 seconds", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                                .font(Theme.body(14, weight: .semibold))
                                .foregroundStyle(Theme.brand400)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Theme.brand50)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
                        }
                        .accessibilityIdentifier("recovery-codes.copy-all")

                        ShareLink(item: joinedCodes) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(Theme.body(14, weight: .semibold))
                                .foregroundStyle(Theme.brand400)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Theme.brand50)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.caption(13))
                            .foregroundStyle(Theme.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button { onDone() } label: {
                        HStack(spacing: 8) {
                            if isSaving { ProgressView().tint(.white) }
                            Text(isSaving ? "Saving…" : "I saved these codes")
                        }
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.brand500, in: RoundedRectangle(cornerRadius: Theme.radiusMedium))
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("recovery-codes.saved")
                }
                .padding(20)
            }
            .background(Theme.surface)
            .navigationTitle("Recovery codes")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct RecoveryCodesOneTimePreviewHost: View {
    @State private var isPresented = true

    var body: some View {
        Theme.surface
            .ignoresSafeArea()
            .sheet(isPresented: $isPresented) {
                RecoveryCodesOneTimeSheet(
                    codes: ["mta-1111-2222", "mta-3333-4444", "mta-5555-6666"],
                    isSaving: false,
                    errorMessage: nil
                ) {
                    isPresented = false
                }
                .interactiveDismissDisabled()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
    }
}

struct ClerkMigrationPreviewHost: View {
    @State private var status = ClerkDetachmentStatus(
        linked: true,
        ready: true,
        passkeyCount: 1,
        unusedRecoveryCodes: 8
    )
    @State private var showConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                ClerkMigrationCard(
                    status: status,
                    isDisconnecting: false,
                    errorMessage: nil,
                    onDisconnect: { showConfirmation = true },
                    onRetry: {}
                )
                .cardStyle(padding: 14)
                .padding(16)
            }
            .background(Theme.surface)
            .navigationTitle("Sign-in security")
        }
        .confirmationDialog(
            "Finish moving off Clerk?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect Clerk", role: .destructive) {
                status = ClerkDetachmentStatus(
                    linked: false,
                    ready: true,
                    passkeyCount: 1,
                    unusedRecoveryCodes: 8
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your recordings and current device session stay in Media Tools. Future sign-ins will use your passkey or a recovery code.")
        }
    }
}

private struct DeviceAccount: Decodable {
    let id: String
    let email: String
    let name: String
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
