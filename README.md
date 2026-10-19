# Activity Planet

Find your people and something to do with them this week. A plans app, not a feed: hubs for every interest, real events, real connection. First market: Georgia State University students, Atlanta, January 2027.

This repository is the v2 rebuild (started 2026-10-19). The July 2026 MVP is kept read-only in `legacy/v1/` for reference and is no longer deployed from here once `apps/web` takes over the Vercel project.

## Layout

| Path | What |
|------|------|
| `apps/web` | Next.js 16. Public site: landing, shareable event and hub pages, legal pages, `/api/health`, cron and webhook routes. Deploys to `activityplanet.app`. |
| `apps/app` | Vite + React 19 + TanStack Router. The logged-in product, served as an installable web app at `app.activityplanet.app` and later packaged with Capacitor for the stores. |
| `packages/core` | Shared Zod schemas, database types, Supabase client factory, hub catalog. |
| `packages/ui` | Design tokens and shared components. |
| `supabase/migrations` | Schema v2 migrations (Supabase CLI). |
| `docs/` | Plan, roadmap, decisions log, founder to-do, financial plan, trust/safety/legal checklist, design boards. |

## Develop

```bash
pnpm install
pnpm dev:web   # http://localhost:3000
pnpm dev:app   # http://localhost:3001
```

Copy `apps/web/.env.example` to `apps/web/.env.local` and `apps/app/.env.example` to `apps/app/.env.local`, then fill in the Supabase URL and publishable key from the Supabase dashboard (Project Settings, API Keys). The publishable key is safe in the browser; Row Level Security enforces access. The secret key is never used by client code.

## Verify

```bash
pnpm typecheck && pnpm lint && pnpm test && pnpm build
```

CI runs the same on every push. A scheduled workflow pings `/api/health` every six hours so the free-tier database never pauses.

## Where to start reading

`docs/PLAN.md`, then `docs/ROADMAP.md` and `docs/DECISIONS.md`.
