# iOS submission source of truth

This folder keeps the App Store copy and review guidance beside the code that
implements it. Run `make ios-release-preflight` before an archive and again with
`ARCHIVE_PATH` after archiving.

## Current release status

- Version: `1.0`
- Next TestFlight build: `10`
- Bundle ID: `com.ShimizuTechnology.MediaTools`
- Apple team: `4T358A5S74`
- Minimum OS: iOS 18.5
- Release compiler: Xcode 26.6 / iOS 26.5 SDK
- TestFlight/App Store: build 10 addresses Apple's September 2 rejection after
  the Clerk development Apple connection and native-app mapping were enabled.
  The checked-in `native-auth-release.json` records the dashboard mapping that
  release preflight requires. The owner has explicitly chosen to keep the Clerk
  development instance for this release; re-audit that decision before a future
  production migration.

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
Re-audit Clerk, OpenAI, OpenRouter, storage, and any new SDK before changing the
shipping binary. Apple requires the answers to include third-party partners and
to stay current; see [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/).

Set:

- Privacy Policy URL: `https://media-tools-gu.netlify.app/privacy`
- User Privacy Choices URL: `https://media-tools-gu.netlify.app/delete-account`
- Support URL: `https://media-tools-gu.netlify.app/support`
- Marketing URL: `https://media-tools-gu.netlify.app/`

## App Review prerequisites

Before selecting a build for public review:

1. Confirm the shipping Clerk environment advertises both Apple and Google and
   retains the iOS native-app mapping for this bundle ID. Update
   `native-auth-release.json` only after confirming the mapping in Clerk's
   dashboard; the preflight pins its tenant, Apple team, and bundle ID.
2. Verify native Apple and Google sign-in, Hide My Email, sign-out, and account
   deletion on a physical device.
3. Supply a non-expiring reviewer account in App Review Information. Keep its
   credentials out of this repository.
4. Complete the Digital Services Act trader declaration for the actual business
   and confirm the support page exposes the contact information required for the
   selected storefronts. Do not publish a private address or phone number from
   repository code without an explicit business decision.
5. Upload current iPhone and iPad screenshots that show the shipping UI and do
   not include private recordings or transcripts.
6. Confirm Content Rights, age rating, App Privacy, export compliance, and the
   app-review contact fields in App Store Connect.
7. Select the processed build, use the checked-in review notes, and keep the
   first release manual.

Apple's current field limits and requirements are documented in [Platform
Version Information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information),
[Manage App Privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/),
and [Submit an App](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/).
