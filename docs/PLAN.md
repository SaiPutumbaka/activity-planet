# Activity Planet — Business & Product Plan (v2)

Owner: Sai Putumbaka · Written: 2026-10-19 · Status: living document, revised as decisions land.
Companion files: `DECISIONS.md` (why each call was made), `ROADMAP.md` (week-by-week), `FOUNDER-TODO.md` (things only Sai can do).

---

## 1. What Activity Planet is

Activity Planet turns shared interests into real-world plans. You pick what you love (pickup basketball, pool, anime, board games, running, coding), you see everything happening around you for those interests this week, you tap Going, you chat with the people going, you show up. Anyone can post a plan. Verified captains run recurring ones. Coaches can offer paid sessions. The app pulls in events that already exist on campus and in the city so the feed is never empty.

Positioning: **a plans app, not a feed.** The mission copy stays (loneliness epidemic, "social media made us reachable, not less alone"), but the pitch is "find your people and something to do with them this week."

Wedge: Georgia State University students, Spring 2027. Open to anyone with any email from day one; a verified `.edu` address unlocks campus-only spaces (the GSU space first). Expansion path: other Atlanta campuses, then intown Atlanta 18 to 35, then other cities.

## 2. Decisions locked on 2026-10-18/19

| # | Question | Decision |
|---|----------|----------|
| 1 | First market | GSU students first, Spring 2027 launch. Open signup for everyone. |
| 2 | Event supply | Founder does not host. Three sources: imported events (public campus/city feeds), verified captains, member-posted events. |
| 3 | Founder presence | None on campus. Product must work without the founder in the room. |
| 4 | Campus permission | Plan around events that need no permission. GSU partnership is an outreach track, not a dependency. |
| 5 | Identity | Any email can sign up. `.edu` verification required for campus spaces. |
| 6 | Messaging | Everything: DMs, group chats, event chats, hub chats. The app is the destination, not a layer on GroupMe. |
| 7 | Scope | Coaching marketplace, payments, and AI matching are in. Launch with as many features as possible. |
| 8 | Platform | Web + installable PWA, and App Store / Play listings before launch. |
| 9 | Metrics | All of them: signups, events held, attended once, attended twice in 30 days, plus the funnel. |
| 10 | Accelerator | Main Street Foundry was missed. Re-enter programs once the product and vision are sharp. |
| 11 | Database | Restore the existing Supabase project (done 2026-10-19). |
| 12 | Brand | Keep the name. Discord server does not exist yet; set it up as part of launch. |

Two honest notes on these decisions, so nobody is surprised later:

- **Scope vs. clock.** Everything in section 4 is buildable, but twelve weeks to a January launch with one founder plus AI is tight. The roadmap sequences the show-up loop first because nothing else matters if nobody comes back. Coaching and AI land late in the window. If we slip, the cut list in section 11 is pre-agreed.
- **Scraping.** Handshake and LinkedIn are login-walled and their terms prohibit automated collection; LinkedIn litigates over it. We do not scrape them. We import from sources that publish public feeds or APIs and we always link out to the original registration page. GSU's PIN (Anthology Engage) and the GSU calendar (Localist) both expose public JSON APIs, verified 2026-10-19, so the campus supply problem is solvable the legitimate way.

## 3. Who it is for

Primary (launch): GSU students who want to do something with people this week and are tired of checking six group chats. Two personas from the June interview guide: the athlete organizing pickup games, and the hobbyist who got burned by fake users on Activitybees.

Secondary (launch): student org leaders and informal captains who already run recurring things (Tuesday pool, Thursday pickup) and want an audience and an RSVP list.

Tertiary (launch, small): coaches and instructors (fitness, tennis, tutoring, music) who want students to find and book them.

Later: Atlanta 18 to 35 across campuses and neighborhoods.

## 4. The product (v2 scope)

Tag legend: **L** = in the January launch · **P** = post-launch, Feb to May 2027.

### 4.1 Identity and onboarding
- **L** Email+password, Google sign-in, Apple sign-in (required by Apple once Google exists), magic link, password reset, resend confirmation, cross-device-safe email links.
- **L** Profile: real first name, photo (required to RSVP or message), handle, bio, interests, campus/neighborhood, birthday (private, for the 18+ gate).
- **L** `.edu` verification: a second verified email unlocks campus spaces; stored separately from the login email.
- **L** Onboarding ends in an action: pick interests, see this week near you, tap Going. Under two minutes.
- **L** Account settings: change email/password, notification preferences, privacy toggles, delete account (App Store requirement).

### 4.2 Hubs and Spaces
- **L** Hubs are database rows (not a TypeScript list): slug, name, category, emoji/cover, description, member count, activity score. Seeded from the 577-entry catalog after pruning synonyms; about 40 visible at launch, the rest behind search and "request a hub."
- **L** Spaces: an organization scope (GSU first). A hub can have a campus chapter ("GSU Pickleball") with its own chat and events. Chapters are what make a worldwide "Soccer" room feel local.
- **L** Hub page: next events, members, chat, captains, "start an event here."
- **P** User-created hubs with light review.

### 4.3 Events (the social object)
- **L** Three sources, one card: *Imported* (from public feeds, with a "Register" button to the source), *Captain-hosted*, *Member-posted*.
- **L** Event page with full description, venue, map pin, attendee avatars, host card, event chat, share link that works logged out with an OG image, Add to Calendar.
- **L** RSVP states: going / interested / waitlisted / cancelled. Host auto-RSVPs. Capacity and waitlist. Optional "happens if N join" minimum headcount.
- **L** Edit, cancel (attendees notified), recurring events for captains.
- **L** Check-in and the morning-after prompt ("Did you go? Who did you meet?"). This is how we measure the mission and it feeds "people you've met."
- **L** Feed: location-first, interest-ranked, Today / This week / Later sections, filters by distance, hub, source, free/paid. Never empty on day one because of the importer.
- **P** Event photos, co-hosts, tickets for paid non-coaching events.

### 4.4 Event importer (the cold-start engine)
- **L** Connectors, each a small scheduled job that normalizes into `events` with `source = imported`, dedupes, geocodes, tags hubs, and stores the outbound registration URL:
  - **GSU PIN**: Anthology Engage public discovery API (`pin.gsu.edu/api/discovery/event/search`). About 22k historical events indexed; themes include Athletics, Social, Arts, Cultural.
  - **GSU Calendar**: Localist public API (`calendar.gsu.edu/api/2/events`).
  - **Eventbrite** (official API, Atlanta plus category filters), **Luma** (public calendar feeds), **Meetup** (public group event pages or ICS where available).
  - **GSU Recreation** schedules (intramurals, open rec, group fitness) once a feed or page structure is confirmed.
- **L** Moderation queue: imported events go live automatically from trusted sources; anything else is reviewed in the admin panel.
- **L** Attribution: every imported card shows the source and links out. We never claim the event as ours.
- **P** Submit-a-source form; org admins can claim their imported events.
- **Not doing:** Handshake, LinkedIn, or anything behind a login or against terms.

### 4.5 Captains
- **L** Apply, quick verification (identity plus a reference or a public track record), badge. Captains get recurring events, attendee management (remove, message all), a simple dashboard (attendance over time), and a public captain profile.
- **L** Target: 10 verified GSU captains before launch week, recruited from the people who already run pickup basketball at the Rec, pool in the game room, anime nights, and so on.
- **P** Captain perks (featured placement, early access to coaching tools).

### 4.6 Messaging
- **L** DMs, group chats, event chats, hub/chapter chats. Realtime, optimistic send, newest-first history with infinite scroll, unread counts, typing indicator, image sharing, link previews.
- **L** Safety built in: block, report, mute, delete own message, moderator delete, rate limits, link/profanity filter, "first message to a stranger" friction (must share a hub or event, or be accepted). Account-level ban. Messaging requires a photo on the profile.
- **P** Reactions, read receipts, voice notes.

### 4.7 Coaching marketplace
What "coaching" means here: any person offering a skill for money, in person or online. Tennis lessons, personal training, tutoring, guitar, pickleball clinics.
- **L** Coach profile (credentials, rates, photos, reviews), listings (1:1 session, group clinic), availability calendar, booking request then confirmation, messaging with the client.
- **L** Payments via **Stripe Connect**: the coach onboards to Stripe Express (Stripe handles identity checks, tax forms, and payouts), the student pays in-app by card or Apple/Google Pay, Activity Planet takes a platform fee (proposed 12%), refunds and cancellations follow a published policy. Activity Planet never holds money or touches card numbers.
- **L** Reviews after a completed session.
- **P** Packages, subscriptions, group-clinic ticketing, coach analytics.

### 4.8 AI
What "AI matching" means here, in three layers:
1. **L** **Recommendations**: ranked hubs, events, people and coaches for you, from interests plus location plus schedule plus what you RSVP'd to plus what similar users did. Starts as rules plus embeddings; improves with data.
2. **L** **Assistant**: "I'm free Thursday night, what should I do?" or "find me a tennis coach under $40 near Midtown." A chat surface that answers from live data and takes actions (RSVP, message, book).
3. **L** **Import intelligence**: an LLM tags imported events with hubs, cleans titles, extracts venues and times, flags duplicates and spam.
- **P** Smart matchmaking ("3 people in your hub are also free Thursday, start a group?"), auto-generated weekly digests per user.

### 4.9 Notifications
- **L** In-app inbox, email (Resend), push (via the mobile apps; web push for installed PWA). RSVP confirmation plus calendar file, day-before and 2-hour reminders, "someone joined your event," "new event in your hub this week," message notifications, post-event check-in prompt, weekly digest.

### 4.10 Mobile and the stores
- **L** Installable PWA from the web app.
- **L** iOS and Android apps built with **Capacitor** wrapping the same web app, plus native push, native share, camera for profile photos, and app-store-compliant account deletion. Submitted to App Store and Google Play by early December so review time (and one likely rejection round) fits before January.
- **P** Decide on a React Native client only if store data says the wrapper is the bottleneck.

### 4.11 Trust, safety, legal
- **L** 18+ at signup (birthday collected, not shown). Community guidelines accepted at first RSVP. "Meet in public places" nudge on every event. Report and block everywhere. Moderator role for the founder. Public profile shows no email, no birthday, no exact location; distance shown in bands.
- **L** Terms of Service, Privacy Policy, Coach Terms, Refund Policy, Cookie notice. Data export and deletion.
- **L** Private data split from public profile at the database level, not just in the UI.

### 4.12 Analytics and admin
- **L** PostHog with the full funnel: landing, signup, confirmed, onboarded, first RSVP, attended, attended again. Events: hub join, event view, share, message sent, booking, check-in.
- **L** Admin panel: live numbers (signups, WAU, events this week by source, attendance, second-attendance rate, captains active, messages, bookings, GMV), moderation queue, user lookup, ban, importer health.
- **L** Weekly scorecard auto-emailed to Sai.

## 5. Architecture

Keep from v1: Supabase auth plumbing (`auth/callback`, middleware), the Zod validation layer, the RLS policy conventions, the hub catalog as seed data, geo helpers. Replace: the schema, the UI, the palette, the hand-pasted migration process.

| Layer | Choice | Why |
|-------|--------|-----|
| App | Next.js 16 (App Router), React 19, TypeScript strict | Current; v1 is on 15.5. One codebase for web, PWA and the Capacitor shells. |
| Styling | Tailwind v4 plus current shadcn/ui, custom design system | v1 is two generations behind; rebuild once. |
| Data/Auth | Supabase (restored project `gtesfiqxqontescqpllo`), Postgres 17, RLS everywhere, Supabase CLI migrations, generated types, staging project | Hand-pasted migrations caused the July outage. Upgrade to Pro so it never pauses again. |
| Realtime | Supabase Realtime (chat, presence) | Already proven in v1. |
| Jobs | pg_cron plus Edge Functions (importer, reminders, digests, aggregates) | No separate worker to run. |
| Email | Resend (custom domain) | Supabase's built-in sender throttles. |
| Push | Capacitor push (FCM/APNs), web push for PWA | |
| Payments | Stripe Connect Express | Standard for marketplaces; handles KYC, 1099s, payouts. |
| AI | Claude API (recommendations, assistant, import tagging), pgvector for embeddings | |
| Maps/geo | MapTiler tiles, Mapbox or Google geocoding via server proxy | OSM/Nominatim direct from the browser violates their policies. |
| Analytics/errors | PostHog, Sentry | v1 had neither; the outage was invisible. |
| Mobile | Capacitor 8 | Same app in the stores without a second codebase. |
| Hosting | Vercel Pro | Hobby forbids commercial use. |
| CI | GitHub Actions: typecheck, lint, tests, schema drift check, migration push to staging | |

Schema v2 (summary): `profiles` (public) plus `profile_private` (email, birthday, precise location) · `organizations` plus `org_memberships` plus `verified_emails` · `hubs` plus `hub_chapters` plus `hub_members` · `events` (source, status, starts/ends, capacity, min_headcount, venue, geography, external_url, chapter_id) plus `rsvps` (status, checked_in_at) plus `event_imports` (source, external_id, raw, hash) · `conversations` plus `conversation_members` plus `messages` · `captain_applications` · `coaches` plus `listings` plus `availability` plus `bookings` plus `payments` plus `reviews` · `notifications` plus `notification_prefs` · `reports` plus `blocks` plus `moderation_actions` · `user_roles` · `analytics_events` (mirror of key PostHog events for SQL).

## 6. Design direction

The brown palette goes. The new identity needs: one energetic action color (the Going button is the most alive thing on screen), semantic state colors (going, live, full, cancelled, imported), a small category color system so hubs don't rely on emoji, one type family that works in the app and on the landing page, a mark that reads as people/places/play rather than a Saturn ring, and a full icon/OG/manifest set. The original logo (blue wave, orange peaks, green hill with sun) says "outdoors and energy" and is a better starting mood than the café palette. Final direction is chosen with Sai in week 1 from three candidate boards.

## 7. Timeline

Twelve weeks from 2026-10-20 to the GSU spring start (confirm exact date; typically the second week of January). Detail in `ROADMAP.md`. Shape:

- **Weeks 1 to 2** Foundation: schema v2 plus CLI migrations plus CI, auth (Google/Apple/reset/.edu), design system v2, shell, analytics, errors, email.
- **Weeks 3 to 4** Show-up loop: hubs/chapters, events, RSVP, event page plus share, reminders, check-in, feed.
- **Weeks 5 to 6** Messaging plus trust and safety plus admin.
- **Weeks 7 to 8** Supply: importer (PIN, Localist, Eventbrite, Luma), captains, GSU space.
- **Weeks 9 to 10** Coaching plus Stripe Connect; AI recommendations, assistant, import tagging.
- **Weeks 11 to 12** Capacitor apps plus store submission (started in week 8 in parallel), QA, seed, landing page, Discord, launch kit, soft launch to captains and friends, then public launch week 1 of the semester.

Business track runs in parallel every week (section 8).

## 8. Business track

1. **Entity and money.** Georgia LLC (Secretary of State, about $100), EIN, business bank account, Stripe account (needs the LLC), accounting (Wave or similar). Stripe Connect platform approval needs a live site with ToS and Privacy.
2. **Name and domain.** `activityplanet.com` is taken; `activityplanet.app` ($9.99/yr), `.co`, `.io`, `.us` are available. Recommendation: buy `.app` now, watch `.com`. A USPTO search found "ACTIVITY PLANIT" (kids' activity scheduling) and "PLANET APP" (social event calendaring), close enough that a trademark attorney consult (about $300 to 500) is worth it before spending on brand.
3. **Legal docs.** ToS, Privacy, Community Guidelines, Coach Terms, Refund Policy. Draft from templates, then review.
4. **Captain recruitment.** Target 10 verified GSU captains by launch: the people already running pickup basketball at the Rec, pool in the game room, anime and board-game nights, running groups, intramural teams. Channel: Sai's current-student friends, Instagram and GroupMe, PIN org listings (we can see which orgs host Athletics and Social events most).
5. **GSU partnership outreach** (parallel, not blocking): Student Engagement and PIN admins (claim imported events, official listing), Campus Recreation (intramurals and open-rec schedules in the app), three student org presidents as pilot partners. The ask is "promote the app to your students and let your events live in it," not "give us a room."
6. **Programs and funding.** Re-enter the ecosystem once the beta has numbers: Atlanta Tech Village pitch practice and Pre-Accelerator, ATDC (Georgia Tech's statewide incubator, open to all Georgia startups), Techstars Atlanta, Goodie Nation, Atlanta Innovation Cup (next cycle), GSU's own ENI and Launch programs as an alumnus founder, Main Street Foundry Cohort 7 if alumni-eligible. Pitch deck v2 replaces the 2025 deck: one campus, real numbers, honest team slide, competitor slide that names GroupMe, Partiful, Timeleft, Meetup, PIN.
7. **Monetization** (sequenced): coaching platform fee (launch), then promoted events and local-business sponsorship of hubs (spring), then campus or organization licensing of an official space (summer), then premium member features (later). Free for students to use, always.
8. **Launch marketing.** Discord server (community plus captains plus feedback), Instagram, a shareable event page as the growth loop (every event link is a landing page), tabling via student friends during welcome week, GroupMe seeding by captains, launch-week events calendar from the importer.

## 9. Metrics

North star for Spring 2027: **people who attended two or more events in 30 days.** Reported alongside: signups, confirmed, onboarded, first-RSVP rate, events this week by source, unique attendees, check-in rate, second-attendance rate, captains active, messages per day, bookings and GMV, D7/D30 retention, imported-event click-through.

## 10. Budget (monthly unless noted)

| Item | Cost |
|------|------|
| Supabase Pro | $25 |
| Vercel Pro | $20 |
| Resend | $0 to 20 |
| PostHog plus Sentry | $0 at beta scale |
| MapTiler / geocoding | $0 to 25 |
| Claude API (assistant plus tagging) | about $10 to 40 |
| Domain `.app` | $10/yr |
| Apple Developer Program | $99/yr |
| Google Play | $25 once |
| Georgia LLC | about $100 once plus $50/yr |
| Trademark consult | about $300 to 500 once |
| **Run rate** | **about $75 to 130/mo** plus one-time about $550 to 750 |

## 11. Risks and the pre-agreed cut list

Risks: scope vs. twelve weeks; App Store rejection of a web wrapper (mitigation: native push, share, camera, deletion, real native feel; submit early); Stripe Connect approval timing; importer sources changing their APIs; no founder on campus (mitigation: captains plus importer plus student friends); trademark conflict; free-tier dependencies breaking at launch (mitigation: paid tiers from week 1); solo-founder bus factor (mitigation: CI, tests, generated types, docs).

If we slip, cut in this order, never the reverse: (1) AI assistant, ship recommendations plus import tagging only; (2) coach *payments*, ship coach profiles plus booking requests plus "pay the coach directly," add Stripe in February; (3) Android store, ship iOS first; (4) group chats, ship DMs plus event plus hub chats; (5) Luma/Meetup connectors, ship PIN plus Localist plus Eventbrite. The show-up loop, messaging basics, trust and safety, the importer, captains and the stores are never cut.

## 12. Open questions for Sai

1. Design taste: name two or three apps whose look you admire, and say whether the original blue/orange/green logo mood is right or you want something new.
2. Age policy: 18+ at launch (recommended for a strangers-meet-in-person product on a college wedge)? If you want 17-year-old freshmen, say so and we design the gate and policies for it.
3. Platform fee for coaching: 12% proposed. Any strong feeling?
4. Budget confirmation: roughly $100/month plus about $700 one-time is acceptable?
5. Discord: yes to building the server now as the captain plus beta community home?
