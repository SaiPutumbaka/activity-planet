# Browser smoke flows

Plain Node scripts on Playwright (not part of `pnpm test`). Each exits 0 with `SKIP:` when its
credentials or Playwright are missing. Run against a built app served with `vite preview`:

```sh
pnpm --filter @ap/app build && pnpm --filter @ap/app preview --port 4173 &
export E2E_BASE_URL=http://localhost:4173 E2E_QA_DIR=/some/scratch/folder
export E2E_EMAIL=... E2E_PASSWORD=...       # account A (staging only)
export E2E_EMAIL_B=... E2E_PASSWORD_B=...   # account B (staging only)
node apps/app/e2e/01-onboarding.mjs   # sign in and first-run onboarding (fresh account)
node apps/app/e2e/02-browse.mjs       # Home, Also happening, Hubs, a hub, Map list, Suggest a calendar
node apps/app/e2e/03-plan.mjs         # post a plan, Add to calendar, Share, RSVP and leave
node apps/app/e2e/04-safety-you.mjs   # mute, report, block, Blocked accounts, inbox, settings, delete page
node apps/app/e2e/05-sweep.mjs        # every route at 390x844 and 1280x800
node apps/app/e2e/06-offline.mjs      # "You're offline" with the service worker, recovery when back
node apps/app/e2e/07-messaging.mjs    # photo gate, a request A to B, realtime both ways, typing,
                                      # delete, report, the Chats badge, block stops delivery
node apps/app/e2e/09-collector.mjs    # an imported listing's removal and organizer links, start a
                                      # claim (code, copy, Check now), /organizer, the calendar
                                      # form, the moderator tabs; with E2E_SITE_URL (apps/web on
                                      # :3000) also /bot and /bot/remove?event=
node apps/app/e2e/10-recs.mjs        # For you with chips, Not interested (and Undo), Why am I
                                      # seeing this, Similar plans, the other rows, the privacy
                                      # switches, the install card (iPhone, installed), the update
                                      # toast on a waiting worker; with E2E_SITE_URL (apps/web,
                                      # next build + next start) the landing page at both widths
                                      # (E2E_ONLY=landing runs only that part)
E2E_SITE_URL=http://localhost:3000 node apps/app/e2e/11-site.mjs  # the public site at both
                                      # widths: landing, /bot, Safety Center, policy pages,
                                      # /account/delete, internal links, the 404 (no account)
E2E_PHASE=book node apps/app/e2e/08-coaching.mjs    # A coaches (profile, listing, availability,
                                                    # publish), B requests a time, A confirms, DM
E2E_PHASE=finish node apps/app/e2e/08-coaching.mjs  # A marks it done, B reviews, cleanup
```

`07-messaging.mjs` sends a message request, which needs account A to be a day old: on staging,
run `supabase/staging/qa_account_age.sql` as the `staging_file` of a staging-only `migrate.yml`
run first. Once B has accepted, later runs find an open DM and say so instead of a request.

`08-coaching.mjs` books a slot at least an hour ahead, so it cannot complete in real time: between
`E2E_PHASE=book` and `E2E_PHASE=finish`, run `supabase/staging/qa_coaching_past.sql` as the
`staging_file` of a staging-only `migrate.yml` run; it moves the test accounts' confirmed bookings
into the past. Run 07 before 08, not between its phases: 07 blocks and unblocks the pair, and a
block cancels their open bookings. Both phases run at 390x844 and then at 1280x800, each width
with its own listing and booking (two booking requests a run; the app allows ten a day);
`E2E_WIDTHS=phone` or `E2E_WIDTHS=desktop` runs one width.

Leftovers from earlier runs (plans, listings, bookings, chat messages, test reports, claims and
notifications of the QA accounts, older than a day) are removed by
`supabase/staging/qa_cleanup.sql`, run the same way. It keeps the QA accounts, the demo accounts
(`demo_*`), the demo chapter and demo plans.

02, 05, 08, 09 and 11 walk both widths (390x844 and 1280x800) themselves; the single-width
flows (01, 03, 04, 06, 07, 10) run at the phone width, or at 1280x800 with `E2E_VIEWPORT=desktop`.

Use test accounts on staging only, never production. Screenshots go to `E2E_QA_DIR`
(default `./e2e-output`, git-ignored). Output names flows and steps only, never user rows.
The map canvas needs the OpenFreeMap tile host; where it is unreachable the Map tab falls back
to its list.
