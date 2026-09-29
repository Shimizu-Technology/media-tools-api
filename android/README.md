# Media Tools for Android

The native Android app is a Jetpack Compose client for the same account-scoped Media Tools API used by the web and iOS apps.

## Local setup

Requirements:

- Android Studio with Android 16 / API 36 installed
- JDK 17
- a Clerk development publishable key

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
credential even if Clerk's short session has expired. A server-side account
recovery/sign-in route is required before Clerk can be removed entirely.

The refresh credential and an in-progress replacement are encrypted with a
device-only Android Keystore key. The app writes the replacement before
refreshing so it can recover if the server responds but the phone loses the
response. Sign out requires server revocation and keeps the user signed in if
revocation cannot be confirmed. Android backup is disabled for this app.

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

Source and internal debug builds are ready. A public Play release remains deliberately blocked until Media Tools has a Clerk production instance and Android signing/app-listing configuration. Run `../scripts/android-release-preflight.sh --release` to validate those prerequisites without exposing secret values.
