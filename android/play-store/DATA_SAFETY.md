# Google Play data safety working declaration

This is the source-backed answer key for the Play Console form. Re-audit every dependency and production provider immediately before submission.

## Data handled

| Play category | Collected | Shared | Required | Purpose and handling |
| --- | --- | --- | --- | --- |
| Name and email address | Yes | No | Required for an account | Media Tools stores the email (and an optional name) to run sign-in. The email provider, Resend, receives the address and the message to deliver verification and password-reset codes as a service provider. Data is encrypted in transit and is included in account deletion. |
| User IDs | Yes | No | Required for an account | An internal opaque user ID and device-session ID enforce account ownership. The Android consent key stores only a one-way hash locally. |
| Audio files | When the person uploads or records | No | Optional | Sent through the Media Tools API and OpenAI transcription service only after explicit AI permission. Stored for app functionality and deleted with the account or item. |
| Files and documents | When the person uploads a PDF | No | Optional | Extracted for app functionality and deleted with the account or item. |
| Other user-generated content | When the person submits text, prompts, or report details | No | Optional | Used for transcripts, summaries, chat, and AI safety reports. Deleted with the account. |
| App interactions | Server requests and operational logs | No | Required while using the service | Security, fraud prevention, reliability, and app functionality. Retention must match the public privacy policy and infrastructure settings. |
| Device or other identifiers | Device model name and session records | No | Required while signed in | The phone model is sent at sign-in so the account can list and revoke its devices. The server also processes network and IP information for security and rate limiting. No advertising ID or analytics SDK is used. Re-audit hosting logs before release. |

“Shared” above uses Google Play's service-provider exception. Confirm every production provider remains under a processor/service-provider agreement and is not using the data for its own advertising or unrelated purposes.

## Form controls

- Data is encrypted in transit: **Yes**.
- Users can request deletion: **Yes**.
- In-app deletion path: **Settings → Delete account and data**.
- Web deletion URL: `https://media.shimizu-technology.com/delete-account`.
- Privacy policy: `https://media.shimizu-technology.com/privacy`.
- Account creation: **Yes**, with a Media Tools email and password. No third-party sign-in service or SDK is used.
- Independent security review: answer only after obtaining the review Google describes; do not claim one from automated tests.

## Passwords and sign-in

- A password is typed in the app and sent once over TLS. The app never writes it to disk, logs, or backups, and Android backup is disabled. Play has no separate data type for credentials; they are disclosed here and covered by the account-creation answer.
- The server stores only a salted Argon2id hash. When a new password is set, the server checks it against Have I Been Pwned with a 5-character hash prefix; the password and full hash never leave the server.
- Verification and reset codes are stored as hashes, expire after 10 minutes, and are never logged.
- Re-audit before submission: the Resend agreement (service-provider terms, no use of the data for its own purposes) and hosting logs.
