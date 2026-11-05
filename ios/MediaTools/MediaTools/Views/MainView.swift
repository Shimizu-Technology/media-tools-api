import SwiftUI
import UniformTypeIdentifiers

/// Screens pushed inside a tab. The recorder is not one of these: it covers the whole
/// app from `MainView`, with no sheet involved, so it can never collide with the one
/// presentation that can arrive at any moment, the AI consent sheet at the app root.
enum AppRoute: Hashable {
    case item(LibraryReference)
    case collection(String)
    case addLink
    case addPDF
    case settings(SettingsPage)

    /// A recording's detail and the two forms need the whole screen.
    var hidesTabBar: Bool {
        switch self {
        case .item, .addLink, .addPDF: true
        case .collection, .settings: false
        }
    }
}

enum AppTab: String, CaseIterable, Hashable, Identifiable {
    case home
    case library
    case collections
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .collections: "Collections"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .library: "text.alignleft"
        case .collections: "folder"
        case .settings: "gearshape"
        }
    }
}

/// Everything that moves the person around, in one place, so that the Action Button,
/// the Live Activity, and a notification tap all land the same way.
@MainActor
@Observable
final class AppNavigator {
    var selectedTab: AppTab
    private(set) var visitedTabs: Set<AppTab>
    var homePath: [AppRoute] = []
    var libraryPath: [AppRoute] = []
    var collectionsPath: [AppRoute] = []
    var settingsPath: [AppRoute] = []
    private(set) var isRecorderPresented = false
    var isImporterPresented = false
    /// The Library's selection bar takes the bottom of the screen while selecting.
    var isTabBarSuppressed = false

    init(initialTab: AppTab = .home) {
        selectedTab = initialTab
        visitedTabs = [initialTab]
    }

    /// A second tap on the current tab goes back to its top, as tab bars do.
    func select(_ tab: AppTab) {
        if tab == selectedTab {
            setPath([], for: tab)
        }
        selectedTab = tab
        visitedTabs.insert(tab)
    }

    func path(for tab: AppTab) -> [AppRoute] {
        switch tab {
        case .home: homePath
        case .library: libraryPath
        case .collections: collectionsPath
        case .settings: settingsPath
        }
    }

    func setPath(_ path: [AppRoute], for tab: AppTab) {
        switch tab {
        case .home: homePath = path
        case .library: libraryPath = path
        case .collections: collectionsPath = path
        case .settings: settingsPath = path
        }
    }

    func push(_ route: AppRoute) {
        setPath(path(for: selectedTab) + [route], for: selectedTab)
    }

    var showsTabBar: Bool {
        guard !isTabBarSuppressed, !isRecorderPresented else { return false }
        return path(for: selectedTab).last?.hidesTabBar != true
    }

    func showRecorder() {
        isRecorderPresented = true
    }

    func closeRecorder() {
        isRecorderPresented = false
    }

    /// A notification tap or a finished recording. It opens in the Library, whatever
    /// was on top there, and any running capture carries on underneath.
    func openFromOutside(_ reference: LibraryReference) {
        isRecorderPresented = false
        libraryPath = [.item(reference)]
        selectedTab = .library
        visitedTabs.insert(.library)
    }
}

struct MainView: View {
    @State private var navigator: AppNavigator
    @State private var libraryModel: LibraryViewModel
    @State private var homeModel: HomeViewModel
    @State private var isKeyboardVisible = false
    @State private var importError: String?
    @Environment(NotificationRouter.self) private var notificationRouter
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(RecordingUploadCoordinator.self) private var uploader
    @Environment(AIProcessingConsentManager.self) private var aiProcessingConsent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let previewItems: [LibraryListItem]?
    private let service = MediaToolsService.shared

    /// `previewItems` swaps in sample rows for the Debug launch modes.
    init(previewItems: [LibraryListItem]? = nil, initialTab: AppTab = .home) {
        self.previewItems = previewItems
        _navigator = State(initialValue: AppNavigator(initialTab: initialTab))
        _libraryModel = State(initialValue: LibraryViewModel(previewItems: previewItems))
        _homeModel = State(initialValue: HomeViewModel(previewItems: previewItems))
    }

    var body: some View {
        ZStack {
            tabs
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if navigator.showsTabBar, !isKeyboardVisible {
                        AppTabBar(navigator: navigator, onRecord: startRecording)
                            .transition(.move(edge: .bottom))
                    }
                }
                .animation(reduceMotion ? nil : Theme.settle, value: navigator.showsTabBar)
                .animation(reduceMotion ? nil : Theme.settle, value: isKeyboardVisible)
                .accessibilityHidden(navigator.isRecorderPresented)

            if navigator.isRecorderPresented {
                RecordView(
                    onClose: { closeRecorder() },
                    onOpenItem: { navigator.openFromOutside($0) }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .environment(navigator)
        .animation(reduceMotion ? nil : Theme.quick, value: navigator.isRecorderPresented)
        // At the app's root, so Import involves no other screen, and on a sibling view,
        // because SwiftUI honors only one file importer along a chain of parents. A
        // recording imported this way joins Home and the Library like any other.
        .background {
            Color.clear.fileImporter(
                isPresented: $navigator.isImporterPresented,
                allowedContentTypes: [.audio, .mpeg4Movie, .quickTimeMovie],
                allowsMultipleSelection: false,
                onCompletion: handleImport
            )
        }
        .alert(
            "Couldn’t import that file",
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onOpenURL { url in
            // The Live Activity's deep link.
            guard url.scheme == "mediatools", url.host == "record" else { return }
            showRecorderOverEverything()
        }
        #if DEBUG
        // What a press does while the app is open, for tests that must not relaunch it.
        .onReceive(NotificationCenter.default.publisher(for: .uiTestActionButton)) { _ in
            Task { @MainActor in
                _ = await recorder.toggleFromSystem()
                QuickCaptureNavigation.requestRecordTab()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .uiTestRecordLink)) { _ in
            showRecorderOverEverything()
        }
        #endif
        .onAppear {
            // A cold Action Button press lands on the recorder, with nothing under it
            // sliding or fading on the way. So does any capture already running.
            if QuickCaptureNavigation.consumeRecordTabRequest() || recorder.isRecording {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { showRecorderOverEverything() }
            }
            openPendingNotificationRoute()
        }
        .onChange(of: notificationRouter.pendingReference) { _, _ in
            openPendingNotificationRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaToolsQuickCapture)) { _ in
            // Consume the persisted fallback as well so a later onAppear does
            // not replay a warm-launch navigation request.
            _ = QuickCaptureNavigation.consumeRecordTabRequest()
            showRecorderOverEverything()
        }
        .onChange(of: recorder.isRecording) { wasRecording, isRecording in
            // However a capture began, its screen is what comes up.
            if isRecording, !wasRecording { showRecorderOverEverything() }
        }
        // Known changes reach every list at once, past its refresh throttle: what was
        // deleted goes straight away, and a short pause gathers a bulk action's changes.
        .onChange(of: service.libraryRevision) { _, _ in
            homeModel.invalidate()
            libraryModel.invalidate()
            homeModel.remove(service.deletedReferences)
            libraryModel.remove(service.deletedReferences)
        }
        .task(id: service.libraryRevision) {
            guard service.libraryRevision > 0 else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            await refreshLists()
            if navigator.visitedTabs.contains(.collections) {
                await service.loadCollections()
            }
        }
        .onChange(of: navigator.homePath) { previous, current in
            refreshAfterDetail(previous: previous, current: current)
        }
        .onChange(of: navigator.libraryPath) { previous, current in
            refreshAfterDetail(previous: previous, current: current)
        }
        .onChange(of: navigator.collectionsPath) { previous, current in
            refreshAfterDetail(previous: previous, current: current)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            // A hardware keyboard reports only its small shortcuts bar.
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            isKeyboardVisible = (frame?.height ?? 0) > 120
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
    }

    // MARK: - Tabs

    /// A system tab view with its bar hidden, under the custom bar. It keeps every
    /// visited tab alive with its place and stack, and takes the others out of the
    /// hierarchy, so VoiceOver can't reach a tab that isn't showing. A change of tab
    /// does not slide: the new one is simply there.
    private var tabs: some View {
        TabView(selection: Binding(
            get: { navigator.selectedTab },
            set: { navigator.select($0) }
        )) {
            ForEach(AppTab.allCases) { tab in
                tabStack(tab)
                    .tag(tab)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .tabViewStyle(.tabBarOnly)
    }

    private func tabStack(_ tab: AppTab) -> some View {
        NavigationStack(path: Binding(
            get: { navigator.path(for: tab) },
            set: { navigator.setPath($0, for: tab) }
        )) {
            tabRoot(tab)
                .navigationDestination(for: AppRoute.self) { route in
                    AppRouteDestination(route: route, previewItems: previewItems)
                }
        }
    }

    @ViewBuilder
    private func tabRoot(_ tab: AppTab) -> some View {
        let isActive = navigator.selectedTab == tab && !navigator.isRecorderPresented
        switch tab {
        case .home:
            HomeView(
                model: homeModel,
                isActive: isActive,
                onRecord: startRecording,
                onSeeAllFailed: showFailedItems
            )
        case .library:
            LibraryView(model: libraryModel, previewItems: previewItems, isActive: isActive)
        case .collections:
            CollectionsListView()
        case .settings:
            SettingsView()
        }
    }

    // MARK: - Actions

    /// One tap: the capture starts, and its screen is already up.
    private func startRecording(contentType: String) {
        recorder.start(contentType: contentType)
        Haptics.medium()
        showRecorderOverEverything()
    }

    /// The Library's own list of every failure, which Home only samples.
    private func showFailedItems() {
        libraryModel.selectedChip = .all
        libraryModel.selectedStatus = .failed
        libraryModel.searchText = ""
        navigator.libraryPath = []
        navigator.select(.library)
    }

    /// The recorder sits inside this view, so anything already presented would stay on
    /// top of Pause and Stop. Every route to it clears them first. The capture itself
    /// has already started or is started separately, so this never holds it up.
    private func showRecorderOverEverything() {
        clearPresentations()
        navigator.showRecorder()
    }

    /// An AI permission prompt is the one thing that outranks an idle recorder: pressing
    /// the Action Button to stop can raise it, and it must stay up to be answered. It
    /// gives way only to a capture that is running, as if "Not now" had been chosen.
    private func clearPresentations() {
        if aiProcessingConsent.isPresentingDisclosure {
            guard recorder.isRecording || recorder.isStarting else { return }
            aiProcessingConsent.decline()
        }
        AppPresentations.dismissAll()
    }

    private func closeRecorder() {
        navigator.closeRecorder()
        Task { await refreshLists() }
    }

    private func refreshLists() async {
        await homeModel.refresh()
        // Only one the person has opened has anything on screen to keep current.
        guard navigator.visitedTabs.contains(.library) else { return }
        await libraryModel.refresh()
        // A selected collection renders its own rows, so it needs its own reload.
        if libraryModel.selectedCollection != nil {
            await libraryModel.loadSelectedCollection()
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let recording = try recorder.importRecording(from: url, contentType: "general")
                Task { await uploader.transcribe(recording) }
            } catch {
                importError = error.localizedDescription
                Haptics.error()
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    /// A detail screen may have renamed, archived, or finished the item.
    private func refreshAfterDetail(previous: [AppRoute], current: [AppRoute]) {
        guard current.count < previous.count, case .item = previous.last else { return }
        Task { await refreshLists() }
    }

    private func openPendingNotificationRoute() {
        guard let reference = notificationRouter.consume() else { return }
        clearPresentations()
        navigator.openFromOutside(reference)
    }
}

/// Clears whatever is on screen above the app's main view, however it got there: a
/// sheet, a sheet over a sheet, an alert, a confirmation, a share sheet, a file picker, a
/// menu, or the keyboard. Doing this from the top means no screen has to remember to
/// take part, including any sheet added later.
@MainActor
enum AppPresentations {
    static func dismissAll() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                dismissMenus(in: window)
                // Not animated, so the recorder is never underneath something leaving.
                if window.rootViewController?.presentedViewController != nil {
                    window.rootViewController?.dismiss(animated: false)
                }
            }
        }
    }

    private static func dismissMenus(in view: UIView) {
        for interaction in view.interactions {
            (interaction as? UIContextMenuInteraction)?.dismissMenu()
        }
        for subview in view.subviews {
            dismissMenus(in: subview)
        }
    }
}

struct AppRouteDestination: View {
    let route: AppRoute
    var previewItems: [LibraryListItem]?

    var body: some View {
        switch route {
        case .item(let reference):
            LibraryDetailLoader(
                reference: reference,
                previewTitle: previewItems?.first { $0.reference == reference }?.displayTitle
            )
        case .collection(let id):
            CollectionDetailView(collectionId: id)
        case .addLink:
            TranscribeView()
        case .addPDF:
            PDFUploadView()
        case .settings(let page):
            SettingsPageView(page: page)
        }
    }
}

// MARK: - Tab bar

/// A custom bar, so the raised Record button looks and behaves the same on iOS 18 and
/// iOS 26, on iPhone and iPad.
struct AppTabBar: View {
    let navigator: AppNavigator
    let onRecord: (String) -> Void
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private static let barHeight: CGFloat = 56

    var body: some View {
        HStack(spacing: 0) {
            tabButton(.home)
            tabButton(.library)
            recordButton
            tabButton(.collections)
            tabButton(.settings)
        }
        // On a wide screen the five stay together in the middle instead of spreading out.
        .frame(maxWidth: horizontalSizeClass == .regular ? 560 : .infinity)
        .frame(maxWidth: .infinity)
        .frame(height: Self.barHeight)
        .background {
            Theme.tabBar
                .overlay(alignment: .top) { Hairline() }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func tabButton(_ tab: AppTab) -> some View {
        let isSelected = navigator.selectedTab == tab
        return Button {
            navigator.select(tab)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 21, weight: isSelected ? .semibold : .regular))
                    .frame(height: 26)
                    .accessibilityHidden(true)
                Text(tab.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Theme.accentText : Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("tab.\(tab.rawValue)")
        // The bar stays one size, as system tab bars do; a long press shows it large.
        .accessibilityShowsLargeContentViewer {
            Label(tab.title, systemImage: tab.systemImage)
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        Group {
            if recorder.isRecording {
                Button {
                    navigator.showRecorder()
                } label: {
                    recordingLabel
                }
                .accessibilityLabel("Return to recording")
                .accessibilityValue(recorder.formattedDuration)
                .accessibilityIdentifier("tab.recording")
            } else {
                Button {
                    onRecord(RecordView.defaultContentType)
                } label: {
                    recordLabel
                }
                .disabled(recorder.isStarting)
                .accessibilityLabel("Record")
                .accessibilityHint("Starts recording from the microphone")
                .accessibilityIdentifier("tab.record")
                .contextMenu {
                    RecordAsMenu { onRecord($0) }
                }
            }
        }
        .buttonStyle(PressFeedbackButtonStyle(pressedScale: 0.92))
        .frame(maxWidth: .infinity)
    }

    private var recordLabel: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(Theme.onHero)
            .modifier(RaisedRecordCircle())
    }

    /// Back from the recording screen, the bar shows what is still running.
    private var recordingLabel: some View {
        VStack(spacing: 2) {
            RecordingPulseDot(size: 7, isPulsing: recorder.captureState == .recording)
            Text(recorder.formattedDuration)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 4)
        }
        .foregroundStyle(Theme.onHero)
        .modifier(RaisedRecordCircle())
    }
}

/// The circle that sits above the bar, ringed in the page color so it reads as lifted.
private struct RaisedRecordCircle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(width: 56, height: 56)
            .background(Theme.heroGradient, in: Circle())
            .padding(4)
            .background(Theme.background, in: Circle())
            .contentShape(Circle())
            .offset(y: -18)
    }
}

/// Recording keeps a pulsing dot beside its timer, so color is not the only signal.
/// With Reduce Motion the dot simply stays on.
struct RecordingPulseDot: View {
    var size: CGFloat = 10
    var isPulsing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        Circle()
            .fill(Theme.onHero)
            .frame(width: size, height: size)
            .opacity(isDimmed && isPulsing && !reduceMotion ? 0.35 : 1)
            .animation(
                isPulsing && !reduceMotion ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : nil,
                value: isDimmed
            )
            .onAppear { isDimmed = true }
            .accessibilityHidden(true)
    }
}
