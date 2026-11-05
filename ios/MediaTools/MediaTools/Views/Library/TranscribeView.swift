import SwiftUI

struct TranscribeView: View {
    @State private var url = ""
    @State private var isSubmitting = false
    @State private var result: Transcript?
    @State private var error: String?
    @State private var pollTimer: Timer?

    private let service = MediaToolsService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    TextField("Paste a video link", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .themedField()

                    Button {
                        if let clipboard = UIPasteboard.general.string {
                            url = clipboard
                            Haptics.light()
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundStyle(Theme.accentText)
                            .frame(width: 44, height: 50)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Paste")
                }

                Text("YouTube, Vimeo, and most other video links work.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)

                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(Theme.onAccent)
                            Text("Transcribing…")
                        }
                    } else {
                        Text("Transcribe")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(url.isEmpty || isSubmitting)

                // Result
                if let result {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(resultStatusText(result))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)

                        Text(result.displayTitle)
                            .font(.rowTitle)
                            .foregroundStyle(Theme.text)

                        if let wc = result.wordCount, wc > 0 {
                            Text("\(wc) words")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        if result.status == "failed" {
                            InlineError(result.errorMessage ?? "This video could not be transcribed.")
                        } else if result.isComplete {
                            NavigationLink {
                                ItemDetailView(item: .transcript(result))
                            } label: {
                                Text("Open")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.accentText)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Error
                if let error {
                    InlineError(error)
                }
            }
            .readingMeasure()
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .navigationTitle("Add a Link")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func resultStatusText(_ result: Transcript) -> String {
        if result.status == "failed" { return "Couldn’t import this video" }
        return result.isComplete ? "Complete" : "Processing..."
    }

    private func submit() async {
        error = nil
        isSubmitting = true

        do {
            result = nil
            let transcript = try await service.transcribeURL(url)
            withMotion {
                result = transcript
            }

            guard let id = result?.id else {
                isSubmitting = false
                return
            }
            var consecutiveFailures = 0
            while result?.status != "completed" && result?.status != "failed" {
                try await Task.sleep(for: .seconds(5))
                do {
                    let updated = try await service.getTranscript(id)
                    consecutiveFailures = 0
                    withMotion {
                        result = updated
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The import keeps running on the server, so a short loss of
                    // connection must not read as a failure.
                    consecutiveFailures += 1
                    guard consecutiveFailures >= 3 else { continue }
                    result = nil
                    self.error = "Status could not refresh. The import keeps running; check your Library for the result."
                    isSubmitting = false
                    return
                }
            }

            isSubmitting = false

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
            isSubmitting = false
            Haptics.error()
        }
    }
}
