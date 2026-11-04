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
                            Image(systemName: resultIcon(result))
                                .foregroundStyle(resultColor(result))
                            Text(resultStatusText(result))
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

                        if result.status == "failed" {
                            Text(result.errorMessage ?? "This video could not be transcribed.")
                                .font(Theme.caption())
                                .foregroundStyle(Theme.error)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if result.isComplete {
                            NavigationLink {
                                ItemDetailView(item: .transcript(result))
                            } label: {
                                Label("Open", systemImage: "arrow.right.circle.fill")
                                    .font(Theme.body(14, weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.brand500)
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

    private func resultIcon(_ result: Transcript) -> String {
        if result.status == "failed" { return "exclamationmark.triangle.fill" }
        return result.isComplete ? "checkmark.circle.fill" : "clock"
    }

    private func resultColor(_ result: Transcript) -> Color {
        if result.status == "failed" { return Theme.error }
        return result.isComplete ? Theme.success : Theme.audioColor
    }

    private func resultStatusText(_ result: Transcript) -> String {
        if result.status == "failed" { return "Couldn’t import this video" }
        return result.isComplete ? "Complete" : "Processing..."
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

            guard let id = result?.id else {
                withAnimation(Theme.springSnappy) { isSubmitting = false }
                return
            }
            var consecutiveFailures = 0
            while result?.status != "completed" && result?.status != "failed" {
                try await Task.sleep(for: .seconds(5))
                do {
                    let updated = try await service.getTranscript(id)
                    consecutiveFailures = 0
                    withAnimation(Theme.springGentle) {
                        result = updated
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The import keeps running on the server, so a short loss of
                    // connection must not read as a failure.
                    consecutiveFailures += 1
                    guard consecutiveFailures >= 3 else { continue }
                    withAnimation(Theme.springGentle) { result = nil }
                    self.error = "Status could not refresh. The import keeps running; check your Library for the result."
                    withAnimation(Theme.springSnappy) { isSubmitting = false }
                    return
                }
            }

            withAnimation(Theme.springSnappy) { isSubmitting = false }

            if result?.status == "failed" {
                Haptics.error()
            } else if result?.status == "completed" {
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
