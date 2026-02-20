import SwiftUI

struct TranscribeView: View {
    @State private var url = ""
    @State private var isSubmitting = false
    @State private var result: Transcript?
    @State private var error: String?
    @State private var pollTimer: Timer?
    @State private var submitPulse = false

    private let service = MediaToolsService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Brand gradient header
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.brand400)

                    Text("Transcribe Video")
                        .font(Theme.heading(20))
                        .foregroundStyle(Theme.textPrimary)

                    Text("Paste a URL to get a full transcript")
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(Theme.subtleGlow)

                // URL Input
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(text: "Video URL", icon: "link")

                    HStack(spacing: 8) {
                        TextField("Paste YouTube, Vimeo, or any video URL", text: $url)
                            .textFieldStyle(.themed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        Button {
                            if let clipboard = UIPasteboard.general.string {
                                url = clipboard
                                Haptics.light()
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.body)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .secondaryButtonStyle()
                    }
                }
                .padding(.horizontal)

                // Submit
                Button {
                    submitPulse = true
                    Task {
                        await submit()
                        submitPulse = false
                    }
                } label: {
                    if isSubmitting {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                            Text("Transcribing...")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Transcribe", systemImage: "waveform")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand500)
                .disabled(url.isEmpty || isSubmitting)
                .padding(.horizontal)
                .scaleEffect(submitPulse ? 0.97 : 1.0)
                .animation(Theme.springSnappy, value: submitPulse)

                // Result
                if let result {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: result.isComplete ? "checkmark.circle.fill" : "clock")
                                .foregroundStyle(result.isComplete ? Theme.success : Theme.audioColor)
                            Text(result.isComplete ? "Complete" : "Processing...")
                                .font(Theme.body(16, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }

                        Text(result.displayTitle)
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.textSecondary)

                        if let wc = result.wordCount, wc > 0 {
                            Text("\(wc) words")
                                .font(Theme.caption())
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accentCardStyle()
                    .padding(.horizontal)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                // Error
                if let error {
                    Text(error)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.error)
                        .padding(.horizontal)
                        .transition(.opacity)
                }

                Spacer(minLength: 40)

                // Supported platforms
                VStack(spacing: 10) {
                    SectionHeader(text: "Supported Platforms")

                    HStack(spacing: 12) {
                        PlatformChip(name: "YouTube", icon: "play.rectangle.fill")
                        PlatformChip(name: "Vimeo", icon: "video.fill")
                        PlatformChip(name: "Any URL", icon: "link")
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .background(Theme.surface)
        .navigationTitle("Transcribe")
    }

    private func submit() async {
        error = nil
        withAnimation(Theme.springSnappy) { isSubmitting = true }

        do {
            withAnimation(Theme.springGentle) {
                result = nil
            }
            let transcript = try await service.transcribeURL(url)
            withAnimation(Theme.springGentle) {
                result = transcript
            }

            guard let id = result?.id else { return }
            while result?.status != "completed" && result?.status != "failed" {
                try await Task.sleep(for: .seconds(5))
                let updated = try await service.getTranscript(id)
                withAnimation(Theme.springGentle) {
                    result = updated
                }
            }

            withAnimation(Theme.springSnappy) { isSubmitting = false }

            if result?.status == "completed" {
                url = ""
                await service.loadTranscripts()
                Haptics.success()
                NotificationService.notifyTranscriptionComplete(
                    title: result?.displayTitle ?? "Video",
                    itemId: result?.id ?? ""
                )
            }
        } catch {
            self.error = error.localizedDescription
            withAnimation(Theme.springSnappy) { isSubmitting = false }
            Haptics.error()
        }
    }
}

struct PlatformChip: View {
    let name: String
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(name)
                .font(.caption2)
        }
        .chipStyle()
    }
}
