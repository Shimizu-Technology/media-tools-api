import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var currentPage = 0

    private let pages: [(icon: String, color: Color, title: String, subtitle: String)] = [
        (
            "waveform.circle.fill", .teal,
            "Transcribe Anything",
            "Paste a YouTube, Vimeo, or any video URL and get a full transcript in seconds."
        ),
        (
            "mic.fill", .orange,
            "Record & Transcribe",
            "Record audio right in the app — meetings, lectures, voice memos — and get instant transcriptions."
        ),
        (
            "bubble.left.and.bubble.right.fill", .purple,
            "Chat with AI",
            "Ask questions about your transcripts. Get summaries, key points, and action items."
        ),
        (
            "square.and.arrow.up", .blue,
            "Share from Anywhere",
            "Use the iOS Share Sheet to send videos, audio, and PDFs directly to Media Tools from any app."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                ForEach(0..<pages.count, id: \.self) { index in
                    OnboardingPage(
                        icon: pages[index].icon,
                        color: pages[index].color,
                        title: pages[index].title,
                        subtitle: pages[index].subtitle
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            // Bottom button
            Button {
                if currentPage < pages.count - 1 {
                    withAnimation { currentPage += 1 }
                } else {
                    isComplete = true
                }
            } label: {
                Text(currentPage < pages.count - 1 ? "Next" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .padding(.horizontal, 32)
            .padding(.bottom, 16)

            if currentPage < pages.count - 1 {
                Button("Skip") {
                    isComplete = true
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
            } else {
                Spacer().frame(height: 48)
            }
        }
    }
}

struct OnboardingPage: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(color.opacity(0.1))
                    .frame(width: 140, height: 140)

                Image(systemName: icon)
                    .font(.system(size: 64))
                    .foregroundStyle(color)
            }

            VStack(spacing: 12) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()
            Spacer()
        }
    }
}
