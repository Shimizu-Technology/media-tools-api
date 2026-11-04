# Media Tools Web App

React 19 + TypeScript + Vite frontend for the Media Tools workspace.

## Run locally

From the repository root:

```bash
make frontend-install
make frontend-dev
```

Vite runs at `http://localhost:5173` and proxies `/api` to the Go API at
`http://localhost:8080`. The browser signs in with first-party cookie sessions,
so the API needs `FIRST_PARTY_AUTH_ENABLED`, `FIRST_PARTY_PASSWORD_AUTH_ENABLED`
and `WEB_COOKIE_AUTH_ENABLED`, and `CORS_ORIGIN=http://localhost:5173`.
Production builds always use the same-origin `/api` path that Netlify proxies;
there are no web auth build variables. Backend, AI, database, and admin
credentials must never use a `VITE_` variable.

Local API-key mode (no account) exists only under `vite dev`: set
`VITE_LOCAL_API_KEY_MODE=true` (and optionally `VITE_API_URL`). It is compiled
out of production builds.

## Main areas

- `src/App.tsx` — public and authenticated route structure.
- `src/pages/` — landing, workspace, library, processing, item, collection,
  settings, developer, docs, and operations pages.
- `src/components/` — reusable product UI.
- `src/lib/api.ts` — authenticated API client and response types.
- `src/index.css` — Tailwind v4 setup and shared design tokens.

## Verification

```bash
npm run lint
npm run build
npm run audit:prod
```

The root `make gate` runs these checks together with backend, credential, and
available native iOS verification.
