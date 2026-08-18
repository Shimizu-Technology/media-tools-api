import SwiftUI
import ClerkKit
import ClerkKitUI

struct ContentView: View {
    @Environment(Clerk.self) private var clerk
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
                VStack(spacing: 16) {
                    // Hero
                    VStack(spacing: 10) {
                        // Layered circles
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

                        VStack(spacing: 10) {
                            Text("Media Tools")
                                .font(Theme.heading(30))
                                .foregroundStyle(Theme.textPrimary)

                            Text("Transcribe. Organize. Understand.")
                                .font(Theme.body(16))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    // The whole page scrolls so no feature or action is clipped
                    // on a compact device.
                    VStack(spacing: 6) {
                        FeatureRow(
                            icon: "play.rectangle.fill",
                            color: Theme.videoColor,
                            title: "Video Transcription",
                            subtitle: "Supported YouTube and Vimeo links"
                        )
                        FeatureRow(
                            icon: "mic.fill",
                            color: Theme.audioColor,
                            title: "Audio Recording",
                            subtitle: "Record audio and turn it into text"
                        )
                        FeatureRow(
                            icon: "bubble.left.and.bubble.right.fill",
                            color: .purple,
                            title: "AI Chat",
                            subtitle: "Ask questions about your content"
                        )
                        FeatureRow(
                            icon: "folder.fill",
                            color: .blue,
                            title: "Collections",
                            subtitle: "Keep related content organized"
                        )
                    }
                    .padding(.horizontal, 32)

                    Button {
                        showAuth = true
                    } label: {
                        Text("Get Started")
                            .frame(maxWidth: .infinity)
                    }
                    .brandButtonStyle()
                    .padding(.horizontal, 32)

                    Text("Powered by Shimizu Technology")
                        .font(Theme.caption(11))
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.top, 12)
                .padding(.bottom, 20)
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
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
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
        .preferredColorScheme(.dark)
}
