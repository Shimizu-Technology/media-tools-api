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
                        .foregroundStyle(.red.opacity(0.7))

                    VStack(spacing: 4) {
                        Text("Select PDF")
                            .font(.headline)
                        Text("Tap to browse your files")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .foregroundStyle(.secondary.opacity(0.3))
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            if isUploading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Uploading & extracting...")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let result {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Extracted!")
                            .font(.headline)
                    }
                    Text(result.displayTitle)
                        .font(.subheadline)
                    if let pages = result.pageCount {
                        Text("\(pages) pages")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
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

        // Start accessing security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            error = "Cannot access file"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let data = try Data(contentsOf: url)
            result = try await APIClient.shared.upload(
                "/pdf/extractions",
                fileData: data,
                filename: url.lastPathComponent,
                mimeType: "application/pdf"
            )
            await service.loadPDFs()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
