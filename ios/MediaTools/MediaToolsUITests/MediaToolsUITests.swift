import XCTest

final class MediaToolsUITests: XCTestCase {
    func testOnboardingAsksForEachPermissionWithANeutralContinue() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-onboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Prepare your microphone"].waitForExistence(timeout: 10))
        let progress = app.otherElements["Setup progress"]
        XCTAssertTrue(progress.exists)
        XCTAssertEqual(progress.value as? String, "Step 1 of 3")

        // App Review: nothing but a neutral Continue before a permission prompt.
        let next = app.buttons["onboarding.next"]
        XCTAssertEqual(next.label, "Continue")
        XCTAssertFalse(app.buttons["Skip setup"].exists)
        XCTAssertFalse(app.buttons["Allow microphone"].exists)
        XCTAssertFalse(app.buttons["Not now"].exists)

        next.tap()
        allowSystemPromptIfShown()
        XCTAssertTrue(app.staticTexts["Know when it’s ready"].waitForExistence(timeout: 5))
        XCTAssertEqual(next.label, "Continue")
        XCTAssertFalse(app.buttons["Enable completion alerts"].exists)

        next.tap()
        allowSystemPromptIfShown()
        XCTAssertTrue(app.staticTexts["Private and durable"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Shortcuts"].exists)
        XCTAssertEqual(next.label, "Continue to sign in")
        XCTAssertEqual(progress.value as? String, "Step 3 of 3")
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
        XCTAssertEqual(nextButton.label, "Continue")
        XCTAssertTrue(nextButton.isHittable)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(nextButton.waitForExistence(timeout: 5))
        XCTAssertTrue(nextButton.isHittable)

        nextButton.tap()
        allowSystemPromptIfShown()
        XCTAssertTrue(app.staticTexts["Know when it’s ready"].waitForExistence(timeout: 5))
        XCTAssertTrue(nextButton.isHittable)
    }

    func testSignInIsTheFirstScreenAndOffersEveryWayIn() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-welcome"]
        app.launch()

        let email = app.textFields["password-sign-in.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["password-sign-in.password"].exists)
        let signIn = app.buttons["password-sign-in.continue"]
        XCTAssertTrue(signIn.exists)
        XCTAssertFalse(signIn.isEnabled, "Nothing to submit yet")
        XCTAssertTrue(app.buttons["welcome.create-account"].exists)
        XCTAssertTrue(app.buttons["welcome.forgot-password"].exists)
        // Available, but not the first thing offered.
        XCTAssertTrue(app.buttons["welcome.passkey"].exists)
        XCTAssertTrue(app.buttons["welcome.recovery-code"].exists)
        XCTAssertLessThan(signIn.frame.minY, app.buttons["welcome.passkey"].frame.minY)
        XCTAssertTrue(app.staticTexts["welcome.authentication.options"].exists)
        let thirdParty = NSPredicate(format: "label CONTAINS[c] 'Clerk' OR label CONTAINS[c] 'Apple' OR label CONTAINS[c] 'Google'")
        XCTAssertFalse(app.buttons.matching(thirdParty).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(thirdParty).firstMatch.exists)

        // The password can be checked before submitting it.
        let password = app.secureTextFields["password-sign-in.password"]
        password.tap()
        password.typeText("not-a-real-password")
        app.buttons["Show password"].tap()
        XCTAssertTrue(app.textFields["password-sign-in.password"].waitForExistence(timeout: 5))
        app.buttons["Hide password"].tap()
        XCTAssertTrue(app.secureTextFields["password-sign-in.password"].waitForExistence(timeout: 5))

        // A recovery path sits right where a failed sign-in leaves the person.
        app.buttons["welcome.forgot-password"].tap()
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

    func testLibraryIsHomeAndReachesEveryDestination() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-main", "-ui-test-reset-recordings"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The Library is home, with no tab bar")
        XCTAssertTrue(app.searchFields["Search"].exists)
        XCTAssertTrue(app.buttons["library.record"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["library.record"].frame.height.rounded(), 44)

        app.buttons["library.add"].tap()
        app.buttons["Add a Link"].tap()
        XCTAssertTrue(app.navigationBars["Add a Link"].waitForExistence(timeout: 5))
        goBack(in: app)

        app.buttons["library.add"].tap()
        app.buttons["Upload a PDF"].tap()
        XCTAssertTrue(app.navigationBars["Upload a PDF"].waitForExistence(timeout: 5))
        goBack(in: app)

        openCollections(in: app)
        goBack(in: app)

        app.buttons["library.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Notification settings"].exists)
        let quickRecord = app.buttons["settings.quick-record"]
        XCTAssertTrue(quickRecord.waitForExistence(timeout: 5))
        quickRecord.tap()
        XCTAssertTrue(app.buttons["Open Shortcuts"].waitForExistence(timeout: 5))
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

        // The type stays optional and keeps its default.
        XCTAssertEqual(app.buttons["record.content-type"].value as? String, "General")

        let upload = app.buttons["Upload audio file"]
        XCTAssertTrue(upload.exists)
        if !upload.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(upload.isHittable)
    }

    func testRecordingControlsFitAtTheLargestAccessibilitySize() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-quick-capture",
            "-ui-test-simulated-recording",
            "-ui-test-reset-recordings",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()

        let stop = app.buttons["Stop and save recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        if !stop.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(stop.isHittable)
        XCTAssertGreaterThanOrEqual(stop.frame.height.rounded(), 44)
        XCTAssertTrue(app.buttons["Pause recording"].isHittable)
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
        XCTAssertTrue(app.staticTexts["Recording"].exists)
        XCTAssertTrue(app.staticTexts["Press the Action Button again to stop."].exists)

        pause.tap()
        XCTAssertTrue(app.staticTexts["Paused"].waitForExistence(timeout: 5))
        let resume = app.buttons["Resume recording"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stop and save recording"].exists)

        resume.tap()
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 5))
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

        recordFromTheLibraryAndStop(in: app)

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

        XCTAssertTrue(app.buttons["library.settings"].waitForExistence(timeout: 10))
        app.buttons["library.settings"].tap()
        let toggle = app.switches["settings.auto-transcribe"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "Automatic transcription defaults to on")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        goBack(in: app)

        recordFromTheLibraryAndStop(in: app)

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

        recordFromTheLibraryAndStop(in: app)

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
        openFirstDeviceRow(in: app)
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

        openFirstShareRow(in: app)
        let transcribe = app.buttons["Transcribe"]
        XCTAssertTrue(transcribe.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fixture shared video"].exists)

        // Relaunching keeps the share and does not ask again.
        app.terminate()
        app.launchArguments = signedInFixture
        app.launch()
        openFirstShareRow(in: app)
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

    func testActiveRecordingSurvivesLeavingTheRecorder() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-main",
            "-ui-test-simulated-recording",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        let record = app.buttons["library.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.tap()
        XCTAssertTrue(app.buttons["Stop and save recording"].waitForExistence(timeout: 5))

        // Back to reading, with the Record control showing what is still running.
        goBack(in: app)
        let returnToRecording = app.buttons["library.recording"]
        XCTAssertTrue(returnToRecording.waitForExistence(timeout: 5))
        XCTAssertFalse(record.exists)

        app.buttons["library.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        goBack(in: app)

        returnToRecording.tap()
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
        XCTAssertTrue(app.staticTexts["Recording"].exists)
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

        // Account resolution finishes a few seconds after launch. That used to
        // rebuild the screen and silently land on the Library mid-recording.
        XCTAssertFalse(stop.waitForNonExistence(timeout: 6))
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

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
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

        recordFromTheLibraryAndStop(in: app)
        goBack(in: app)

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

        recordFromTheLibraryAndStop(in: app)
        goBack(in: app)

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
        XCTAssertTrue(
            app.staticTexts["Transcript from the UI test fixture."].waitForExistence(timeout: 10)
        )
        // Rare, so one level down the toolbar menu.
        app.buttons["detail.more"].tap()
        app.buttons["Summary Style"].tap()
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

        let add = app.buttons["library.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        app.buttons["Add a Link"].tap()
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

        openCollections(in: app)
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

    func testCollectionsFilterTheLibrary() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + ["-ui-test-reset-recordings"]
        app.launch()

        let filter = app.buttons["library.collections"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertEqual(filter.value as? String, "All collections")
        filter.tap()
        app.buttons["Fixture collection"].tap()
        XCTAssertEqual(filter.value as? String, "Fixture collection")

        let item = app.buttons["UI test recording"]
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

        let ask = app.buttons["detail.ask"]
        XCTAssertTrue(ask.waitForExistence(timeout: 10))
        ask.tap()

        // A text field stops matching its placeholder once it has text.
        let input = app.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("What was decided?")
        app.buttons["chat.send"].tap()

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

    func testDetailKeepsEveryRareActionInItsMenu() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + [
            "-ui-test-rich-content",
            "-ui-test-notification-route",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Monday planning call"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Add to Collection"].exists)
        XCTAssertTrue(app.buttons["Export"].exists)

        let more = app.buttons["detail.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        for action in ["Rename Recording", "Star", "Tags", "Copy Text", "Summarize Again", "Report Summary", "Archive", "Delete"] {
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5), action)
        }

        // Findable for App Review, one tap inside the menu.
        app.buttons["Report Summary"].tap()
        XCTAssertTrue(app.navigationBars["Report AI output"].waitForExistence(timeout: 5))
    }

    func testTappingATimestampKeepsYourPlace() throws {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + [
            "-ui-test-rich-content",
            "-ui-test-notification-route",
            "-ui-test-reset-recordings",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Monday planning call"].waitForExistence(timeout: 10))
        let modes = app.buttons["detail.transcript-mode"]
        // Clear of the bottom bar, which a control can pass under while still "hittable".
        for _ in 0..<4 where !modes.isHittable || modes.frame.midY > app.frame.height * 0.6 {
            app.swipeUp()
        }
        modes.tap()
        app.buttons["Timestamps"].tap()

        // Move on from the player, then use whichever row sits clear of the bars.
        app.swipeUp()
        // A tap during the swipe's momentum only stops the scroll.
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(value: true), object: nil)
        _ = XCTWaiter.wait(for: [settled], timeout: 1.5)
        let rows = app.buttons.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9]{2}, .*'"))
        let height = app.frame.height
        let moment = try XCTUnwrap(
            rows.allElementsBoundByIndex.first { row in
                row.isHittable && row.frame.minY > height * 0.15 && row.frame.midY < height * 0.6
            }
        )
        let before = moment.frame.minY
        moment.tap()

        // The page has not moved, and the audio can be paused from here.
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        XCTAssertEqual(moment.frame.minY, before, accuracy: 60)
    }

    func testSignOutAsksBeforeSigningOut() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + ["-ui-test-reset-recordings"]
        app.launch()

        XCTAssertTrue(app.buttons["library.settings"].waitForExistence(timeout: 10))
        app.buttons["library.settings"].tap()
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
        XCTAssertTrue(app.navigationBars["Settings"].exists, "Dismissing must not sign out")
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
        XCTAssertTrue(app.searchFields["Search"].exists)
        XCTAssertTrue(app.staticTexts["Weekly product review"].exists)
        XCTAssertTrue(app.staticTexts["Team planning session"].exists)

        // Status appears only when something needs attention.
        XCTAssertTrue(app.staticTexts["Transcribing"].exists)
        XCTAssertFalse(app.staticTexts["Completed"].exists)

        app.buttons["Library actions"].tap()
        XCTAssertTrue(app.buttons["PDFs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Select Items"].exists)
        app.buttons["Select Items"].tap()

        let firstItem = app.buttons["Select Weekly product review"]
        XCTAssertTrue(firstItem.waitForExistence(timeout: 5))
        firstItem.tap()
        XCTAssertTrue(app.staticTexts["1 selected"].exists)
        XCTAssertTrue(app.buttons["Delete"].isHittable)
        XCTAssertTrue(app.buttons["Done"].isHittable)

        app.buttons["Done"].tap()
        let search = app.searchFields["Search"]
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
        XCTAssertGreaterThanOrEqual(app.buttons["session-recovery.retry"].frame.height.rounded(), 44)

        app.buttons["session-recovery.retry"].tap()

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
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

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
    }

    func testRecordingsThatCouldNotReconnectSayWhyAndRetry() {
        let app = XCUIApplication()
        app.launchArguments = signedInFixture + ["-ui-test-legacy-owned-share", "-ui-test-reset-recordings"]
        app.launch()

        let retry = app.buttons["legacy-reconnect.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "An offline check must be visible")
        XCTAssertGreaterThanOrEqual(retry.frame.height.rounded(), 44)

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

    /// Starting and stopping from home, which is how a recording usually begins.
    private func recordFromTheLibraryAndStop(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let record = app.buttons["library.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), file: file, line: line)
        record.tap()
        let stop = app.buttons["Stop and save recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), file: file, line: line)
        stop.tap()
    }

    private func goBack(in app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func openCollections(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let filter = app.buttons["library.collections"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10), file: file, line: line)
        filter.tap()
        let manage = app.buttons["Manage Collections"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5), file: file, line: line)
        manage.tap()
        XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 5), file: file, line: line)
    }

    private func openFirstDeviceRow(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'library-device-'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), file: file, line: line)
        row.tap()
    }

    private func openFirstShareRow(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'library-share-'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), file: file, line: line)
        row.tap()
    }

    /// Onboarding reaches the real system prompts the first time it runs on a device.
    private func allowSystemPromptIfShown() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) {
            allow.tap()
        }
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
