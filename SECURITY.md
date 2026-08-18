# Security and Credential Handling

## Rules for contributors and operators

- Never commit `.env`, cookies, private keys, service-account files, database
  URLs, bearer tokens, or real API keys.
- Keep backend secrets only in local ignored `.env` files and the deployment
  provider's encrypted environment settings.
- Variables prefixed with `VITE_` are included in the browser bundle. Only
  public client configuration, such as a Clerk publishable key, belongs there.
- iOS binaries also cannot hold secrets. The Clerk publishable key and API URL
  are configuration, not credentials; backend/AI/admin secrets must stay on the
  server.
- Treat yt-dlp cookie files and `YT_DLP_COOKIES_B64` as credentials. Restrict
  access, rotate the underlying session when exposed, and never attach their
  content to an issue or pull request.
- Raw Media Tools API keys are shown once. The database stores only their hash.

## Local protection

Copy `.env.example` to `.env`; `.env` and frontend environment files are
gitignored. Before committing, run:

```bash
make security-scan
make gate
```

The scanner checks the complete committed history and a snapshot containing
tracked files plus non-ignored untracked files. It deliberately excludes local
ignored `.env` files, while still catching a credential if someone stages it or
places it in a source/documentation file. Findings are fully redacted.

Gitleaks is downloaded from its pinned official release and verified against
the publisher's SHA-256 digest pinned in the install script before execution.
`.gitleaks.toml` allows only specific documentation placeholder patterns; no
file is exempted wholesale.

## Production requirements

When `GIN_MODE=release`, startup refuses:

- a missing, default, or shorter-than-32-character `JWT_SECRET`;
- a missing or shorter-than-32-character `ADMIN_API_KEY`; or
- Clerk authentication without an audience/authorized-party boundary (or a
  single explicit production `CORS_ORIGIN` from which one can be inferred).

Generate independent random values; do not reuse a Clerk, OpenAI, OpenRouter,
AWS, database, or Media Tools API credential.

```bash
openssl rand -base64 48  # JWT_SECRET
openssl rand -hex 32     # ADMIN_API_KEY
```

The bootstrap admin-key comparison uses constant-time digest comparison. Clerk
and API-key protected media routes still enforce record ownership in the API;
clients are not trusted to filter another user's data.

## If a credential is exposed

1. Revoke or rotate it at the issuing provider immediately. Deleting a commit
   or resolving a scanner alert does not invalidate the credential.
2. Inspect provider audit/usage logs for unexpected access.
3. Update the encrypted deployment/local value and redeploy affected services.
4. Remove the value from the current branch. Coordinate separately before any
   shared-history rewrite because rewriting published Git history is disruptive
   and does not replace rotation.
5. Document the incident without reproducing the secret.

## Reporting

Do not open a public issue containing exploit details or credentials. Contact
the Shimizu Technology repository owner privately with the affected surface,
time observed, and a redacted description.
