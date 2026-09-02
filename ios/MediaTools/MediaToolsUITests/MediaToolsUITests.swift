import XCTest

final class MediaToolsUITests: XCTestCase {
    func testOnboardingExplainsPermissionsBackgroundCaptureAndQuickRecord() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-onboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Capture a thought anywhere"].waitForExistence(timeout: 10))
        let progress = app.otherElements["Setup progress"]
        XCTAssertTrue(progress.exists)
        XCTAssertEqual(progress.value as? String, "Step 1 of 4")
        XCTAssertTrue(app.buttons["Skip setup"].isHittable)

        let nextButton = app.buttons["onboarding.next"]
        XCTAssertEqual(nextButton.label, "Next")
        nextButton.tap()
        XCTAssertTrue(app.staticTexts["Prepare your microphone"].waitForExistence(timeout: 5))
        let microphonePermission = app.buttons["onboarding.microphone.permission"]
        XCTAssertTrue(microphonePermission.exists)
        XCTAssertTrue(["Continue", "Open device Settings", "Microphone ready"].contains(microphonePermission.label))
        XCTAssertFalse(app.buttons["Allow microphone"].exists)

        nextButton.tap()
        XCTAssertTrue(app.staticTexts["Know when it’s ready"].waitForExistence(timeout: 5))
        let notificationPermission = app.buttons["onboarding.notifications.permission"]
        XCTAssertTrue(notificationPermission.exists)
        XCTAssertTrue(["Continue", "Open device Settings", "Completion alerts ready"].contains(notificationPermission.label))
        XCTAssertFalse(app.buttons["Enable completion alerts"].exists)

        nextButton.tap()
        XCTAssertTrue(app.staticTexts["Private, durable, and ready"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Shortcuts"].exists)
        XCTAssertTrue(app.buttons["Continue to sign in"].isHittable)
        XCTAssertEqual(progress.value as? String, "Step 4 of 4")
    }

    func testOnboardingNavigationSupportsLandscapeAndAccessibilityText() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-onboarding",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }

        let nextButton = app.buttons["onboarding.next"]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 10))
        XCTAssertEqual(nextButton.label, "Next")
        XCTAssertTrue(nextButton.isHittable)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(nextButton.waitForExistence(timeout: 5))
        XCTAssertTrue(nextButton.isHittable)
        XCTAssertTrue(app.buttons["Skip setup"].isHittable)

        nextButton.tap()
        XCTAssertTrue(app.staticTexts["Prepare your microphone"].waitForExistence(timeout: 5))
        XCTAssertTrue(nextButton.isHittable)
    }

    func testWelcomeMakesEquivalentAuthenticationOptionsDiscoverable() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-welcome"]
        app.launch()

        XCTAssertTrue(app.buttons["Sign in or create account"].waitForExistence(timeout: 10))
        let options = app.staticTexts["welcome.authentication.options"]
        XCTAssertTrue(options.exists)
        XCTAssertEqual(
            options.label,
            "Continue with Apple, Google, or email. Apple lets you keep your email private."
        )
    }

    func testMainWorkspaceConnectsCaptureAndOrganizationDestinations() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-main", "-ui-test-reset-recordings"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["workspace.record"].exists)
        XCTAssertTrue(app.buttons["workspace.video"].exists)
        XCTAssertTrue(app.buttons["workspace.pdf"].exists)
        XCTAssertTrue(app.buttons["workspace.library"].exists)
        XCTAssertTrue(app.buttons["workspace.collections"].exists)

        XCTAssertTrue(app.tabBars.buttons["Home"].exists)
        XCTAssertTrue(app.tabBars.buttons["Library"].exists)
        XCTAssertTrue(app.tabBars.buttons["Record"].exists)
        XCTAssertTrue(app.tabBars.buttons["Collections"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
        XCTAssertFalse(app.tabBars.buttons["Transcribe"].exists)

        app.buttons["workspace.record"].tap()
        XCTAssertTrue(app.buttons["Start recording"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        app.buttons["workspace.video"].tap()
        XCTAssertTrue(app.navigationBars["Transcribe"].waitForExistence(timeout: 5))
        app.navigationBars["Transcribe"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Notification settings"].exists)
        let openShortcuts = app.buttons["Open Shortcuts"]
        for _ in 0..<3 where !openShortcuts.exists {
            app.swipeUp()
        }
        XCTAssertTrue(openShortcuts.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Review setup"].exists)
    }

    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    func testRecordScreenExposesAccessiblePrimaryActions() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-record", "-ui-test-reset-recordings"]
        app.launch()

        XCTAssertTrue(app.buttons["Start recording"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["00:00"].exists)

        let upload = app.buttons["Upload Audio File"]
        XCTAssertTrue(upload.exists)
        if !upload.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(upload.isHittable)
    }

    func testRecordingCanStartStopAndRemainAvailableAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-record",
            "-ui-test-simulated-recording",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        let start = app.buttons["Start recording"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        let pause = app.buttons["Pause recording"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        let stop = app.buttons["Stop and save recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recording now"].exists)

        pause.tap()
        XCTAssertTrue(app.staticTexts["Recording paused"].waitForExistence(timeout: 5))
        let resume = app.buttons["Resume recording"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stop and save recording"].exists)

        resume.tap()
        XCTAssertTrue(app.staticTexts["Recording now"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause recording"].exists)
        stop.tap()

        let savedRecordingTitle = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Recording — '")
        ).firstMatch
        XCTAssertTrue(savedRecordingTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["00:00"].exists)
        XCTAssertTrue(app.staticTexts["Ready for another recording"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Transcribe'")).firstMatch.exists)

        app.terminate()
        app.launchArguments = ["-ui-test-record", "-ui-test-simulated-recording"]
        app.launch()

        let savedQueueLabel = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'saved on this iPhone'")
        ).firstMatch
        XCTAssertTrue(savedQueueLabel.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Transcribe'")).firstMatch.exists)
    }

    func testSavedRecordingUploadsInBackgroundAndDeliversCompletion() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-record",
            "-ui-test-simulated-recording",
            "-ui-test-simulated-upload",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        let start = app.buttons["Start recording"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let stop = app.buttons["Stop and save recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()

        let transcribe = app.buttons.matching(
            NSPredicate(format: "label == 'Transcribe'")
        ).firstMatch
        XCTAssertTrue(transcribe.waitForExistence(timeout: 5))
        transcribe.tap()

        XCTAssertTrue(app.buttons["Uploading"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Transcription complete!"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label == 'Transcribe'")).firstMatch.exists
        )
        let viewDetails = app.buttons["View Details"]
        expectation(
            for: NSPredicate(format: "hittable == true"),
            evaluatedWith: viewDetails
        )
        waitForExpectations(timeout: 5)
    }

    func testAbruptTerminationRecoversRecordingForTranscription() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-record",
            "-ui-test-simulated-recording",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        let start = app.buttons["Start recording"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.buttons["Stop and save recording"].waitForExistence(timeout: 5))

        // Terminate without calling stop. This leaves the manifest in its
        // active state and exercises the same relaunch recovery path as an iOS
        // process termination while the phone is locked.
        app.terminate()
        app.launchArguments = ["-ui-test-record", "-ui-test-simulated-recording"]
        app.launch()

        let recovered = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'recovered after an interruption'")
        ).firstMatch
        XCTAssertTrue(recovered.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label == 'Transcribe'")).firstMatch.exists
        )
    }

    func testActiveRecordingSurvivesTabChanges() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-main",
            "-ui-test-simulated-recording",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        app.tabBars.buttons["Record"].tap()
        let start = app.buttons["Start recording"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.buttons["Stop and save recording"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Record"].tap()
        let stop = app.buttons["Stop and save recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        assertSavedRecordingQueueIsVisible(in: app)
    }

    func testSystemQuickCaptureStartsAndCanBeStoppedInTheApp() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-quick-capture",
            "-ui-test-simulated-recording",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        let stop = app.buttons["Stop and save recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Recording now"].exists)
        stop.tap()

        assertSavedRecordingQueueIsVisible(in: app)
        XCTAssertTrue(app.staticTexts["00:00"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Transcribe'")).firstMatch.exists)
    }

    func testColdQuickCaptureRoutesToRecordAfterMainTabsMount() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-main",
            "-ui-test-cold-quick-capture",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["Start recording"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Record"].isSelected)
    }

    func testQuickCaptureLiveActivityCanStopFromTheDynamicIsland() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-quick-capture",
            "-ui-test-simulated-recording",
            "-ui-test-reset-recordings",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Stop and save recording"].waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowLiveActivities = springboard.buttons["Allow"]
        if allowLiveActivities.waitForExistence(timeout: 3) {
            allowLiveActivities.tap()
        }

        // Expand the compact Dynamic Island presentation to expose its label
        // and explicit Stop action while Media Tools remains in the background.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035))
            .press(forDuration: 1)

        XCTAssertTrue(springboard.staticTexts["Recording"].waitForExistence(timeout: 10))
        XCTAssertTrue(springboard.staticTexts["Voice Memo"].exists)

        let pause = springboard.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        XCTAssertTrue(springboard.staticTexts["Recording paused"].waitForExistence(timeout: 5))

        let resume = springboard.buttons["Resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(springboard.staticTexts["Recording"].waitForExistence(timeout: 5))

        let stopAndSave = springboard.buttons["Stop & Save"]
        XCTAssertTrue(stopAndSave.waitForExistence(timeout: 5))
        stopAndSave.tap()
        XCTAssertTrue(stopAndSave.waitForNonExistence(timeout: 10))
    }

    func testLibrarySupportsTypedSelectionAndResponsiveActions() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-library"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.searchFields["Search all media"].exists)
        XCTAssertTrue(app.buttons["All"].isHittable)
        XCTAssertTrue(app.buttons["PDFs"].isHittable)
        XCTAssertTrue(app.staticTexts["Weekly product review"].exists)
        XCTAssertTrue(app.staticTexts["Team planning session.m4a"].exists)

        app.buttons["Library actions"].tap()
        XCTAssertTrue(app.buttons["Select Items"].waitForExistence(timeout: 5))
        app.buttons["Select Items"].tap()

        let firstItem = app.buttons["Select Weekly product review"]
        XCTAssertTrue(firstItem.waitForExistence(timeout: 5))
        firstItem.tap()
        XCTAssertTrue(app.staticTexts["1 selected"].exists)
        XCTAssertTrue(app.buttons["Delete"].isHittable)
        XCTAssertTrue(app.buttons["Done"].isHittable)

        app.buttons["Done"].tap()
        let search = app.searchFields["Search all media"]
        search.tap()
        search.typeText("client")
        XCTAssertTrue(app.staticTexts["Client discovery notes.pdf"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Weekly product review"].exists)
    }

    func testLibraryPrefetchesAndRestoresPositionAfterOpeningDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-library-pagination"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        let target = app.buttons["library-row-audio:audio-25"]
        for _ in 0..<12 where !target.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(target.isHittable)

        target.tap()
        XCTAssertTrue(app.navigationBars["Recording 25"].waitForExistence(timeout: 5))
        app.navigationBars["Recording 25"].buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(target.isHittable)
        XCTAssertFalse(app.buttons["library-row-audio:audio-1"].isHittable)
    }

    private func assertSavedRecordingQueueIsVisible(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let savedQueue = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'saved on this iPhone'")
        ).firstMatch
        if !savedQueue.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(savedQueue.waitForExistence(timeout: 5), file: file, line: line)
    }
}
