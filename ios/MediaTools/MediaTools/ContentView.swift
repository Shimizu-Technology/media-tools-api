import SwiftUI
import ClerkKit
import ClerkKitUI

struct ContentView: View {
    @Environment(Clerk.self) private var clerk
    @State private var showAuth = false

    var body: some View {
        Group {
            if clerk.user != nil {
                MainTabView()
            } else {
                WelcomeView(showAuth: $showAuth)
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
        VStack(spacing: 32) {
            Spacer()

            // Logo
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.teal)

            VStack(spacing: 8) {
                Text("Media Tools")
                    .font(.system(size: 32, weight: .bold, design: .rounded))

                Text("Transcribe. Organize. Chat.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showAuth = true
            } label: {
                Text("Sign In")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .padding(.horizontal, 40)

            Spacer()
                .frame(height: 60)
        }
    }
}

#Preview {
    ContentView()
        .environment(Clerk.shared)
}
