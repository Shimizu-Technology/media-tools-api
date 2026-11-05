import SwiftUI
import UniformTypeIdentifiers

struct PDFUploadView: View {
    @State private var showFilePicker = false
    @State private var isUploading = false
    @State private var result: PDFExtraction?
    @State private var error: String?

    private let service = MediaToolsService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose a PDF and its text joins your Library, ready to search and ask about.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showFilePicker = true
                } label: {
                    Label("Choose PDF", systemImage: "doc")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isUploading)

                if isUploading {
                    ProgressNote(text: "Uploading and extracting…")
                }

                if let result {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.displayTitle)
                            .font(.rowTitle)
                            .foregroundStyle(Theme.text)
                        if let pages = result.pageCount {
                            Text("\(pages) pages")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        NavigationLink {
                            ItemDetailView(item: .pdf(result))
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

                if let error {
                    InlineError(error)
                }
            }
            .readingMeasure()
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Upload a PDF")
        .navigationBarTitleDisplayMode(.inline)
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
            withMotion {
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
