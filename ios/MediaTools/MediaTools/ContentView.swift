import SwiftUI
import ClerkKit
import ClerkKitUI

struct ContentView: View {
    @Environment(Clerk.self) private var clerk
    @Environment(RecordingUploadCoordinator.self) private var uploadCoordinator
    @Environment(AIProcessingConsentManager.self) private var aiProcessingConsent
    @Environment(DeviceSessionController.self) private var deviceSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAuth = false
    @State private var isResolvingAccount = Configuration.firstPartyIOSAuthEnabled
    @State private var isReconcilingDeletion: Bool
    @State private var migrationFailed = false
    @State private var migrationRetry = 0
    @State private var nativeAuthOperation: NativeAuthOperation?
    @State private var nativeAuthError: String?
    @State private var recoveryCode = ""
    @State private var showRecoveryCode = false
    @State private var showPasswordSignIn = false
    @State private var passwordEmail = ""
    @State private var passwordValue = ""
    @State private var passwordAuthAvailable: Bool?
    @State private var passwordCapabilityRetry = 0
    private let forceSignedOutForUITesting: Bool
    private let tokenSync = TokenSyncService.shared

    init(forceSignedOutForUITesting: Bool = false) {
        self.forceSignedOutForUITesting = forceSignedOutForUITesting
        _passwordAuthAvailable = State(initialValue: forceSignedOutForUITesting ? true : nil)
        _isReconcilingDeletion = State(
            initialValue: !forceSignedOutForUITesting
                && Configuration.firstPartyIOSAuthEnabled
                && AccountDeletionRecoveryService.shared.hasPendingDeletion
        )
    }

    private var activeUserID: String? {
        if forceSignedOutForUITesting { return nil }
        guard Configuration.firstPartyIOSAuthEnabled else {
            return deviceSession.fallbackOwnerID(for: clerk.user?.id)
        }
        if let clerkID = clerk.user?.id,
           let migration = deviceSession.verifiedMigration,
           migration.clerkID != clerkID {
            return nil
        }
        return deviceSession.activeUserID
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
                    Button("Try again") { deviceSession.reloadStoredSessionIfUnavailable() }
                        .frame(minHeight: 44)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(Theme.textPrimary)
                .background(Theme.surface)
            } else if migrationFailed {
                VStack(spacing: 16) {
                    Text("Your local recordings could not be connected to this account.")
                        .multilineTextAlignment(.center)
                    Button("Try again") { migrationRetry += 1 }
                        .frame(minHeight: 44)
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
                    .onAppear {
                        if deviceSession.hasNativeFirstPartySession {
                            tokenSync.stopSyncing()
                            tokenSync.clearToken()
                        } else {
                            tokenSync.startSyncing()
                        }
                    }
                    .onDisappear {
                        tokenSync.stopSyncing()
                    }
            } else {
                WelcomeView(
                    showAuth: $showAuth,
                    showRecoveryCode: $showRecoveryCode,
                    showPasswordSignIn: $showPasswordSignIn,
                    recoveryCode: $recoveryCode,
                    passwordEmail: $passwordEmail,
                    passwordValue: $passwordValue,
                    passwordAuthAvailable: passwordAuthAvailable,
                    nativeAuthOperation: nativeAuthOperation,
                    nativeAuthError: $nativeAuthError,
                    onRetryPasswordCapability: { passwordCapabilityRetry += 1 },
                    onPasskeySignIn: { await completeNativeSignIn(.passkey) },
                    onPasswordSignIn: { await completeNativeSignIn(.password) },
                    onRecoveryCodeSignIn: { await completeNativeSignIn(.recoveryCode) }
                )
                .onAppear {
                    tokenSync.clearToken()
                }
            }
        }
        .onChange(of: clerk.isLoaded) { _, isLoaded in
            guard isLoaded, !forceSignedOutForUITesting else { return }
            deviceSession.clerkFinishedLoading(clerkID: clerk.user?.id)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            deviceSession.reloadStoredSessionIfUnavailable()
        }
        .task(id: "\(clerk.user?.id ?? "signed-out")|\(deviceSession.needsSignIn)|\(deviceSession.sessionRevision)|\(migrationRetry)") {
            let clerkID = forceSignedOutForUITesting ? nil : clerk.user?.id
            if Configuration.firstPartyIOSAuthEnabled && !forceSignedOutForUITesting {
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
                let retryDeletionOwnerID = deviceSession.storedUserID
                    ?? deviceSession.fallbackOwnerID(for: clerk.user?.id)
                if let pending = try? await AccountDeletionRecoveryService.shared.confirmedPendingDeletion(
                    retryOwnerID: retryDeletionOwnerID
                ) {
                    try? await AccountDeletionRecoveryService.shared.finishLocalDeletion(
                        pending,
                        uploadCoordinator: uploadCoordinator,
                        consent: aiProcessingConsent,
                        deviceSession: deviceSession,
                        tokenSync: tokenSync,
                        clerk: clerk
                    )
                }
                guard !Task.isCancelled else { return }
                isReconcilingDeletion = false
                let clerkID = clerk.user?.id
                let ownerID = await deviceSession.activate(
                    clerkID: clerkID,
                    clerkIsLoaded: clerk.isLoaded
                )
                guard !Task.isCancelled else { return }
                guard await applyVerifiedMigration() else { return }
                if ownerID != nil, deviceSession.hasNativeFirstPartySession, clerk.user != nil {
                    do {
                        try await clerk.auth.signOut()
                        tokenSync.clearToken()
                    } catch {
                        // The first-party session remains authoritative; try
                        // clearing Clerk again on the next foreground task.
                    }
                }
                aiProcessingConsent.setActiveOwnerID(ownerID)
                await uploadCoordinator.setActiveOwnerID(ownerID)
                isResolvingAccount = false
            } else {
                let ownerID: String?
                if forceSignedOutForUITesting {
                    ownerID = nil
                } else {
                    ownerID = await deviceSession.activate(
                        clerkID: clerkID,
                        clerkIsLoaded: clerk.isLoaded
                    )
                }
                // The consent owner comes first: resuming work may need to ask.
                aiProcessingConsent.setActiveOwnerID(ownerID)
                await uploadCoordinator.setActiveOwnerID(ownerID)
                guard !Task.isCancelled else { return }
                isResolvingAccount = false
            }
        }
        .task(id: "password-capability|\(scenePhase)|\(activeUserID ?? "signed-out")|\(passwordCapabilityRetry)") {
            guard Configuration.firstPartyIOSAuthEnabled,
                  !forceSignedOutForUITesting,
                  scenePhase == .active,
                  activeUserID == nil else { return }
            do {
                let health: HealthResponse = try await APIClient.shared.getPublic("/health")
                guard !Task.isCancelled else { return }
                passwordAuthAvailable = health.passwordAuthEnabled == true
            } catch {
                guard !Task.isCancelled else { return }
                passwordAuthAvailable = nil
            }
        }
        .sheet(isPresented: $showAuth) {
            AuthView()
        }
        .onChange(of: showRecoveryCode) { _, isPresented in
            if isPresented {
                // A passkey-specific failure should not appear inside the
                // recovery-code sheet before the user submits a code.
                nativeAuthError = nil
            }
        }
    }

    /// A background refresh must not cover an open workspace with a spinner:
    /// that destroys the tabs and any route the Action Button just requested.
    private var isBlockedOnAccountResolution: Bool {
        isResolvingAccount && Configuration.firstPartyIOSAuthEnabled && activeUserID == nil
    }

    /// Returns false when the workspace must stay closed. A partial migration
    /// is repeatable, but opening here could hide Clerk-owned recordings.
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
                showPasswordSignIn = false
            case .recoveryCode:
                try await FirstPartyAuthService.shared.redeemRecoveryCode(recoveryCode)
                recoveryCode = ""
                showRecoveryCode = false
            }
            tokenSync.stopSyncing()
            tokenSync.clearToken()
            if clerk.user != nil {
                do {
                    try await clerk.auth.signOut()
                } catch {
                    nativeAuthError = "You are signed in. Media Tools will finish clearing the old sign-in when the app refreshes."
                }
            }
            migrationRetry += 1
        } catch {
            guard !FirstPartyAuthService.isCancellation(error) else { return }
            nativeAuthError = error.localizedDescription.isEmpty
                ? "Could not sign in. Please try again."
                : error.localizedDescription
        }
    }

}

enum NativeAuthOperation {
    case passkey
    case password
    case recoveryCode
}

// MARK: - Welcome (unauthenticated)

struct WelcomeView: View {
    @Binding var showAuth: Bool
    @Binding var showRecoveryCode: Bool
    @Binding var showPasswordSignIn: Bool
    @Binding var recoveryCode: String
    @Binding var passwordEmail: String
    @Binding var passwordValue: String
    let passwordAuthAvailable: Bool?
    let nativeAuthOperation: NativeAuthOperation?
    @Binding var nativeAuthError: String?
    let onRetryPasswordCapability: () -> Void
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

                    if Configuration.firstPartyIOSAuthEnabled {
                        VStack(spacing: 10) {
                            if passwordAuthAvailable == true {
                                Button {
                                    nativeAuthError = nil
                                    showPasswordSignIn = true
                                } label: {
                                    Label("Sign in with email", systemImage: "envelope.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .brandButtonStyle()
                                .disabled(nativeAuthOperation != nil)
                            } else if passwordAuthAvailable == nil {
                                Button {
                                    onRetryPasswordCapability()
                                } label: {
                                    Label("Check email sign-in", systemImage: "arrow.clockwise")
                                        .frame(maxWidth: .infinity)
                                }
                                .secondaryButtonStyle()
                                .disabled(nativeAuthOperation != nil)
                            }

                            Button {
                                Task { await onPasskeySignIn() }
                            } label: {
                                HStack(spacing: 8) {
                                    if nativeAuthOperation == .passkey {
                                        ProgressView().tint(.white)
                                    } else {
                                        Image(systemName: "key.fill")
                                    }
                                    Text(nativeAuthOperation == .passkey ? "Checking passkey…" : "Continue with passkey")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .brandButtonStyle()
                            .disabled(nativeAuthOperation != nil)

                            Button {
                                showRecoveryCode = true
                            } label: {
                                Label("Use a recovery code", systemImage: "lifepreserver")
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.brand400)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .background(Theme.brand50)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
                            }
                            .disabled(nativeAuthOperation != nil)

                            if let nativeAuthError {
                                Text(nativeAuthError)
                                    .font(Theme.caption(12))
                                    .foregroundStyle(Theme.error)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        HStack(spacing: 12) {
                            Rectangle().fill(Theme.borderSubtle).frame(height: 1)
                            Text("More sign-in options")
                                .font(Theme.caption(12, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)
                            Rectangle().fill(Theme.borderSubtle).frame(height: 1)
                        }
                    }

                    Button {
                        showAuth = true
                    } label: {
                        Label(
                            Configuration.firstPartyIOSAuthEnabled
                                ? "Move an existing Clerk account"
                                : "Sign in or create account",
                            systemImage: "arrow.right"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .brandButtonStyle()
                    .disabled(nativeAuthOperation != nil)

                    Text(Configuration.firstPartyIOSAuthEnabled
                         ? "Apple, Google, and Clerk email sign-in are available only to move an existing account into Media Tools."
                         : "Continue with Apple, Google, or email. Apple lets you keep your email private.")
                        .font(Theme.caption(12))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("welcome.authentication.options")

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
        .sheet(isPresented: $showRecoveryCode) {
            RecoveryCodeSignInSheet(
                code: $recoveryCode,
                isSigningIn: nativeAuthOperation == .recoveryCode,
                errorMessage: nativeAuthError,
                onCancel: { showRecoveryCode = false },
                onContinue: { Task { await onRecoveryCodeSignIn() } }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPasswordSignIn) {
            PasswordSignInSheet(
                email: $passwordEmail,
                password: $passwordValue,
                isSigningIn: nativeAuthOperation == .password,
                errorMessage: nativeAuthError,
                onCancel: { showPasswordSignIn = false; passwordValue = "" },
                onContinue: { Task { await onPasswordSignIn() } }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(nativeAuthOperation == .password)
        }
        .onChange(of: showPasswordSignIn) { _, isPresented in
            if isPresented {
                nativeAuthError = nil
            } else {
                passwordValue = ""
                nativeAuthError = nil
            }
        }
    }
}

private struct PasswordSignInSheet: View {
    @Binding var email: String
    @Binding var password: String
    let isSigningIn: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign in with email")
                            .font(Theme.heading(24))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Use your Media Tools password. This iPhone stays signed in until you sign out or revoke it.")
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldCardStyle()
                        .accessibilityIdentifier("password-sign-in.email")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .textFieldCardStyle()
                        .accessibilityIdentifier("password-sign-in.password")
                    if let errorMessage {
                        Text(errorMessage).font(Theme.caption(13)).foregroundStyle(Theme.error)
                    }
                    Button { onContinue() } label: {
                        HStack(spacing: 8) {
                            if isSigningIn { ProgressView().tint(.white) }
                            Text(isSigningIn ? "Signing in…" : "Sign in")
                        }
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.brand500, in: RoundedRectangle(cornerRadius: Theme.radiusMedium))
                    }
                    .disabled(isSigningIn || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    .accessibilityIdentifier("password-sign-in.continue")
                }
                .padding(20)
            }
            .background(Theme.surface)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() }.disabled(isSigningIn) } }
        }
    }
}

private extension View {
    func textFieldCardStyle() -> some View {
        self
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .background(Theme.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
            .overlay { RoundedRectangle(cornerRadius: Theme.radiusMedium).stroke(Theme.borderSubtle, lineWidth: 1) }
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
        .environment(Clerk.shared)
        .environment(RecordingUploadCoordinator.shared)
        .preferredColorScheme(.dark)
}
