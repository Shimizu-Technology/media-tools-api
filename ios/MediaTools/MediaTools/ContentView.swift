import SwiftUI
import ClerkKit
import ClerkKitUI

struct ContentView: View {
    @Environment(Clerk.self) private var clerk
    @Environment(RecordingUploadCoordinator.self) private var uploadCoordinator
    @Environment(AIProcessingConsentManager.self) private var aiProcessingConsent
    @Environment(DeviceSessionController.self) private var deviceSession
    @State private var showAuth = false
    @State private var isResolvingAccount = Configuration.firstPartyIOSAuthEnabled
    @State private var migrationFailed = false
    @State private var migrationRetry = 0
    private let forceSignedOutForUITesting: Bool
    private let tokenSync = TokenSyncService.shared

    init(forceSignedOutForUITesting: Bool = false) {
        self.forceSignedOutForUITesting = forceSignedOutForUITesting
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
            if isResolvingAccount && Configuration.firstPartyIOSAuthEnabled {
                ProgressView("Restoring your workspace…")
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
                    .onAppear {
                        tokenSync.startSyncing()
                    }
                    .onDisappear {
                        tokenSync.stopSyncing()
                    }
            } else {
                WelcomeView(showAuth: $showAuth)
                    .onAppear {
                        tokenSync.clearToken()
                    }
            }
        }
        .task(id: "\(clerk.user?.id ?? "signed-out")|\(deviceSession.needsSignIn)|\(migrationRetry)") {
            let clerkID = forceSignedOutForUITesting ? nil : clerk.user?.id
            if Configuration.firstPartyIOSAuthEnabled && !forceSignedOutForUITesting {
                isResolvingAccount = true
                migrationFailed = false
                let ownerID = await deviceSession.activate(clerkID: clerkID)
                guard !Task.isCancelled else { return }
                if let migration = deviceSession.verifiedMigration {
                    do {
                        try await uploadCoordinator.migrateOwnerID(
                            from: migration.clerkID,
                            to: migration.userID
                        )
                        aiProcessingConsent.migrateConsent(
                            from: migration.clerkID,
                            to: migration.userID
                        )
                    } catch {
                        guard !Task.isCancelled else { return }
                        // A partial migration is repeatable, but exposing the
                        // workspace here could hide Clerk-owned recordings.
                        await uploadCoordinator.setActiveOwnerID(nil)
                        aiProcessingConsent.setActiveOwnerID(nil)
                        migrationFailed = true
                        isResolvingAccount = false
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                aiProcessingConsent.setActiveOwnerID(ownerID)
                await uploadCoordinator.setActiveOwnerID(ownerID)
                isResolvingAccount = false
            } else {
                let ownerID: String?
                if forceSignedOutForUITesting {
                    ownerID = nil
                } else {
                    ownerID = await deviceSession.activate(clerkID: clerkID)
                }
                await uploadCoordinator.setActiveOwnerID(ownerID)
                guard !Task.isCancelled else { return }
                aiProcessingConsent.setActiveOwnerID(ownerID)
                isResolvingAccount = false
            }
        }
        .sheet(isPresented: $showAuth) {
            AuthView()
        }
    }
}

// MARK: - Welcome (unauthenticated)

struct WelcomeView: View {
    @Binding var showAuth: Bool
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

                    if !recorder.availableRecordings.isEmpty || !recorder.pendingSharedItems.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Saved on this iPhone", systemImage: "iphone.and.arrow.forward")
                                .font(Theme.body(16, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("These recordings are saved here. Sign in to review and transcribe them.")
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
                            ForEach(recorder.pendingSharedItems) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    if let fileURL = recorder.sharedFileURL(for: item) {
                                        ShareLink(item: fileURL) {
                                            Label(item.originalName, systemImage: "square.and.arrow.up")
                                        }
                                        .font(Theme.caption(13))
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

                    Button {
                        showAuth = true
                    } label: {
                        Label("Sign in or create account", systemImage: "arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .brandButtonStyle()

                    Text("Continue with Apple, Google, or email. Apple lets you keep your email private.")
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
