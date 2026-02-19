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
                        systemImage: "folder.badge.plus",
                        description: Text("Create your first collection below.")
                    )
                }

                ForEach(service.collections) { collection in
                    Button {
                        Task { await addTo(collection) }
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.teal)
                            VStack(alignment: .leading) {
                                Text(collection.name)
                                    .font(.subheadline.weight(.medium))
                                if let count = collection.itemCount {
                                    Text("\(count) items")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if addedTo == collection.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(isAdding)
                }

                // Create new
                Section {
                    if showCreateNew {
                        HStack {
                            TextField("Collection name", text: $newName)
                            Button("Create") {
                                Task { await createAndAdd() }
                            }
                            .disabled(newName.isEmpty)
                        }
                    } else {
                        Button {
                            showCreateNew = true
                        } label: {
                            Label("New Collection", systemImage: "plus")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
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

            // Auto-dismiss after short delay
            try? await Task.sleep(for: .seconds(0.8))
            onDismiss()
        } catch {
            print("Add failed: \(error)")
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

            try? await Task.sleep(for: .seconds(0.8))
            onDismiss()
        } catch {
            print("Create + add failed: \(error)")
        }
    }
}
