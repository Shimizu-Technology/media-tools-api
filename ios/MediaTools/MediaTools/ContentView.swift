import SwiftUI

struct ContentView: View {
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(RecordingUploadCoordinator.self) private var uploadCoordinator
    @Environment(AIProcessingConsentManager.self) private var aiProcessingConsent
    @Environment(DeviceSessionController.self) private var deviceSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var isResolvingAccount = true
    @State private var isReconcilingDeletion: Bool
    @State private var migrationFailed = false
    @State private var migrationRetry = 0
    @State private var legacyReconnect = LegacyRecordingReconnect.idle
    @State private var legacyReconnectRetry = 0
    @State private var nativeAuthOperation: NativeAuthOperation?
    @State private var nativeAuthError: String?
    @State private var recoveryCode = ""
    @State private var activeSheet: WelcomeSheet?
    @State private var passwordEmail = ""
    @State private var passwordValue = ""
    @State private var authAvailability: AuthAvailability
    @State private var authAvailabilityRetry = 0
    private let forceSignedOutForUITesting: Bool

    init(forceSignedOutForUITesting: Bool = false) {
        self.forceSignedOutForUITesting = forceSignedOutForUITesting
        _authAvailability = State(initialValue: forceSignedOutForUITesting ? .uiTestSignedOut : .unknown)
        _isReconcilingDeletion = State(
            initialValue: !forceSignedOutForUITesting
                && AccountDeletionRecoveryService.shared.hasPendingDeletion
        )
    }

    private var activeUserID: String? {
        forceSignedOutForUITesting ? nil : deviceSession.activeUserID
    }

    var body: some View {
        Group {
            if isReconcilingDeletion || isBlockedOnAccountResolution {
                ProgressView("Restoring your workspace…")
            } else if deviceSession.isSessionStoreUnavailable,
                      activeUserID == nil,
                      !forceSignedOutForUITesting {
                VStack(spacing: 16) {
                    Text("Unlock your iPhone to open Media Tools. Your recordings are safe.")
                        .multilineTextAlignment(.center)
                    tryAgainButton { deviceSession.reloadStoredSessionIfUnavailable() }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(Theme.textPrimary)
                .background(Theme.surface)
            } else if deviceSession.isAwaitingSessionRecovery,
                      activeUserID == nil,
                      !forceSignedOutForUITesting {
                VStack(spacing: 16) {
                    Text("Reconnecting your account. Your recordings are safe on this iPhone.")
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("session-recovery.message")
                    tryAgainButton { migrationRetry += 1 }
                        .accessibilityIdentifier("session-recovery.retry")
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(Theme.textPrimary)
                .background(Theme.surface)
            } else if migrationFailed {
                VStack(spacing: 16) {
                    Text("Your local recordings could not be connected to this account.")
                        .multilineTextAlignment(.center)
                    tryAgainButton { migrationRetry += 1 }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(Theme.textPrimary)
                .background(Theme.surface)
            } else if activeUserID != nil {
                MainTabView()
                    // A different account gets fresh tabs and library state. A
                    // background refresh of the same account never rebuilds them.
                    .id(activeUserID)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if legacyReconnect != .idle { legacyReconnectBanner }
                    }
            } else {
                WelcomeView(
                    activeSheet: $activeSheet,
                    recoveryCode: $recoveryCode,
                    passwordEmail: $passwordEmail,
                    passwordValue: $passwordValue,
                    availability: authAvailability,
                    nativeAuthOperation: nativeAuthOperation,
                    nativeAuthError: $nativeAuthError,
                    onRetryAvailability: { authAvailabilityRetry += 1 },
                    onPasskeySignIn: { await completeNativeSignIn(.passkey) },
                    onPasswordSignIn: { await completeNativeSignIn(.password) },
                    onRecoveryCodeSignIn: { await completeNativeSignIn(.recoveryCode) }
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            deviceSession.reloadStoredSessionIfUnavailable()
            // Launch reaches this while the first attempt is still on the wire.
            if deviceSession.isAwaitingSessionRecovery, !isResolvingAccount { migrationRetry += 1 }
            startShareKeySetup()
        }
        .onChange(of: deviceSession.activeUserID) { _, ownerID in
            // A sign-up or reset finishes inside its own sheet.
            if ownerID != nil { activeSheet = nil }
        }
        .task(id: "\(deviceSession.needsSignIn)|\(deviceSession.sessionRevision)|\(migrationRetry)") {
            guard !forceSignedOutForUITesting else {
                aiProcessingConsent.setActiveOwnerID(nil)
                await uploadCoordinator.setActiveOwnerID(nil)
                isResolvingAccount = false
                return
            }
            isResolvingAccount = true
            migrationFailed = false
            // Open a stored workspace before any network request: a slow or
            // absent connection must not stand between Leon and his library
            // or a recording. Everything below keeps running in the background.
            if !isReconcilingDeletion, let openOwnerID = activeUserID {
                guard await applyVerifiedMigration() else { return }
                aiProcessingConsent.setActiveOwnerID(openOwnerID)
                await uploadCoordinator.setActiveOwnerID(openOwnerID)
                guard !Task.isCancelled else { return }
                isResolvingAccount = false
            }
            if let pending = try? await AccountDeletionRecoveryService.shared.confirmedPendingDeletion(
                retryOwnerID: deviceSession.storedUserID
            ) {
                try? await AccountDeletionRecoveryService.shared.finishLocalDeletion(
                    pending,
                    uploadCoordinator: uploadCoordinator,
                    consent: aiProcessingConsent,
                    deviceSession: deviceSession,
                    shareKeys: .shared
                )
            }
            guard !Task.isCancelled else { return }
            isReconcilingDeletion = false
            let ownerID = await deviceSession.activate()
            guard !Task.isCancelled else { return }
            guard await applyVerifiedMigration() else { return }
            aiProcessingConsent.setActiveOwnerID(ownerID)
            await uploadCoordinator.setActiveOwnerID(ownerID)
            isResolvingAccount = false
            startShareKeySetup()
        }
        // Runs again on every foreground, on Try again, and whenever the list of
        // waiting recordings changes, which includes a late manifest restore.
        .task(id: legacyReconnectTrigger) {
            await reconnectLegacyRecordings()
        }
        .task(id: "auth-availability|\(scenePhase)|\(activeUserID ?? "signed-out")|\(authAvailabilityRetry)") {
            guard !forceSignedOutForUITesting,
                  scenePhase == .active,
                  activeUserID == nil else { return }
            do {
                let health: HealthResponse = try await APIClient.shared.getPublic("/health")
                guard !Task.isCancelled else { return }
                authAvailability = AuthAvailability(health: health)
            } catch {
                guard !Task.isCancelled else { return }
                authAvailability = .unknown
            }
        }
    }

    /// A background refresh must not cover an open workspace with a spinner:
    /// that destroys the tabs and any route the Action Button just requested.
    private var isBlockedOnAccountResolution: Bool {
        isResolvingAccount && activeUserID == nil
    }

    /// Never awaited by anything the person is waiting on. Without a key, a share
    /// simply waits for this app, so a failure here has no visible effect.
    private func startShareKeySetup() {
        guard !forceSignedOutForUITesting, let ownerID = activeUserID,
              deviceSession.hasNativeFirstPartySession else { return }
        Task { await ShareUploadKeyManager.shared.ensureKey(ownerID: ownerID) }
    }

    private var legacyReconnectTrigger: String {
        let owners = recorder.legacyProviderOwnerIDs.sorted().joined(separator: ",")
        return "\(activeUserID ?? "")|\(scenePhase == .active)|\(isResolvingAccount)|\(owners)|\(legacyReconnectRetry)"
    }

    /// A build that ran on the retired provider without a device session saved
    /// recordings under a provider ID, with no local record of whose it was. The
    /// server knows, so it is asked only when such a recording is actually here.
    private func reconnectLegacyRecordings() async {
        let legacyOwners = recorder.legacyProviderOwnerIDs
        guard !forceSignedOutForUITesting, let ownerID = activeUserID, !legacyOwners.isEmpty else {
            legacyReconnect = .idle
            return
        }
        // Moved to the background or still opening. The next trigger tries again.
        guard scenePhase == .active, !isResolvingAccount else { return }
        legacyReconnect = .reconnecting
        let outcome = await LegacyRecordingReconnect.run(
            ownerID: ownerID,
            legacyOwners: legacyOwners,
            profile: { try await FirstPartyAuthService.shared.accountProfile() }
        )
        guard !Task.isCancelled else { return }
        switch outcome {
        case .belongsHere(let clerkID):
            deviceSession.adoptServerVerifiedLegacyIdentity(clerkID, ownerID: ownerID)
            legacyReconnect = .idle
            migrationRetry += 1
        case .belongsElsewhere:
            // Another account's work stays hidden here, and is not a failure.
            legacyReconnect = .idle
        case .couldNotCheck:
            legacyReconnect = .failed
        }
    }

    /// The height goes on the label: on the button, it would not grow the tap area.
    private func tryAgainButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Try again")
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.brand400)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var legacyReconnectBanner: some View {
        HStack(spacing: 12) {
            Text(legacyReconnect == .failed
                ? "Some recordings on this iPhone aren't connected to your account yet. They're safe."
                : "Reconnecting recordings saved on this iPhone…")
                .font(Theme.caption(13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("legacy-reconnect.message")
            if legacyReconnect == .failed {
                tryAgainButton { legacyReconnectRetry += 1 }
                    .accessibilityIdentifier("legacy-reconnect.retry")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.surfaceCard)
    }

    /// Returns false when the workspace must stay closed. A partial migration
    /// is repeatable, but opening here could hide recordings saved under the
    /// provider ID this account used before.
    private func applyVerifiedMigration() async -> Bool {
        guard let migration = deviceSession.verifiedMigration else { return true }
        do {
            try await uploadCoordinator.migrateOwnerID(
                from: migration.clerkID,
                to: migration.userID
            )
            aiProcessingConsent.migrateConsent(
                from: migration.clerkID,
                to: migration.userID
            )
            return !Task.isCancelled
        } catch {
            guard !Task.isCancelled else { return false }
            await uploadCoordinator.setActiveOwnerID(nil)
            aiProcessingConsent.setActiveOwnerID(nil)
            migrationFailed = true
            isResolvingAccount = false
            return false
        }
    }

    private func completeNativeSignIn(_ operation: NativeAuthOperation) async {
        guard nativeAuthOperation == nil else { return }
        nativeAuthOperation = operation
        nativeAuthError = nil
        defer { nativeAuthOperation = nil }

        do {
            switch operation {
            case .passkey:
                try await FirstPartyAuthService.shared.signInWithPasskey()
            case .password:
                try await FirstPartyAuthService.shared.signInWithPassword(
                    email: passwordEmail,
                    password: passwordValue
                )
                passwordValue = ""
                activeSheet = nil
            case .recoveryCode:
                try await FirstPartyAuthService.shared.redeemRecoveryCode(recoveryCode)
                recoveryCode = ""
                activeSheet = nil
            }
            migrationRetry += 1
        } catch {
            guard !FirstPartyAuthService.isCancellation(error) else { return }
            nativeAuthError = AuthCopy.message(
                for: error,
                fallback: "Could not sign in. Please try again."
            )
        }
    }
}

/// Recordings saved under a provider ID, while the server is asked whose they are.
enum LegacyRecordingReconnect: Equatable {
    case idle
    case reconnecting
    case failed

    enum Outcome: Equatable {
        case belongsHere(clerkID: String)
        case belongsElsewhere
        case couldNotCheck
    }

    /// Only an answer from the server for this exact account can move a recording.
    static func run(
        ownerID: String,
        legacyOwners: Set<String>,
        profile: () async throws -> AccountProfile
    ) async -> Outcome {
        guard let account = try? await profile(), account.id == ownerID else { return .couldNotCheck }
        guard let clerkID = account.clerkId, legacyOwners.contains(clerkID) else { return .belongsElsewhere }
        return .belongsHere(clerkID: clerkID)
    }
}

enum NativeAuthOperation {
    case passkey
    case password
    case recoveryCode
}

enum WelcomeSheet: String, Identifiable {
    case signIn
    case createAccount
    case forgotPassword
    case recoveryCode

    var id: String { rawValue }
}

/// What the server offers. Unknown means it could not be reached, in which case
/// signing in still shows: an existing account must never look unavailable.
struct AuthAvailability: Equatable {
    var passwordAuth: Bool?
    var signup: Bool
    var passwordReset: Bool?

    static let unknown = AuthAvailability(passwordAuth: nil, signup: false, passwordReset: nil)
    static let uiTestSignedOut = AuthAvailability(passwordAuth: true, signup: true, passwordReset: true)

    init(passwordAuth: Bool?, signup: Bool, passwordReset: Bool?) {
        self.passwordAuth = passwordAuth
        self.signup = signup
        self.passwordReset = passwordReset
    }

    init(health: HealthResponse) {
        passwordAuth = health.passwordAuthEnabled == true
        signup = health.signupEnabled == true
        passwordReset = health.authCapabilities?.passwordReset == true
    }
}

// MARK: - Welcome (unauthenticated)

struct WelcomeView: View {
    @Binding var activeSheet: WelcomeSheet?
    @Binding var recoveryCode: String
    @Binding var passwordEmail: String
    @Binding var passwordValue: String
    let availability: AuthAvailability
    let nativeAuthOperation: NativeAuthOperation?
    @Binding var nativeAuthError: String?
    let onRetryAvailability: () -> Void
    let onPasskeySignIn: () async -> Void
    let onPasswordSignIn: () async -> Void
    let onRecoveryCodeSignIn: () async -> Void
    @Environment(RecordingCoordinator.self) private var recorder

    var body: some View {
        ZStack {
            Theme.surface.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Theme.brand500.opacity(0.06))
                                .frame(width: 90, height: 90)

                            Circle()
                                .fill(Theme.brand500.opacity(0.12))
                                .frame(width: 62, height: 62)

                            Image(systemName: "waveform.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(Theme.brand500)
                        }

                        VStack(spacing: 8) {
                            Text("PRIVATE MEDIA WORKSPACE")
                                .font(Theme.caption(11, weight: .semibold))
                                .foregroundStyle(Theme.brand400)
                                .tracking(1.2)

                            Text("Media Tools")
                                .font(Theme.heading(30))
                                .foregroundStyle(Theme.textPrimary)

                            Text("Sign in to record, transcribe, and organize your media in one private workspace.")
                                .font(Theme.body(16))
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(spacing: 12) {
                        FeatureRow(
                            icon: "mic.fill",
                            color: Theme.brand400,
                            title: "Capture from your phone",
                            subtitle: "Record live or upload existing audio and video files."
                        )
                        FeatureRow(
                            icon: "play.rectangle.fill",
                            color: Theme.videoColor,
                            title: "Bring in videos and PDFs",
                            subtitle: "Extract text, summaries, and answers from your source."
                        )
                        FeatureRow(
                            icon: "lock.shield.fill",
                            color: Theme.success,
                            title: "Keep work connected",
                            subtitle: "Reopen everything from your library on web or iPhone."
                        )
                    }
                    .padding(16)
                    .background(Theme.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.radiusLarge)
                            .stroke(Theme.borderSubtle, lineWidth: 1)
                    }

                    if !recorder.availableRecordings.isEmpty || !recorder.availableSharedItems.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Saved on this iPhone", systemImage: "iphone.and.arrow.forward")
                                .font(Theme.body(16, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("These are saved here. Sign in to review and transcribe them.")
                                .font(Theme.caption(13))
                                .foregroundStyle(Theme.textSecondary)
                            ForEach(recorder.availableRecordings) { recording in
                                if let fileURL = recorder.fileURL(for: recording) {
                                    ShareLink(item: fileURL) {
                                        Label(recording.displayTitle, systemImage: "square.and.arrow.up")
                                    }
                                    .font(Theme.caption(13))
                                }
                            }
                            ForEach(recorder.availableSharedItems) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    if let fileURL = recorder.sharedFileURL(for: item) {
                                        ShareLink(item: fileURL) {
                                            Label(item.originalName, systemImage: "square.and.arrow.up")
                                        }
                                        .font(Theme.caption(13))
                                    } else {
                                        Label(item.originalName, systemImage: "link")
                                            .font(Theme.caption(13))
                                            .foregroundStyle(Theme.textPrimary)
                                            .lineLimit(2)
                                    }
                                    if item.resolvedKind != .audio,
                                       recorder.pendingSharedErrors[item.id] == nil {
                                        Text("Waiting for you to sign in")
                                            .font(Theme.caption(12))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                    if let reason = recorder.pendingSharedErrors[item.id] {
                                        Text(reason)
                                            .font(Theme.caption(12))
                                            .foregroundStyle(Theme.error)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Theme.surfaceCard)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
                    }

                    VStack(spacing: 10) {
                        if availability.passwordAuth != false {
                            Button {
                                nativeAuthError = nil
                                activeSheet = .signIn
                            } label: {
                                Label("Sign in", systemImage: "envelope.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .brandButtonStyle()
                            .disabled(nativeAuthOperation != nil)
                            .accessibilityIdentifier("welcome.sign-in")
                        }

                        if availability.signup {
                            Button {
                                nativeAuthError = nil
                                activeSheet = .createAccount
                            } label: {
                                Label("Create account", systemImage: "person.badge.plus")
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.brand400)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .background(Theme.brand50)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
                            }
                            .disabled(nativeAuthOperation != nil)
                            .accessibilityIdentifier("welcome.create-account")
                        }

                        if availability.passwordReset != false, availability.passwordAuth != false {
                            Button {
                                nativeAuthError = nil
                                activeSheet = .forgotPassword
                            } label: {
                                Text("Forgot password?")
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.brand400)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .disabled(nativeAuthOperation != nil)
                            .accessibilityIdentifier("welcome.forgot-password")

                            Text("Never set a password? Use Forgot password with your account email.")
                                .font(Theme.caption(12))
                                .foregroundStyle(Theme.textMuted)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("welcome.authentication.options")
                        }

                        if availability.passwordAuth == nil {
                            Button("Check connection", action: onRetryAvailability)
                                .font(Theme.caption(13, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(minHeight: 44)
                                .disabled(nativeAuthOperation != nil)
                        }

                        if let nativeAuthError, activeSheet == nil {
                            Text(nativeAuthError)
                                .font(Theme.caption(12))
                                .foregroundStyle(Theme.error)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 12) {
                        Rectangle().fill(Theme.borderSubtle).frame(height: 1)
                        Text("Other ways to sign in")
                            .font(Theme.caption(12, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize()
                        Rectangle().fill(Theme.borderSubtle).frame(height: 1)
                    }

                    VStack(spacing: 4) {
                        secondarySignInButton(
                            title: nativeAuthOperation == .passkey ? "Checking passkey…" : "Continue with passkey",
                            icon: "key.fill",
                            identifier: "welcome.passkey"
                        ) {
                            Task { await onPasskeySignIn() }
                        }
                        secondarySignInButton(
                            title: "Use a recovery code",
                            icon: "lifepreserver",
                            identifier: "welcome.recovery-code"
                        ) {
                            nativeAuthError = nil
                            activeSheet = .recoveryCode
                        }
                    }

                    Text("Powered by Shimizu Technology")
                        .font(Theme.caption(11))
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(item: $activeSheet, onDismiss: { passwordValue = "" }) { sheet in
            sheetContent(sheet)
                .presentationDetents(sheet == .recoveryCode ? [.medium, .large] : [.large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(nativeAuthOperation != nil)
        }
    }

    private func secondarySignInButton(
        title: String,
        icon: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(nativeAuthOperation != nil)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: WelcomeSheet) -> some View {
        switch sheet {
        case .signIn:
            PasswordSignInSheet(
                email: $passwordEmail,
                password: $passwordValue,
                isSigningIn: nativeAuthOperation == .password,
                errorMessage: nativeAuthError,
                showsForgotPassword: availability.passwordReset != false,
                onForgotPassword: {
                    nativeAuthError = nil
                    activeSheet = .forgotPassword
                },
                onCancel: { nativeAuthError = nil; activeSheet = nil },
                onContinue: { Task { await onPasswordSignIn() } }
            )
        case .createAccount, .forgotPassword:
            EmailPasswordFlowView(
                purpose: sheet == .createAccount ? .createAccount : .resetPassword,
                initialEmail: passwordEmail,
                onSignInNeeded: { email in
                    passwordEmail = email
                    nativeAuthError = "Your password is saved. Sign in to continue."
                    activeSheet = .signIn
                },
                onCancel: { activeSheet = nil }
            )
        case .recoveryCode:
            RecoveryCodeSignInSheet(
                code: $recoveryCode,
                isSigningIn: nativeAuthOperation == .recoveryCode,
                errorMessage: nativeAuthError,
                onCancel: { nativeAuthError = nil; activeSheet = nil },
                onContinue: { Task { await onRecoveryCodeSignIn() } }
            )
        }
    }
}

private struct PasswordSignInSheet: View {
    @Binding var email: String
    @Binding var password: String
    let isSigningIn: Bool
    let errorMessage: String?
    let showsForgotPassword: Bool
    let onForgotPassword: () -> Void
    let onCancel: () -> Void
    let onContinue: () -> Void

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign in")
                            .font(Theme.heading(24))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Use your Media Tools email and password. This iPhone stays signed in until you sign out or revoke it.")
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .authFieldStyle()
                        .accessibilityIdentifier("password-sign-in.email")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit {
                            guard !isSigningIn, canSubmit else { return }
                            onContinue()
                        }
                        .authFieldStyle()
                        .accessibilityIdentifier("password-sign-in.password")
                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.caption(13))
                            .foregroundStyle(Theme.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("password-sign-in.error")
                    }
                    AuthPrimaryButton(
                        title: "Sign in",
                        busyTitle: "Signing in…",
                        isBusy: isSigningIn,
                        isEnabled: canSubmit,
                        identifier: "password-sign-in.continue",
                        action: onContinue
                    )
                    if showsForgotPassword {
                        Button("Forgot password?", action: onForgotPassword)
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(Theme.brand400)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(isSigningIn)
                            .accessibilityIdentifier("password-sign-in.forgot-password")
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.surface)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() }.disabled(isSigningIn) } }
        }
    }
}

private struct RecoveryCodeSignInSheet: View {
    @Binding var code: String
    let isSigningIn: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use recovery code")
                            .font(Theme.heading(24))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Enter one saved code to restore access on this iPhone. Each code works once.")
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    TextField("Recovery code", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.mono(16))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 50)
                        .background(Theme.surfaceCard)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.radiusMedium)
                                .stroke(Theme.borderSubtle, lineWidth: 1)
                        }
                        .accessibilityIdentifier("recovery-code.sign-in-field")

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.caption(13))
                            .foregroundStyle(Theme.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button { onContinue() } label: {
                        HStack(spacing: 8) {
                            if isSigningIn { ProgressView().tint(.white) }
                            Text(isSigningIn ? "Checking code…" : "Continue")
                        }
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.brand500, in: RoundedRectangle(cornerRadius: Theme.radiusMedium))
                    }
                    .disabled(isSigningIn || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("recovery-code.continue")

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .background(Theme.surface)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .disabled(isSigningIn)
                }
            }
        }
    }
}

struct RecoveryCodeSignInPreviewHost: View {
    @State private var code = ""
    @State private var isPresented = true

    var body: some View {
        Theme.surface
            .ignoresSafeArea()
            .sheet(isPresented: $isPresented) {
                RecoveryCodeSignInSheet(
                    code: $code,
                    isSigningIn: false,
                    errorMessage: "Check the code and try again.",
                    onCancel: { isPresented = false },
                    onContinue: {}
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
    }
}
struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.body(15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.caption(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    ContentView()
        .environment(RecordingUploadCoordinator.shared)
        .preferredColorScheme(.dark)
}
