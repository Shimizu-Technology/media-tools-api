import SwiftUI

struct CollectionsListView: View {
    @State private var service = MediaToolsService.shared
    @State private var showCreateSheet = false
    @State private var newName = ""
    @State private var newDescription = ""
    @State private var listWidth: CGFloat = 0
    @State private var hasLoaded = false

    private var rowInsets: EdgeInsets {
        let margin = Theme.pageMargin(forWidth: min(listWidth, Theme.readableWidth))
        return EdgeInsets(top: 0, leading: margin, bottom: 0, trailing: margin)
    }

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 2) {
                ScreenHeader("Collections") {
                    Button {
                        showCreateSheet = true
                    } label: {
                        HeaderIconLabel(systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New Collection")
                    .accessibilityIdentifier("collections.add")
                }
                .padding(.trailing, -8)
                Text("Group recordings, then ask questions across everything in the group.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
            .listRowInsets(rowInsets)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if service.collections.isEmpty && hasLoaded {
                QuietPlaceholder(
                    systemImage: "folder",
                    title: "No Collections",
                    message: "Create a collection to group related recordings, links, and PDFs together."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(service.collections) { collection in
                NavigationLink(value: AppRoute.collection(collection.id)) {
                    CollectionRow(collection: collection)
                }
                .listRowInsets(rowInsets)
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
        .themedListBackground()
        .readableContentWidth()
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { listWidth = $0 }
        .navigationTitle("Collections")
        .toolbar(.hidden, for: .navigationBar)
        .statusBarBackdrop()
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
                .themedListBackground()
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
            hasLoaded = true
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
    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 46

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white)
                .frame(width: tileSize, height: tileSize)
                .background(
                    CollectionColor(key: collection.color).color,
                    in: RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                    .font(.rowTitle)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)

                if let count = collection.itemCount {
                    Text("\(count) item\(count == 1 ? "" : "s")")
                        .font(.number)
                        .foregroundStyle(Theme.textSecondary)
                }
                if let desc = collection.description, !desc.isEmpty {
                    Text(desc)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .padding(.vertical, 4)
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
                                        .font(.rowTitle)
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
                .themedListBackground()
                .readableContentWidth()
                .navigationTitle(collection.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showChat = true
                        } label: {
                            Image(systemName: "sparkles")
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
                        .buttonStyle(QuietButtonStyle())
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
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
