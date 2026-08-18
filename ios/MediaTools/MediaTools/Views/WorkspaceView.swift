import SwiftUI

struct WorkspaceView: View {
    let onOpenLibrary: () -> Void
    let onOpenRecord: () -> Void
    let onOpenCollections: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                workspaceHeader
                captureSection
                organizeSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.surface)
        .navigationTitle("Home")
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Private workspace", systemImage: "lock.fill")
                .font(Theme.caption(11, weight: .semibold))
                .foregroundStyle(Theme.brand400)
                .textCase(.uppercase)

            Text("Turn media into useful knowledge")
                .font(Theme.heading(28))
                .foregroundStyle(Theme.textPrimary)

            Text("Record something now or bring in a video, audio file, or PDF. Every result stays organized in one library.")
                .font(Theme.body(15))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(text: "Start something new", icon: "plus.circle")

            Button(action: onOpenRecord) {
                WorkspaceActionCard(
                    icon: "mic.fill",
                    color: Theme.brand500,
                    title: "Record or upload audio",
                    detail: "Capture a voice note, meeting, lecture, or existing recording.",
                    isFeatured: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace.record")

            NavigationLink {
                TranscribeView()
            } label: {
                WorkspaceActionCard(
                    icon: "play.rectangle.fill",
                    color: Theme.videoColor,
                    title: "Import a video",
                    detail: "Paste a supported link and extract its transcript."
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace.video")

            NavigationLink {
                PDFUploadView()
            } label: {
                WorkspaceActionCard(
                    icon: "doc.text.fill",
                    color: Theme.pdfColor,
                    title: "Upload a PDF",
                    detail: "Extract searchable, page-aware document text."
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace.pdf")
        }
    }

    private var organizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(text: "Your workspace", icon: "square.grid.2x2")

            HStack(spacing: 12) {
                WorkspaceDestinationButton(
                    icon: "books.vertical.fill",
                    title: "Library",
                    detail: "Find every result",
                    action: onOpenLibrary
                )
                .accessibilityIdentifier("workspace.library")

                WorkspaceDestinationButton(
                    icon: "folder.fill",
                    title: "Collections",
                    detail: "Group related work",
                    action: onOpenCollections
                )
                .accessibilityIdentifier("workspace.collections")
            }
        }
    }
}

private struct WorkspaceActionCard: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String
    var isFeatured = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isFeatured ? Color.white : color)
                .frame(width: 48, height: 48)
                .background(isFeatured ? color : color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.body(16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.caption(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(isFeatured ? Theme.brand400 : Theme.textMuted)
        }
        .padding(16)
        .background(isFeatured ? Theme.brand500.opacity(0.1) : Theme.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusLarge)
                .stroke(isFeatured ? Theme.brand500.opacity(0.7) : Theme.borderSubtle, lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
}

private struct WorkspaceDestinationButton: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Theme.brand400)
                Text(title)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.caption(12))
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .padding(16)
            .background(Theme.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusLarge)
                    .stroke(Theme.borderSubtle, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        WorkspaceView(onOpenLibrary: {}, onOpenRecord: {}, onOpenCollections: {})
    }
    .preferredColorScheme(.dark)
}
