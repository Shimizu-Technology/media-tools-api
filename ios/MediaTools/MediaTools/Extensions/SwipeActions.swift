import SwiftUI

/// Swipe action modifiers for library items.
struct LibrarySwipeActions: ViewModifier {
    let itemType: String
    let itemId: String
    let onDelete: () async -> Void
    @State private var showAddToCollection = false

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    Task { await onDelete() }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    showAddToCollection = true
                } label: {
                    Label("Collect", systemImage: "folder.badge.plus")
                }
                .tint(.teal)
            }
            .sheet(isPresented: $showAddToCollection) {
                AddToCollectionSheet(
                    itemType: itemType,
                    itemId: itemId,
                    onDismiss: { showAddToCollection = false }
                )
            }
    }
}

extension View {
    func librarySwipeActions(itemType: String, itemId: String, onDelete: @escaping () async -> Void) -> some View {
        modifier(LibrarySwipeActions(itemType: itemType, itemId: itemId, onDelete: onDelete))
    }
}
