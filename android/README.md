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

## Privacy and account boundaries

- Clerk session JWTs authenticate API requests. A rejected cached JWT is refreshed once.
- The server derives ownership from the JWT. The app never accepts or sends a user ID as an ownership selector.
- AI permission is explicit, revocable, device-local, versioned, and keyed to a hash of the signed-in Clerk user ID.
- Clerk development telemetry is disabled in the Android SDK configuration.
- The manifest requests internet access only. Future uploads must use Android's system document picker rather than broad storage permission.
- In-app and public-web account deletion both use the durable cross-system deletion process documented in the repository.

## Release status

Source and internal debug builds are ready. A public Play release remains deliberately blocked until Media Tools has a Clerk production instance and Android signing/app-listing configuration. Run `../scripts/android-release-preflight.sh --release` to validate those prerequisites without exposing secret values.
