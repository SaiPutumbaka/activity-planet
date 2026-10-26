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
Sai's call; restored 2026-10-19 via the Supabase API and verified healthy. Contents at restore: 5 auth users, 4 profiles, 1 event, 0 RSVPs, 2 chat messages; all four v1 migrations are applied (the July notes saying 0004 was missing are out of date). It stays in us-west-2 (cross-country from Vercel's default region and Atlanta users). Mitigation: upgrade to Pro so it never pauses, minimize serial round-trips per page. If latency is measurable at beta, migrate to a fresh us-east-1 project during a quiet week; schema v2 makes that cheap.

## D-009 — Work on `main`, publish continuously (2026-10-19)
Sai chose no feature branch. Every change set is verified (typecheck, lint, build) then committed and pushed; Vercel deploys main. During the rebuild, production will show work in progress; the public launch gets its own go/no-go.

## D-010 — Keep the name, buy `activityplanet.app`, get a trademark opinion (2026-10-19)
`.com` is taken. USPTO search surfaced "ACTIVITY PLANIT" and "PLANET APP" in adjacent classes. Not blocking; a short attorney consult is budgeted before brand spend.

## D-011 — Next.js 16 / React 19 / Tailwind v4 / current shadcn for v2 (2026-10-19)
v1 is Next 15.5, Tailwind 3.4, late-2024 shadcn. Rebuilding once on current versions avoids carrying a deprecated base into the stores.

## D-012 — Measure everything from day one (2026-10-19)
PostHog plus Sentry plus an admin scorecard ship in week 1. The July outage was invisible for days because nothing was measured.

## D-013 — Mobile architecture: bundled client app via a monorepo; installable web app first, stores after the evidence test (confirmed by Sai 2026-10-19, option C)
Sai chose C: launch in January as an installable web app (PWA) and submit to the App Store and Google Play after the eight-week evidence test, saving the $124 of store fees until then. The architecture below is unchanged, so the store step later is packaging, not a rebuild. Consequence: no TestFlight in the twelve weeks; Sai reviews the PWA on his iPhone; iPhone push works only after add-to-home-screen, so reminders also go by email. Original rationale:
Next.js static export cannot include server actions, middleware, cookies or dynamic route handlers, so "wrap the same Next.js app" meant a remote web view, which is the artifact Apple's guideline 4.2 rejects and which breaks Google sign-in inside the web view. Chose: `apps/web` (Next.js: marketing, public share pages with OG, legal, webhooks, cron), `apps/app` (Vite + React + TanStack Router: the logged-in product, served as a PWA and bundled into Capacitor with native sign-in, push, share, camera, offline shell, Universal Links), `packages/core` and `packages/ui`. Mutations go through RLS, Postgres RPC and Edge Functions instead of server actions. Considered: remote-URL Capacitor (rejection risk, broken OAuth), PWA-only launch with stores in February (Sai wants stores at launch), a React Native client (second codebase). Supersedes the "same Next.js app" wording of D-007.

## D-014 — Importer licensing posture: syndication feeds and organizer-connected sources only (2026-10-19)
Verified 2026-10-19: PIN's `robots.txt` disallows `/api/`; its `events.rss` is a Campus Labs Engage syndication feed with 370 upcoming items and a 60-day window; the GSU calendar's Localist API answers anonymously. Eventbrite retired public event search in 2020; Luma's and Meetup's APIs are gated behind paid tiers. Chose three lanes: institution syndication feeds (PIN RSS, Localist API) polled politely and cached; organizer-connected feeds (ICS URL, Eventbrite organization OAuth); IMLeagues if a feed exists. Imported text stays verbatim (facts, short excerpt, link); the LLM emits tags only; organizers get one-click claim or takedown. Imported events are an "also happening" shelf below human-hosted events, with a kill criterion (under 2% click-through after four weeks hides the shelf). Supersedes the connector list in the first draft of PLAN.md 4.4.

## D-015 — Supply model: student-org chapters first, launch gate on human-hosted events (2026-10-19)
PIN's upcoming events on 2026-10-19 contained 3 Athletics items and zero matches for basketball, pickup, pool, anime, pickleball or soccer, so the importer cannot make the mission real. Chose: RSO officers claim chapters as the primary supply, recruited through Sai's current-student friends before Nov 24 and again after Jan 11; chapter tools ship in week 4; one sponsoring RSO handles tabling and PIN listings. Launch gate on Jan 4: 10 recurring human-hosted events for each of the weeks of Jan 11 and Jan 19 and 5 chapters live, else chapter-only soft launch Jan 11 and public push Jan 19. Launch hubs come from RSOs that exist (basketball, volleyball, swim, running, table tennis, tennis, tabletop and TCG, anime, chess, film, dance, esports, coding and robotics), not from the 577 catalog; pickleball is an intown hub, not a campus one.

## D-016 — Store seller identity: individual accounts now, LLC later (revised 2026-10-19 by Sai; original proposal below)
Sai: "Let's wait till we have a solid product to create the LLC." Chose: individual Apple developer account and personal Google Play account now; the LLC forms at the first paid booking or 100 weekly actives (FINANCIAL-PLAN.md) and takes over both accounts. Consequences accepted: Sai's name as App Store seller, Play's 12-tester 14-day closed test, Stripe as a sole proprietor, a P.O. box or virtual mailbox for the postal address. Original proposal, superseded:
Google Play personal accounts must run a 12-tester, 14-day closed test before production and display the developer's legal address when monetizing; Apple prefers a legal entity for apps collecting sensitive data. Chose: file the LLC expedited in week 1, request the D-U-N-S immediately, enroll Apple and Play as the LLC in weeks 2 to 3. Fallback if the D-U-N-S has not arrived by Nov 13: enroll Apple as an individual and move Android to February.

## D-017 — Two store reviews (2026-10-19)
Build A (events, chapters, messaging, trust and safety, deletion; no payments) submitted Dec 8 after a Dec 5 feature freeze; build B (coaching payments, recommendations, assistant) submitted by Jan 4. Reviewed builds match production behind feature flags. Avoids both Apple's "changed after review" and "incomplete features" rejections and gives a rejection round of slack before the Dec 20 to 26 slowdown.

## D-018 — Account age minimum: 18+ at launch, 16+ with teen protections as a spring upgrade (confirmed by Sai 2026-10-19, option a)
After the options below were explained, Sai chose 18+ accounts for January with event-level 18+ and 21+ flags; lowering to 16+ with teen protections is a post-evidence project once there is a lawyer. The options as presented: (a) 18+ accounts at launch, 16+ later; (b) 16+ accounts with teen protections (adults and minors cannot message each other unless they share a chapter event; no location sharing, no coaching, no 18+/21+ events for minors; parental-consent machinery avoided because Georgia's law applies it under 16). Under 16 is out regardless (COPPA, Georgia law, App Store rating). Event flags (18+, 21+) exist in both options. Original proposal:
A strangers-meet-in-person product with open messaging, plus Georgia's social-media age law (reported enforceable as of Oct 15, 2026; attorney to confirm), makes minors a liability with no upside for a college wedge. Neutral DOB entry, no hint, no retention of failed attempts. Closes question 2 of the first plan draft.

## D-019 — Coaching listing shapes at launch (2026-10-19)
In-person one-on-one, in-person group, online one-on-one. Online group sessions are an in-app-purchase product under Apple 3.1.3(d) and are either web checkout in the system browser or post-launch. Enforced by a database constraint and stated in Coach Terms and App Review notes. Payments ship in store build B (week 10); cut-list item 2 is "pay the coach directly" at launch if build B slips.

## D-020 — Stripe Connect Express with a 12% plus $3 minimum fee (proposed 2026-10-19, pending Sai)
Express fees ($2 per active connected account per month plus 0.25% and $0.25 per payout) make a flat 12% on a $40 lesson net about $3.30; a $3 minimum keeps small bookings from being free to host. The platform, not the coach, is the party of record for disputes and negative balances; Coach Terms and the Refund Policy allocate that. Considered Standard accounts (no monthly fee, coach sees Stripe's dashboard); revisit after the first month of bookings.

## D-021 — Trust and safety ships with messaging, not after it (2026-10-19)
Image classification on every upload, message requests, symmetric blocks, report, moderator tools, a second moderator, a 48-hour NCII removal flow, an NCMEC runbook, a DMCA agent, a Child Safety Standards page and a Safety Center are launch requirements (Apple 1.2, Google Play UGC and Child Safety Standards, the Take It Down Act). Full list in `TRUST-SAFETY-LEGAL.md`.

## D-022 — Georgia State's name is used nominatively only until written permission (2026-10-19)
Chapters are "X at Georgia State Atlanta"; no "GSU" or Panther imagery in the app name, icon, screenshots or keywords; a not-affiliated line on the campus space, landing page and listings; permission is an explicit ask in the week-3 Student Engagement email. Apple 5.2.1 and the university's trademark program make this the cheapest way to keep the partnership conversation alive.

## D-023 — A hub for everything (2026-10-19)
Sai: "The goal is for there to be a category for everything, so people with all interests can have hubs." Chose: the hub taxonomy covers hobbies and sports and also campus life (careers, academics and study sessions, culture and identity, faith, service, wellness, arts, nightlife 21+, free food). Imported campus events are tagged into these hubs by the LLM, so the importer stops being a demoted shelf and becomes the thing that makes campus-life hubs useful on day one; chapters and members fill the activity hubs. Ranking by local activity keeps the long tail from looking empty. Refines D-015.

## D-024 — Lean spending with evidence triggers (2026-10-19)
Sai: no budget until there is evidence the idea has a future. Chose: free tiers everywhere plus Apple's $99, about $5 to 15 a month through March; an evidence test at eight weeks after launch; every later spend (LLC, attorney, Pro tiers) tied to a trigger; 100% of revenue reinvested; non-dilutive programs first; a fund-or-bootstrap decision in summer 2027. Full detail in FINANCIAL-PLAN.md. Accepted costs: a free database that needs a keep-alive, hobby hosting that is a gray area until revenue, template legal documents until Phase 2.

## D-025 — Design references and a new logo (2026-10-19)
Sai: Instagram and Snapchat; the old logo was a rough draft. Chose: a native-feeling consumer mobile product (white or black surfaces, one vivid accent, large type, rounded cards, bottom tabs, story-style rows, instant motion) and a redesigned mark. Three boards in week 1.

## D-026 — Coaching fee model confirmed (2026-10-19)
Sai confirmed: coaches pay Activity Planet 12% of each booking with a $3 minimum, deducted automatically; coaches define any service, price and duration. Platform absorbs Stripe processing (proposal; settle in Coach Terms).

## D-027 — 21+ events allowed, outside the campus space (2026-10-19)
Sai: all things should be allowed; 21+ events belong to non-campus hubs. Chose: 18+ and 21+ flags on events, enforced against the viewer's date of birth; the Georgia State space hides them; private addresses revealed only after host approval.

## D-028 — Second moderator deferred, but a soft-launch gate (2026-10-19)
Sai has nobody in mind yet. A named second moderator with a real role is still required before the week-11 soft launch, because the 48-hour removal clock and the 24-hour report expectation cannot depend on one phone.

## D-029 — Design direction: Plain Sight system, After Dark discipline, Field Day mark (2026-10-19)
Sai reviewed the three week-1 boards: "B and C are stylistically cleaner, but A has the idea we should brand around"; the hill, sky and ball felt organic because the app connects people with their interests and with each other, but it must not read as sports only. Chose: C's surfaces, Figtree type, radii and true-black dark mode as the system; B's rule that the primary action (Going) is the only loud element and that its text is ink, never white (white on the orange fails AA at 3.3:1, ink passes at 5.8:1); A's planet mark kept as sky over a hill, with the ball replaced. The replacement is picked from the candidates on `docs/design/boards/board-d-horizon.html` (sunrise behind the hill is the recommendation; ring, two people on the crest, a pin, and a path are the alternatives). The sun orange is the single accent so the mark and the Going button share one color; the sky blue and grass green appear only in the mark and in default event covers, never as text or buttons. Considered: keeping C's blue accent with the mark as a three-color exception (Instagram's gradient model); rejected because a second vivid color weakens the one-loud-thing rule.

## D-030 — The mark is Sunrise (2026-10-19)
Sai picked candidate 1 from the Horizon board: the orange disc drops behind the crest of the hill, so it reads as a sun coming up over a hill and cannot be read as a ball. Considered: ring, two people on the crest, pin, trail (board section 02). Consequences: the mark ships as an SVG component, favicon, PWA icon set and the default event cover; the app icon is the same scene cropped to a tile; the one-color version is a solid half sun over a horizon line; pull-to-refresh is the sun rising a little, the only place the brand animates.

## D-031 — Account deletion is immediate, with a 30-day evidence ledger and no grace period (2026-10-20)
One RPC closes the account in a single transaction (tombstone profile, private data and memberships removed, handle released for 30 days, auth user banned) and an Edge Function frees the email by soft-deleting the auth user. Considered a 14- or 30-day grace period with a `cancel_account_deletion()` RPC; rejected because Apple 5.1.1(v) and Google Play accept a deferred deletion only when it is disclosed and short, nothing in the product yet justifies a cooling-off window, a restorable state keeps every piece of personal data for the whole window, and GoTrue cannot undo a soft delete. Someone who changes their mind signs up again with the same email. Retained: the `account_deletions` row (id, hashed email, timestamps, reason) for 30 days as moderation evidence, the released handle for 30 days, payment records as tax law requires, and a tombstone with no personal data so other people's content keeps a "Deleted user" author. Full table in `TRUST-SAFETY-LEGAL.md` section 11.

## D-032 — A profile photo is required to message, not to RSVP (2026-10-26)
The plan's photo-required-to-message rule (PLAN 4.1) stays and lands with messaging in week 5; migration 7 re-creates `set_rsvp` without the `photo_required` check, so the first RSVP only asks the person to accept the community guidelines (`accept_guidelines()`, still enforced as `guidelines_required`). A photo gate at the first RSVP would stop every early tester at the first plan they tap, before there is anyone to message, while the guidelines acceptance already records the commitment moderators need.
