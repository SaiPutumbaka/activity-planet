# Activity Planet 🪐

A modern social networking and event-discovery web app. Find campus activities,
join hubs around your interests, post events, and RSVP — built mobile-first
with a full desktop experience and light/dark themes.

## Tech stack

| Layer            | Choice                                                        |
| ---------------- | ------------------------------------------------------------- |
| Framework        | Next.js 15 (App Router) · strict TypeScript                    |
| Styling          | Tailwind CSS · Shadcn UI · next-themes (light/dark/system)     |
| Database & Auth  | Supabase (PostgreSQL + Row Level Security)                     |
| State            | React context for the session · server components for data     |
| Deployment       | Vercel                                                         |

## Features

- **Email/password auth** with confirmation emails, built on `@supabase/ssr`
  Server Actions — no client-side credential handling.
- **Forced onboarding**: username, optional organization, and a hub picker
  (College Campus Life, Basketball, Pickleball, Anime, TV Shows, Movies,
  Ping Pong, Pool).
- **Home feed** of upcoming events with category badges, times, attendee
  counts, and one-tap Join/Leave.
- **Discover** page with hub filter chips (URL-driven, shareable).
- **Create event** form with client + server validation.
- **Profile dashboard**: your hubs, events you're attending, events you
  created, sign out.
- **Responsive shell**: bottom navigation bar on mobile, side rail on desktop,
  theme toggle in both.

## Local development

### Prerequisites

- Node.js 20+ (developed on 22)
- A free [Supabase](https://supabase.com) project

### 1. Install

```bash
npm install
```

### 2. Configure environment

```bash
cp .env.example .env.local
```

Fill in both values from your Supabase dashboard → **Project Settings → API
Keys**:

```
NEXT_PUBLIC_SUPABASE_URL=https://<project-ref>.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
```

> The publishable key is safe to expose to the browser: all data access is
> enforced by Row Level Security. The app never uses the secret/service-role
> key.

### 3. Set up the database

In the Supabase dashboard → **SQL Editor**, run the migrations in order:

1. `supabase/migrations/0001_initial_schema.sql` — tables, constraints,
   indexes, and RLS policies
2. `supabase/migrations/0002_university_to_organization.sql` — renames
   `university` → `organization` and makes it optional
3. `supabase/migrations/0003_profile_customization_and_hub_features.sql` —
   avatar/birthday/location profile fields, event coordinates, the
   `hub_messages` live chat table (with Realtime enabled), and the public
   `avatars` storage bucket

### 4. Configure auth URLs

Supabase dashboard → **Authentication → URL Configuration**:

- **Site URL**: `http://localhost:3000`
- **Redirect URLs**: add `http://localhost:3000/auth/callback`

(After deploying, add your production URL and
`https://<your-domain>/auth/callback` as well.)

### 5. Run

```bash
npm run dev
```

Open http://localhost:3000, sign up with a real email, click the confirmation
link, and complete onboarding.

## Scripts

| Command             | Purpose                                     |
| ------------------- | ------------------------------------------- |
| `npm run dev`       | Start the dev server                        |
| `npm run build`     | Production build                            |
| `npm start`         | Serve the production build                  |
| `npm run lint`      | ESLint (no implicit/explicit `any` allowed) |
| `npm run typecheck` | Strict TypeScript check                     |

## Project structure

```
src/
├── actions/            # Server Actions (auth, onboarding, events)
├── app/
│   ├── (auth)/         # Public: login, signup
│   ├── (app)/          # Protected: home, discover, create, profile
│   ├── auth/callback/  # Exchanges Supabase auth links for sessions
│   └── onboarding/     # Forced first-run profile setup
├── components/
│   ├── ui/             # Shadcn UI primitives
│   └── shared/         # App shell, forms, event card, theme toggle…
├── lib/
│   ├── supabase/       # Browser + server Supabase clients
│   └── validation/     # Zod schemas shared by client forms & Server Actions
├── types/              # Database types (mirror the SQL migrations)
└── middleware.ts       # Session refresh + route protection
supabase/migrations/    # SQL to run in the Supabase SQL Editor
```

## Security model

- **RLS everywhere**: every table has Row Level Security enabled; every policy
  is scoped to authenticated users. Users can only update their own profile,
  only edit/delete events they created, and only RSVP as themselves. The
  anonymous role has no access at all.
- **Defense in depth**: database check constraints mirror the app-layer Zod
  validation (lengths, formats, category whitelist), so bad data is rejected
  even if the app layer were bypassed.
- **Server Actions only**: credentials and writes never go through client-side
  fetches; every action re-validates its input on the server with the same
  schema the form used.
- **No injection paths**: all queries are parameterized by supabase-js; text
  inputs are trimmed and stripped of control characters; React escapes all
  output.
- **Open-redirect protection**: `next` redirect params are validated to be
  internal paths.
- **Anti-enumeration**: login failures and already-registered signups return
  generic messages.
- **Security headers**: `nosniff`, `DENY` framing, strict referrer policy, and
  a locked-down permissions policy are set globally in `next.config.mjs`.

## Deployment (Vercel)

1. Push the repository to GitHub (see below).
2. In [Vercel](https://vercel.com), **Import Project** → select the repo.
   The Next.js defaults are correct.
3. Add the two environment variables from `.env.local` under
   **Settings → Environment Variables**.
4. Deploy, then update Supabase **Authentication → URL Configuration** with
   your production domain (Site URL + `/auth/callback` redirect URL).

### Initialize Git and push

```bash
git init
git add .
git commit -m "Activity Planet MVP: auth, onboarding, events, RSVPs"
git branch -M main
git remote add origin https://github.com/<your-username>/activity-planet.git
git push -u origin main
```

## Known notes

- `npm run build` prints one warning about `process.version` in
  `@supabase/supabase-js` under the Edge Runtime — it's an upstream version
  check, harmless, and does not affect the deployed middleware.
- `next lint` is deprecated by Next.js in favor of the ESLint CLI; it still
  works on Next 15. Migrate with
  `npx @next/codemod@canary next-lint-to-eslint-cli .` when convenient.
