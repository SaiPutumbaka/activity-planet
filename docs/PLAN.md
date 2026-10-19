# Activity Planet — Business & Product Plan (v2)

Owner: Sai Putumbaka · Written: 2026-10-19 · Revised: 2026-10-19 after a three-lens critique (feasibility, business, compliance) · Status: living document.
Companion files: `DECISIONS.md` (why each call was made), `ROADMAP.md` (week-by-week), `FOUNDER-TODO.md` (things only Sai can do), `TRUST-SAFETY-LEGAL.md` (compliance checklist).

---

## 1. What Activity Planet is

Activity Planet turns shared interests into real-world plans. You pick what you love (pickup basketball, pool, anime, board games, running, coding), you see everything happening around you for those interests this week, you tap Going, you chat with the people going, you show up. Anyone can post a plan. Student orgs and verified captains run recurring ones. Coaches can offer paid sessions. The app also shows what is already happening on campus and in the city so there is always something to do.

Positioning: **a plans app, not a feed.** The mission copy stays (loneliness epidemic, "social media made us reachable, not less alone"), but the pitch is "find your people and something to do with them this week."

Wedge: Georgia State University's Atlanta campus, Spring 2027. Open to anyone with any email from day one; a verified `.edu` address unlocks campus-only spaces (Georgia State first). Expansion path: other Atlanta campuses, then intown Atlanta 18 to 35, then other cities.

## 2. Decisions locked on 2026-10-18/19

| # | Question | Decision |
|---|----------|----------|
| 1 | First market | GSU Atlanta-campus students first, Spring 2027 launch. Open signup for everyone. |
| 2 | Event supply | Founder does not host. Supply = student-org chapters and verified captains (primary), member-posted events, and an imported "also happening" shelf from licensed feeds. |
| 3 | Founder presence | None on campus day to day. Product must work without the founder in the room. |
| 4 | Campus permission | Plan around events that need no permission. One sponsoring student org is needed for tabling and PIN listings (see 8.4). GSU administration partnership is an outreach track, not a dependency. |
| 5 | Identity | Any email can sign up. `.edu` verification plus declared campus required for campus spaces. 18+ only. |
| 6 | Messaging | Everything: DMs, group chats, event chats, hub chats. The app is the destination, not a layer on GroupMe. |
| 7 | Scope | Coaching marketplace, payments, and AI are in. Sequenced so the show-up loop ships first; cut order pre-agreed in section 11. |
| 8 | Platform | Web, installable PWA, and App Store / Play listings at launch via a bundled Capacitor app (see 4.10 and D-013). |
| 9 | Metrics | All of them, with human-hosted and imported events reported separately. |
| 10 | Accelerator | Main Street Foundry was missed in 2026. Cohort 7 application is expected to open around Jan 18 to 30, 2027; draft it in December. |
| 11 | Database | Restore the existing Supabase project (done 2026-10-19; healthy; 5 test users). |
| 12 | Brand | Keep the name. Buy `activityplanet.app`. Discord server set up before soft launch. |

Three honest notes on these decisions:

- **Scope vs. clock.** Twelve weeks to January 11 with one founder plus an AI builder is tight. The roadmap sequences the show-up loop first because nothing else matters if nobody comes back. Coaching payments and the AI assistant land in the second store build (early January). If we slip, section 11 says what gives.
- **Imported events are a shelf, not the feed.** The campus feeds are real and public (PIN's RSS has 370 upcoming events; the GSU calendar has 613), but almost none of it is pickup sports or hobby nights: on 2026-10-19 PIN listed 3 Athletics events and zero matches for basketball, pickup, pool, anime, pickleball or soccer. The feed that makes the mission real comes from student orgs that already run Tuesday practice and Thursday anime night. The importer keeps the app from ever looking dead; the chapters make it worth opening.
- **No scraping, no undocumented endpoints.** Handshake and LinkedIn are login-walled and their terms forbid automated collection. PIN's `robots.txt` disallows its `/api/` path, so we use its RSS syndication feed and ask Student Engagement for an official Engage API key. Eventbrite retired public event search in 2020; Luma and Meetup gate their APIs behind paid tiers. We import only from syndication feeds, documented APIs, and feeds an organizer connects themselves, and every imported card links to the source.

## 3. Who it is for

Primary (launch): GSU Atlanta-campus students, especially the 4,000 to 5,000 who live downtown (Piedmont Central, University Commons, Piedmont North, Patton Hall, University Lofts) and are still on campus at 8 p.m. Two personas from the June interview guide: the athlete organizing pickup games, and the hobbyist burned by fake users on Activitybees.

Secondary (launch): officers of registered student organizations (RSOs) who already run recurring things and want an RSVP list and new members: Basketball Club, Men's Volleyball Club, Swim Club, Run Club at GSU, Table Tennis at GSU, Tennis clubs, Tabletop Club, Trading Card Game Club, Anime Club, Chess Club, Film Society, dance clubs, esports, PantherDev, Robotics Club. PIN lists 616 orgs with public contacts.

Tertiary (launch, small): coaches and instructors (fitness, tennis, tutoring, music) who want students to find and book them.

Later: Atlanta 18 to 35 across campuses and neighborhoods. Note that Perimeter College's five suburban campuses share the `student.gsu.edu` domain, so the campus space keys on domain plus declared campus, and chapters are named by place ("Basketball at Georgia State Atlanta").

## 4. The product (v2 scope)

Tag legend: **A** = store build A and web, by Dec 8 · **B** = store build B and web, by Jan 4 · **P** = post-launch, Feb to May 2027.

### 4.1 Identity and onboarding
- **A** Email+password, Google sign-in, Sign in with Apple (equal prominence everywhere Google appears), magic link, password reset, resend confirmation, cross-device-safe `token_hash` email links, Turnstile, leaked-password protection.
- **A** Native Google and Apple sign-in inside the mobile app (Google blocks OAuth in embedded webviews), finishing with Supabase `signInWithIdToken`.
- **A** Profile: real first name, photo (required to RSVP or message), handle, bio, interests, campus or neighborhood, date of birth (private; neutral entry screen; 18+ enforced).
- **A** `.edu` verification: a one-time code to a second email, matched against `organizations.email_domains`, plus a declared campus. Unlocks the campus space.
- **A** Onboarding ends in an action: pick interests, see this week near you, tap Going. Under two minutes.
- **A** Account settings: change email/password, notification preferences, privacy toggles, data export, and delete account (in-app and at a public web URL; revokes Apple tokens; anonymizes messages others received; fans out to processors; retains only moderation evidence and payment records under a stated policy).

### 4.2 Hubs, chapters and spaces
- **A** Hubs are database rows: slug, name, category, emoji/cover, description, member count, activity score. Seeded from the 577-entry catalog after pruning synonyms; about 40 visible at launch, the rest behind search and "request a hub."
- **A** Chapters: a hub scoped to an organization and campus ("Table Tennis at Georgia State Atlanta") with its own chat, events, captains and member count. An RSO officer claims a chapter; this is the primary supply mechanism.
- **A** Spaces: the Georgia State space shows chapters, campus events and the imported campus shelf to verified students on the Atlanta campus. Copy carries "Not affiliated with or endorsed by Georgia State University" until written permission exists.
- **A** Hub page: next events, members, chat, captains, "start an event here."
- **P** User-created hubs with light review.

### 4.3 Events (the social object)
- **A** Three kinds, one card design: *Chapter or captain-hosted*, *Member-posted*, *Imported* (facts, a short excerpt, source attribution and a Register button to the source).
- **A** Event page with full description, venue, map pin, attendee avatars, host card, event chat, share link that works logged out with an OG image, Add to Calendar. Public-venue default; private addresses revealed only after host approval. A 21+ flag that the campus space rejects.
- **A** RSVP states: going / interested / waitlisted / cancelled. Host auto-RSVPs. Capacity and waitlist. Optional "happens if N join" minimum headcount.
- **A** Edit, cancel (attendees notified), weekly recurrence materialized as occurrences (RSVP per occurrence). Full recurrence editing is **P**.
- **A** Check-in and the morning-after prompt ("Did you go? Who did you meet?"). This measures the mission and feeds "people you've met."
- **A** Feed: location-first, interest-ranked, Today / This week / Later, filters by distance, hub, kind, free/paid. Human-hosted events rank above the imported shelf.
- **P** Event photos, co-hosts, tickets for paid non-coaching events.

### 4.4 Importer (the "also happening" shelf)
- **A** Three licensed lanes over a `feed_sources` allowlist:
  1. **Institution syndication**: PIN `events.rss` (Campus Labs Engage syndication feed; 60-day window; polled at or under 1 request per 5 minutes) and the GSU Calendar Localist API (`/api/2/events`, paginated, cached, under 1 request per second). Filter PIN by hosting organization (Recreational Services, Athletics, the sport and hobby RSOs) rather than by theme.
  2. **Organizer-connected feeds**: a host pastes their own ICS URL (Luma, Meetup group, Google Calendar), or connects Eventbrite by OAuth for their organization. Shipped at launch, not post-launch.
  3. **IMLeagues** (GSU intramurals and open rec) if a feed or export exists; feasibility check in week 7.
- **A** Pipeline: fetch per source as a scheduled job, normalize, dedupe on (source, external id, occurrence start) plus a content hash, geocode once into a `venues` table, tag hubs with the LLM (tags and dedupe signals only; the LLM never rewrites titles or descriptions), store the raw payload, mark cancelled when a source stops returning an event for two runs.
- **A** Display: title, time, venue, about 300 characters of excerpt, source name and link; images hotlinked from the feed, never re-hosted. One-click claim or takedown for the organizer.
- **A** Health panel in admin; kill criterion: if imported-event click-through is under 2% after four weeks, the shelf is hidden.
- **Not doing:** Handshake, LinkedIn, Eventbrite city search, PIN's `/api/discovery`, or anything behind a login or against terms.

### 4.5 Chapters and captains
- **A** RSO officers claim a chapter (verified by their PIN listing or `.edu` plus a reference). Informal captains apply: government-ID check via Stripe Identity (about $1.50) plus one reference plus a signed Captain Program agreement. The badge tooltip and the ToS say exactly what "verified" means (identity plus reference, not a background check).
- **A** Chapter and captain tools: weekly recurring events, attendee management (remove, message all), a dashboard (attendance over time), a public chapter or captain profile. Shipped in week 4 so RSOs can enter spring schedules before winter break.
- **A** Target: 5 RSO chapters with spring schedules entered by Nov 23; 10 recurring human-hosted events per week confirmed for the weeks of Jan 11 and Jan 19 (this is the launch gate in section 7); more chapters recruited Jan 11 to 22 when students are back.
- **P** Captain perks (featured placement, early access to coaching tools).

### 4.6 Messaging
- **A** DMs, group chats, event chats, hub and chapter chats. Supabase Realtime Broadcast from database triggers, optimistic send, newest-first history with infinite scroll, unread counts and mute (`last_read_at`, `muted_until`), typing indicator, image sharing with moderation.
- **A** Safety built in: message requests for first contact with someone you share no event or hub with (no images or links until accepted; accounts under 24 hours old cannot send requests), block (symmetric; blocked users cannot see your RSVPs; warning when someone you blocked RSVPs to your event), report, mute, delete own message, moderator delete (soft delete), rate limits, link and profanity filter, every uploaded image classified before it is visible. Messaging requires a photo on the profile.
- **P** Reactions, read receipts, voice notes, link previews.

### 4.7 Coaching marketplace
What "coaching" means here: any person offering a skill for money. Tennis lessons, personal training, tutoring, guitar, pickleball clinics.
- **A** Coach profile (credentials, rates, photos, reviews), listings, availability calendar, booking request and confirmation, messaging with the client, reviews after a completed session. Each listing has a delivery (in person / online) and a format (one-on-one / group).
- **B** Payments via **Stripe Connect Express**: the coach onboards to Stripe (identity checks, tax forms, payouts handled by Stripe), the student pays in-app by card or Apple/Google Pay, Activity Planet takes a platform fee (proposed 12% with a $3 minimum), refunds follow the published policy. Activity Planet never touches card numbers, but as the platform it is the party of record for disputes and negative balances; that is why Coach Terms and the Refund Policy matter.
- **B** Launch listing shapes: in-person one-on-one, in-person group, online one-on-one. Online group sessions are an in-app-purchase product under Apple's rules, so they either open web checkout in the system browser or wait for **P**. Enforced by a database constraint, stated in Coach Terms and in App Review notes.
- **B** Coach Terms incorporate the Stripe Connected Account Agreement and require 18+, US work authorization (relevant for international students), venue permission, independent-contractor status, self-reported credentials.
- **P** Packages, subscriptions, group-clinic ticketing, coach analytics.

### 4.8 AI
What "AI matching" means here, in three layers:
1. **A** **Import intelligence**: an LLM tags imported events with hubs, extracts venues and times, flags duplicates and spam. Tags and signals only; the source text stays verbatim.
2. **B** **Recommendations**: ranked hubs, events, people and coaches for you, from interests plus location plus schedule plus what you RSVP'd to plus what similar users did. Embeddings via Supabase's built-in model (no new vendor) in `pgvector`; rules first, learned ranking later.
3. **B** **Assistant**: "I'm free Thursday night, what should I do?" or "find me a tennis coach under $40 near Midtown." Answers from live data and drafts actions (RSVP, message, booking) that the user confirms with a tap; it never sends or charges on its own. Labeled as AI; every proposed action logged. Falls to **P** if weeks 1 to 9 slip.
- **P** Smart matchmaking ("3 people in your hub are also free Thursday"), weekly digests per user.

### 4.9 Notifications
- **A** In-app inbox, email (Resend from `activityplanet.app`, registered with Apple's private email relay so Hide My Email users receive mail), push (APNs/FCM via `push_devices`; web push for installed PWA). RSVP confirmation plus calendar file, day-before and 2-hour reminders, "someone joined your event," "new event in your hub this week," message notifications, post-event check-in prompt, weekly digest (with postal address, per CAN-SPAM).

### 4.10 Mobile and the stores
- **A** Installable PWA at `app.activityplanet.app`.
- **A** iOS and Android apps built with **Capacitor** around a bundled client build of the product (not a remote web view): native tab bar feel, offline shell, native Sign in with Apple and Google, push, share sheet, camera, Universal Links / App Links from share URLs, in-app browser for outbound registration links, account deletion in two taps. Built on GitHub Actions macOS runners (free for the public repo) with fastlane; reviewed on Sai's iPhone via TestFlight from week 3.
- **A/B** Two store reviews: build A (events, chapters, messaging, trust and safety, deletion; no payments) submitted Dec 8; build B (coaching payments, recommendations, assistant) submitted by Jan 4. Reviewed builds match what is live, behind feature flags.
- **A** Store identity: Activity Planet LLC (organization accounts; needs the LLC and a D-U-N-S number in week 1 to 3). Fallback if D-U-N-S slips past Nov 13: enroll Apple as an individual and move Android to February rather than run Play's 12-tester, 14-day closed test under a personal account.
- **P** A React Native client only if store data says the Capacitor app is the bottleneck.

### 4.11 Trust, safety, legal
Full checklist in `TRUST-SAFETY-LEGAL.md`. Headlines:
- **A** 18+ only. Community Guidelines (with child-safety and 21+ language) accepted at first RSVP. "Meet in public places" plus a Safety Center page linked from every event and the DM composer. Report and block everywhere. Moderator role for Sai and a named second moderator; 24-hour response target on reports; 48-hour removal for non-consensual intimate imagery with a public request page; NCMEC reporting runbook; DMCA agent registered; public Child Safety Standards page (Google Play requirement).
- **A** Public profile shows no email, no birthday, no exact location; distance shown in bands; private data split from public at the database level; PostHog session replay off; Sentry PII scrubbing on.
- **A** Documents live on the domain by Nov 16: Terms, Privacy, Community Guidelines, Child Safety Standards, NCII Removal, Support/Contact, Account Deletion page; by week 9: Coach Terms and Refund/Cancellation Policy; Captain Program agreement by week 4. Attorney review of the set and of Georgia's social media age law before launch.
- **A** Georgia State's name used nominatively only ("at Georgia State"), never in the app name, icon, screenshots or keywords; disclaimer shown until written permission.
- **A** Accessibility: WCAG 2.1 AA tokens, focus states, labels, reduced motion; a VPAT before any GSU procurement conversation.

### 4.12 Analytics and admin
- **A** PostHog with the full funnel: landing, signup, confirmed, onboarded, first RSVP, attended, attended again. Events: hub join, chapter claim, event view, share, message sent, booking, check-in, imported-event click.
- **A** Admin panel: live numbers (signups, WAU, human-hosted events this week, imported shelf clicks, events with 4+ checked-in attendees, unique attendees, second-attendance rate, chapters active, messages, bookings, GMV), moderation queue with SLA timers, user lookup, ban, importer health.
- **A** Weekly scorecard auto-emailed to Sai.

## 5. Architecture

Keep from v1: the Zod validation layer, the RLS policy conventions, the hub catalog as seed data, geo helpers, the Supabase auth callback and cookie patterns for the web. Replace: the schema, the UI, the palette, the hand-pasted migration process, and server actions as the mutation layer (they cannot ship inside a bundled mobile app).

| Layer | Choice | Why |
|-------|--------|-----|
| Repo | Monorepo: `apps/web` (Next.js 16: marketing, public event and hub share pages with OG images, legal pages, webhooks, cron routes), `apps/app` (Vite + React 19 + TanStack Router: the logged-in product, served as a PWA and bundled into Capacitor), `packages/core` (types, Zod schemas, Supabase client, API helpers) | One product codebase that runs identically on web and in the stores; SEO pages where SEO matters. See D-013. |
| Styling | Tailwind v4 plus current shadcn/ui, custom design system in `packages/ui` | v1 is two generations behind; rebuild once. |
| Data/Auth | Supabase (restored project `gtesfiqxqontescqpllo`, us-west-2), Postgres 17 with PostGIS and pgvector, RLS everywhere, Supabase CLI migrations, generated types, a staging project | Hand-pasted migrations caused the July outage. Pro plan so it never pauses. |
| Mutations | RLS-protected inserts/updates from the client, Postgres RPC for multi-step writes, Edge Functions (service role) for privileged work: deletion, moderation, notifications, Stripe, importer | Works from a bundled app; no server actions. |
| Realtime | Supabase Realtime Broadcast from triggers (private channels) | Supabase's recommended path; v1's `postgres_changes` per-listener RLS does not scale. |
| Jobs | pg_cron as scheduler, Supabase Queues (pgmq) plus small Edge Function workers (importer fetch, geocode, tag, reminders, digests) | Edge Functions have a 2-second CPU cap per invocation; one job per page or feed, not one giant run. |
| Email | Resend (custom domain; also Supabase Auth's SMTP; `token_hash` templates) | Supabase's built-in sender throttles. |
| Push | Capacitor push (FCM/APNs) via `push_devices`; web push for PWA | |
| Payments | Stripe Connect Express, webhooks idempotent via `stripe_events` | Standard for marketplaces. |
| AI | Claude API (tagging, assistant with confirm-before-act tools); Supabase built-in embeddings (gte-small) in pgvector | Anthropic has no embeddings model; Supabase's is free and on-platform. |
| Maps/geo | MapTiler tiles; Geoapify geocoding (terms allow stored results) into a `venues` table; PostGIS `ST_DWithin` for the feed radius | Mapbox and Google forbid storing geocodes long-term; OSM/Nominatim from the browser violates policy. |
| Moderation | Sightengine (or Hive) image classification on every upload; perceptual hashing for repeat NCII | Required by Apple 1.2 and Play UGC policy for an app with image DMs. |
| Analytics/errors | PostHog (replay off), Sentry (PII scrub) | v1 had neither. |
| Mobile | Capacitor 8; GitHub Actions macOS + fastlane for iOS; Gradle on Linux runners for Android | Windows laptop; public repo gets free macOS minutes. |
| Hosting | Vercel Pro (web and app), Supabase Pro + staging | Hobby forbids commercial use. |
| CI/CD | GitHub Actions: typecheck, lint, tests, schema drift check; on push to main: `supabase db push` to staging, then prod, then a Vercel deploy hook (Vercel Git auto-deploy off); `/api/health` selects the newest columns | Code must never deploy ahead of its migration again. |

Schema v2 (summary): `profiles` (public) + `profile_private` (email, birthday, precise location, `apple_refresh_token`) · `organizations` (`email_domains[]`, campuses) + `org_memberships` + `verified_emails` (OTP) · `hubs` + `hub_chapters` + `hub_members` + `event_hubs` · `events` (kind, status, visibility, `starts_at`, `ends_at`, timezone, capacity, `min_headcount`, `venue_id`, `is_21_plus`, `external_url`, `chapter_id`) + `event_occurrences` + `rsvps` (status, `checked_in_at`, waitlist position) + `venues` (normalized address, PostGIS point) + `feed_sources` + `event_imports` (source, external id, raw, hash, `last_seen_at`) · `conversations` + `conversation_members` (`last_read_at`, `muted_until`) + `messages` (`deleted_at`) + `message_requests` · `captain_applications` + `verifications` · `coaches` (`stripe_account_id`) + `listings` (delivery, format, constraint) + `availability` + `bookings` + `payments` (intent, fee, transfer, refund ids) + `stripe_events` + `reviews` · `notifications` + `notification_prefs` + `push_devices` · `reports` + `blocks` + `moderation_actions` + `takedown_requests` · `user_roles` · `analytics_events`.

## 6. Design direction

The brown palette goes. The new identity needs: one energetic action color (Going is the most alive thing on screen), semantic state colors (going, live, full, cancelled, imported), a small category color system so hubs don't rely on emoji, one type family that works in the app and on the landing page, a mark that reads as people/places/play rather than a Saturn ring, a full icon/OG/manifest set, and WCAG 2.1 AA contrast baked into the tokens. The original logo (blue wave, orange peaks, green hill with sun) says "outdoors and energy" and is a better starting mood than the café palette. Final direction is chosen with Sai in week 1 from three candidate boards.

## 7. Timeline and launch gate

Twelve weeks from 2026-10-20 to GSU's first day of spring classes, **Monday 2027-01-11** (University System of Georgia calendar; drop/add Jan 11 to 15; MLK holiday Jan 18; most RSOs restart the week of Jan 19; spring break Mar 15 to 21; classes end Apr 26). Detail in `ROADMAP.md`. Shape:

- **Weeks 1 to 2** Foundation: monorepo, schema v2, CLI migrations and CI, auth, design system, shell, analytics, errors, email, deletion. LLC and store accounts in motion.
- **Weeks 3 to 4** Show-up loop and chapter tools: hubs, chapters, events, RSVP, event page and share, reminders, check-in, feed; first TestFlight build; legal pages live.
- **Weeks 5 to 6** Messaging, trust and safety, admin, Stripe account.
- **Weeks 7 to 8** Importer, native app layer, feature freeze Dec 5, **store build A submitted Dec 8**; coaching profiles start.
- **Weeks 9 to 10** Coaching, Stripe checkout, assistant; Foundry application drafted.
- **Weeks 11 to 12** Recommendations, landing page v2, QA, **store build B by Jan 4**, soft launch Dec 29 to Jan 4, go/no-go Jan 8, public launch Jan 11, tabling Jan 12 to 15, second push Jan 19 to 29.

**Launch gate (checked Jan 4):** at least 10 recurring human-hosted events confirmed for each of the weeks of Jan 11 and Jan 19, and at least 5 RSO chapters live. If fewer than 5 events, Jan 11 becomes a chapter-only soft launch and the public push moves to Jan 19.

## 8. Business track

1. **Entity and money (week 1).** Georgia LLC with expedited processing, EIN the same day, registered agent or virtual mailbox (a postal address is needed on every email and must not be Sai's home), business bank account, D-U-N-S number request the day the LLC is approved (needed for Apple and Play organization accounts), DMCA designated agent ($6). Stripe account under the LLC in week 6, once legal pages are live.
2. **Name, domain, marks.** `activityplanet.com` is taken; buy `activityplanet.app` ($9.99/yr) now, watch `.com`. A USPTO search found "ACTIVITY PLANIT" (kids' activity scheduling) and "PLANET APP" (social event calendaring); the attorney consult covers this.
3. **Legal.** One Georgia-licensed attorney engagement (budget $1,500 to 3,000) covering the document set, the trademark question, and Georgia's social-media age law (SB 351; see `TRUST-SAFETY-LEGAL.md`). Drafts come from Claude in week 2 so the attorney reviews rather than writes.
4. **Sponsoring student org and chapters (weeks 1 to 5).** Pull the PIN org directory this week and shortlist 20 sport and hobby RSOs. Through Sai's current-student friends, make 10 warm introductions to RSO officers by Nov 20 with the ask: "your Tuesday practice is the first recurring event; we are your RSVP list and bring you members." Sign one friendly RSO (PantherDev, Tabletop Club, Run Club are natural fits) by Nov 15 as the sponsoring org that reserves Student Center East tables for Jan 12 to 15 and Jan 19 to 22 (the 60-day booking window opens about Nov 13) and lists launch events on PIN. Sai buys the degree-holding-alumni Rec Center membership ($102/semester) in January so he can be at Rec events.
5. **GSU administration outreach (parallel, not blocking).** Week 3 email to Student Engagement / PIN administration asking for an Engage API key, written permission to reference Georgia State by name, and a courtesy heads-up about the RSS import; separate note to Campus Recreation about intramural and open-rec schedules. Expect a VPAT and a HECVAT security questionnaire before any official promotion.
6. **Programs and funding.** Draft the Main Street Foundry Cohort 7 application and pitch deck v2 in week 10 (the window is expected around Jan 18 to 30; confirm with ENI in November). Check Atlanta Tech Village's Pre-Accelerator (next cohort opens around Dec to Jan; 1 to 2 days per week on-site in Buckhead; eligibility criteria to confirm with ATV). ATDC's Educate tier is open to Georgia residents now. Goodie Nation is rolling, equity-free community support. Techstars Atlanta is dormant; the Atlanta Innovation Cup is a student competition (check eligibility as a May 2026 graduate before counting on it). Pitch deck v2: one campus, real numbers, honest team slide, competitor slide naming GroupMe, Instagram, PIN, IMLeagues, Partiful, Timeleft, Meetup, Fizz/Sidechat.
7. **Monetization** (sequenced): coaching platform fee (store build B) and, as the first real revenue, downtown businesses within walking distance of campus sponsoring a hub or offering a perk to people marked Going (spring); campus or organization licensing of an official space (summer); premium member features (later). Free for students to use, always.
8. **Launch marketing.** Discord live by Jan 5, Instagram, every event link a landing page, tabling Jan 12 to 15 under the sponsoring RSO (Student Center East plus residence-hall lobbies), GroupMe seeding by chapter officers, second push Jan 19 to 29 when RSOs restart.

## 9. Metrics

North star for Spring 2027: **people who attended two or more human-hosted events in 30 days** (spring break excluded from the window). Reported alongside: signups, confirmed, onboarded, first-RSVP rate, human-hosted events per week, events with 4+ checked-in attendees, events hosted by non-founder humans, imported-shelf click-through, unique attendees, check-in rate, second-attendance rate, chapters active, messages per day, bookings and GMV, D7/D30 retention.

## 10. Budget

| Item | Cost |
|------|------|
| Supabase Pro + staging project | $35/mo |
| Vercel Pro | $20/mo |
| Resend | $0 to 20/mo |
| Image moderation (Sightengine/Hive) | $0 to 20/mo |
| Claude API (tagging, assistant) | about $10 to 40/mo |
| PostHog, Sentry, MapTiler, Geoapify, Supabase embeddings | $0 at beta scale |
| **Run rate** | **about $85 to 150/mo** |
| Domain `.app` | $10/yr |
| Apple Developer Program | $99/yr |
| Google Play Console | $25 once |
| Georgia LLC + expedite + registered agent/virtual mailbox | about $200 once + $100 to 300/yr |
| DMCA agent | $6 |
| Attorney (documents, trademark, SB 351) | $1,500 to 3,000 once |
| Stripe Identity for captain and coach verification | $1.50 each |
| Rec Center alumni membership | $102/semester |
| **One-time** | **about $2,000 to 3,700** |

Stripe Connect Express also costs the platform $2 per monthly active connected account plus 0.25% and $0.25 per payout; at 12% on a $40 lesson the platform nets about $3.30 after processing, which is why the fee proposal includes a $3 minimum.

## 11. Risks and the pre-agreed cut list

Risks: scope vs. twelve weeks; store review timing across the Dec 20 to 26 slowdown; D-U-N-S or Apple organization enrollment slipping; Stripe activation timing; feed sources changing; no founder on campus (mitigation: RSO chapters, sponsoring org, student friends); trademark conflict; free-tier dependencies (mitigation: paid tiers from week 1); solo-founder bus factor (mitigation: CI, tests, generated types, docs, a second moderator); one trust-and-safety incident before protections exist (mitigation: everything in 4.11 ships with messaging, not after).

If we slip, cut in this order, never the reverse: (1) the AI assistant moves to post-launch; (2) coach payments move to a February store update ("pay the coach directly" at launch); (3) Android moves to February, iOS launches alone; (4) group chats move to post-launch (DMs, event and hub chats stay); (5) organizer-connected feeds move to post-launch (PIN RSS and Localist stay). Never cut: the show-up loop, chapter tools, messaging basics, trust and safety, deletion, the importer's two campus feeds, the iOS app.

## 12. Open questions for Sai

Answered on 2026-10-19 and recorded in `DECISIONS.md`: market, supply, messaging, scope, database, name. Still open (also listed in the conversation):

1. Design taste: two or three apps whose look you admire; is the original blue/orange/green mood right?
2. Confirm 18+ only (recommended; closes the age question and most of the Georgia age-law exposure).
3. Store seller identity: Activity Planet LLC (wait for the D-U-N-S, about three weeks) or your personal name now?
4. Mobile architecture: bundled client app in Capacitor via the monorepo (recommended, D-013) versus a remote web view; and do you have an iPhone for TestFlight?
5. Coaching at launch: in-person (any size) plus online one-on-one only, and 12% plus $3 minimum?
6. Second moderator: who?
7. Alcohol and private venues: allow 21+ events outside the campus space; private addresses only after host approval?
8. Budget confirmation: about $100 to 150 a month plus about $2,000 to 3,700 one-time including the attorney.
9. Current GSU students you can name, and whether any are in the RSOs listed in section 3.
10. Hours per week through May, and whether this runs alongside a job or job search.
