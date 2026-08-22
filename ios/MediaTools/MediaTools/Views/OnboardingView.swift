import AVFoundation
import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var currentPage = 0
    @State private var microphoneState: MicrophonePermissionState = .notRequested
    @State private var notificationState: NotificationPermissionState = .notRequested
    @State private var appeared = false

    private let pageCount = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [Theme.surface, Theme.surfaceElevated, Theme.surface],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                Circle()
                    .fill(Theme.brand500.opacity(0.08))
                    .frame(width: 400, height: 400)
                    .blur(radius: 80)
                    .offset(y: -280)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                VStack(spacing: 0) {
                    HStack {
                        Text("Media Tools")
                            .font(Theme.heading(17))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Button("Skip setup") { finish() }
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(minHeight: 44)
                    }
                    .frame(width: max(0, geometry.size.width - 48))
                    .padding(.top, 8)

                    TabView(selection: $currentPage) {
                        onboardingPage(
                            availableWidth: geometry.size.width,
                            icon: "button.programmable",
                            color: Theme.brand400,
                            title: "Capture a thought anywhere",
                            subtitle:
                                "Press the Action Button, a widget, Control Center, or Back Tap to open Media Tools and begin recording automatically. Once capture starts, it keeps recording when the screen locks or you use another app.",
                            note: "You always get a visible recording indicator and one-tap stop control."
                        )
                        .tag(0)

                        onboardingPage(
                            availableWidth: geometry.size.width,
                            icon: microphoneIcon,
                            color: microphoneState == .denied ? Theme.warning : Theme.audioColor,
                            title: "Prepare your microphone",
                            subtitle:
                                "Media Tools only listens after you deliberately start a recording. Audio is saved on this iPhone first, then uploaded when you choose Transcribe.",
                            note: microphoneDetail
                        ) {
                            permissionButton(
                                title: microphoneActionTitle,
                                icon: microphoneIcon,
                                isComplete: microphoneState == .enabled,
                                action: handleMicrophoneAction
                            )
                        }
                        .tag(1)

                        onboardingPage(
                            availableWidth: geometry.size.width,
                            icon: notificationIcon,
                            color: notificationState == .denied ? Theme.warning : Color.blue,
                            title: "Know when it’s ready",
                            subtitle:
                                "Uploads and transcription continue without keeping Media Tools open. Optional completion alerts tell you when the transcript is ready or needs attention.",
                            note: notificationDetail
                        ) {
                            permissionButton(
                                title: notificationActionTitle,
                                icon: notificationIcon,
                                isComplete: notificationState == .enabled,
                                action: handleNotificationAction
                            )
                        }
                        .tag(2)

                        onboardingPage(
                            availableWidth: geometry.size.width,
                            icon: "lock.shield.fill",
                            color: Theme.brand400,
                            title: "Private, durable, and ready",
                            subtitle:
                                "Recordings stay recoverable on this iPhone until the server accepts them. Before the first transcription, summary, formatting, or chat request, Media Tools explains which third-party AI providers receive your content and asks your permission.",
                            note:
                                "Your AI permission is account-scoped and can be revoked in Settings. Next, add Media Tools → Quick Record to your Action Button."
                        ) {
                            Button {
                                guard let url = URL(string: "shortcuts://") else { return }
                                openURL(url)
                            } label: {
                                Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                                    .font(Theme.body(15, weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.brand400)
                            .accessibilityHint("Opens Shortcuts so you can configure Quick Record")
                        }
                        .tag(3)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(width: geometry.size.width)

                    pageIndicator

                    Button {
                        if currentPage < pageCount - 1 {
                            if reduceMotion {
                                currentPage += 1
                            } else {
                                withAnimation(Theme.springSnappy) { currentPage += 1 }
                            }
                        } else {
                            finish()
                        }
                    } label: {
                        Text(currentPage < pageCount - 1 ? "Continue" : "Continue to sign in")
                            .font(Theme.heading(16))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.radiusMedium)
                                    .fill(Theme.brandGradient)
                            )
                    }
                    .frame(width: max(0, geometry.size.width - 48))
                    .padding(.top, 18)
                    .padding(.bottom, 20)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : (reduceMotion ? 0 : 12))
                    .accessibilityHint(
                        currentPage < pageCount - 1
                            ? "Shows the next setup step" : "Finishes setup and opens sign in"
                    )
                }
                .frame(width: geometry.size.width)
            }
        }
        .preferredColorScheme(.dark)
        .task { await refreshPermissionStates() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshPermissionStates() }
        }
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(Theme.springGentle.delay(0.15)) { appeared = true }
            }
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? Theme.brand400 : Theme.borderSubtle)
                    .frame(width: index == currentPage ? 24 : 8, height: 8)
                    .animation(reduceMotion ? nil : Theme.springSnappy, value: currentPage)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup progress")
        .accessibilityValue("Step \(currentPage + 1) of \(pageCount)")
    }

    private func onboardingPage<Actions: View>(
        availableWidth: CGFloat,
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        note: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.08))
                        .frame(width: 150, height: 150)
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 126, height: 126)
                    Image(systemName: icon)
                        .font(.system(size: 54, weight: .medium))
                        .foregroundStyle(color)
                }
                .accessibilityHidden(true)

                VStack(spacing: 12) {
                    Text(title)
                        .font(Theme.heading(26))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(subtitle)
                        .font(Theme.body(16))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)

                Label(note, systemImage: "info.circle.fill")
                    .font(Theme.caption(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))

                actions()
            }
            .frame(width: max(0, min(availableWidth - 48, 560)))
            .padding(.top, 30)
            .padding(.bottom, 20)
        }
        .frame(width: availableWidth)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func onboardingPage(
        availableWidth: CGFloat,
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        note: String
    ) -> some View {
        onboardingPage(
            availableWidth: availableWidth,
            icon: icon,
            color: color,
            title: title,
            subtitle: subtitle,
            note: note
        ) { EmptyView() }
    }

    private func permissionButton(
        title: String,
        icon: String,
        isComplete: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: isComplete ? "checkmark.circle.fill" : icon)
                .font(Theme.body(15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        .tint(isComplete ? Theme.success : Theme.brand500)
    }

    private var microphoneIcon: String {
        switch microphoneState {
        case .enabled: "checkmark.circle.fill"
        case .denied: "mic.slash.fill"
        case .notRequested: "mic.fill"
        }
    }

    private var microphoneDetail: String {
        switch microphoneState {
        case .enabled: "Microphone access is ready."
        case .denied: "Microphone access is off. You can enable it in device Settings."
        case .notRequested: "When you tap Allow microphone, iOS will ask for access."
        }
    }

    private var microphoneActionTitle: String {
        switch microphoneState {
        case .enabled: "Microphone ready"
        case .denied: "Open device Settings"
        case .notRequested: "Allow microphone"
        }
    }

    private var notificationIcon: String {
        switch notificationState {
        case .enabled: "checkmark.circle.fill"
        case .denied: "bell.slash.fill"
        case .notRequested: "bell.badge.fill"
        }
    }

    private var notificationDetail: String {
        switch notificationState {
        case .enabled: "Completion alerts are on."
        case .denied: "Completion alerts are off. You can change this in device Settings."
        case .notRequested: "Alerts are optional and only describe Media Tools work you started."
        }
    }

    private var notificationActionTitle: String {
        switch notificationState {
        case .enabled: "Completion alerts ready"
        case .denied: "Open device Settings"
        case .notRequested: "Enable completion alerts"
        }
    }

    private func handleMicrophoneAction() {
        switch microphoneState {
        case .enabled:
            return
        case .denied:
            openDeviceSettings()
        case .notRequested:
            Task {
                microphoneState = await MicrophonePermissionService.requestPermission()
            }
        }
    }

    private func handleNotificationAction() {
        switch notificationState {
        case .enabled:
            return
        case .denied:
            openDeviceSettings()
        case .notRequested:
            Task {
                _ = await NotificationService.requestPermission()
                notificationState = await NotificationService.permissionState()
            }
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

    private func finish() {
        if reduceMotion {
            isComplete = true
        } else {
            withAnimation(Theme.springGentle) { isComplete = true }
        }
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
