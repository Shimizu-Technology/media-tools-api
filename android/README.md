# Media Tools for Android

The native Android app is a Jetpack Compose client for the same account-scoped Media Tools API used by the web and iOS apps.

## Local setup

Requirements:

- Android Studio with Android 16 / API 36 installed
- JDK 17
- a Clerk development publishable key for migration testing

Keep the publishable key outside source control. Add this line to `~/.gradle/gradle.properties`:

```properties
MEDIA_TOOLS_CLERK_PUBLISHABLE_KEY=pk_test_your_development_key
```

Then build from this directory:

```bash
./gradlew lint testDebugUnitTest assembleDebug
```

The Clerk dashboard must have Native API enabled and an Android application mapping for package `com.shimizutechnology.mediatools`. That external development setting is intentionally not changed by source code.

### Staged first-party device session

The new session path is off by default. To exercise it in a development build,
set `MEDIA_TOOLS_FIRST_PARTY_ANDROID_AUTH=true` in Gradle properties or the
environment. The Go server must also have `FIRST_PARTY_AUTH_ENABLED=true`.
Sign in with the existing Clerk flow once; Android exchanges that verified
session for a Media Tools device session. Subsequent launches use the device
credential even if Clerk's short session has expired. The sign-in screen also
accepts a saved one-time recovery code and persists its exact retry credentials
in encrypted storage before sending the request. A lost response can therefore
recover the same session without consuming another code.

The refresh credential and an in-progress replacement are encrypted with a
device-only Android Keystore key. The app writes the replacement before
refreshing so it can recover if the server responds but the phone loses the
response. Sign out requires server revocation and keeps the user signed in if
revocation cannot be confirmed. Android backup is disabled for this app.

Settings shows the active recovery-code count and a two-step replacement flow.
The app encrypts the pending rotation ID and plaintext codes, binds them to the
stable Media Tools user ID, and activates the new set only after the user checks
that the codes were saved. Canceling leaves the old set active. Sign-out,
account deletion, and account switching clear all recovery journals.

## Privacy and account boundaries

- Clerk session JWTs authenticate API requests by default. With the staged
  switch enabled, a first-party access credential authenticates after bootstrap.
  A rejected access credential is refreshed once.
- The server derives ownership from the JWT. The app never accepts or sends a user ID as an ownership selector.
- AI permission is explicit, revocable, device-local, and versioned. A verified
  bootstrap moves existing consent from the Clerk ID to the stable app user ID.
- Clerk development telemetry is disabled in the Android SDK configuration.
- The manifest requests internet access only. Future uploads must use Android's system document picker rather than broad storage permission.
- In-app and public-web account deletion both use the durable cross-system deletion process documented in the repository.

## Release status

Source and internal debug builds are ready. Release builds force first-party
Android auth off. A public first-party release remains blocked until the Play
production signing certificate is available, its Digital Asset Links entry is
published for `media.shimizu-technology.com`, and Android passkeys are tested
end to end. Clerk remains the migration fallback in that release. Run
`../scripts/android-release-preflight.sh --release` to validate current release
prerequisites without exposing secret values.
