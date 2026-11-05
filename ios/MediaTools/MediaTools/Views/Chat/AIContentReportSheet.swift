import SwiftUI

/// Collects an in-app safety report for one server-selected AI output.
struct AIContentReportSheet: View {
    let target: AIContentReportTarget

    @Environment(\.dismiss) private var dismiss
    @State private var category: AIContentReportCategory = .dangerous
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var didSubmit = false
    @State private var error: String?

    private let service = MediaToolsService.shared

    var body: some View {
        NavigationStack {
            Group {
                if didSubmit {
                    ContentUnavailableView {
                        Label("Report received", systemImage: "checkmark.shield.fill")
                    } description: {
                        Text("Shimizu Technology can review this output and use the report to improve safeguards.")
                    } actions: {
                        Button("Done") { dismiss() }
                            .buttonStyle(QuietButtonStyle())
                    }
                } else {
                    Form {
                        Section {
                            Text(
                                "The selected AI output, category, and optional note will be available to Shimizu Technology for review. Media Tools does not attach a separate copy of your source recording, transcript, or document."
                            )
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .listRowBackground(Theme.surface)
                        }

                        Section("What is wrong with it?") {
                            Picker("Category", selection: $category) {
                                ForEach(AIContentReportCategory.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                            .listRowBackground(Theme.surface)
                        }

                        Section("Note (optional)") {
                            TextField(
                                "Tell us what concerned you",
                                text: $details,
                                axis: .vertical
                            )
                            .lineLimit(3...6)
                            .listRowBackground(Theme.surface)
                            .onChange(of: details) { _, value in
                                if value.count > 1_000 {
                                    details = String(value.prefix(1_000))
                                }
                            }
                            Text("Do not add passwords, API keys, or source content. \(details.count)/1000")
                                .listRowBackground(Theme.surface)
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        if let error {
                            Section {
                                InlineError(error)
                                    .listRowBackground(Color.clear)
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .themedListBackground()
                }
            }
            .navigationTitle("Report AI output")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !didSubmit {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isSubmitting)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await submit() }
                        } label: {
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text("Submit")
                            }
                        }
                        .disabled(isSubmitting)
                    }
                }
            }
        }
    }

    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        error = nil
        do {
            _ = try await service.reportAIContent(
                target: target,
                category: category,
                details: details.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            Haptics.success()
            didSubmit = true
        } catch {
            self.error = error.localizedDescription
        }
        isSubmitting = false
    }
}
