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

    func testWelcomeOffersSignInCreateAccountAndForgotPassword() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-welcome"]
        app.launch()

        XCTAssertTrue(app.buttons["welcome.sign-in"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["welcome.create-account"].exists)
        XCTAssertTrue(app.buttons["welcome.forgot-password"].exists)
        // Available, but no longer the first thing offered.
        XCTAssertTrue(app.buttons["welcome.passkey"].exists)
        XCTAssertTrue(app.buttons["welcome.recovery-code"].exists)
        XCTAssertLessThan(app.buttons["welcome.sign-in"].frame.minY, app.buttons["welcome.passkey"].frame.minY)
        XCTAssertTrue(app.staticTexts["welcome.authentication.options"].exists)
        let thirdParty = NSPredicate(format: "label CONTAINS[c] 'Clerk' OR label CONTAINS[c] 'Apple' OR label CONTAINS[c] 'Google'")
        XCTAssertFalse(app.buttons.matching(thirdParty).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(thirdParty).firstMatch.exists)

        app.buttons["welcome.sign-in"].tap()
        XCTAssertTrue(app.textFields["password-sign-in.email"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["password-sign-in.password"].exists)
        XCTAssertTrue(app.buttons["password-sign-in.continue"].exists)
        XCTAssertFalse(app.buttons["password-sign-in.continue"].isEnabled, "Nothing to submit yet")

        // A recovery path sits right where a failed sign-in leaves the person.
        app.buttons["password-sign-in.forgot-password"].tap()
        XCTAssertTrue(app.textFields["reset.email"].waitForExistence(timeout: 5))
    }

    func testCreateAccountShowsTheGenericReceiptAndAsksForCodeAndPassword() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-welcome", "-ui-test-auth-api"]
        app.launch()

        let create = app.buttons["welcome.create-account"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()

        let email = app.textFields["sign-up.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["sign-up.password"].exists, "No password before the email is proved")
        email.tap()
        email.typeText("new.person@example.com")
        app.buttons["sign-up.send-code"].tap()

        let receipt = app.staticTexts["sign-up.receipt"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertTrue(receipt.label.hasPrefix("If this request is eligible, an email will arrive shortly"))
        XCTAssertTrue(app.textFields["sign-up.code"].exists)
        XCTAssertTrue(app.secureTextFields["sign-up.password"].exists)
        XCTAssertTrue(app.secureTextFields["sign-up.confirm-password"].exists)
        XCTAssertFalse(app.buttons["sign-up.resend"].isEnabled, "The server spaces out resends")
    }

    func testAShortPasswordIsCaughtWithoutLosingTheForm() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-welcome", "-ui-test-auth-api"]
        app.launch()

        let forgot = app.buttons["welcome.forgot-password"]
        XCTAssertTrue(forgot.waitForExistence(timeout: 10))
        forgot.tap()
        let email = app.textFields["reset.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("person@example.com")
        app.buttons["reset.send-code"].tap()

        let code = app.textFields["reset.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText("123456")
        let password = app.secureTextFields["reset.password"]
        password.tap()
        password.typeText("short")
        let confirmation = app.secureTextFields["reset.confirm-password"]
        confirmation.tap()
        confirmation.typeText("short")
        app.buttons["reset.submit"].tap()

        let error = app.staticTexts["reset.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Use a password of 12 to 128 characters.")
        XCTAssertEqual(code.value as? String, "123456")
    }

    func testMainWorkspaceConnectsCaptureAndOrganizationDestinations() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-main", "-ui-test-reset-recordings"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
        app.tabBars.buttons["Home"].tap()
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



    func testSignInSecurityStatusFailureShowsRetryAndKeepsPreviousCounts() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-security-status-error"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Could not check sign-in security."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1 passkey is set up."].exists)
        XCTAssertTrue(app.staticTexts["2 recovery codes left"].exists)
        let retry = app.buttons["sign-in-security.retry"]
        XCTAssertTrue(retry.exists)
        retry.tap()
        XCTAssertTrue(app.staticTexts["Security status refreshed"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Could not check sign-in security."].exists)
    }

    func testRecoveryCodeOneTimeDisplayRequiresExplicitSavedConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-recovery-codes-sheet"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Save recovery codes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["recovery-codes.copy-all"].exists)
        XCTAssertTrue(app.buttons["Share"].exists)
        let saved = app.buttons["recovery-codes.saved"]
        XCTAssertTrue(saved.exists)
        saved.tap()
        XCTAssertFalse(app.staticTexts["Save recovery codes"].waitForExistence(timeout: 2))
    }



    func testRecoveryCodeSignInSheetSupportsLargeDynamicType() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-recovery-sign-in-sheet",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Use recovery code"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Recovery code"].exists || app.textFields["recovery-code.sign-in-field"].exists)
        let continueButton = app.buttons["recovery-code.continue"]
        if !continueButton.exists || !continueButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(continueButton.exists)
    }

    func testRecoveryCodeSheetSupportsLargeDynamicType() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-recovery-codes-sheet",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Save recovery codes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["recovery-codes.copy-all"].exists)
        let saved = app.buttons["recovery-codes.saved"]
        if !saved.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(saved.isHittable)
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

    func testSavedRecordingUploadsWithNoTapsAndDeliversCompletion() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + [
            "-ui-test-ai-consent",
            "-ui-test-simulated-recording",
            "-ui-test-simulated-upload",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        app.tabBars.buttons["Record"].tap()
        let start = app.buttons["Start recording"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let stop = app.buttons["Stop and save recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()

        // Stop is the last tap. Everything from here happens on its own.
        XCTAssertTrue(app.staticTexts["Transcription complete!"].waitForExistence(timeout: 15))
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

    func testSettingOffKeepsTheManualTranscribeButton() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + [
            "-ui-test-ai-consent",
            "-ui-test-simulated-recording",
            "-ui-test-simulated-upload",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["settings.auto-transcribe"]
        for _ in 0..<6 where !toggle.isHittable {
            app.swipeUp()
        }
        XCTAssertEqual(toggle.value as? String, "1", "Automatic transcription defaults to on")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0")

        app.tabBars.buttons["Record"].tap()
        let start = app.buttons["Start recording"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let stop = app.buttons["Stop and save recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()

        let transcribe = app.buttons.matching(NSPredicate(format: "label == 'Transcribe'")).firstMatch
        XCTAssertTrue(transcribe.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Uploading"].waitForExistence(timeout: 2))
        transcribe.tap()
        XCTAssertTrue(app.staticTexts["Transcription complete!"].waitForExistence(timeout: 15))
    }

    func testWithoutConsentAsksOnceAndKeepsTheRecording() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + [
            "-ui-test-simulated-recording",
            "-ui-test-simulated-upload",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        app.tabBars.buttons["Record"].tap()
        let start = app.buttons["Start recording"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let stop = app.buttons["Stop and save recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()

        let disclosure = app.staticTexts["Allow third-party AI processing?"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'go to OpenAI when they are saved'")
            ).firstMatch.exists
        )
        app.buttons["Not now"].tap()
        assertSavedRecordingQueueIsVisible(in: app)

        // Relaunching must neither lose the recording nor ask again.
        app.terminate()
        app.launchArguments = signedInFixture + [
            "-ui-test-simulated-recording",
            "-ui-test-simulated-upload",
        ]
        app.launch()
        app.tabBars.buttons["Record"].tap()
        assertSavedRecordingQueueIsVisible(in: app)
        XCTAssertFalse(disclosure.waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label == 'Transcribe'")).firstMatch.exists
        )
    }

    func testSignedOutShareShowsItIsWaitingForSignIn() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-welcome",
            "-ui-test-reset-recordings",
            "-ui-test-staged-link",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Waiting for you to sign in"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'Fixture shared video'")
            ).firstMatch.exists
        )
    }

    func testDeclinedSharedLinkStaysAndCanBeSentWithATap() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + [
            "-ui-test-reset-recordings",
            "-ui-test-staged-link",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Allow third-party AI processing?"].waitForExistence(timeout: 10))
        app.buttons["Not now"].tap()

        app.tabBars.buttons["Record"].tap()
        let transcribe = app.buttons["Transcribe"]
        XCTAssertTrue(transcribe.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fixture shared video"].exists)

        // Relaunching keeps the share and does not ask again.
        app.terminate()
        app.launchArguments = signedInFixture
        app.launch()
        app.tabBars.buttons["Record"].tap()
        XCTAssertTrue(transcribe.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Allow third-party AI processing?"].exists)

        transcribe.tap()
        XCTAssertTrue(app.staticTexts["Allow third-party AI processing?"].waitForExistence(timeout: 5))
        app.buttons["Allow AI processing"].tap()

        let waitingRow = app.staticTexts["Fixture shared video"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: waitingRow)
        waitForExpectations(timeout: 10)
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

    func testColdActionButtonThroughContentViewStaysOnRecord() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + [
            "-ui-test-ai-consent",
            "-ui-test-cold-action-button",
            "-ui-test-simulated-recording",
            "-ui-test-simulated-upload",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        let stop = app.buttons["Stop and save recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Record"].isSelected)

        // Account resolution finishes a few seconds after launch. That used to
        // rebuild the tabs and silently land on the default tab mid-recording.
        XCTAssertFalse(app.tabBars.buttons["Library"].waitForSelection(timeout: 6))
        XCTAssertTrue(app.tabBars.buttons["Record"].isSelected)
        XCTAssertTrue(stop.exists)

        stop.tap()
        XCTAssertTrue(app.staticTexts["Transcription complete!"].waitForExistence(timeout: 15))
    }

    func testStoredSessionOpensLibraryEvenWhenTheNetworkNeverAnswers() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + [
            "-ui-test-expired-session",
            "-ui-test-stalled-network",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
        XCTAssertTrue(app.navigationBars["Library"].exists)
        XCTAssertFalse(app.staticTexts["Restoring your workspace…"].exists)
    }

    func testLibraryShowsTheUploadThenUpdatesWithoutAPull() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + [
            "-ui-test-ai-consent",
            "-ui-test-simulated-recording",
            "-ui-test-simulated-upload",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Your Library Is Ready"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Record"].tap()
        let start = app.buttons["Start recording"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let stop = app.buttons["Stop and save recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        app.tabBars.buttons["Library"].tap()

        // The finished server row appears on its own. No pull-to-refresh here.
        let serverRow = app.buttons["library-row-audio:ui-test-audio"]
        XCTAssertTrue(serverRow.waitForExistence(timeout: 15))
    }

    func testRecordingStaysVisibleInLibraryWhileOfflineAndKeepsItsAudio() {
        let app = XCUIApplication()
        // No simulated upload: the API stub refuses presigning, as an outage would.
        app.launchArguments = signedInFixture + [
            "-ui-test-ai-consent",
            "-ui-test-simulated-recording",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        app.tabBars.buttons["Record"].tap()
        let start = app.buttons["Start recording"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let stop = app.buttons["Stop and save recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        app.tabBars.buttons["Library"].tap()

        let deviceRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'library-device-'")
        ).firstMatch
        XCTAssertTrue(deviceRow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'retry automatically'")
            ).firstMatch.waitForExistence(timeout: 10)
        )

        // Tapping an in-progress row goes to where it can be managed.
        deviceRow.tap()
        XCTAssertTrue(app.tabBars.buttons["Record"].waitForSelection(timeout: 5))
        assertSavedRecordingQueueIsVisible(in: app)
    }

    func testNotificationRouteOpensTheItemFromAColdLaunch() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + [
            "-ui-test-notification-route",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["UI test recording"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
        XCTAssertTrue(
            app.staticTexts["Transcript from the UI test fixture."].waitForExistence(timeout: 5)
        )
    }

    func testAudioSummaryStylesMatchWhatTheServerAccepts() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + [
            "-ui-test-notification-route",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["UI test recording"].waitForExistence(timeout: 10))
        for style in ["General", "Conversation", "Meeting", "Voice Memo", "Interview", "Lecture"] {
            XCTAssertTrue(app.buttons[style].waitForExistence(timeout: 5), style)
        }
        for style in ["Tutorial", "Podcast", "Conference", "Review", "News"] {
            XCTAssertFalse(app.buttons[style].exists, style)
        }
    }

    func testFailedVideoImportStopsProcessingAndExplainsWhy() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + ["-ui-test-reset-recordings"]
        app.launch()

        app.tabBars.buttons["Home"].tap()
        let video = app.buttons["workspace.video"]
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        video.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://example.com/video")
        app.buttons["Transcribe"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Couldn’t import this video"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["The provider could not read this video."].exists)
        XCTAssertFalse(app.staticTexts["Processing..."].exists)
    }

    func testCollectionItemsOpenAndALoadFailureCanRetry() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + ["-ui-test-reset-recordings"]
        app.launch()

        app.tabBars.buttons["Collections"].tap()
        let broken = app.staticTexts["Unreachable collection"]
        XCTAssertTrue(broken.waitForExistence(timeout: 10))
        broken.tap()
        XCTAssertTrue(app.staticTexts["Couldn’t Open Collection"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Try Again"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let working = app.staticTexts["Fixture collection"]
        XCTAssertTrue(working.waitForExistence(timeout: 5))
        working.tap()
        let item = app.staticTexts["UI test recording"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.tap()
        XCTAssertTrue(app.navigationBars["UI test recording"].waitForExistence(timeout: 10))
    }

    func testFailedChatSendGivesTheMessageBack() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + [
            "-ui-test-ai-consent",
            "-ui-test-notification-route",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        let chat = app.buttons["Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: chat)
        waitForExpectations(timeout: 10)
        chat.tap()

        // A text field stops matching its placeholder once it has text.
        let input = app.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("What was decided?")
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'arrow' OR label CONTAINS[c] 'Up'"))
            .firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Couldn't send message"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        XCTAssertEqual(input.value as? String, "What was decided?")
    }

    func testExportSheetPresentsSharingOverItself() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + [
            "-ui-test-notification-route",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["UI test recording"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Transcript from the UI test fixture."].waitForExistence(timeout: 10)
        )
        app.navigationBars["UI test recording"].buttons.element(boundBy: 1).tap()
        let export = app.buttons["Export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()

        let plainText = app.buttons["Plain Text (.txt)"]
        XCTAssertTrue(plainText.waitForExistence(timeout: 5))
        plainText.tap()
        // The system share sheet opens over the export sheet rather than failing.
        XCTAssertTrue(
            app.otherElements["ActivityListView"].waitForExistence(timeout: 10)
                || app.buttons["Copy"].waitForExistence(timeout: 5)
        )
    }

    func testSignOutAsksBeforeSigningOut() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + ["-ui-test-reset-recordings"]
        app.launch()

        app.tabBars.buttons["Settings"].tap()
        let signOut = app.buttons["Sign out"]
        for _ in 0..<10 where !signOut.isHittable {
            app.swipeUp()
        }
        signOut.tap()
        XCTAssertTrue(app.staticTexts["Sign out of Media Tools?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Sign Out"].exists)

        // iOS 26 shows this as a popover whose cancel action is tapping away.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.staticTexts["Sign out of Media Tools?"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected, "Dismissing must not sign out")
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
        XCTAssertTrue(app.staticTexts["Team planning session"].exists)

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
        XCTAssertTrue(app.staticTexts["Client discovery notes"].waitForExistence(timeout: 5))
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

    /// Build 13 lost the response to its bootstrap, so only the journal exists.
    func testALostBootstrapResponseWaitsAndRecoversWithoutShowingSignIn() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + ["-ui-test-pending-bootstrap", "-ui-test-reset-recordings"]
        app.launch()

        let message = app.staticTexts["session-recovery.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["welcome.sign-in"].exists, "This person never signed out")
        XCTAssertGreaterThanOrEqual(app.buttons["session-recovery.retry"].frame.height, 44)

        app.buttons["session-recovery.retry"].tap()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(message.exists)
        XCTAssertFalse(app.buttons["welcome.sign-in"].exists)
    }

    func testALostBootstrapResponseRecoversOnForeground() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + ["-ui-test-pending-bootstrap", "-ui-test-reset-recordings"]
        app.launch()
        XCTAssertTrue(app.staticTexts["session-recovery.message"].waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
    }

    func testRecordingsThatCouldNotReconnectSayWhyAndRetry() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + ["-ui-test-legacy-owned-share", "-ui-test-reset-recordings"]
        app.launch()

        let retry = app.buttons["legacy-reconnect.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "An offline check must be visible")
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)

        retry.tap()

        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: retry)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
        XCTAssertFalse(app.staticTexts["legacy-reconnect.message"].exists)
    }

    func testRecordingsThatCouldNotReconnectRetryOnForeground() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + ["-ui-test-legacy-owned-share", "-ui-test-reset-recordings"]
        app.launch()
        let retry = app.buttons["legacy-reconnect.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        app.activate()

        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: retry)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
    }

    /// The real launch path through `ContentView`, with a Debug-only session and
    /// API stub in place of Keychain and network.
    private var signedInFixture: [String] { ["-ui-test-signed-in"] }

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

private extension XCUIElement {
    /// Waits to see whether this element becomes selected. Returning false after
    /// the timeout is the expected result when asserting nothing changed.
    func waitForSelection(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "selected == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
