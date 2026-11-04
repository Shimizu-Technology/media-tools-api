import AVFoundation
import SwiftUI

/// Only what iOS will ask about, and what happens to the audio. Each permission gets
/// its own screen and a single neutral Continue, with no way out before the system
/// prompt: App Review treats a skip or "not now" there as steering the decision.
struct OnboardingView: View {
    @Binding var isComplete: Bool
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var currentPage = 0
    @State private var microphoneState: MicrophonePermissionState = .notRequested
    @State private var notificationState: NotificationPermissionState = .notRequested
    @State private var isAdvancing = false

    private let pageCount = 3

    var body: some View {
        ScrollView {
            pageContent
                .readingMeasure()
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 16)
                .id(currentPage)
                .transition(.opacity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.bg)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                pageIndicator
                Button(action: advance) {
                    Text(currentPage < pageCount - 1 ? "Continue" : "Continue to sign in")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.next")
                .accessibilityHint(
                    currentPage < pageCount - 1 ? "Shows the next setup step" : "Finishes setup and opens sign in"
                )
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(Theme.bg)
        }
        .task { await refreshPermissionStates() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshPermissionStates() }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch currentPage {
        case 0:
            page(
                title: "Prepare your microphone",
                message: "Media Tools only listens after you deliberately start a recording. Only record people when you have their permission and recording is lawful where you are. Audio is saved on this iPhone first, then transcribed automatically once you allow AI processing.",
                note: microphoneDetail
            ) {
                if microphoneState == .denied {
                    settingsButton
                }
            }
        case 1:
            page(
                title: "Know when it’s ready",
                message: "Uploads and transcription continue without keeping Media Tools open. Completion alerts tell you when a transcript is ready or needs attention.",
                note: notificationDetail
            ) {
                if notificationState == .denied {
                    settingsButton
                }
            }
        default:
            page(
                title: "Private and durable",
                message: "Recordings stay recoverable on this iPhone until the server accepts them. Before the first transcription, summary, formatting, or chat request, Media Tools explains which third-party AI providers receive your content and asks your permission. You can revoke that in Settings.",
                note: "To record with one press, add Media Tools, then Quick Record, to your Action Button."
            ) {
                Button("Open Shortcuts") {
                    guard let url = URL(string: "shortcuts://") else { return }
                    openURL(url)
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityHint("Opens Shortcuts so you can configure Quick Record")

                legalLinks
            }
        }
    }

    /// Keeps the public resources compact at normal sizes and reliably tappable
    /// when Dynamic Type needs a vertical layout.
    private var legalLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                legalLink("Terms", destination: Configuration.termsURL)
                legalLink("Privacy", destination: Configuration.privacyURL)
                legalLink("Support", destination: Configuration.supportURL)
            }

            VStack(alignment: .leading, spacing: 0) {
                legalLink("Terms", destination: Configuration.termsURL)
                legalLink("Privacy", destination: Configuration.privacyURL)
                legalLink("Support", destination: Configuration.supportURL)
            }
        }
    }

    private func legalLink(_ title: String, destination: URL) -> some View {
        Link(title, destination: destination)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    private var settingsButton: some View {
        Button("Open device Settings", action: openDeviceSettings)
            .buttonStyle(QuietButtonStyle())
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { index in
                Circle()
                    .fill(index == currentPage ? Theme.accent : Theme.separator)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup progress")
        .accessibilityValue("Step \(currentPage + 1) of \(pageCount)")
    }

    private func page<Actions: View>(
        title: String,
        message: String,
        note: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.ledgerLargeTitle)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(message)
                .readingText()
                .fixedSize(horizontal: false, vertical: true)

            Text(note)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func advance() {
        // A second tap must not skip the next permission page.
        guard !isAdvancing else { return }
        isAdvancing = true
        Task {
            defer { isAdvancing = false }
            // Continue on a permission page asks iOS first, whatever the answer.
            switch currentPage {
            case 0 where microphoneState == .notRequested:
                microphoneState = await MicrophonePermissionService.requestPermission()
            case 1 where notificationState == .notRequested:
                _ = await NotificationService.requestPermission()
                notificationState = await NotificationService.permissionState()
            default:
                break
            }
            if currentPage < pageCount - 1 {
                withMotion(Theme.quick) { currentPage += 1 }
            } else {
                isComplete = true
            }
        }
    }

    private var microphoneDetail: String {
        switch microphoneState {
        case .enabled: "Microphone access is on."
        case .denied: "Microphone access is off. You can turn it on in device Settings."
        case .notRequested: "When you tap Continue, iOS will ask for microphone access."
        }
    }

    private var notificationDetail: String {
        switch notificationState {
        case .enabled: "Completion alerts are on."
        case .denied: "Completion alerts are off. You can change this in device Settings."
        case .notRequested:
            "When you tap Continue, iOS will ask whether to allow alerts. They are optional."
        }
    }

    private func refreshPermissionStates() async {
        microphoneState = MicrophonePermissionService.permissionState
        notificationState = await NotificationService.permissionState()
    }

    private func openDeviceSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

enum MicrophonePermissionState: Equatable {
    case notRequested
    case enabled
    case denied
}

enum MicrophonePermissionService {
    static var permissionState: MicrophonePermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .enabled
        case .denied: .denied
        case .undetermined: .notRequested
        @unknown default: .notRequested
        }
    }

    static func requestPermission() async -> MicrophonePermissionState {
        guard permissionState == .notRequested else { return permissionState }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        return granted ? .enabled : .denied
    }
}
