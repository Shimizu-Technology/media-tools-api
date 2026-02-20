import SwiftUI
import ClerkKit
import ClerkKitUI

struct SettingsView: View {
    @Environment(Clerk.self) private var clerk
    @State private var health: HealthResponse?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Branded header
                VStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Theme.brandGradient)

                    Text("Media Tools")
                        .font(Theme.heading(22))
                        .foregroundStyle(Theme.textPrimary)

                    Text("Transcribe, record, and analyze")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(Theme.subtleGlow)

                // Account section
                if let user = clerk.user {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(text: "Account", icon: "person.circle")

                        HStack(spacing: 12) {
                            UserButton()
                                .frame(width: 44, height: 44)

                            VStack(alignment: .leading, spacing: 2) {
                                if let first = user.firstName {
                                    Text([first, user.lastName].compactMap { $0 }.joined(separator: " "))
                                        .font(Theme.body(15, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                }
                                if let email = user.primaryEmailAddress?.emailAddress {
                                    Text(email)
                                        .font(Theme.caption())
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }

                            Spacer()
                        }
                        .cardStyle(padding: 12)
                    }
                    .padding(.horizontal)
                }

                // API Status
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(text: "API Status", icon: "server.rack")

                    VStack(spacing: 0) {
                        if let health {
                            SettingsRow(label: "Status") {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(health.status == "ok" ? Theme.success : Theme.error)
                                        .frame(width: 8, height: 8)
                                    Text(health.status.capitalized)
                                        .font(Theme.body(14))
                                        .foregroundStyle(Theme.textPrimary)
                                }
                            }
                            Divider().overlay(Theme.borderSubtle)
                            SettingsRow(label: "Version") {
                                Text(health.version)
                                    .font(Theme.body(14))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Divider().overlay(Theme.borderSubtle)
                            SettingsRow(label: "Database") {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(health.database == "connected" ? Theme.success : Theme.error)
                                        .frame(width: 8, height: 8)
                                    Text(health.database.capitalized)
                                        .font(Theme.body(14))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            Divider().overlay(Theme.borderSubtle)
                            SettingsRow(label: "Workers") {
                                Text("\(health.workers)")
                                    .font(Theme.body(14))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        } else {
                            HStack {
                                Text("Checking...")
                                    .font(Theme.body(14))
                                    .foregroundStyle(Theme.textMuted)
                                Spacer()
                                ProgressView()
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .cardStyle(padding: 12)
                }
                .padding(.horizontal)

                // Server
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(text: "Server", icon: "network")

                    HStack {
                        Text("API URL")
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(Configuration.apiBaseURL)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                    .cardStyle(padding: 12)
                }
                .padding(.horizontal)

                // About
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(text: "About", icon: "info.circle")

                    VStack(spacing: 0) {
                        SettingsRow(label: "App") {
                            Text("Media Tools")
                                .font(Theme.body(14))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Divider().overlay(Theme.borderSubtle)
                        SettingsRow(label: "Version") {
                            Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                                .font(Theme.body(14))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Divider().overlay(Theme.borderSubtle)
                        Link(destination: URL(string: "https://shimizu-technology.com")!) {
                            HStack {
                                Text("Shimizu Technology")
                                    .font(Theme.body(14))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textMuted)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .cardStyle(padding: 12)
                }
                .padding(.horizontal)

                Spacer(minLength: 20)
            }
        }
        .background(Theme.surface)
        .navigationTitle("Settings")
        .task { await checkHealth() }
        .refreshable { await checkHealth() }
    }

    private func checkHealth() async {
        do {
            health = try await APIClient.shared.get("/health")
        } catch {
            print("Health check failed: \(error)")
        }
    }
}

// MARK: - Settings Row Helper

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
