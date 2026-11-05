import SwiftUI

// MARK: - Needs you row

/// One thing that needs a person, with what they would do about it right on the row.
struct NeedsYouRow: View {
    let item: NeedsYouItem
    let onOptions: (DeviceItemTarget) -> Void
    let onOpen: (LibraryReference) -> Void
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(RecordingUploadCoordinator.self) private var uploader
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Button(action: rowTapped) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.title3)
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(rowHint)

            actionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var title: String {
        switch item {
        case .recording(let recording): recording.needsYouTitle
        case .share(let share): share.originalName
        case .serverFailure(let row): row.displayTitle
        }
    }

    private var detail: String {
        switch item {
        case .recording(let recording):
            return recording.needsYouDetail
        case .share(let share):
            let status = uploader.shareStatusMessage(for: share)
            return status.isEmpty ? "Shared, not sent yet" : status
        case .serverFailure(let row):
            let day = MediaFormat.rowDate(row.createdAt)
            return day.map { "\($0), did not finish" } ?? "Did not finish"
        }
    }

    private var rowHint: String {
        if case .serverFailure = item { return "Opens the item" }
        return "Shows options for this item"
    }

    private func rowTapped() {
        switch item {
        case .recording(let recording): onOptions(.recording(recording.id))
        case .share(let share): onOptions(.share(share.id))
        case .serverFailure(let row): onOpen(row.reference)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch item {
        case .recording(let recording):
            switch recording.needsYouAction {
            case .transcribe:
                NeedsYouPill(title: "Transcribe", isPrimary: true) {
                    Task { await uploader.transcribe(recording) }
                }
                .disabled(recorder.isRecording || recorder.isStarting)
                .accessibilityLabel("Transcribe \(title)")
                .accessibilityIdentifier("needs-you.transcribe.\(recording.id.uuidString)")
            case .options, .open:
                NeedsYouPill(title: "Options", isPrimary: false) {
                    onOptions(.recording(recording.id))
                }
                .accessibilityLabel("Options for \(title)")
                .accessibilityIdentifier("needs-you.options.\(recording.id.uuidString)")
            }
        case .share(let share):
            NeedsYouPill(title: uploader.shareActionTitle(for: share), isPrimary: true) {
                Task { await uploader.retrySharedItem(share) }
            }
            .accessibilityIdentifier("needs-you.share.\(share.id)")
        case .serverFailure(let row):
            NeedsYouPill(title: "View", isPrimary: false) {
                onOpen(row.reference)
            }
            .accessibilityLabel("View \(title)")
            .accessibilityIdentifier("needs-you.view.\(row.reference.id)")
        }
    }
}

/// A compact pill on the outside and a full 44-point target around it.
struct NeedsYouPill: View {
    let title: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isPrimary ? Theme.onAccent : Theme.text)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(isPrimary ? Theme.accentFill : Theme.surface2, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .fixedSize()
        }
        .buttonStyle(PressFeedbackButtonStyle(pressedScale: 0.96))
    }
}

/// "Uploading 42%", with a thin bar under it, for a recording on its way.
struct DeviceProgressLabel: View {
    let recording: LocalRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(recording.recoveryDescription)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            if recording.state == .uploading {
                ProgressView(value: recording.uploadProgress ?? 0)
                    .tint(Theme.accentFill)
                    .accessibilityLabel("Upload progress")
                    .accessibilityValue("\(Int(((recording.uploadProgress ?? 0) * 100).rounded())) percent")
            }
        }
    }
}

// MARK: - Options

enum DeviceItemTarget: Identifiable, Hashable {
    case recording(UUID)
    case share(UUID)

    var id: String {
        switch self {
        case .recording(let id): "recording:\(id.uuidString)"
        case .share(let id): "share:\(id.uuidString)"
        }
    }
}

extension View {
    /// Adds the options sheet shared by Home and the Library. Anything that may need
    /// the AI consent sheet runs after this one closes, because the root can only
    /// present one over the other.
    func deviceItemActions(target: Binding<DeviceItemTarget?>) -> some View {
        modifier(DeviceItemActionsModifier(target: target))
    }
}

private struct DeviceItemActionsModifier: ViewModifier {
    @Binding var target: DeviceItemTarget?
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(RecordingUploadCoordinator.self) private var uploader
    @State private var afterDismiss: (@MainActor () async -> Void)?

    func body(content: Content) -> some View {
        content.sheet(item: $target, onDismiss: runAfterDismiss) { target in
            DeviceItemOptionsSheet(target: target) { action in
                afterDismiss = action
                self.target = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func runAfterDismiss() {
        guard let action = afterDismiss else { return }
        afterDismiss = nil
        Task { await action() }
    }
}

/// Save, try again, or delete. Nothing here removes a recording without a second,
/// explicit confirmation, and nothing anywhere removes one automatically.
struct DeviceItemOptionsSheet: View {
    let target: DeviceItemTarget
    let dismissThen: (@escaping @MainActor () async -> Void) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(RecordingUploadCoordinator.self) private var uploader
    @State private var showDeleteConfirmation = false
    @State private var retryMessage: String?

    private var recording: LocalRecording? {
        if case .recording(let id) = target { return recorder.recording(withID: id) }
        return nil
    }

    private var share: ShareInboxStore.Item? {
        if case .share(let id) = target {
            return recorder.availableSharedItems.first { $0.id == id }
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Saved on this \(UIDevice.current.localizedModel)")
                        .font(.sectionLabel)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, -12)
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("options.close")
                }
                Text(title)
                    .font(.displayTitle3)
                    .foregroundStyle(Theme.text)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("options.explanation")

                if let retryMessage {
                    InlineError(retryMessage, identifier: "options.retry-message")
                        .padding(.bottom, 10)
                }

                if let recording {
                    recordingOptions(recording)
                } else if let share {
                    shareOptions(share)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.background)
        .alert(deleteTitle, isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive, action: deleteConfirmed)
            Button("Keep", role: .cancel) {}
        } message: {
            Text("This removes the copy on this \(UIDevice.current.localizedModel) and cannot be undone.")
        }
    }

    private var title: String {
        recording?.needsYouTitle ?? share?.originalName ?? "Removed"
    }

    private var explanation: String {
        if let recording {
            switch recording.state {
            case .invalid:
                return "\(recording.needsYouDetail). You can keep the file, check it again, or delete it."
            case .uploadFailed, .ready, .interrupted:
                return recording.recoveryDescription
            default:
                return recording.recoveryDescription
            }
        }
        if let share {
            let status = uploader.shareStatusMessage(for: share)
            return status.isEmpty ? "This share has not been sent yet." : status
        }
        return "This item is gone from this \(UIDevice.current.localizedModel)."
    }

    private var deleteTitle: String {
        recording == nil ? "Remove this share?" : "Delete this recording?"
    }

    @ViewBuilder
    private func recordingOptions(_ recording: LocalRecording) -> some View {
        if let fileURL = recorder.fileURL(for: recording) {
            ShareLink(item: fileURL) {
                optionLabel("Save the file", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("options.save")
            Hairline()
        }

        if recording.state == .invalid {
            Button {
                tryInvalidAgain(recording)
            } label: {
                optionLabel("Try again", systemImage: "arrow.clockwise")
            }
            .disabled(recorder.isRecording || recorder.isStarting)
            .accessibilityIdentifier("options.retry")
            Hairline()
        } else if recording.canUpload {
            Button {
                dismissThen { await uploader.transcribe(recording) }
            } label: {
                optionLabel(
                    recording.state == .uploadFailed ? "Try again" : "Transcribe",
                    systemImage: recording.state == .uploadFailed ? "arrow.clockwise" : "waveform"
                )
            }
            .disabled(recorder.isRecording || recorder.isStarting)
            .accessibilityIdentifier("options.transcribe")
            Hairline()
        }

        // A transfer in flight finishes or fails first, so it can't lose its file midway.
        if !recording.isUploadInProgress || recording.state == .waitingForUpload {
            Button {
                showDeleteConfirmation = true
            } label: {
                optionLabel("Delete", systemImage: "trash", color: Theme.danger)
            }
            .disabled(recorder.isRecording || recorder.isStarting)
            .accessibilityIdentifier("options.delete")
        }
    }

    @ViewBuilder
    private func shareOptions(_ share: ShareInboxStore.Item) -> some View {
        if let fileURL = recorder.sharedFileURL(for: share) {
            ShareLink(item: fileURL) {
                optionLabel("Save the file", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("options.save")
            Hairline()
        }
        Button {
            dismissThen { await uploader.retrySharedItem(share) }
        } label: {
            optionLabel(uploader.shareActionTitle(for: share), systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier("options.transcribe")
        Hairline()
        Button {
            showDeleteConfirmation = true
        } label: {
            optionLabel("Remove", systemImage: "trash", color: Theme.danger)
        }
        .accessibilityIdentifier("options.delete")
    }

    private func optionLabel(_ title: String, systemImage: String, color: Color = Theme.text) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(color == Theme.text ? Theme.accentText : color)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(color)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    /// Checks the file again, and only a pass goes anywhere. A failure leaves it where
    /// it is and says what is still possible.
    private func tryInvalidAgain(_ recording: LocalRecording) {
        switch recorder.recheckInvalidRecording(recording.id) {
        case .success(let current):
            retryMessage = nil
            dismissThen { await uploader.transcribe(current) }
        case .failure:
            retryMessage = "This file still can’t be read, because it stopped before it finished saving. It stays here until you save or delete it."
            Haptics.error()
        }
    }

    private func deleteConfirmed() {
        if let recording {
            withMotion { uploader.discard(recording) }
        } else if let share {
            uploader.discardSharedItem(share)
        }
        Haptics.success()
        dismiss()
    }
}
