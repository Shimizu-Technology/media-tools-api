import SwiftUI
import ClerkKit
import ClerkKitUI

struct SettingsView: View {
    @Environment(Clerk.self) private var clerk
    @State private var health: HealthResponse?

    var body: some View {
        List {
            // User section
            if let user = clerk.user {
                Section("Account") {
                    HStack(spacing: 12) {
                        UserButton()
                            .frame(width: 44, height: 44)

                        VStack(alignment: .leading) {
                            if let name = user.fullName {
                                Text(name)
                                    .font(.subheadline.weight(.medium))
                            }
                            if let email = user.primaryEmailAddress?.emailAddress {
                                Text(email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // API Status
            Section("API Status") {
                if let health {
                    LabeledContent("Status", value: health.status.capitalized)
                    LabeledContent("Version", value: health.version)
                    LabeledContent("Database", value: health.database.capitalized)
                    LabeledContent("Workers", value: "\(health.workers)")
                } else {
                    HStack {
                        Text("Checking...")
                        Spacer()
                        ProgressView()
                    }
                }
            }

            // Server
            Section("Server") {
                LabeledContent("API URL", value: Configuration.apiBaseURL)
                    .font(.caption)
            }

            // About
            Section("About") {
                LabeledContent("App", value: "Media Tools")
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                Link(destination: URL(string: "https://shimizu-technology.com")!) {
                    HStack {
                        Text("Shimizu Technology")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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
