import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var currentPage = 0
    @State private var appeared = false

    private let pages: [(icon: String, color: Color, title: String, subtitle: String)] = [
        (
            "waveform.circle.fill", Theme.brand400,
            "Transcribe Anything",
            "Paste a YouTube, Vimeo, or any video URL and get a full transcript in seconds."
        ),
        (
            "mic.fill", Theme.audioColor,
            "Record & Transcribe",
            "Record audio right in the app — meetings, lectures, voice memos — and get instant transcriptions."
        ),
        (
            "bubble.left.and.bubble.right.fill", Color.purple,
            "Chat with AI",
            "Ask questions about your transcripts. Get summaries, key points, and action items."
        ),
        (
            "square.and.arrow.up", Color.blue,
            "Share from Anywhere",
            "Use the iOS Share Sheet to send videos, audio, and PDFs directly to Media Tools from any app."
        ),
    ]

    var body: some View {
        ZStack {
            // Brand gradient background
            LinearGradient(
                colors: [Theme.surface, Theme.surfaceElevated, Theme.surface],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Subtle brand glow at top
            VStack {
                Circle()
                    .fill(Theme.brand500.opacity(0.08))
                    .frame(width: 400, height: 400)
                    .blur(radius: 80)
                    .offset(y: -120)
                Spacer()
            }
            .ignoresSafeArea()

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
                        withAnimation(Theme.springSnappy) { currentPage += 1 }
                    } else {
                        withAnimation(Theme.springGentle) { isComplete = true }
                    }
                } label: {
                    Text(currentPage < pages.count - 1 ? "Next" : "Get Started")
                        .font(Theme.heading(16))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radiusMedium)
                                .fill(Theme.brandGradient)
                        )
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 20)

                if currentPage < pages.count - 1 {
                    Button("Skip") {
                        withAnimation(Theme.springGentle) { isComplete = true }
                    }
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.bottom, 24)
                } else {
                    Spacer().frame(height: 48)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(Theme.springGentle.delay(0.3)) {
                appeared = true
            }
        }
    }
}

struct OnboardingPage: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                // Outer glow
                Circle()
                    .fill(color.opacity(0.06))
                    .frame(width: 160, height: 160)
                    .scaleEffect(appeared ? 1.0 : 0.8)

                Circle()
                    .fill(color.opacity(0.1))
                    .frame(width: 140, height: 140)

                Image(systemName: icon)
                    .font(.system(size: 64))
                    .foregroundStyle(color)
                    .scaleEffect(appeared ? 1.0 : 0.6)
            }
            .animation(Theme.springGentle, value: appeared)

            VStack(spacing: 12) {
                Text(title)
                    .font(Theme.heading(24))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)

                Text(subtitle)
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
            }
            .animation(Theme.springGentle.delay(0.15), value: appeared)

            Spacer()
            Spacer()
        }
        .onAppear {
            appeared = true
        }
        .onDisappear {
            appeared = false
        }
    }
}
