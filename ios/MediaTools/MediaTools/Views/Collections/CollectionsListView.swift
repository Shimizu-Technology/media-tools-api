import SwiftUI

struct CollectionsListView: View {
    @State private var service = MediaToolsService.shared
    @State private var showCreateSheet = false
    @State private var newName = ""
    @State private var newDescription = ""

    var body: some View {
        List {
            if service.collections.isEmpty && !service.isLoading {
                ContentUnavailableView(
                    "No Collections",
                    systemImage: "folder",
                    description: Text("Create a collection to group related transcripts, audio, and PDFs together.")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(service.collections) { collection in
                NavigationLink(value: AppRoute.collection(collection.id)) {
                    CollectionRow(collection: collection)
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.separator)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        delete(collection)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        delete(collection)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .ledgerListBackground()
        .navigationTitle("Collections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("New Collection")
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            NavigationStack {
                Form {
                    Section("Name") {
                        TextField("Collection name", text: $newName)
                            .listRowBackground(Theme.surface)
                    }
                    Section("Description") {
                        TextField("Optional description", text: $newDescription)
                            .listRowBackground(Theme.surface)
                    }
                }
                .ledgerListBackground()
                .navigationTitle("New Collection")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showCreateSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            Task { await createCollection() }
                        }
                        .disabled(newName.isEmpty)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .refreshable {
            await service.loadCollections()
        }
        .task {
            await service.loadCollections()
        }
    }

    private func delete(_ collection: Collection) {
        Task {
            try? await service.deleteCollection(collection.id)
            await service.loadCollections()
            Haptics.success()
        }
    }

    private func createCollection() async {
        do {
            _ = try await service.createCollection(
                name: newName,
                description: newDescription.isEmpty ? nil : newDescription
            )
            newName = ""
            newDescription = ""
            showCreateSheet = false
            await service.loadCollections()
            Haptics.success()
        } catch {
            print("Create failed: \(error)")
        }
    }
}

struct CollectionRow: View {
    let collection: Collection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(collection.name)
                .font(.ledgerRowTitle)
                .foregroundStyle(Theme.text)

            HStack(spacing: 6) {
                if let count = collection.itemCount {
                    Text("\(count) item\(count == 1 ? "" : "s")")
                }
                if let desc = collection.description, !desc.isEmpty {
                    Text(desc)
                        .lineLimit(1)
                }
            }
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
        }
        .frame(minHeight: 44, alignment: .leading)
    }
}

// MARK: - Collection Detail

struct CollectionDetailView: View {
    let collectionId: String
    @State private var collection: Collection?
    @State private var showChat = false
    @State private var error: String?

    private let service = MediaToolsService.shared

    var body: some View {
        Group {
            if let collection {
                List {
                    if let items = collection.items, !items.isEmpty {
                        ForEach(items) { item in
                            NavigationLink(value: AppRoute.item(
                                LibraryReference(itemType: item.itemType, itemId: item.itemId)
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.itemTitle ?? item.itemId)
                                        .font(.ledgerRowTitle)
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    if let status = item.itemStatus,
                                       let attention = ItemAttention(status: status) {
                                        AttentionLabel(attention: attention)
                                    }
                                }
                                .frame(minHeight: 44, alignment: .leading)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.separator)
                        }
                    } else {
                        ContentUnavailableView(
                            "Empty Collection",
                            systemImage: "tray",
                            description: Text("Swipe right on anything in your Library to add it.")
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .ledgerListBackground()
                .navigationTitle(collection.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showChat = true
                        } label: {
                            Image(systemName: "bubble.left")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Ask about this collection")
                    }
                }
                .sheet(isPresented: $showChat) {
                    NavigationStack {
                        ChatView(itemType: "collection", itemId: collectionId)
                            .navigationTitle("Ask")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { showChat = false }
                                }
                            }
                    }
                }
            } else if let error {
                ContentUnavailableView {
                    Label("Couldn’t Open Collection", systemImage: "exclamationmark.circle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .task { await load() }
    }

    private func load() async {
        error = nil
        do {
            collection = try await service.getCollection(collectionId)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
