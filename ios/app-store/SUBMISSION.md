# iOS submission source of truth

This folder keeps the App Store copy and review guidance beside the code that
implements it. Run `make ios-release-preflight` before an archive and again with
`ARCHIVE_PATH` after archiving.

## Current release status

- Version: `1.0`
- TestFlight build: `15`, the Sunrise and Studio redesign, for owner testing before submission.
- Bundle ID: `com.ShimizuTechnology.MediaTools`
- Apple team: `4T358A5S74`
- Minimum OS: iOS 18.5
- Release compiler: Xcode 26.6 / iOS 26.5 SDK
- Sign-in: Media Tools owns email and password accounts, with sign-up, email
  verification, password reset, and email change. Passkeys and recovery codes
  stay available as secondary methods. There is no third-party login. Passwords are hashed with Argon2id on the API;
  plaintext passwords are never stored on the device.
- Updating from build 13: a stored session stays signed in, and recordings and AI
  consent saved under the previous sign-in's user ID move to the same account.
- Share uploads: the Share Extension holds a key limited to `capture:upload`,
  starts the upload itself when AI consent and automatic transcription are on,
  and iOS wakes the app to finish it. Anything else leaves the share in the inbox.

Production must have `FIRST_PARTY_AUTH_ENABLED` and
`FIRST_PARTY_PASSWORD_AUTH_ENABLED` on before distributing this build, plus the
email settings in `docs/AUTH_API.md`. Create account appears only while the API
reports `signup_enabled`.

Apple requires iOS uploads to use the iOS 26 SDK or later as of April 28, 2026.
See [Submitting to the App Store](https://developer.apple.com/app-store/submitting/).

## App Store Connect fields

Use the files in `en-US/` for the localized name, subtitle, description,
keywords, promotional text, URLs, and review notes. Required screenshots remain
managed in App Store Connect because they must show the exact shipping UI.

Use these non-localized values:

- Primary category: Productivity
- Secondary category: Utilities
- Copyright: `2026 Shimizu Technology`
- Price: Free, with no in-app purchases or subscriptions
- Release: Manual until the first review is accepted
- Export compliance: no non-exempt encryption (`ITSAppUsesNonExemptEncryption`
  is `false`)
- Advertising identifier/tracking: none
- Made for Kids: no
- Unrestricted web access: no; submitted links are processed, not browsed in an
  embedded general-purpose browser
- User-generated content capability: yes, because people upload and create
  private workspace content
- Messaging and chat capability: yes, because the app includes private AI chat
- Social media, gambling, contests, ads, and commerce: no

Apple determines the final age rating from the current questionnaire. Do not
guess or force a rating outside App Store Connect. The capability answers above
are factual; objectionable-content frequency should remain `None` unless the
shipping app or its supplied content changes.

## App privacy answers

The checked-in privacy manifest and App Store privacy answers must match. Declare
collection by the developer and integrated partners for App Functionality only,
linked to the user, not used for tracking:

| App Store data type | Why it is collected |
| --- | --- |
| Name | Account authentication and display |
| Email Address | Account authentication and support identity |
| User ID | Account ownership and authorization |
| Audio Data | User-requested recording storage and transcription |
| Other User Content | URLs, PDFs, transcripts, summaries, chats, collections, and optional AI report notes |

Do not declare analytics, advertising, location, contacts, purchases, financial
information, or health data unless the implementation begins collecting them.
The app embeds no third-party SDK. Re-audit OpenAI, OpenRouter, storage, email
delivery, and any new SDK before changing the shipping binary. Apple requires the answers to include third-party partners and
to stay current; see [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/).

Set:

- Privacy Policy URL: `https://media.shimizu-technology.com/privacy`
- User Privacy Choices URL: `https://media.shimizu-technology.com/delete-account`
- Support URL: `https://media.shimizu-technology.com/support`
- Marketing URL: `https://media.shimizu-technology.com/`

## App Review prerequisites

Before selecting a build for public review:

1. Keep `FIRST_PARTY_AUTH_ENABLED` and `FIRST_PARTY_PASSWORD_AUTH_ENABLED`
   enabled, confirm email delivery works, and verify readiness after each change.
2. Confirm the signed archive passes preflight, including no third-party sign-in
   SDK or entitlement and the App Group on both the app and the Share Extension.
3. On a physical device, install over the previous build and confirm it stays
   signed in with its recordings. Then sign up, verify, reset a password, change
   email, sign out, sign in with a password, passkey, and recovery code, refresh
   after access expiry, share from Voice Memos and Files with the app closed, and
   verify account deletion recovery.
4. Create a dedicated reviewer account, verify its login, and supply its
   non-expiring credentials in App Review Information. Keep credentials out of this repository.
5. Complete the Digital Services Act trader declaration for the actual business
   and confirm the support page exposes the contact information required for the
   selected storefronts. Do not publish a private address or phone number from
   repository code without an explicit business decision.
6. Upload current iPhone and iPad screenshots that show the shipping UI and do
   not include private recordings or transcripts.
7. Confirm Content Rights, age rating, App Privacy, export compliance, and the
   app-review contact fields in App Store Connect.
8. Select the processed build, use the checked-in review notes, and keep the
   first release manual.

Apple's current field limits and requirements are documented in [Platform
Version Information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information),
[Manage App Privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/),
and [Submit an App](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/).
