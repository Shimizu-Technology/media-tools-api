import SwiftUI

struct AIProcessingDisclosureView: View {
    @Bindable var manager: AIProcessingConsentManager
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Allow third-party AI processing?")
                            .font(.displayTitle)
                            .foregroundStyle(Theme.text)
                        Text("With automatic transcription on, new recordings and shared audio go to OpenAI when they are saved, as do shared video links that have no subtitles, and their transcripts go to OpenRouter. Everything else is sent only when you use an AI feature. You can turn automatic transcription off in Settings. This permission applies to this account on this iPhone.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Hairline()
                        providerRow(
                            title: "OpenAI",
                            detail: "Receives audio for transcription and may process text if the primary AI route is unavailable. API content is not used to train OpenAI models by default."
                        )
                        Hairline()
                        providerRow(
                            title: "OpenRouter + selected model provider",
                            detail: "Receives transcript or document text and chat prompts for readable formatting, summaries, citations, and answers. Media Tools requires zero-data-retention providers."
                        )
                        Hairline()
                    }

                    Text("You can revoke permission for future requests in Settings. Processing already started may finish.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        openURL(URL(string: "https://media.shimizu-technology.com/privacy#ai-processing")!)
                    } label: {
                        Text("Read AI and privacy details")
                    }
                    .buttonStyle(QuietButtonStyle())

                    VStack(spacing: 4) {
                        Button("Allow AI processing") {
                            manager.allow()
                        }
                        .buttonStyle(PrimaryButtonStyle())

                        Button("Not now") {
                            manager.decline()
                        }
                        .buttonStyle(QuietButtonStyle(color: Theme.textSecondary))
                        .frame(maxWidth: .infinity)
                    }
                }
                .readingMeasure()
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("AI processing")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }

    private func providerRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }
}
