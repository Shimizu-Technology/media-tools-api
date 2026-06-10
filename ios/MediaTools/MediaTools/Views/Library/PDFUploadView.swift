import SwiftUI
import UniformTypeIdentifiers

struct PDFUploadView: View {
    @State private var showFilePicker = false
    @State private var isUploading = false
    @State private var result: PDFExtraction?
    @State private var error: String?

    private let service = MediaToolsService.shared

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Drop zone
            Button {
                showFilePicker = true
            } label: {
                VStack(spacing: 16) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.pdfColor.opacity(0.7))

                    VStack(spacing: 4) {
                        Text("Select PDF")
                            .font(Theme.heading(16))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Tap to browse your files")
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusLarge)
                        .fill(Theme.surfaceCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusLarge)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .foregroundStyle(Theme.border)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            if isUploading {
                VStack(spacing: 8) {
                    ProgressView()
                        .tint(Theme.brand400)
                    Text("Uploading & extracting...")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let result {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                        Text("Extracted!")
                            .font(Theme.heading(16))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Text(result.displayTitle)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textSecondary)
                    if let pages = result.pageCount {
                        Text("\(pages) pages")
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accentCardStyle()
                .padding(.horizontal)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let error {
                Text(error)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.error)
            }

            Spacer()
        }
        .background(Theme.surface)
        .navigationTitle("Upload PDF")
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { pickerResult in
            switch pickerResult {
            case .success(let urls):
                if let url = urls.first {
                    Task { await upload(url: url) }
                }
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }

    private func upload(url: URL) async {
        isUploading = true
        error = nil
        defer { isUploading = false }

        guard url.startAccessingSecurityScopedResource() else {
            error = "Cannot access file"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let data = try Data(contentsOf: url)
            let extraction: PDFExtraction = try await APIClient.shared.upload(
                "/pdf/extract",
                fileData: data,
                filename: url.lastPathComponent,
                mimeType: "application/pdf"
            )
            withAnimation(Theme.springGentle) {
                result = extraction
            }
            await service.loadPDFs()
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}
