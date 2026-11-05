import SwiftUI

struct AddToCollectionSheet: View {
    let itemType: String
    let itemId: String
    let onDismiss: () -> Void

    @State private var service = MediaToolsService.shared
    @State private var isAdding = false
    @State private var addedTo: String?
    @State private var showCreateNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                if service.collections.isEmpty {
                    ContentUnavailableView(
                        "No Collections",
                        systemImage: "folder",
                        description: Text("Create your first collection below.")
                    )
                    .listRowBackground(Color.clear)
                }

                Section {
                    ForEach(service.collections) { collection in
                        Button {
                            Task { await addTo(collection) }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(collection.name)
                                        .font(.body)
                                        .foregroundStyle(Theme.text)
                                    if let count = collection.itemCount {
                                        Text("\(count) item\(count == 1 ? "" : "s")")
                                            .font(.footnote)
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                Spacer()
                                if addedTo == collection.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accentText)
                                        .accessibilityLabel("Added")
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isAdding)
                        .listRowBackground(Theme.surface)
                    }
                }

                Section {
                    if showCreateNew {
                        HStack(spacing: 8) {
                            TextField("Collection name", text: $newName)
                                .submitLabel(.done)
                                .onSubmit {
                                    guard !newName.isEmpty else { return }
                                    Task { await createAndAdd() }
                                }
                            Button("Create") {
                                Task { await createAndAdd() }
                            }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(newName.isEmpty)
                        }
                        .frame(minHeight: 44)
                        .listRowBackground(Theme.surface)
                    } else {
                        Button {
                            showCreateNew = true
                        } label: {
                            Label("New Collection", systemImage: "plus")
                                .foregroundStyle(Theme.accentText)
                                .frame(minHeight: 44)
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
            }
            .themedListBackground()
            .navigationTitle("Add to Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
            }
            .task {
                await service.loadCollections()
            }
        }
    }

    private func addTo(_ collection: Collection) async {
        isAdding = true
        defer { isAdding = false }
        do {
            try await service.addToCollection(collection.id, itemType: itemType, itemId: itemId)
            addedTo = collection.id
            Haptics.success()

            try? await Task.sleep(for: .seconds(0.8))
            onDismiss()
        } catch {
            print("Add failed: \(error)")
            Haptics.error()
        }
    }

    private func createAndAdd() async {
        isAdding = true
        defer { isAdding = false }
        do {
            let collection = try await service.createCollection(name: newName)
            try await service.addToCollection(collection.id, itemType: itemType, itemId: itemId)
            addedTo = collection.id
            newName = ""
            showCreateNew = false
            await service.loadCollections()
            Haptics.success()

            try? await Task.sleep(for: .seconds(0.8))
            onDismiss()
        } catch {
            print("Create + add failed: \(error)")
            Haptics.error()
        }
    }
}
