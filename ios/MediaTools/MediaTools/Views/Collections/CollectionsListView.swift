import SwiftUI

struct CollectionsListView: View {
    @State private var service = MediaToolsService.shared
    @State private var showCreateSheet = false
    @State private var newName = ""
    @State private var newDescription = ""
    @State private var hasAppeared = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if service.collections.isEmpty && !service.isLoading {
                    ContentUnavailableView(
                        "No Collections",
                        systemImage: "folder",
                        description: Text("Create a collection to group related transcripts, audio, and PDFs together.")
                    )
                    .padding(.top, 60)
                }

                ForEach(Array(service.collections.enumerated()), id: \.element.id) { index, collection in
                    NavigationLink(value: collection.id) {
                        CollectionRow(collection: collection)
                            .cardStyle(padding: 12)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .contextMenu {
                        Button(role: .destructive) {
                            Task {
                                try? await service.deleteCollection(collection.id)
                                await service.loadCollections()
                                Haptics.success()
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Theme.surface)
        .navigationTitle("Collections")
        .navigationDestination(for: String.self) { collectionId in
            CollectionDetailView(collectionId: collectionId)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            NavigationStack {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(text: "Name", icon: "folder")
                        TextField("Collection name", text: $newName)
                            .textFieldStyle(.themed)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(text: "Description")
                        TextField("Optional description", text: $newDescription)
                            .textFieldStyle(.themed)
                    }

                    Spacer()
                }
                .padding()
                .background(Theme.surface)
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
            .presentationDetents([.medium])
            .preferredColorScheme(.dark)
        }
        .refreshable {
            await service.loadCollections()
        }
        .task {
            await service.loadCollections()
            withAnimation(Theme.springGentle) {
                hasAppeared = true
            }
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
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(Theme.brand500)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(collection.name)
                    .font(Theme.body(15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 8) {
                    if let count = collection.itemCount {
                        Text("\(count) item\(count == 1 ? "" : "s")")
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let desc = collection.description, !desc.isEmpty {
                        Text(desc)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
        }
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
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if let items = collection.items, !items.isEmpty {
                            SectionHeader(text: "Items", icon: "square.stack")
                                .frame(maxWidth: .infinity, alignment: .leading)

                            ForEach(items) { item in
                                HStack(spacing: 12) {
                                    Image(systemName: iconForType(item.itemType))
                                        .foregroundStyle(colorForType(item.itemType))
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.itemTitle ?? item.itemId)
                                            .font(Theme.body(14, weight: .medium))
                                            .foregroundStyle(Theme.textPrimary)
                                            .lineLimit(2)
                                        if let status = item.itemStatus {
                                            StatusBadge(status: status)
                                        }
                                    }

                                    Spacer()
                                }
                                .cardStyle(padding: 12)
                            }
                        } else {
                            ContentUnavailableView(
                                "Empty Collection",
                                systemImage: "tray",
                                description: Text("Add items from your library.")
                            )
                            .padding(.top, 60)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Theme.surface)
                .navigationTitle(collection.name)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showChat = true
                        } label: {
                            Image(systemName: "bubble.left.and.bubble.right")
                        }
                    }
                }
                .sheet(isPresented: $showChat) {
                    NavigationStack {
                        ChatView(itemType: "collection", itemId: collectionId)
                            .navigationTitle("Collection Chat")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { showChat = false }
                                }
                            }
                    }
                    .preferredColorScheme(.dark)
                }
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                collection = try await service.getCollection(collectionId)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func iconForType(_ type: String) -> String {
        switch type {
        case "transcript": "play.rectangle.fill"
        case "audio": "mic.fill"
        case "pdf": "doc.fill"
        default: "questionmark.circle"
        }
    }

    private func colorForType(_ type: String) -> Color {
        switch type {
        case "transcript": Theme.brand500
        case "audio": Theme.audioColor
        case "pdf": Theme.error
        default: .gray
        }
    }
}
