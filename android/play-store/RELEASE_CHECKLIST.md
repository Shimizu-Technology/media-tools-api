# Google Play release checklist

## Source gates

- [x] Package name is `com.shimizutechnology.mediatools`.
- [x] `targetSdk` and `compileSdk` are API 36, meeting the August 31, 2026 submission requirement.
- [x] AGP 9.3.1 is newer than the 8.5.1 minimum for 16 KB page alignment.
- [x] Manifest requests internet only; no broad media, storage, contacts, location, advertising ID, or background permissions.
- [x] App data is excluded from Android backup and device transfer.
- [x] Sign-in is first-party in every build type; no third-party sign-in SDK or key is bundled, and `scripts/android-release-preflight.sh` fails if one returns.
- [x] API host is `https://media-tools-api.onrender.com/api/v1` and is checked by the preflight.
- [x] Sign-up appears only when the server reports `signup_enabled`.
- [x] In-app account deletion and a public web deletion path are available.
- [x] Explicit account-scoped AI permission can be revoked.
- [x] Existing AI summaries are labeled and reportable in-app.
- [x] Recording consent guidance, privacy, terms, and support are available in Settings.

## External configuration before internal testing

- [ ] Confirm the server has first-party password auth enabled and real email delivery verified (see `docs/AUTH_API.md`, "Availability and rollout").
- [ ] Test sign-in, sign-out, token refresh after the access token expires, change password, forgot password, and account deletion (which asks for the password) with a disposable account.
- [ ] If `signup_enabled` is on: test sign-up with the emailed code, resend, and a wrong code.
- [ ] Update from an earlier internal build that has a stored session and confirm it stays signed in.

## External configuration before production

- [ ] Purchase and verify the production domain.
- [ ] Create the Play Console app and reserve the package name.
- [ ] Create and securely escrow the upload key; enroll in Play App Signing.
- [ ] Complete App access instructions with a working email-and-password reviewer account if sign-in is required.
- [ ] Complete Data safety from `DATA_SAFETY.md` after re-auditing production SDKs, providers, and retention.
- [ ] Enter privacy policy and account-deletion URLs.
- [ ] Complete Content rating, Target audience, Ads, News, Health apps, Financial features, and Data deletion declarations accurately.
- [ ] Provide phone, 7-inch tablet, and 10-inch tablet screenshots from the release candidate.
- [ ] Add a 512×512 icon and 1024×500 feature graphic.
- [ ] Run `scripts/android-release-preflight.sh --release`.
- [ ] Build an AAB, verify signing, and check APK splits with `zipalign -c -P 16 -v 4`.
- [ ] Test on API 24, API 36, and a 16 KB page-size emulator/device.
- [ ] Upload to Internal testing first, review the pre-launch report and automated policy checks, then promote deliberately.
