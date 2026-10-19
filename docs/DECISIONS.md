# Decisions Log

Format: what was chosen, what else was considered, why. Newest at the bottom.

## D-001 — Rebuild, don't restyle (2026-10-19)
Chose a v2 rebuild of schema and UI on the same stack. Considered: polishing the July 2026 code. The audit showed three palette swaps in seven commits with no product loop underneath, a four-table schema that cannot express hubs, lifecycle, status, moderation or notifications, and migrations applied by hand. Keep auth plumbing, validation, RLS conventions, hub catalog, geo helpers.

## D-002 — Wedge: GSU students first, open signup for everyone (2026-10-19)
Sai's call. Considered: intown Atlanta 18 to 35; one activity community. GSU gives density, a known "nobody hangs out on a commuter campus" problem, public event feeds, and Sai's network. Signup is open to any email; `.edu` verification unlocks campus spaces so the product can expand without a rewrite.

## D-003 — No founder-hosted events; supply = importer plus captains plus members (2026-10-19)
Sai's call. Consequence: the importer and the captain program are launch blockers, not nice-to-haves, and the feed must never be empty.

## D-004 — Import only from public feeds and APIs; never scrape login-walled sites (2026-10-19)
Sai suggested Handshake, PIN and LinkedIn. PIN (Anthology Engage) and the GSU calendar (Localist) have public JSON APIs, verified by request on 2026-10-19. Handshake and LinkedIn are behind logins and their terms forbid automated collection; LinkedIn litigates. Imported events always link out to the source registration page and show attribution.

## D-005 — Messaging everywhere, app is the destination (2026-10-19)
Sai's call. Consequence: block, report, mute, moderator tools, rate limits, photo-required-to-message and an 18+ gate ship with messaging, not after.

## D-006 — Coaching marketplace, Stripe Connect, and AI features are in scope (2026-10-19)
Sai's call. Sequenced to weeks 9 and 10 so the show-up loop ships first. Stripe Connect Express chosen over direct charges so Activity Planet never holds funds or handles KYC. Pre-agreed cut order lives in PLAN.md section 11.

## D-007 — Stores via Capacitor, not a React Native rewrite (2026-10-19)
Sai wants App Store and Play listings before launch. Considered: Expo/React Native client (second codebase, months), PWA only (no store presence). Capacitor wraps the same Next.js app with native push, share, camera and account deletion. Revisit only if store data shows the wrapper is the bottleneck.

## D-008 — Restore the existing Supabase project rather than start fresh (2026-10-19)
Sai's call; restored 2026-10-19 via the Supabase API. It stays in us-west-2 (cross-country from Vercel's default region and Atlanta users). Mitigation: upgrade to Pro so it never pauses, minimize serial round-trips per page. If latency is measurable at beta, migrate to a fresh us-east-1 project during a quiet week; schema v2 makes that cheap.

## D-009 — Work on `main`, publish continuously (2026-10-19)
Sai chose no feature branch. Every change set is verified (typecheck, lint, build) then committed and pushed; Vercel deploys main. During the rebuild, production will show work in progress; the public launch gets its own go/no-go.

## D-010 — Keep the name, buy `activityplanet.app`, get a trademark opinion (2026-10-19)
`.com` is taken. USPTO search surfaced "ACTIVITY PLANIT" and "PLANET APP" in adjacent classes. Not blocking; a short attorney consult is budgeted before brand spend.

## D-011 — Next.js 16 / React 19 / Tailwind v4 / current shadcn for v2 (2026-10-19)
v1 is Next 15.5, Tailwind 3.4, late-2024 shadcn. Rebuilding once on current versions avoids carrying a deprecated base into the stores.

## D-012 — Measure everything from day one (2026-10-19)
PostHog plus Sentry plus an admin scorecard ship in week 1. The July outage was invisible for days because nothing was measured.
