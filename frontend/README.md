# Media Tools Web App

React 19 + TypeScript + Vite frontend for the Media Tools workspace.

## Run locally

From the repository root:

```bash
make frontend-install
make frontend-dev
```

Vite runs at `http://localhost:5173` and proxies `/api` to the Go API at
`http://localhost:8080`. Use `frontend/.env.example` only for public client
configuration. `VITE_CLERK_PUBLISHABLE_KEY` is safe to expose; backend, AI,
database, and admin credentials must never use a `VITE_` variable.

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
