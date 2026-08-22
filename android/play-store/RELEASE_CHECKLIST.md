# Google Play release checklist

## Source gates

- [x] Package name is `com.shimizutechnology.mediatools`.
- [x] `targetSdk` and `compileSdk` are API 36, meeting the August 31, 2026 submission requirement.
- [x] AGP 9.3.1 is newer than the 8.5.1 minimum for 16 KB page alignment.
- [x] Manifest requests internet only; no broad media, storage, contacts, location, advertising ID, or background permissions.
- [x] App data is excluded from Android backup and device transfer.
- [x] Clerk telemetry is disabled.
- [x] In-app account deletion and a public web deletion path are available.
- [x] Explicit account-scoped AI permission can be revoked.
- [x] Existing AI summaries are labeled and reportable in-app.
- [x] Recording consent guidance, privacy, terms, and support are available in Settings.

## External configuration before internal testing

- [ ] Confirm the Clerk development Native API warning and enable it.
- [ ] Add Android package `com.shimizutechnology.mediatools` to the Clerk development instance.
- [ ] Test sign-up, sign-in, token refresh, sign-out, and account deletion with a disposable account.

## External configuration before production

- [ ] Purchase and verify the production domain.
- [ ] Create/switch to the Clerk production instance and use a `pk_live_` publishable key outside source control.
- [ ] Create the Play Console app and reserve the package name.
- [ ] Create and securely escrow the upload key; enroll in Play App Signing.
- [ ] Complete App access instructions with a working reviewer account if sign-in is required.
- [ ] Complete Data safety from `DATA_SAFETY.md` after re-auditing production SDKs, providers, and retention.
- [ ] Enter privacy policy and account-deletion URLs.
- [ ] Complete Content rating, Target audience, Ads, News, Health apps, Financial features, and Data deletion declarations accurately.
- [ ] Provide phone, 7-inch tablet, and 10-inch tablet screenshots from the release candidate.
- [ ] Add a 512×512 icon and 1024×500 feature graphic.
- [ ] Run `scripts/android-release-preflight.sh --release`.
- [ ] Build an AAB, verify signing, and check APK splits with `zipalign -c -P 16 -v 4`.
- [ ] Test on API 24, API 36, and a 16 KB page-size emulator/device.
- [ ] Upload to Internal testing first, review the pre-launch report and automated policy checks, then promote deliberately.
