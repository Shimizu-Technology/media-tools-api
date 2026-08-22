import SwiftUI
import ClerkKit
import ClerkKitUI

struct ContentView: View {
    @Environment(Clerk.self) private var clerk
    @Environment(RecordingUploadCoordinator.self) private var uploadCoordinator
    @Environment(AIProcessingConsentManager.self) private var aiProcessingConsent
    @State private var showAuth = false
    private let tokenSync = TokenSyncService.shared

    var body: some View {
        Group {
            if clerk.user != nil {
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
        .task(id: clerk.user?.id) {
            await uploadCoordinator.setActiveOwnerID(clerk.user?.id)
            aiProcessingConsent.setActiveOwnerID(clerk.user?.id)
        }
        .sheet(isPresented: $showAuth) {
            AuthView()
        }
    }
}

// MARK: - Welcome (unauthenticated)

struct WelcomeView: View {
    @Binding var showAuth: Bool

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

                    Button {
                        showAuth = true
                    } label: {
                        Label("Sign in", systemImage: "arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .brandButtonStyle()

                    Text("Your account keeps recordings, transcripts, PDFs, chats, and collections together.")
                        .font(Theme.caption(12))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)

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
