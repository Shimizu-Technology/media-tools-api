# Media Tools for Android

The native Android app is a Jetpack Compose client for the same account-scoped Media Tools API used by the web and iOS apps.

## Local setup

Requirements:

- Android Studio with Android 16 / API 36 installed
- JDK 17

No sign-in key or other secret is needed to build. Build from this directory:

```bash
./gradlew lint testDebugUnitTest assembleDebug
```

Command-line builds need the SDK location: set `ANDROID_HOME` (for example
`~/Library/Android/sdk`) or add `sdk.dir=...` to the untracked `local.properties`.

The app talks to `https://media-tools-api.onrender.com/api/v1` in every build type.

## Sign-in

Media Tools owns Android sign-in (contract: [`docs/AUTH_API.md`](../docs/AUTH_API.md)):

- **Email and password.** The device sends its password once, over TLS, and keeps
  only an opaque device session. A saved successor refresh credential lets a lost
  sign-in response recover the same session; the password is never stored.
- **Create an account** with a 6-digit email code and a password of 12 to 128
  characters. The option appears only when the server's `/health` reports
  `signup_enabled`.
- **Forgot password** emails a code, sets a new password, and signs the account out
  everywhere. Accounts that never had a password use this with their stored email.
- **Change or set a password** from Settings. Changing it signs other devices out.
- **Recovery codes** remain a secondary way in, and Settings can replace them.

Requesting a code always shows the same message, whether or not the address has an
account. Resending is throttled on the device and by the server.

### Device session

The refresh credential and an in-progress replacement are encrypted with a
device-only Android Keystore key. The app writes the replacement before
refreshing so it can recover if the server responds but the phone loses the
response. Only a refresh the server rejects (401) ends the session. A dropped
connection, timeout, 429, 5xx, or `session_refresh_in_progress` keeps the stored
credentials and retries later. Sign out requires server revocation and keeps the
user signed in if revocation cannot be confirmed. Android backup is disabled for
this app.

Sessions saved by earlier internal builds (including ones that came from the old
third-party sign-in) keep working: the stored format is unchanged, and the
device-local AI consent they recorded is moved to the stable account id once.

Settings shows the active recovery-code count and a two-step replacement flow.
The app encrypts the pending rotation ID and plaintext codes, binds them to the
stable Media Tools user ID, and activates the new set only after the user checks
that the codes were saved. Canceling leaves the old set active. Sign-out,
account deletion, and account switching clear all recovery journals.

## Privacy and account boundaries

- A first-party access credential authenticates API calls. A rejected access
  credential is refreshed once; a wrong *password* is never replayed.
- The server derives ownership from the credential. The app never accepts or sends a user ID as an ownership selector.
- AI permission is explicit, revocable, device-local, and versioned.
- The manifest requests internet access only. Future uploads must use Android's system document picker rather than broad storage permission.
- In-app and public-web account deletion both use the durable cross-system deletion process documented in the repository.

## Release status

Source and internal debug builds are ready, and release builds use the same
first-party sign-in as debug builds. No third-party sign-in SDK is bundled;
`../scripts/android-release-preflight.sh` fails if one returns or if the API host
drifts. Run it with `--release` to validate signing prerequisites without exposing
secret values. Publishing to Google Play is a separate step tracked in
`play-store/RELEASE_CHECKLIST.md`.
