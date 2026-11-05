import SwiftUI

struct ContentView: View {
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(RecordingUploadCoordinator.self) private var uploadCoordinator
    @Environment(AIProcessingConsentManager.self) private var aiProcessingConsent
    @Environment(DeviceSessionController.self) private var deviceSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var isResolvingAccount = true
    @State private var isReconcilingDeletion: Bool
    @State private var isDeletionUnresolved = false
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
            if isReconcilingDeletion && isDeletionUnresolved {
                VStack(spacing: 16) {
                    Text("Media Tools is confirming a previous account deletion. Your recordings are safe on this iPhone. Check your connection and try again.")
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("deletion-recovery.message")
                    tryAgainButton {
                        isDeletionUnresolved = false
                        migrationRetry += 1
                    }
                    .accessibilityIdentifier("deletion-recovery.retry")
                }
                .font(.body)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(Theme.text)
                .background(Theme.background)
            } else if isReconcilingDeletion || isBlockedOnAccountResolution {
                ProgressView("Restoring your workspace…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            } else if deviceSession.isSessionStoreUnavailable,
                      activeUserID == nil,
                      !forceSignedOutForUITesting {
                VStack(spacing: 16) {
                    Text("Unlock your iPhone to open Media Tools. Your recordings are safe.")
                        .multilineTextAlignment(.center)
                    tryAgainButton { deviceSession.reloadStoredSessionIfUnavailable() }
                }
                .font(.body)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(Theme.text)
                .background(Theme.background)
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
                .font(.body)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(Theme.text)
                .background(Theme.background)
            } else if migrationFailed {
                VStack(spacing: 16) {
                    Text("Your local recordings could not be connected to this account.")
                        .multilineTextAlignment(.center)
                    tryAgainButton { migrationRetry += 1 }
                }
                .font(.body)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(Theme.text)
                .background(Theme.background)
            } else if activeUserID != nil {
                MainView()
                    // A different account gets a fresh stack and library state. A
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
            if isDeletionUnresolved { isDeletionUnresolved = false; migrationRetry += 1 }
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
            let resolution = await AccountDeletionRecoveryService.shared.resolvePendingDeletion(
                retryOwnerID: deviceSession.storedUserID,
                uploadCoordinator: uploadCoordinator,
                consent: aiProcessingConsent,
                deviceSession: deviceSession,
                shareKeys: .shared
            )
            guard !Task.isCancelled else { return }
            // An unconfirmed deletion keeps the workspace closed, with the stored
            // session and every recording untouched, until a later try resolves it.
            if resolution == .unresolved {
                isReconcilingDeletion = true
                isDeletionUnresolved = true
                isResolvingAccount = false
                return
            }
            isDeletionUnresolved = false
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
    /// that destroys the stack and any route the Action Button just requested.
    private var isBlockedOnAccountResolution: Bool {
        isResolvingAccount && activeUserID == nil
    }

    /// Never awaited by anything the person is waiting on. Without a key, a share
    /// simply waits for this app, so a failure here has no visible effect.
    private func startShareKeySetup() {
        guard !forceSignedOutForUITesting, !isReconcilingDeletion, let ownerID = activeUserID,
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

    private func tryAgainButton(action: @escaping () -> Void) -> some View {
        Button("Try again", action: action)
            .buttonStyle(QuietButtonStyle())
    }

    private var legacyReconnectBanner: some View {
        HStack(spacing: 12) {
            Text(legacyReconnect == .failed
                ? "Some recordings on this iPhone aren't connected to your account yet. They're safe."
                : "Reconnecting recordings saved on this iPhone…")
                .font(.footnote)
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
        .background(Theme.surface)
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

// MARK: - Sign in

/// The first screen a signed-out person sees is the form itself.
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isPasswordVisible = false
    @ScaledMetric(relativeTo: .body) private var fieldLabelWidth: CGFloat = 92

    private var canSubmitPassword: Bool {
        !passwordEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !passwordValue.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                brand
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .padding(.bottom, 24)

                Text("Sign in")
                    .font(.displayLargeTitle)
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 12)

                if availability.passwordAuth != false {
                    passwordForm
                } else {
                    passkeyPrimaryButton
                }

                if let nativeAuthError, activeSheet == nil {
                    InlineError(nativeAuthError, identifier: "password-sign-in.error")
                        .padding(.top, 12)
                }

                alternatives
                    .padding(.top, 16)

                if !recorder.availableRecordings.isEmpty || !recorder.availableSharedItems.isEmpty {
                    savedOnThisPhone
                        .padding(.top, 24)
                }
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
                .presentationDetents(sheet == .recoveryCode ? [.medium, .large] : [.large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(nativeAuthOperation != nil)
        }
    }

    private var brand: some View {
        VStack(spacing: 12) {
            Image("AppMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14.3, style: .continuous))
                .accessibilityHidden(true)
            Text("Media Tools")
                .font(.displayTitle3)
                .foregroundStyle(Theme.text)
        }
    }

    private var passwordForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                fieldRow("Email") {
                    // Verbatim, or SwiftUI's markdown turns the address into a link.
                    TextField("Email", text: $passwordEmail, prompt: Text(verbatim: "name@example.com"))
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .accessibilityLabel("Email")
                        .accessibilityIdentifier("password-sign-in.email")
                }
                Hairline()
                fieldRow("Password") {
                    HStack(spacing: 4) {
                        Group {
                            if isPasswordVisible {
                                TextField("Required", text: $passwordValue)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("Required", text: $passwordValue)
                            }
                        }
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit(submitPassword)
                        .accessibilityLabel("Password")
                        .accessibilityIdentifier("password-sign-in.password")

                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .font(.body)
                                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                    }
                }
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous)
                    .stroke(Theme.fieldBorder, lineWidth: 1)
            }

            if availability.passwordReset != false {
                HStack {
                    Spacer()
                    Button("Forgot password?") {
                        nativeAuthError = nil
                        activeSheet = .forgotPassword
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(nativeAuthOperation != nil)
                    .accessibilityIdentifier("welcome.forgot-password")
                }
            }

            AuthPrimaryButton(
                title: "Sign in",
                busyTitle: "Signing in…",
                isBusy: nativeAuthOperation == .password,
                isEnabled: canSubmitPassword && nativeAuthOperation == nil,
                identifier: "password-sign-in.continue",
                action: submitPassword
            )
            .padding(.top, 12)
        }
    }

    private func submitPassword() {
        guard nativeAuthOperation == nil, canSubmitPassword else { return }
        Task { await onPasswordSignIn() }
    }

    /// Labels sit beside the fields until accessibility sizes, then above them.
    private func fieldRow<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(label)
                .font(.body)
                .foregroundStyle(Theme.text)
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : fieldLabelWidth, alignment: .leading)
                .accessibilityHidden(true)
            field()
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .frame(minHeight: 50)
    }

    private var passkeyPrimaryButton: some View {
        Button {
            Task { await onPasskeySignIn() }
        } label: {
            Text(nativeAuthOperation == .passkey ? "Checking passkey…" : "Continue with passkey")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(nativeAuthOperation != nil)
        .accessibilityIdentifier("welcome.passkey")
    }

    private var alternatives: some View {
        VStack(spacing: 0) {
            if availability.signup {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { createAccountLine }
                    VStack(spacing: 0) { createAccountLine }
                }
            }

            if availability.passwordAuth != false {
                Button(nativeAuthOperation == .passkey ? "Checking passkey…" : "Continue with passkey") {
                    Task { await onPasskeySignIn() }
                }
                .buttonStyle(QuietButtonStyle(color: Theme.textSecondary))
                .disabled(nativeAuthOperation != nil)
                .accessibilityIdentifier("welcome.passkey")
            }

            Button("Use a recovery code") {
                nativeAuthError = nil
                activeSheet = .recoveryCode
            }
            .buttonStyle(QuietButtonStyle(color: Theme.textSecondary))
            .disabled(nativeAuthOperation != nil)
            .accessibilityIdentifier("welcome.recovery-code")

            if availability.passwordReset != false, availability.passwordAuth != false {
                Text("Never set a password? Use Forgot password with your account email.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .accessibilityIdentifier("welcome.authentication.options")
            }

            if availability.passwordAuth == nil {
                Button("Check connection", action: onRetryAvailability)
                    .buttonStyle(QuietButtonStyle(color: Theme.textSecondary))
                    .disabled(nativeAuthOperation != nil)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var createAccountLine: some View {
        Text("New here?")
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
        Button("Create an account") {
            nativeAuthError = nil
            activeSheet = .createAccount
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(nativeAuthOperation != nil)
        .accessibilityIdentifier("welcome.create-account")
    }

    private var savedOnThisPhone: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Saved on this iPhone")
                .font(.sectionLabel)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Text("These are saved here. Sign in to review and transcribe them.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(recorder.availableRecordings) { recording in
                if let fileURL = recorder.fileURL(for: recording) {
                    ShareLink(item: fileURL) {
                        savedRowLabel(recording.displayTitle)
                    }
                }
            }
            ForEach(recorder.availableSharedItems) { item in
                VStack(alignment: .leading, spacing: 2) {
                    if let fileURL = recorder.sharedFileURL(for: item) {
                        ShareLink(item: fileURL) {
                            savedRowLabel(item.originalName)
                        }
                    } else {
                        Text(item.originalName)
                            .font(.subheadline)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                    }
                    if item.resolvedKind != .audio,
                       recorder.pendingSharedErrors[item.id] == nil {
                        Text("Waiting for you to sign in")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let reason = recorder.pendingSharedErrors[item.id] {
                        InlineError(reason)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func savedRowLabel(_ title: String) -> some View {
        Label(title, systemImage: "square.and.arrow.up")
            .font(.subheadline)
            .foregroundStyle(Theme.accentText)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func sheetContent(_ sheet: WelcomeSheet) -> some View {
        switch sheet {
        case .createAccount, .forgotPassword:
            EmailPasswordFlowView(
                purpose: sheet == .createAccount ? .createAccount : .resetPassword,
                initialEmail: passwordEmail,
                onSignInNeeded: { email in
                    passwordEmail = email
                    nativeAuthError = "Your password is saved. Sign in to continue."
                    activeSheet = nil
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
                            .font(.displayTitle2)
                            .foregroundStyle(Theme.text)
                        Text("Enter one saved code to restore access on this iPhone. Each code works once.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    TextField("Recovery code", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .themedField()
                        .accessibilityIdentifier("recovery-code.sign-in-field")

                    if let errorMessage {
                        InlineError(errorMessage)
                    }

                    Button { onContinue() } label: {
                        HStack(spacing: 8) {
                            if isSigningIn { ProgressView().tint(Theme.onAccent) }
                            Text(isSigningIn ? "Checking code…" : "Continue")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isSigningIn || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("recovery-code.continue")

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .background(Theme.background)
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
        Theme.background
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

#Preview {
    ContentView()
        .environment(RecordingUploadCoordinator.shared)
}
