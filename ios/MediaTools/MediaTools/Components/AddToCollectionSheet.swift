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
            ScrollView {
                LazyVStack(spacing: 10) {
                    if service.collections.isEmpty {
                        ContentUnavailableView(
                            "No Collections",
                            systemImage: "folder.badge.plus",
                            description: Text("Create your first collection below.")
                        )
                        .padding(.top, 40)
                    }

                    ForEach(service.collections) { collection in
                        Button {
                            Task { await addTo(collection) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Theme.brand500)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(collection.name)
                                        .font(Theme.body(15, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    if let count = collection.itemCount {
                                        Text("\(count) items")
                                            .font(Theme.caption())
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                Spacer()
                                if addedTo == collection.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.success)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .cardStyle(padding: 12)
                        }
                        .buttonStyle(.plain)
                        .disabled(isAdding)
                    }

                    // Create new
                    VStack(spacing: 10) {
                        if showCreateNew {
                            HStack(spacing: 8) {
                                TextField("Collection name", text: $newName)
                                    .textFieldStyle(.themed)
                                Button("Create") {
                                    Task { await createAndAdd() }
                                }
                                .brandButtonStyle()
                                .disabled(newName.isEmpty)
                            }
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        } else {
                            Button {
                                withAnimation(Theme.springSnappy) {
                                    showCreateNew = true
                                }
                            } label: {
                                Label("New Collection", systemImage: "plus")
                                    .font(Theme.body(14, weight: .medium))
                                    .frame(maxWidth: .infinity)
                            }
                            .secondaryButtonStyle()
                        }
                    }
                    .padding(.top, 8)
                }
                .padding()
            }
            .background(Theme.surface)
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
        .preferredColorScheme(.dark)
    }

    private func addTo(_ collection: Collection) async {
        isAdding = true
        defer { isAdding = false }
        do {
            try await service.addToCollection(collection.id, itemType: itemType, itemId: itemId)
            withAnimation(Theme.springSnappy) {
                addedTo = collection.id
            }
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
            withAnimation(Theme.springSnappy) {
                addedTo = collection.id
            }
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
