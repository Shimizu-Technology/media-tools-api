import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One screen of everyday choices and short rows into the rest. Every account and
/// security action lives one level down, in the page its row names.
struct SettingsView: View {
    @Environment(AIProcessingConsentManager.self) private var aiProcessingConsent
    @Environment(DeviceSessionController.self) private var deviceSession
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var notificationState: NotificationPermissionState = .notRequested
    @State private var usage: AccountUsage?
    @State private var usageError: String?
    @State private var usageRetry = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScreenHeader("Settings")
                recordingCard
                usageCard
                destinationsCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("Settings")
        .toolbar(.hidden, for: .navigationBar)
        .statusBarBackdrop()
        .task { await refreshNotificationState() }
        .task(id: "usage|\(deviceSession.activeUserID ?? "")|\(usageRetry)") {
            await loadUsage()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshNotificationState() }
        }
    }

    // MARK: - Daily settings

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCard {
                Toggle(isOn: Binding(
                    get: { aiProcessingConsent.isAutoTranscribeEnabled },
                    set: { aiProcessingConsent.setAutoTranscribeEnabled($0) }
                )) {
                    SettingsRowLabel("Auto-transcribe", systemImage: "waveform")
                }
                .tint(Theme.accentFill)
                .settingsCardRow()
                .accessibilityIdentifier("settings.auto-transcribe")
                SettingsCardDivider()

                if aiProcessingConsent.isAutoTranscribeEnabled,
                   aiProcessingConsent.hasConsent,
                   !aiProcessingConsent.hasAutomaticConsent {
                    Button("Review automatic transcription") {
                        Task { _ = await aiProcessingConsent.requestAutomaticPermission() }
                    }
                    .foregroundStyle(Theme.accentText)
                    .settingsCardRow()
                    SettingsCardDivider()
                }

                Button(action: handleNotificationAction) {
                    HStack {
                        SettingsRowLabel("Completion alerts", systemImage: "bell")
                        Spacer(minLength: 8)
                        Text(notificationTrailing)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .settingsCardRow()
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityLabel("Notification settings")
                .accessibilityValue(notificationTrailing)
                SettingsCardDivider()

                NavigationLink(value: AppRoute.settings(.quickRecord)) {
                    SettingsLinkRow("Quick Record", systemImage: "mic", trailing: "Action Button")
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("settings.quick-record")
            }
            Text(autoTranscribeDetail)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var usageCard: some View {
        if deviceSession.activeUserID != nil, usage != nil || usageError != nil {
            SettingsCard {
                if let usage {
                    UsageSummaryView(usage: usage)
                        .padding(14)
                } else if let usageError {
                    VStack(alignment: .leading, spacing: 0) {
                        InlineError(usageError)
                        Button("Try again") { usageRetry += 1 }
                            .buttonStyle(QuietButtonStyle())
                    }
                    .padding(14)
                }
            }
        }
    }

    private var destinationsCard: some View {
        SettingsCard {
            if deviceSession.activeUserID != nil {
                destination("Account", systemImage: "person", page: .account, identifier: "settings.account")
                SettingsCardDivider()
                destination("Devices and passkeys", systemImage: "key", page: .security, identifier: "settings.security")
                SettingsCardDivider()
            }
            destination("AI processing", systemImage: "sparkles", page: .aiProcessing, identifier: "settings.ai")
            SettingsCardDivider()
            destination("Developer and agent keys", systemImage: "link", page: .developer, identifier: "settings.developer")
            SettingsCardDivider()
            destination("Help", systemImage: "questionmark.circle", page: .help, identifier: "settings.help")
        }
    }

    private func destination(
        _ title: String,
        systemImage: String,
        page: SettingsPage,
        identifier: String
    ) -> some View {
        NavigationLink(value: AppRoute.settings(page)) {
            SettingsLinkRow(title, systemImage: systemImage)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityIdentifier(identifier)
    }

    private var autoTranscribeDetail: String {
        guard aiProcessingConsent.isAutoTranscribeEnabled else {
            return "New recordings stay on this iPhone until you tap Transcribe."
        }
        return aiProcessingConsent.hasAutomaticConsent
            ? "New recordings, shared audio, and shared video links with no subtitles are sent for transcription when they are saved."
            : "New recordings stay on this iPhone until you allow AI processing."
    }

    private var notificationTrailing: String {
        switch notificationState {
        case .enabled: "On"
        case .denied: "Settings"
        case .notRequested: "Enable"
        }
    }

    private func handleNotificationAction() {
        switch notificationState {
        case .enabled, .denied:
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

    private func loadUsage() async {
        guard deviceSession.activeUserID != nil else {
            usage = nil
            usageError = nil
            return
        }
        do {
            let loaded = try await FirstPartyAuthService.shared.usage()
            guard !Task.isCancelled else { return }
            usage = loaded
            usageError = nil
        } catch {
            guard !Task.isCancelled else { return }
            if usage == nil { usageError = "Could not load this month's usage." }
        }
    }
}

/// The pages one level under Settings. They are routes, so a second tap on the tab
/// comes back from any of them.
enum SettingsPage: Hashable {
    case quickRecord
    case account
    case security
    case devices
    case aiProcessing
    case developer
    case help
}

struct SettingsPageView: View {
    let page: SettingsPage
    @Environment(DeviceSessionController.self) private var deviceSession

    var body: some View {
        switch page {
        case .quickRecord: QuickRecordSetupView()
        case .account: AccountSettingsView()
        case .security: SecuritySettingsView()
        case .devices: DevicesListView(currentSessionID: deviceSession.currentSessionID)
        case .aiProcessing: AIProcessingSettingsView()
        case .developer: DeveloperSettingsView()
        case .help: HelpSettingsView()
        }
    }
}

/// A rounded group of rows, as in the mockup.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SettingsCardDivider: View {
    var body: some View {
        Hairline()
            .padding(.leading, 56)
    }
}

private extension View {
    func settingsCardRow() -> some View {
        self
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 14)
    }
}

/// A row that goes somewhere, with what it currently says and a chevron.
private struct SettingsLinkRow: View {
    let title: String
    let systemImage: String
    var trailing: String?

    init(_ title: String, systemImage: String, trailing: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            SettingsRowLabel(title, systemImage: systemImage)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
        }
        .settingsCardRow()
        .contentShape(Rectangle())
    }
}

/// A settings row: a small tinted tile, then its name.
struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    var detail: String?
    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 30

    init(_ title: String, systemImage: String, detail: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.accentText)
                .frame(width: tileSize, height: tileSize)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.text)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private func settingLabel(_ title: String, detail: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title)
            .font(.body)
            .foregroundStyle(Theme.text)
        if let detail {
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A settings page's own list, with the shared width and title treatment.
private extension View {
    func settingsPage(_ title: String) -> some View {
        self
            .themedListBackground()
            .readableContentWidth(640, minimumMargin: 16)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Account

private struct AccountSettingsView: View {
    @Environment(RecordingUploadCoordinator.self) private var uploadCoordinator
    @Environment(AIProcessingConsentManager.self) private var aiProcessingConsent
    @Environment(DeviceSessionController.self) private var deviceSession

    @State private var deviceAccount: AccountProfile?
    @State private var isLoadingDeviceAccount = false
    @State private var deviceAccountError: String?
    @State private var deviceAccountRetry = 0
    @State private var passwordStatus: PasswordStatus?
    @State private var passwordAuthAvailable = false
    @State private var showChangeEmail = false
    @State private var accountMessage: String?
    @State private var isSigningOut = false
    @State private var showSignOutConfirmation = false
    @State private var signOutError: String?
    @State private var showDeleteAccount = false
    @State private var deletionConfirmation = ""
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?
    @State private var deleteAccountPassword = ""

    var body: some View {
        List {
            accountSection
            signOutSection
            deleteAccountSection
        }
        .settingsPage("Account")
        .task(id: "\(deviceSession.activeUserID ?? "")|\(deviceAccountRetry)") {
            deviceAccount = nil
            deviceAccountError = nil
            guard deviceSession.activeUserID != nil else { return }
            isLoadingDeviceAccount = true
            do {
                let account = try await FirstPartyAuthService.shared.accountProfile()
                guard !Task.isCancelled else { return }
                deviceAccount = account
            } catch {
                guard !Task.isCancelled else { return }
                deviceAccountError = "Could not load your account details."
            }
            isLoadingDeviceAccount = false
        }
        .task(id: "password|\(deviceSession.activeUserID ?? "")") {
            await loadPasswordStatus()
        }
        .sheet(isPresented: $showDeleteAccount) {
            deleteAccountConfirmationSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showChangeEmail) {
            ChangeEmailSheet(
                currentEmail: deviceAccount?.email ?? "",
                onFinished: {
                    showChangeEmail = false
                    accountMessage = "Email changed. Other devices were signed out."
                    deviceAccountRetry += 1
                },
                onCancel: { showChangeEmail = false }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if let deviceAccount {
                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceAccount.name.isEmpty ? "Media Tools account" : deviceAccount.name)
                        .font(.body)
                        .foregroundStyle(Theme.text)
                    Text(deviceAccount.email)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("settings.account-email")
                }
                .frame(minHeight: 44, alignment: .leading)
                .listRowBackground(Theme.surface)
                if passwordAuthAvailable {
                    Button("Change email") {
                        accountMessage = nil
                        showChangeEmail = true
                    }
                    .foregroundStyle(Theme.accentText)
                    .frame(minHeight: 44)
                    .listRowBackground(Theme.surface)
                    .accessibilityIdentifier("settings.change-email")
                }
            } else if isLoadingDeviceAccount {
                ProgressView("Loading account…")
                    .frame(minHeight: 44)
                    .listRowBackground(Theme.surface)
            } else if let deviceAccountError {
                VStack(alignment: .leading, spacing: 0) {
                    InlineError(deviceAccountError)
                    Button("Try again") { deviceAccountRetry += 1 }
                        .buttonStyle(QuietButtonStyle())
                }
                .listRowBackground(Theme.surface)
            }

            if let accountMessage {
                Label(accountMessage, systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Theme.surface)
            }
        }
    }

    private var signOutSection: some View {
        Section {
            Button {
                showSignOutConfirmation = true
            } label: {
                HStack(spacing: 8) {
                    if isSigningOut { ProgressView() }
                    Text(isSigningOut ? "Signing out…" : "Sign out")
                }
                .foregroundStyle(Theme.accentText)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .disabled(isSigningOut)
            .listRowBackground(Theme.surface)
            .confirmationDialog(
                "Sign out of Media Tools?",
                isPresented: $showSignOutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    Task { await signOut() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Recordings saved on this iPhone stay here and finish after you sign back in.")
            }

            if let signOutError {
                InlineError(signOutError)
                    .listRowBackground(Theme.surface)
            }
        }
    }

    private var deleteAccountSection: some View {
        Section {
            Button(role: .destructive) {
                deletionConfirmation = ""
                deleteAccountPassword = ""
                deleteAccountError = nil
                showDeleteAccount = true
            } label: {
                Text("Delete account and data")
                    .foregroundStyle(Theme.danger)
                    .frame(minHeight: 44)
            }
            .disabled(isDeletingAccount)
            .listRowBackground(Theme.surface)
        } footer: {
            Text("Permanently removes your recordings, transcripts, PDFs, chats, collections, developer keys, and account. Device recordings owned by this account are also removed.")
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var deleteAccountConfirmationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Permanently delete your account?")
                            .font(.displayTitle2)
                            .foregroundStyle(Theme.text)
                        Text("This cannot be undone. Export any device recordings you want to keep before continuing. Server data is purged immediately; secure provider cleanup continues in the background.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Type DELETE to confirm")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                        TextField("DELETE", text: $deletionConfirmation)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                            .themedField()
                    }

                    if DeletionPasswordPolicy.showsField(status: passwordStatus) {
                        SecureField(
                            DeletionPasswordPolicy.isRequired(status: passwordStatus)
                                ? "Current password"
                                : "Current password, if you have one",
                            text: $deleteAccountPassword
                        )
                            .textContentType(.password)
                            .authFieldStyle()
                            .accessibilityIdentifier("delete-account.password")
                    }

                    if let deleteAccountError {
                        InlineError(deleteAccountError)
                    }

                    Button(role: .destructive) {
                        Task { await deleteAccount() }
                    } label: {
                        HStack(spacing: 8) {
                            if isDeletingAccount { ProgressView().tint(Theme.onDanger) }
                            Text(isDeletingAccount ? "Deleting…" : "Permanently delete account")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(fill: Theme.danger, foreground: Theme.onDanger))
                    .disabled(!canSubmitDeletion || isDeletingAccount)
                }
                .padding(20)
            }
            .background(Theme.background)
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

    private var canSubmitDeletion: Bool {
        deletionConfirmation == "DELETE"
            && (!DeletionPasswordPolicy.isRequired(status: passwordStatus) || !deleteAccountPassword.isEmpty)
    }

    private func loadPasswordStatus() async {
        do {
            let health: HealthResponse = try await APIClient.shared.getPublic("/health")
            guard !Task.isCancelled else { return }
            passwordAuthAvailable = health.passwordAuthEnabled == true
            passwordStatus = passwordAuthAvailable
                ? try await FirstPartyAuthService.shared.passwordStatus()
                : nil
        } catch {
            guard !Task.isCancelled else { return }
            // Password rollout can be disabled independently, and an unknown status
            // still offers the deletion password field. See DeletionPasswordPolicy.
            passwordAuthAvailable = false
            passwordStatus = nil
        }
    }

    private func signOut() async {
        isSigningOut = true
        signOutError = nil
        defer { isSigningOut = false }

        // Stop every local workspace and background-upload path first. Server
        // cleanup can safely retry without letting the old account continue work
        // in the meantime. Recordings stay here under their owner.
        await uploadCoordinator.setActiveOwnerID(nil)
        aiProcessingConsent.setActiveOwnerID(nil)
        // The share extension stops here, whether or not the server can be reached.
        ShareUploadKeyManager.shared.endCredential()

        do {
            try await deviceSession.revokeOrSuspend()
            FirstPartyAuthService.shared.clearSessionScopedJournals()
        } catch {
            signOutError = "Couldn’t sign out. Please try again."
        }
    }

    private func deleteAccount() async {
        guard canSubmitDeletion,
              let ownerID = deviceSession.activeUserID else { return }
        isDeletingAccount = true
        deleteAccountError = nil
        defer { isDeletingAccount = false }

        do {
            let pending = try await AccountDeletionRecoveryService.shared.requestDeletion(
                ownerID: ownerID,
                currentPassword: DeletionPasswordPolicy.passwordToSend(
                    status: passwordStatus,
                    entered: deleteAccountPassword
                )
            )
            try await AccountDeletionRecoveryService.shared.finishLocalDeletion(
                pending,
                uploadCoordinator: uploadCoordinator,
                consent: aiProcessingConsent,
                deviceSession: deviceSession,
                shareKeys: .shared
            )
        } catch {
            deleteAccountError = error.localizedDescription
            return
        }
        deleteAccountPassword = ""
        showDeleteAccount = false
    }
}

// MARK: - Devices and passkeys

private struct SecuritySettingsView: View {
    @Environment(DeviceSessionController.self) private var deviceSession

    @State private var deviceAccount: AccountProfile?
    @State private var passkeyStatus: PasskeyStatus?
    @State private var passwordStatus: PasswordStatus?
    @State private var passwordAuthAvailable = false
    @State private var showPasswordSetup = false
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
    @State private var accountRetry = 0

    var body: some View {
        List {
            accountSecuritySection
        }
        .settingsPage("Devices and passkeys")
        .task(id: "\(deviceSession.activeUserID ?? "")|\(accountRetry)") {
            guard deviceSession.activeUserID != nil else { return }
            deviceAccount = try? await FirstPartyAuthService.shared.accountProfile()
        }
        .task(id: "security|\(deviceSession.activeUserID ?? "")") {
            await loadRecoveryStatus()
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
        .sheet(isPresented: $showPasswordSetup) {
            PasswordManagementSheet(
                configured: passwordStatus?.configured == true,
                email: deviceAccount?.email ?? "",
                emailVerified: deviceAccount?.emailVerified == true,
                onSaved: { status in
                    let wasConfigured = passwordStatus?.configured == true
                    passwordStatus = status
                    showPasswordSetup = false
                    securityMessage = wasConfigured
                        ? "Password changed. Other devices were signed out."
                        : "Password created. You can now sign in with your email."
                },
                onEmailVerified: { accountRetry += 1 },
                onCancel: { showPasswordSetup = false }
            )
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
    }

    // MARK: - Security

    @ViewBuilder
    private var accountSecuritySection: some View {
        if deviceSession.activeUserID != nil {
            Section {
                Button {
                    Task { await enrollPasskey() }
                } label: {
                    HStack {
                        settingLabel(
                            isEnrollingPasskey ? "Opening passkey setup…" : "Add a passkey",
                            detail: passkeyDetail
                        )
                        Spacer(minLength: 8)
                        if isEnrollingPasskey { ProgressView() }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isEnrollingPasskey || isGeneratingRecoveryCodes)
                .listRowBackground(Theme.surface)

                if passwordAuthAvailable {
                    Button {
                        securityMessage = nil
                        showPasswordSetup = true
                    } label: {
                        settingLabel(
                            passwordStatus?.configured == true ? "Change password" : "Create a password",
                            detail: passwordStatus?.configured == true
                                ? "Sign in with your email on any device."
                                : "Add a password you control for email sign-in."
                        )
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // The sheet needs the account's email for AutoFill and proof.
                    .disabled(deviceAccount == nil)
                    .listRowBackground(Theme.surface)
                    .accessibilityIdentifier("sign-in-security.password")
                }

                Button {
                    showReplaceRecoveryCodesConfirmation = true
                } label: {
                    HStack {
                        settingLabel(
                            recoveryStatus?.remaining ?? 0 > 0 ? "Replace recovery codes" : "Create recovery codes",
                            detail: recoveryDetail
                        )
                        Spacer(minLength: 8)
                        if isLoadingRecoveryStatus || isGeneratingRecoveryCodes {
                            ProgressView()
                        } else if let remaining = recoveryStatus?.remaining {
                            Text("\(remaining) left")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize()
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isGeneratingRecoveryCodes || isEnrollingPasskey)
                .listRowBackground(Theme.surface)

                NavigationLink(value: AppRoute.settings(.devices)) {
                    settingLabel("Devices", detail: "See where you are signed in, and sign out a device.")
                        .frame(minHeight: 44)
                }
                .listRowBackground(Theme.surface)
                .accessibilityIdentifier("sign-in-security.devices")

                if let securityStatusError {
                    SecurityStatusRetryBanner(
                        message: securityStatusError,
                        isRetrying: isLoadingRecoveryStatus
                    ) {
                        Task { await loadRecoveryStatus() }
                    }
                    .listRowBackground(Theme.surface)
                }

                if let securityMessage {
                    Label(securityMessage, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Theme.surface)
                }

                if let securityError {
                    InlineError(securityError)
                        .listRowBackground(Theme.surface)
                }
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

    private func loadRecoveryStatus() async {
        guard deviceSession.activeUserID != nil else {
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
        do {
            let health: HealthResponse = try await APIClient.shared.getPublic("/health")
            guard !Task.isCancelled else { return }
            passwordAuthAvailable = health.passwordAuthEnabled == true
            if passwordAuthAvailable {
                passwordStatus = try await FirstPartyAuthService.shared.passwordStatus()
            } else {
                passwordStatus = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            // Password rollout can be disabled independently. Keep passkey and
            // recovery management usable if that capability is unavailable.
            passwordAuthAvailable = false
            passwordStatus = nil
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
}

// MARK: - AI processing

private struct AIProcessingSettingsView: View {
    @Environment(AIProcessingConsentManager.self) private var aiProcessingConsent

    var body: some View {
        List {
            Section {
                settingLabel(
                    aiProcessingConsent.hasConsent
                        ? "Allowed for this account on this iPhone"
                        : "Not allowed",
                    detail: aiProcessingConsent.hasConsent
                        ? nil
                        : "Media Tools will ask before sending content to third-party AI services."
                )
                .frame(minHeight: 44, alignment: .leading)
                .listRowBackground(Theme.surface)

                Button {
                    if aiProcessingConsent.hasConsent {
                        aiProcessingConsent.revoke()
                    } else {
                        Task { _ = await aiProcessingConsent.requestPermission() }
                    }
                } label: {
                    Text(aiProcessingConsent.hasConsent ? "Revoke permission" : "Review and allow")
                        .foregroundStyle(aiProcessingConsent.hasConsent ? Theme.danger : Theme.accentText)
                        .frame(minHeight: 44)
                }
                .listRowBackground(Theme.surface)
            } footer: {
                Text("This controls future transcription, readable formatting, summary, and chat requests. Processing already started may finish.")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .settingsPage("AI processing")
    }
}

// MARK: - Developer

/// Keys are created and revoked on the web, where their scopes can be read in full.
private struct DeveloperSettingsView: View {
    @State private var health: HealthResponse?
    @State private var healthError: String?
    @State private var isCheckingHealth = false
    @State private var showAdvanced = false

    var body: some View {
        List {
            Section {
                settingsLink(title: "Manage developer and agent keys", destination: Configuration.developerURL)
            } footer: {
                Text("Keys let your agents and tools read and act on your library. They open on the web, signed in to this account.")
                    .foregroundStyle(Theme.textSecondary)
            }

            Section {
                DisclosureGroup("Service status", isExpanded: $showAdvanced) {
                    if isCheckingHealth {
                        ProgressNote(text: "Checking service…")
                            .listRowBackground(Theme.surface)
                    } else if let health {
                        LabeledContent("Service", value: health.status == "ok" ? "Available" : "Degraded")
                            .listRowBackground(Theme.surface)
                        LabeledContent("Workers", value: "\(health.workers)")
                            .listRowBackground(Theme.surface)
                    } else if let healthError {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(healthError)
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                            Button("Try again") {
                                Task { await checkHealth() }
                            }
                            .buttonStyle(QuietButtonStyle())
                        }
                        .listRowBackground(Theme.surface)
                    }
                    LabeledContent("API") {
                        Text(Configuration.apiBaseURL)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    .listRowBackground(Theme.surface)
                }
                .foregroundStyle(Theme.text)
                .frame(minHeight: 44)
                .listRowBackground(Theme.surface)
                .onChange(of: showAdvanced) { _, isExpanded in
                    guard isExpanded, health == nil else { return }
                    Task { await checkHealth() }
                }

                LabeledContent("Version", value: appVersion)
                    .foregroundStyle(Theme.text)
                    .frame(minHeight: 44)
                    .listRowBackground(Theme.surface)
            }
        }
        .settingsPage("Developer and agent keys")
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
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
}

// MARK: - Help

private struct HelpSettingsView: View {
    var body: some View {
        List {
            Section {
                settingsLink(title: "Privacy", destination: Configuration.privacyURL)
                settingsLink(title: "Terms of use", destination: Configuration.termsURL)
                settingsLink(title: "Support and safety", destination: Configuration.supportURL)
                settingsLink(title: "Account deletion help", destination: Configuration.accountDeletionURL)
            }
        }
        .settingsPage("Help")
    }
}

private func settingsLink(title: String, destination: URL) -> some View {
    Link(destination: destination) {
        HStack {
            Text(title)
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
    .listRowBackground(Theme.surface)
    .accessibilityAddTraits(.isLink)
}

/// Quick Record setup lives a level down: it is done once, then rarely revisited.
private struct QuickRecordSetupView: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true

    var body: some View {
        List {
            Section {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1).")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                        Text(step)
                            .font(.subheadline)
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .listRowBackground(Theme.surface)
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                Text("One press opens Media Tools and begins recording. Use it only when everyone who must consent has done so. After capture starts, you can lock your phone or use another app.")
                    .foregroundStyle(Theme.textSecondary)
            }

            Section {
                Button("Open Shortcuts") {
                    guard let shortcutsURL = URL(string: "shortcuts://") else { return }
                    openURL(shortcutsURL)
                }
                .foregroundStyle(Theme.accentText)
                .frame(minHeight: 44)
                .listRowBackground(Theme.surface)
                .accessibilityHint("Opens the Shortcuts app to configure Quick Record")

                Button("Review setup") {
                    hasCompletedOnboarding = false
                }
                .foregroundStyle(Theme.accentText)
                .frame(minHeight: 44)
                .listRowBackground(Theme.surface)
                .accessibilityHint("Shows microphone, alert, and privacy guidance again")
            }
        }
        .themedListBackground()
        .navigationTitle("Quick Record")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let steps = [
        "Open Shortcuts and find Media Tools, then Quick Record.",
        "In Settings, under Action Button, choose Shortcut and select Quick Record.",
        "Press once to start. Press again, or use the Live Activity, to stop.",
    ]
}

private struct SecurityStatusRetryBanner: View {
    let message: String
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InlineError(message)
            Button { onRetry() } label: {
                HStack(spacing: 8) {
                    if isRetrying { ProgressView() }
                    Text(isRetrying ? "Checking…" : "Retry")
                }
            }
            .buttonStyle(QuietButtonStyle())
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
                .font(.displayTitle2)
                .foregroundStyle(Theme.text)
            Text("1 passkey is set up.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Text("2 recovery codes left")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            if let message {
                SecurityStatusRetryBanner(message: message, isRetrying: false) {
                    didRetry = true
                    self.message = nil
                }
            }
            if didRetry {
                Text("Security status refreshed")
                    .font(.footnote)
                    .foregroundStyle(Theme.text)
            }
            Spacer()
        }
        .padding(20)
        .background(Theme.background)
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
                            .font(.displayTitle2)
                            .foregroundStyle(Theme.text)
                        Text("These codes are shown once. Copy or share them now, then keep them somewhere private.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(codes, id: \.self) { code in
                            Text(code)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .background(Theme.background)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 24) { recoveryCodeActions }
                        VStack(alignment: .leading, spacing: 0) { recoveryCodeActions }
                    }

                    if let errorMessage {
                        InlineError(errorMessage)
                    }

                    Button { onDone() } label: {
                        HStack(spacing: 8) {
                            if isSaving { ProgressView().tint(Theme.onAccent) }
                            Text(isSaving ? "Saving…" : "I saved these codes")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isSaving)
                    .accessibilityIdentifier("recovery-codes.saved")
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Recovery codes")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private extension RecoveryCodesOneTimeSheet {
    @ViewBuilder
    var recoveryCodeActions: some View {
        Button {
            RecoveryCodeClipboard.copy(joinedCodes)
            didCopy = true
        } label: {
            Label(didCopy ? "Copied" : "Copy for 60 seconds", systemImage: didCopy ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityIdentifier("recovery-codes.copy-all")

        ShareLink(item: joinedCodes) {
            Label("Share", systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accentText)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
    }
}

struct RecoveryCodesOneTimePreviewHost: View {
    @State private var isPresented = true

    var body: some View {
        Theme.background
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

/// Whether the delete sheet asks for a password. An unknown status, from a failed
/// lookup, offers the field without requiring it: the server decides, and a
/// rejection then has a field to fix. Hiding it would leave "your password is
/// incorrect" with nothing to correct, and requiring it would block deleting an
/// account that has no password.
enum DeletionPasswordPolicy {
    static func isRequired(status: PasswordStatus?) -> Bool {
        status?.configured == true
    }

    static func showsField(status: PasswordStatus?) -> Bool {
        status?.configured != false
    }

    static func passwordToSend(status: PasswordStatus?, entered: String) -> String? {
        switch status?.configured {
        case true: return entered
        case false: return nil
        default: return entered.isEmpty ? nil : entered
        }
    }
}
