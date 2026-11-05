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
```

Use test accounts on staging only, never production. Screenshots go to `E2E_QA_DIR`
(default `./e2e-output`, git-ignored). Output names flows and steps only, never user rows.
The map canvas needs the OpenFreeMap tile host; where it is unreachable the Map tab falls back
to its list.
