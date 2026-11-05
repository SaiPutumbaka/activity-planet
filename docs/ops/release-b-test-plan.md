# Release B test plan

**Release B goes live by Jan 4** (ROADMAP week 11), followed by the soft launch to chapters, coaches
and friends and the Jan 11 public launch. Release B is release A (the hub map, events, chapters,
trust and safety, deletion; `docs/ops/release-a-test-plan.md`) plus messaging (D-043), coaching with
payments off (D-044), collector completion, recommendations, landing page v2 and PWA polish (D-045),
everything merged through migration 68 (schema_version 2.64).

This plan says what is checked automatically, what Sai checks by hand on his iPhone, what has to be
true before Release B ships, and what is known not to work yet. The audience is adults 18+ anywhere
(D-040), so every check runs in at least two places: Atlanta and somewhere outside the US
(Freiburg, Germany, in the demo data). A university affiliation is optional throughout.

## 1. Scope

New in Release B (release A's scope table still applies):

| Area                 | What it covers                                                                                                                                                                                                                   |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Chats (D-043)        | Chats tab and badge, DMs, message requests (Requests tab, accept, decline), plan, hub and chapter chats (created when first opened), typing, delete own message, report a message, chat info, mute, block stops delivery         |
| Coaching (D-044)     | Become a coach (profile, Coach Terms), listings (one-on-one in person or online; online group refused), weekly availability and exceptions, publish and pause, find coaches (near you, online), request a time, confirm, decline |
| Bookings             | `/bookings` for both sides, the booking page, the DM from a booking, mark done, no-show and contest, reviews and replies, the Refund Policy acknowledgment                                                                       |
| Payments             | Off (`meta.coach_payments = 'off'`, no Stripe keys): prices show with "arranged directly with the coach"; no payment entry point anywhere. Stripe test mode on staging only once Sai adds the test keys                          |
| Collector completion | An imported listing's source block and "Request removal", the site's `/bot` and removal form, organizer claims (code, Check now), `/organizer`, connect a calendar, moderator tabs (Takedowns, Claims, Health), venue geocoding  |
| Recommendations      | For you on Home with up to two reason chips, Not interested and Undo, Why am I seeing this, Similar plans, Hubs you may like, Coaches for you, People you might click with, the privacy switches in You                          |
| Landing page v2      | This week near you (Atlanta by default, a city picker, location only after a tap), How it works, the trust section, "On your phone" notes                                                                                        |
| PWA polish           | Install card (Chromium prompt, iPhone instructions, hidden when installed), "A new version is ready" toast, app badge, the full manifest and iOS splash screens                                                                  |
| Site pages           | `/bot`, `/bot/remove`, `/support`, `/terms` (draft), `/privacy` (draft), `/guidelines` (draft), `/coach-terms` (draft), `/refund-policy` (draft), `/safety`, `/safety/intimate-images`, `/map-data`, `/account/delete`, the 404 page |

Out of scope: chat images (off until the classifier exists, section 6), live payments, the
assistant, store apps, and email or push delivery before the keys exist (FOUNDER-TODO, top).

## 2. Environments

Unchanged from release A (its section 2): a fresh local stack in the `rehearse` job, staging
(`gzrscndzzggxmcwnvvcq`) for the SQL suite, the Playwright flows and the demo data, production
(`gtesfiqxqontescqpllo`) only through a merge to `main`. Test and demo accounts live on staging
only, use `@example.com` addresses and are marked `qa_e2e` or `demo_release_a`; their passwords stay
outside the repository. Staging changes and checks go through `migrate.yml` with `staging_only`,
never through the Supabase connector.

For the browser flows, build both apps pointed at staging and serve them:

```sh
pnpm --filter @ap/app build && pnpm --filter @ap/app preview --port 4173 &
# apps/web, with NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY set to staging
pnpm --filter @ap/web build && pnpm --filter @ap/web start -p 3000 &
```

If a `next start` was running while the site was rebuilt, stop it and delete
`apps/web/.next/server/route-cache` before starting again: the old server can leave a cached landing
page that points at script files the new build no longer has (seen on Nov 5; local only, Vercel
always builds fresh).

## 3. Automated checks

### 3.1 Unit tests (every push and PR, `ci.yml`)

```sh
pnpm typecheck && pnpm lint && pnpm test && pnpm build
```

| Package              | Tests (Nov 5)                    | New since release A                                                                                                  |
| -------------------- | -------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `apps/app`           | 241 passed, 1 skipped (23 files) | Chats and outbox, coaching screens' helpers, recs rows, install and update prompts                                   |
| `packages/core`      | 220                              | Messaging schemas and link rules, coaching (slots, prices, statuses), recs reasons and landing cards, distance units |
| `packages/collector` | 284                              | Removal, claims and verification, connected feeds, geocoding, open-data registry and scout, discovery tuning         |

`ci.yml` also runs the Deno tests for the Edge Functions, now including `stripe-connect`,
`stripe-checkout`, `stripe-webhook` (mocked `fetch`), `organizer-verify`, `eventbrite-connect`,
`recs-embed` and `weekly-scorecard`.

### 3.2 SQL regression suite on staging (`supabase/tests/`)

Run as in release A section 3.2: Actions, **Migrate database then deploy**, Run workflow on the
branch with `staging_only`, `staging_tests` and `staging_tests_keep_going` ticked.

The suite now holds 70 files: 65 run in order and 5 live-data smokes sit on `skip:` lines. Release B
added `messaging`, `messaging_safety`, `messaging_review_fixes`, `coaching`, `coaching_rules`,
`coaching_payments`, `coaching_review_fixes`, `listing_removal`, `organizer_claims`,
`organizer_feeds`, `venue_geocoding`, `collector_health`, `discovery_tuning`, `collector_ui`,
`collector_review_fixes`, `recommendations`, `recommendations_people`, `scorecard_landing`,
`recommendations_review_fixes` and `feed_distance`.

Last run: Nov 5, Actions run 42052802707 on `main-r1pc3k` (with `qa_account_age.sql` as the
`staging_file`): **all 65 regression tests passed.**

### 3.3 Browser flows (Playwright, `apps/app/e2e/`)

Plain Node scripts, not part of `pnpm test`; each prints `PASS`/`FAIL` per step and never prints
user rows. How to run them, and the staging files some of them need, is in
`apps/app/e2e/README.md`. Order: 01 to 06, then `qa_account_age.sql` as a `staging_file`, 07, 08
with `E2E_PHASE=book`, `qa_coaching_past.sql` as a `staging_file`, 08 with `E2E_PHASE=finish`,
then 09, 10 and 11 with `E2E_SITE_URL` set.

Results of the Nov 5 QA pass (fresh builds of both apps against staging):

| Flow               | Widths            | Result                   | Notes                                                                                                    |
| ------------------ | ----------------- | ------------------------ | -------------------------------------------------------------------------------------------------------- |
| 01-onboarding      | 390               | 3 passed, 0 failed       | The QA account is already onboarded, so the steps after sign-in report as skipped (see section 6)        |
| 02-browse          | 390 and 1280      | 14 passed, 0 failed      | Home sections: For you, This week, Also happening, Hubs you may like                                     |
| 03-plan            | 390 and 1280      | 8 passed, 0 failed       | Posting as a chapter is not scripted (the QA account has no chapter)                                     |
| 04-safety-you      | 390 and 1280      | 17 passed, 0 failed      |                                                                                                          |
| 05-sweep           | 390 and 1280      | 62 passed, 0 failed      | Every route signed in and out, including the chat, coaching, organizer and admin routes                  |
| 06-offline         | 390               | 5 passed, 0 failed       |                                                                                                          |
| 07-messaging       | 390, two accounts | 18 passed, 0 failed      | The one `400` on `send_message` is the refused send after the block, as intended                         |
| 08-coaching book   | 390, two accounts | 13 passed, 0 failed      |                                                                                                          |
| 08-coaching finish | 390, two accounts | 6 passed, 0 failed       | After `qa_coaching_past.sql` (run 42054036121)                                                           |
| 09-collector       | 390 and 1280      | 20 passed, 0 failed      | The removal form answers 503 locally because the site has no service key; on Vercel it needs the key too |
| 10-recs            | 390 and 1280      | 22 passed, 0 failed      | Coaches for you and People you might click with show 0 cards for the QA account (reported, not failed)   |
| 11-site (new)      | 390 and 1280      | 28 passed, 0 failed      | `/terms` and `/privacy` are linked and not live yet (NOTE lines, section 6)                              |
| **Total**          |                   | **216 passed, 0 failed** | After the fixes below, 02, 03, 05, 10 and 11 were run again on the new builds and still pass             |

The only console noise is `ERR_TUNNEL_CONNECTION_FAILED` from the map tile host and imported image
hosts, which the test container cannot reach.

### 3.4 Exploratory pass (Nov 5, by hand in Playwright)

Beyond the scripts: a member in Freiburg (`demo_lena`) at both widths, with a `de-DE` and an
`en-US` browser; deep links signed out (`/events/<id>` goes to sign-in and back to the plan); back
navigation from a card and the in-app back on a deep-linked plan; sign out and back in; malformed
and unknown ids on `/events`, `/hubs`, `/chapters`, `/chats`, `/coaches` and `/bookings`; empty
states for Chats, Requests, Bookings, Coaches, Organizer and People you've met; coaching screens at
1280 wide; every site page at both widths.

Freiburg makes sense away from Atlanta: Home shows the three Freiburg plans in Berlin time, the
location pill says Freiburg im Breisgau, the map list shows 90 places near the Schlossberg, Hubs
suggests hubs with members nearby, Coaches says "No coaches here yet" around Freiburg, and People
you might click with suggests the other Freiburg member from a shared plan. There are no imported
events in Freiburg (EU discovery is gated until the attorney question, FOUNDER-TODO) and For you
stays hidden there because fewer than three plans qualify.

Bugs found and fixed in this pass (each verified in the browser on a fresh build):

1. **`/guidelines` was a 404.** The app's guidelines sheet (shown at the first RSVP) and the Safety
   Center link to it. It is now a DRAFT page on the site, like the Coach Terms, and in the sitemap.
2. **The site's 404 was Next's bare default** with no way back. It now names the likely reasons and
   links Home, the app and the Safety Center.
3. **Distances were always in miles** on plan cards, recommendation chips, "Why am I seeing this?"
   and coach rows. They now follow the browser's locale (COACHING_DESIGN section 6): a `de-DE`
   browser in Freiburg reads "Under 2 km" and "2 to 8 km", an `en-US` browser still reads "Under 1
   mi". Since the follow-up pass the radius, the map, times, dates and the landing page's week
   cards follow the locale too (section 6).
4. **A broken-image icon** showed on For you when an imported listing's cover image failed to load.
   Plan covers now fall back to the drawn default cover on the card, the For you card, the hub page
   and the plan page.
5. **`/events/<malformed id>` said "Something in the form isn't valid."** It now says "This plan
   isn't here", and the Share button is hidden on a missing plan.
6. **Chats' empty state promised chats that are not there yet.** Plan, hub and chapter chats are made
   when someone first opens them, so a new member who has joined plans saw "No chats yet" under
   "Every plan you join has a chat". The copy now says to open one and tap Chat.
7. **08-coaching left the QA coach page live**: its cleanup closed the browser right after tapping
   "Pause my page". It now waits for the confirmation.
8. **The app's sign-in and sign-up footer linked Help to `/support`, a 404.** The site now has a
   Help page there (the support address, Report in the app, and links to the Safety Center,
   Guidelines, Refund Policy and account deletion), and 11-site checks it.

### 3.5 Demo data

Unchanged from release A section 3.4 (five demo members in Atlanta, Decatur and Freiburg, one area
chapter, seven plans, one report and one pending claim). The QA accounts additionally hold chats, a
completed coaching booking with a review and a paused coach page from 07 and 08.

## 4. Manual checklist: Sai's iPhone, installed web app

Do release A's section 4 first (install, sign up and in, location prompt, notifications, map with
real tiles, plans, offline, safety and deletion). Then these. Use two accounts (your own and a
second address or a friend's phone) on production unless a line says staging.

**Chats**

- [ ] The Chats icon sits beside the bell on Home, Hubs, Map and You. With no chats it shows the
      empty state and a New message button.
- [ ] Open one of your plans and tap Chat. The plan chat opens and now appears in Chats.
- [ ] Without a profile photo you cannot start a conversation, and the app shows how to add one.
- [ ] From the second account, message you by handle with nothing shared. It arrives under
      Requests (no read receipt for them). Accept it. Both sides now chat normally.
- [ ] Messages arrive both ways without pulling to refresh, the typing line shows, and the Chats
      badge counts unread chats. The keyboard does not cover the composer, and the composer clears
      the home indicator.
- [ ] Delete your own message: it goes on both phones. Report one of theirs: you get a
      confirmation, and it shows in `/admin` for a moderator.
- [ ] Mute the chat from its info screen: no more pushes for it (once push is on).
- [ ] Block from chat info: your next message is refused, nothing reaches them. Unblock from You,
      Blocked accounts.
- [ ] A link in a request is refused with a clear message; a short link (bit.ly) is refused
      everywhere.

**Coaching** (payments are off: no card entry anywhere)

- [ ] You, Become a coach: the profile asks for a headline and the Coach Terms (draft) checkbox,
      and the time zone defaults to your phone's.
- [ ] Add a one-on-one listing (in person or online). Online group is not offered.
- [ ] Set weekly times; the next two weeks preview shows slots in your zone. Publish.
- [ ] From the second account: Coaches shows you under Near you (or Online), with "self-reported"
      on credentials and the price with "arranged directly with the coach".
- [ ] Request a time. The Refund Policy (draft) link opens, and the request needs the
      acknowledgment. The request is in your inbox and on coach home; confirm it.
- [ ] Both sides see Confirmed with the meeting place, and Message opens a DM with no request.
- [ ] After the session time: mark it done, the client leaves a review, it shows on your coach page,
      reply once. Report the review from a third view to see it in `/admin`.
- [ ] Pause your coach page: it disappears from Coaches for the second account.

**Organizer claims and imported listings**

- [ ] Open an imported listing (Also happening). The source block names the source, "Request
      removal" opens the site's form with the listing filled in, and "Are you the organizer?" opens
      the claim page.
- [ ] Start a claim with a public calendar link: you get a short code with Copy buttons; Check now
      says it was not found until the code is in the calendar.
- [ ] `/organizer` lists the claim. As a moderator, `/admin` Claims, Organizers shows it.
- [ ] The site's `/bot` page reads well on the phone, and the removal form submits (needs the
      service key on the site project, FOUNDER-TODO top).

**Recommendations**

- [ ] Home shows For you with at most two chips per card once three or more plans qualify.
- [ ] Not interested removes a card, and Undo brings it back. Why am I seeing this lists plain
      sentences and never names a sensitive hub or a person.
- [ ] A plan page shows Similar plans. Hubs shows Hubs you may like. Coaches shows Coaches for you
      when there are coaches near you. People you've met shows People you might click with.
- [ ] Distances, the feed radius and map distances read in your units, and times and dates in
      your format (miles, 4:00 PM and "Thu, Nov 5" on a US iPhone; km, 16:00 and "Thu 5 Nov" on
      one set to Germany).
- [ ] You, Privacy and safety: turning off personalisation changes the For you subtitle to "Close
      by and soon"; turning off people suggestions removes you from others' rows.

**Install and update**

- [ ] In Safari (not installed), the install card shows the Share then Add to Home Screen steps.
      Installed, the card never shows.
- [ ] The installed icon, splash screen and app name look right in light and dark mode.
- [ ] After a deploy, open the installed app: "A new version is ready" appears; tapping it reloads
      into the new version with no sign-out. Ignoring it keeps the app working until the next
      launch.
- [ ] The unread badge on the Home Screen icon (once push is on) clears when the inbox is read.

**Landing page and site pages** (Safari, signed out)

- [ ] The landing page shows This week near you for Atlanta, and the city picker swaps the cards
      without a reload. No location prompt until you tap "Use my location".
- [ ] `/safety`, `/support`, `/terms`, `/privacy`, `/guidelines`, `/coach-terms`,
      `/refund-policy`, `/bot`, `/map-data` and `/account/delete` read well with no sideways
      scroll; the five policy pages carry the DRAFT banner. A wrong address shows the 404 with a
      way home.

## 5. Release criteria (go or no-go on Jan 3)

Release B ships by Jan 4 only when all of these hold on the release candidate merged to `main`:

1. `pnpm typecheck`, `lint`, `test` and `build` pass, and the Deno and place-rules jobs pass.
2. A `staging_only` run with `staging_tests` passes every file in `regression.txt`, and the
   production migration run for that commit succeeds.
3. Playwright flows 01 to 11 pass against staging at both widths where the flow supports them, with
   no `FAIL` lines, or each failure has a written reason.
4. Sai's iPhone checklists (release A section 4 and section 4 here) are complete; every unticked line
   has a bug filed and is fixed or accepted in writing as a known gap.
5. **The Terms of Service and Privacy Policy are live at `/terms` and `/privacy`** (they are linked
   from sign-up, You, the Safety Center and every share page), and the Privacy Policy names the
   Release B processors and data (messages, bookings, Stripe once on, embeddings).
6. No open bug that loses data, shows one person's private data to another (addresses, home points,
   emails, messages, blocked people, bookings), lets an under-18 account in, delivers a message
   across a block, or blocks sign-up, onboarding, posting, RSVP, messaging, booking, report or
   account deletion.
7. Trust and safety end to end on production: a reported message reaches the admin queue with its
   context and can be resolved, the NCII form and the listing removal form submit, and account
   deletion completes for a member with chats and a coach with bookings.
8. Payments stay off on production (`meta.coach_payments = 'off'`, no live Stripe keys) unless the
   attorney has read the Coach Terms and Refund Policy and the LLC trigger has fired (D-044).
9. Rollback is ready, as in release A.

## 6. Known gaps (Nov 5)

- **`/terms` and `/privacy` are drafts.** Both are live as DRAFT pages with the attorney banner,
  like the Coach Terms, Refund Policy and Community Guidelines, and in the sitemap and the site
  footer (Nov 5, written from TRUST-SAFETY-LEGAL, D-031 retention, the processors the code uses
  and the data the schema stores). Release criterion 5 is met in form; the attorney read
  (FOUNDER-TODO item 13) is what turns them from drafts into the terms in effect.
- **Chat images stay off.** `meta.chat_images` is `off` and the composer has no photo button.
  Image-guard's `classify` op (Sightengine, design section 13) is not built yet, so adding the
  Sightengine keys alone does not turn images on. Building it is about a day and a half (the op,
  the monthly cap, the evidence copy and a staging smoke).
- **Payments are off.** Stripe Checkout, Connect onboarding and the webhook have only mocked unit
  tests and the SQL suite; they get a staging run once Sai adds the Stripe test keys.
- **Not-found answers on mutations are still HTTP 500.** Migration 69 moved the read RPCs a
  screen calls on load (`get_coach`, `coach_reviews_page`, `coach_slots`, `get_booking`,
  `conversation_info`, `get_messages`, `mod_message_evidence`, `place_detail`,
  `venue_preview_for_place`, `organizer_source_detail`, `recs_similar_events`, `chapter_dashboard`,
  `mod_user_lookup`) to SQLSTATE `PT404`, which PostgREST answers with HTTP 404; the message is the
  same documented code, so the app behaves as before (`supabase/tests/not_found_404.sql`). Writes
  on a missing row (cancel, send, respond and the rest) keep P0002 and a 500: they are rare, and a
  5xx there is worth a look.
- **Units and formats follow the viewer's locale** (Nov 5, `packages/core/src/locale`): miles or
  kilometres, a 12- or 24-hour clock and month-first or day-first dates, from the browser's
  language, across the app (feed radius, You, coaches, map distances, plan, chat, booking, admin
  and notification times) and the site (week cards, share page times; the server renders the US
  form and the browser switches after hydration, so link previews and the OG image stay US). The
  words stay English. Venue addresses put the postcode first where that is the norm (Germany,
  France and most of Europe) and use a source's own formatted line as it is; there is no full
  international address formatter. Left as is: text inputs for dates and times follow the
  browser's own controls, and error copy such as "Pick a distance between 1 and 50 km" still
  names kilometres.
- **Sign-up with `@example.com` addresses is refused by Supabase Auth**, so a brand-new sign-up and
  the onboarding steps were last checked by hand; 01-onboarding now runs on an onboarded account.
  The Freiburg demo member stands in for a new member outside Atlanta.
- **No imported events in the EU** until the attorney answers the EU database-right question;
  Freiburg members get places, member plans and Ticketmaster or SeatGeek shows once those keys
  exist.
- **Map tiles and imported images were not loaded in the test container** (their hosts are
  blocked); the map is checked through its list panel and by hand.
- **Web push, email and the weekly scorecard are skipped** until the VAPID keys, `RESEND_API_KEY`
  and `SCORECARD_TO` exist.
- **08-coaching runs at phone width only**; the coaching screens at 1280 were checked by hand.
- **The QA coach account's "E2E tennis" listings are archived** (Nov 5,
  `supabase/staging/qa_e2e_listings_cleanup.sql`, run 42064423565: 4 archived, none left active).
  Re-run it after book-only runs of 08-coaching; it leaves a listing with a booking still to come.
- **The demo accounts live on staging**, so an iPhone walkthrough of them needs a staging-pointed
  preview deployment (release A section 2).
- Fixed since release A: the feed now applies distance inside a member's hubs (migration 57), so a
  Freiburg member no longer sees Atlanta plans under This week.
