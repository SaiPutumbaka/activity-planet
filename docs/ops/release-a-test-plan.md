# Release A test plan

**Release A goes live on Dec 8, with a feature freeze on Dec 5** (ROADMAP week 7 and 8). It contains
the hub map, events, chapters, trust and safety, and account deletion, plus everything merged
through migration 56. It has no messaging and no payments. Release A goes to friends as a dress
rehearsal for the Jan 11 public launch.

This plan says what is checked automatically, what Sai checks by hand on his iPhone with the app
installed, what has to be true before Release A ships, and what is known not to work yet. The
audience is adults 18+ anywhere (D-040), so every check runs in at least two places: Atlanta and
somewhere outside the US (Freiburg, Germany, in the demo data). A university affiliation is
optional throughout.

## 1. Scope

In scope (Release A):

| Area                | What it covers                                                                                                                                                                             |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Accounts            | Sign up, email confirmation, sign in, forgot and reset password, the account-switch screen for email links                                                                                 |
| Onboarding          | Birthday (18+ enforced in the database), name and handle, hubs, a home anywhere (a point or an area), optional affiliation                                                                 |
| Home feed           | Today, This week and Later; Also happening (imported listings); Shows and games (only once any exist); the location sheet and radius                                                       |
| Hubs                | Catalog and search, hub page, join and leave                                                                                                                                               |
| Hub map             | Places for the member's hubs, list panel, place sheet, add a place, suggest an edit, report a place, meeting spots, signed-out map                                                         |
| Plans               | Post (member and chapter), edit, cancel, weekly series, RSVP with the guidelines sheet, waitlist, leave, check-in, "Did you go?", Add to calendar (.ics and Google), share links `/e/<id>` |
| Chapters            | Claim (area or organization), moderator review, chapter page, schedule, captain dashboard, message everyone                                                                                |
| Notifications       | Inbox, unread badge, settings, web push opt-in (only once VAPID keys exist)                                                                                                                |
| Trust and safety    | Mute, block, report (people, plans, chapters, hubs, places), Blocked accounts, the NCII takedown form, image checks                                                                        |
| Admin panel         | Overview, Reports, Image requests, Users lookup, Claims, Places, Calendars, Takedowns, Health                                                                                              |
| Account deletion    | `/you/delete` and the deletion job                                                                                                                                                         |
| Installable web app | Install to the Home Screen, service worker, offline screen, updates                                                                                                                        |

Out of scope (Release B or later): messaging and Chats (the tab says "Coming soon"), coaching and
payments, recommendations, the assistant, store apps, and email delivery before Resend is set up
(FOUNDER-TODO 16a).

## 2. Environments

| Environment           | Database                                                                                     | App                                                                                               | Used for                                                                                        |
| --------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Local throwaway stack | Fresh Postgres from `supabase/migrations` and the seed (the `rehearse` job in `migrate.yml`) | none                                                                                              | Proving every migration applies from scratch                                                    |
| Staging               | `gzrscndzzggxmcwnvvcq`                                                                       | A local build pointed at staging (`apps/app/.env.local`, git-ignored), served with `vite preview` | SQL regression suite, Playwright flows, demo walkthrough                                        |
| Production            | `gtesfiqxqontescqpllo`                                                                       | `activity-planet-app.vercel.app`                                                                  | The iPhone checklist (section 4) and the release itself; changes only through a merge to `main` |

Rules:

- Test and demo accounts exist on **staging only**. They use `@example.com` addresses and are
  marked in `auth.users.raw_user_meta_data` (`qa_e2e` for the browser QA accounts,
  `demo_release_a` for the demo accounts) so they are easy to find and delete. Their passwords never
  go in the repository or in workflow logs.
- Staging schema changes and SQL checks go through `migrate.yml` (`staging_only`), never through
  the Supabase connector.
- Production data is never used for testing. On production, Sai tests with his own account and
  deletes test plans afterwards.
- The demo accounts are on staging, so walking through them on the iPhone needs a deployed app that
  points at staging. Today only production is deployed. To get one, set the Vercel **Preview**
  environment variables of `activity-planet-app` (`VITE_SUPABASE_URL`,
  `VITE_SUPABASE_PUBLISHABLE_KEY`) to the staging project and open a preview deployment of the
  branch. Until then, walk through the demo data on a laptop with the local build (section 3.3).

## 3. Automated checks

### 3.1 Unit tests (every push and PR, `ci.yml`)

```sh
pnpm install
pnpm typecheck && pnpm lint && pnpm test && pnpm build
```

| Package              | Tests (Nov 5)         | Covers                                                                                                                                                                               |
| -------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `apps/app`           | 221 passed, 1 skipped | Feed and map logic, the map's start camera, date and time zones (`viewerZone`), push state, chapters, safety, place files and matching, admin helpers, the offline error screen copy |
| `packages/core`      | 106                   | Shared schemas, validation, types                                                                                                                                                    |
| `packages/collector` | 231                   | Collector adapters, robots.txt and rate rules, discovery                                                                                                                             |

`ci.yml` also runs the Deno tests for the Edge Functions (`import-feed`, `collector`,
`places-fill`, `place-files`, `send-notifications`, `image-guard`) and the place-rules
regeneration check.

### 3.2 SQL regression suite on staging (`supabase/tests/`)

Each file is one transaction. It sets up throwaway rows, asserts in `DO` blocks that raise on
failure (as `authenticated` with `request.jwt.claims` set, so RLS applies), prints only pass or
fail, and rolls back. `supabase/tests/regression.txt` lists the order. Live-data smokes that
cannot roll back are on `skip:` lines.

How to run it: in GitHub, open Actions, **Migrate database then deploy**, then Run workflow on the
branch, with `staging_only` and `staging_tests` ticked (`staging_tests_keep_going` runs every
file and reports every failure). A single file can run as `staging_file`. Production is never
touched by a `staging_only` run.

The suite holds 45 files, covering everything from the feed (`everyone_feed_v2`) through
`notify_worker_fixes`, including `trust_safety`, `ncii_takedown`, `admin_panel`,
`location_anywhere`, `viewer_timezone` and the places and collector files. Every new migration
adds its own file and a line in `regression.txt`.

Run it before each merge to `main` and once more on the release candidate after the Dec 5 freeze.

### 3.3 Browser flows (Playwright, `apps/app/e2e/`)

These are plain Node scripts. They are not part of `pnpm test` because they need staging accounts.
Each prints `PASS`/`FAIL` per step and never prints user rows. Screenshots go to `E2E_QA_DIR`.

```sh
# apps/app/.env.local holds the staging URL and publishable key (git-ignored)
pnpm --filter @ap/app build && pnpm --filter @ap/app preview --port 4173 &
export E2E_BASE_URL=http://localhost:4173 E2E_QA_DIR=/some/scratch/folder
export E2E_EMAIL=... E2E_PASSWORD=...        # account A, staging only
export E2E_EMAIL_B=... E2E_PASSWORD_B=...    # account B, staging only
node apps/app/e2e/01-onboarding.mjs   # sign in and first-run onboarding (fresh accounts)
node apps/app/e2e/02-browse.mjs       # Home, Also happening, Hubs, a hub, Map list, Suggest a calendar
node apps/app/e2e/03-plan.mjs         # post a plan, Add to calendar, Share, RSVP and leave
node apps/app/e2e/04-safety-you.mjs   # mute, report, block, Blocked accounts, inbox, settings, delete page
node apps/app/e2e/05-sweep.mjs        # every route at 390x844 and 1280x800, signed in and out
node apps/app/e2e/06-offline.mjs      # "You're offline" with the service worker, recovery when back
```

Playwright comes from `require('playwright')` or `/opt/node-tools`. When credentials or
Playwright are missing, a script exits 0 with `SKIP:`.

Last results (Nov 5): every flow passes except posting as a chapter, which was not scripted. The
demo walkthrough below covers chapter plans instead. Where the OpenFreeMap tile host is
unreachable, the map canvas does not render, so the map is checked through its list panel in CI.
Real tiles are checked by hand (section 4).

### 3.4 Demo data for the walkthrough (staging)

There are five demo members: an admin and moderator in Atlanta, a chapter organizer in Atlanta, a
member in Decatur, and two members in Freiburg. They have one area chapter (Atlanta Running Demo,
on the Running hub) and seven upcoming plans: four in Atlanta, two of them chapter plans, and three
in Freiburg in Europe/Berlin time. The moderation queue holds one open report, and the claims queue
holds one pending chapter claim. Handles start with `demo_`, plan titles end in "(demo)", bios say
"Demo account for the Release A walkthrough (staging only)", and the accounts carry
`demo_release_a = true`. The sign-in details and the cleanup SQL are kept outside the repository,
in the session's scratchpad `qa` folder. Ask Claude for them.

Walkthrough:

1. Sign in as the Atlanta admin. Home shows the Atlanta plans. `/admin/reports` shows the demo
   report, and `/admin/claims` shows the pending claim. Approve or reject it to see the claimant's
   inbox update.
2. Open `/chapters/atlanta-running-demo`. It shows the chapter card and its two plans.
3. Sign in as a Freiburg member. Home shows the Freiburg plans. A plan page shows Berlin time.

## 4. Manual checklist: Sai's iPhone, installed web app

Use Safari on the iPhone with the production app (`activity-planet-app.vercel.app`, or
`app.activityplanet.app` once attached; Vercel Authentication must allow it, FOUNDER-TODO 3) and
your own account. Tick each line, and file anything else in Discord with a screenshot.

**Install**

- [ ] Safari, Share, Add to Home Screen. The icon and name look right, and the app opens full
      screen with no Safari bars.
- [ ] Nothing sits under the notch or the home indicator: the top bar, the tab bar and the post
      button all clear them.
- [ ] Close the app fully and reopen it. You are still signed in.
- [ ] Rotate to landscape and back. Nothing breaks.

**Sign up and sign in** (use a fresh address, then delete the account at the end)

- [ ] Sign up. The confirmation email arrives, and its link opens the installed app or Safari and
      signs you in. Note which one opens.
- [ ] Forgot password: the email arrives and the reset works.
- [ ] Onboarding: under-18 birthdays are refused, the hub picker scrolls smoothly, and Skip on
      affiliation works.

**Location prompt**

- [ ] Nothing asks for your location on launch.
- [ ] Onboarding "Use my location" shows the iOS prompt once. Allow: the home label is your area.
- [ ] Deny it on a second account, or in Settings, Privacy, Location Services, Safari Websites. The
      app explains how to turn it back on (the how-to sheet) and still lets you pick a place by
      search.
- [ ] Home, location sheet, "Use my location": the feed changes to plans near where you are.

**Notifications permission prompt**

- [ ] You, Notifications. Before the VAPID keys exist (FOUNDER-TODO 16a), the "Turn on
      notifications" button is absent and nothing breaks. After they exist, continue below.
- [ ] In Safari (not installed), the page says to add the app to the Home Screen first.
- [ ] In the installed app, tap "Turn on notifications". The iOS prompt appears only after the tap.
      Allow it.
- [ ] Have a second account RSVP to your plan. A push arrives, and tapping it opens that plan in
      the app.
- [ ] Turn notifications off in the app. No more pushes arrive. Sign out: no pushes for that
      account on this phone.
- [ ] The in-app inbox badge and list update either way.

**Map with real tiles** (cannot be checked in CI)

- [ ] The Map tab draws streets and labels within a few seconds on Wi-Fi and on cellular.
- [ ] It opens at your saved home, or at your current position if you allowed it, not at the whole
      world.
- [ ] Pinch, pan and rotate are smooth, and pins stay on their places.
- [ ] Tap a pin: the place sheet opens, and Directions opens Apple Maps.
- [ ] Switch hubs: the pins change. "All my hubs" shows the union.
- [ ] The list panel matches the pins in view.
- [ ] Dark mode: the map style follows, and labels stay readable.
- [ ] Signed out (open the URL in a private Safari tab): public places and public plans show.

**Plans**

- [ ] Post a plan with a public place and a time. The time shows in your zone. Edit it, then
      cancel it.
- [ ] RSVP Going on someone else's plan. The guidelines sheet appears the first time. Leave the
      plan.
- [ ] Add to calendar opens the iOS calendar sheet. Google Calendar opens in Safari.
- [ ] Share opens the iOS share sheet, and the link opens the plan for someone signed out.

**Offline page**

- [ ] With the app open once, turn on Airplane Mode and reopen it from the Home Screen. It shows
      "You're offline", not a blank screen or "Something broke".
- [ ] Turn Airplane Mode off. The screen reloads by itself within a few seconds.
- [ ] While offline, an already open screen keeps what it showed, and actions fail with a message,
      not silently.

**Updates**

- [ ] After a deploy, close and reopen the app. The new version loads, with no stuck old screen and
      no sign-out.

**Safety and deletion**

- [ ] Report a plan, mute a person, block a person, then unblock them from You, Blocked accounts.
- [ ] Delete the test account from You, Delete account. You are signed out, and signing in again
      fails.

## 5. Release criteria (go or no-go on Dec 7)

Release A ships on Dec 8 only when all of these hold on the release candidate, the commit merged to
`main` after the Dec 5 freeze:

1. `pnpm typecheck`, `lint`, `test` and `build` pass, and the Deno and place-rules jobs pass.
2. A `staging_only` run with `staging_tests` passes every file in `regression.txt`, and the
   production migration run for that commit succeeds.
3. Playwright flows 01 to 06 pass against staging at both widths with no `FAIL` lines, or each
   failure has a written reason.
4. Sai's iPhone checklist (section 4) is complete. Every unticked line has a bug filed and is
   either fixed or accepted in writing as a known gap.
5. There are no open bugs that lose data, show one person's private data to another (addresses,
   home points, emails, blocked people), let an under-18 account in, or block sign-up, onboarding,
   posting, RSVP, report or account deletion.
6. Trust and safety works end to end on production: a test report reaches the admin queue and can
   be resolved, the NCII takedown form submits, and account deletion completes.
7. Rollback is ready: the previous Vercel deployment can be promoted, and every migration since the
   last release was rehearsed on a fresh stack. Migrations are forward-only, so a bad one is fixed
   forward.

## 6. Known gaps (Nov 5)

- **The feed ignores distance inside a member's hubs.** `feed_events_v2` returns every plan in the
  member's hubs, so a member in Freiburg or London sees Atlanta plans under This week, next to "Not
  much close by, so this goes a little further out". Fixing it needs a migration and a product call
  on the radius. It is open, and the demo data shows it.
- **Map tiles were not verified in CI.** The tile host is blocked in the test container, so the map
  canvas has only been checked by hand (section 4).
- **Web push and email are off until keys exist.** VAPID keys and `RESEND_API_KEY` are FOUNDER-TODO
  16a. Until then every email and push is marked skipped, and the inbox works on its own.
- **Sign-up with `example.com` addresses** is rejected by Supabase Auth, so sign-up submission is
  checked by hand with a real address.
- **Posting as a chapter has no Playwright script.** It is covered by the demo data and the
  `chapter_tools` SQL tests.
- **Offline is only the error screen.** The app shell and cached screens open offline, but data
  screens need a connection. There is no offline queue for posts or RSVPs.
- **Minor UI:** top toasts cover the back and Share buttons for a few seconds, and the leave sheet
  mentions a waitlist even when the plan has none.
- **The demo accounts live on staging**, so an iPhone walkthrough of them needs a staging-pointed
  deployment (section 2).
- Messaging, payments, coaching and the assistant are Release B.
