# Google Play data safety working declaration

This is the source-backed answer key for the Play Console form. Re-audit every dependency and production provider immediately before submission.

## Data handled

| Play category | Collected | Shared | Required | Purpose and handling |
| --- | --- | --- | --- | --- |
| Name and email address | Yes | No | Required for an account | Clerk processes authentication as a service provider. Data is encrypted in transit and is included in account deletion. |
| User IDs | Yes | No | Required for an account | Clerk ID and an internal opaque user ID enforce account ownership. The Android consent key stores only a one-way hash locally. |
| Audio files | When the person uploads or records | No | Optional | Sent through the Media Tools API and OpenAI transcription service only after explicit AI permission. Stored for app functionality and deleted with the account or item. |
| Files and documents | When the person uploads a PDF | No | Optional | Extracted for app functionality and deleted with the account or item. |
| Other user-generated content | When the person submits text, prompts, or report details | No | Optional | Used for transcripts, summaries, chat, and AI safety reports. Deleted with the account. |
| App interactions | Server requests and operational logs | No | Required while using the service | Security, fraud prevention, reliability, and app functionality. Retention must match the public privacy policy and infrastructure settings. |
| Device or other identifiers | Re-audit Clerk and hosting logs before release | No | SDK-dependent | Clerk telemetry is disabled in Android. Authentication and security services may still process device, network, session, and IP information. |

“Shared” above uses Google Play's service-provider exception. Confirm every production provider remains under a processor/service-provider agreement and is not using the data for its own advertising or unrelated purposes.

## Form controls

- Data is encrypted in transit: **Yes**.
- Users can request deletion: **Yes**.
- In-app deletion path: **Settings → Delete account and data**.
- Web deletion URL: `https://media-tools-gu.netlify.app/delete-account`.
- Privacy policy: `https://media-tools-gu.netlify.app/privacy`.
- Account creation: **Yes**, through Clerk authentication.
- Independent security review: answer only after obtaining the review Google describes; do not claim one from automated tests.
