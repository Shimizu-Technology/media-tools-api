import SwiftUI

struct AIProcessingDisclosureView: View {
    @Bindable var manager: AIProcessingConsentManager
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "brain.head.profile.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.brand400)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Allow third-party AI processing?")
                            .font(Theme.heading(25))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Media Tools only sends content when you choose an AI feature. Your permission applies to this account on this iPhone.")
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    providerRow(
                        title: "OpenAI",
                        detail: "Receives audio for transcription and may process text if the primary AI route is unavailable. API content is not used to train OpenAI models by default."
                    )
                    providerRow(
                        title: "OpenRouter + selected model provider",
                        detail: "Receives transcript or document text and chat prompts for readable formatting, summaries, citations, and answers. Media Tools requires zero-data-retention providers."
                    )

                    Text("You can revoke permission for future requests in Settings. Processing you already started may finish.")
                        .font(Theme.caption(13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        openURL(URL(string: "https://media-tools-gu.netlify.app/privacy#ai-processing")!)
                    } label: {
                        Label("Read AI and privacy details", systemImage: "arrow.up.right.square")
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(Theme.brand400)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 10) {
                        Button {
                            manager.allow()
                        } label: {
                            Text("Allow AI processing")
                                .font(Theme.body(15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(Theme.brand500, in: RoundedRectangle(cornerRadius: Theme.radiusMedium))
                        }

                        Button("Not now") {
                            manager.decline()
                        }
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 46)
                    }
                }
                .padding(20)
            }
            .background(Theme.surface)
            .navigationTitle("AI processing")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
    }

    private func providerRow(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.brand400)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.caption(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle(padding: 14)
    }
}
