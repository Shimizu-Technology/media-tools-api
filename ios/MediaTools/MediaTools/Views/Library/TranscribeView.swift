import SwiftUI

struct TranscribeView: View {
    @State private var url = ""
    @State private var isSubmitting = false
    @State private var result: Transcript?
    @State private var error: String?
    @State private var pollTimer: Timer?

    private let service = MediaToolsService.shared

    var body: some View {
        VStack(spacing: 24) {
            // URL Input
            VStack(alignment: .leading, spacing: 8) {
                Text("Video URL")
                    .font(.subheadline.weight(.medium))

                HStack {
                    TextField("Paste YouTube, Vimeo, or any video URL", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    // Paste button
                    Button {
                        if let clipboard = UIPasteboard.general.string {
                            url = clipboard
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Submit
            Button {
                Task { await submit() }
            } label: {
                if isSubmitting {
                    HStack {
                        ProgressView()
                        Text("Transcribing...")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("Transcribe", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .disabled(url.isEmpty || isSubmitting)
            .padding(.horizontal)

            // Result
            if let result {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: result.isComplete ? "checkmark.circle.fill" : "clock")
                            .foregroundStyle(result.isComplete ? .green : .orange)
                        Text(result.isComplete ? "Complete" : "Processing...")
                            .font(.headline)
                    }

                    Text(result.displayTitle)
                        .font(.subheadline)

                    if let wc = result.wordCount, wc > 0 {
                        Text("\(wc) words")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.teal.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }

            // Error
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()

            // Supported platforms
            VStack(spacing: 8) {
                Text("Supported Platforms")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    PlatformChip(name: "YouTube", icon: "play.rectangle.fill")
                    PlatformChip(name: "Vimeo", icon: "video.fill")
                    PlatformChip(name: "Any URL", icon: "link")
                }
            }
            .padding(.bottom, 20)
        }
        .padding()
        .navigationTitle("Transcribe")
    }

    private func submit() async {
        error = nil
        isSubmitting = true

        do {
            result = try await service.transcribeURL(url)

            // Poll for completion
            guard let id = result?.id else { return }
            while result?.status != "completed" && result?.status != "failed" {
                try await Task.sleep(for: .seconds(5))
                result = try await service.getTranscript(id)
            }

            isSubmitting = false

            if result?.status == "completed" {
                url = "" // Clear on success
                await service.loadTranscripts() // Refresh library
                NotificationService.notifyTranscriptionComplete(
                    title: result?.displayTitle ?? "Video",
                    itemId: result?.id ?? ""
                )
            }
        } catch {
            self.error = error.localizedDescription
            isSubmitting = false
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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.secondary.opacity(0.1))
        .clipShape(Capsule())
    }
}
