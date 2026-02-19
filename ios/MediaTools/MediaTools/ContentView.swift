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
        VStack(spacing: 0) {
            Spacer()

            // Hero section
            VStack(spacing: 24) {
                // Animated icon
                ZStack {
                    Circle()
                        .fill(.teal.opacity(0.1))
                        .frame(width: 120, height: 120)

                    Circle()
                        .fill(.teal.opacity(0.2))
                        .frame(width: 90, height: 90)

                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.teal)
                }

                VStack(spacing: 10) {
                    Text("Media Tools")
                        .font(.system(size: 34, weight: .bold, design: .rounded))

                    Text("Transcribe. Organize. Understand.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Features
            VStack(spacing: 16) {
                FeatureRow(
                    icon: "play.rectangle.fill",
                    color: .teal,
                    title: "Video Transcription",
                    subtitle: "YouTube, Vimeo, and any video URL"
                )
                FeatureRow(
                    icon: "mic.fill",
                    color: .orange,
                    title: "Audio Recording",
                    subtitle: "Record and transcribe with one tap"
                )
                FeatureRow(
                    icon: "bubble.left.and.bubble.right.fill",
                    color: .purple,
                    title: "AI Chat",
                    subtitle: "Ask questions about your content"
                )
                FeatureRow(
                    icon: "square.and.arrow.up",
                    color: .blue,
                    title: "Share Sheet",
                    subtitle: "Share from any app to transcribe"
                )
            }
            .padding(.horizontal, 32)

            Spacer()

            // Sign in button
            Button {
                showAuth = true
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .padding(.horizontal, 32)

            Text("Powered by Shimizu Technology")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
                .padding(.bottom, 32)
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
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

#Preview {
    ContentView()
        .environment(Clerk.shared)
}
