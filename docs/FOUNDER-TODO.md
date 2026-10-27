# Founder To-Do: things only Sai can do

Claude cannot create accounts, enter payment details, or sign anything. Everything below needs you. Ordered by lead time. Cash this week: about $16 (domain $9.99 the first year, $15/yr after; DMCA agent $6). Everything else is free until the triggers in `FINANCIAL-PLAN.md` fire; the store accounts ($124) come after the evidence test.

## Accounts (consolidated Oct 26 to 27)

- **GitHub**: one account, `SaiPutumbaka`, primary email the Gmail address. The `SaiPutumbaka323` account is deleted, and the `.edu` inbox is no longer reachable (item 9 says what that means for testing campus verification).
- **Supabase**: one account (signs in with GitHub), sole Owner of the "Activity Planet" organization (`vfkjimwkzkcdyzjseamp`) with two projects: production `gtesfiqxqontescqpllo` (us-west-2) and staging `gzrscndzzggxmcwnvvcq` (us-east-1). The rice-n-pie and Envi projects are deleted. No GitHub repository is connected at the project level, and it stays that way: `.github/workflows/migrate.yml` owns migrations.
- **Vercel**: unchanged (signs in with GitHub). Two projects on the same repo: `activity-planet` (site, root `apps/web`) and `activity-planet-app` (app, root `apps/app`).

## Now (Oct 27 to Nov 2)

0. **Approve the production cutover** (read `docs/ops/production-cutover.md`, ten minutes). Production still runs the v1 schema with an empty migration history, so the pipeline cannot be switched on until the v1 tables are dropped and the eight v2 migrations are pushed. The document is the plan; nothing runs on production until you say go. Item 7 has to happen first.
1. **Buy `activityplanet.app`** on Vercel (Domains; $9.99 the first year, $15/yr after) and attach it to the `activity-planet` project; add `app.activityplanet.app` to `activity-planet-app`. Then start **Resend** (resend.com, free) domain verification the same day; DNS can take 24 hours. Resend unlocks the email templates (item 8) and real verification-code emails.
2. **Register a DMCA designated agent** at dmca.copyright.gov ($6; individuals can register). Needed for the safe harbor on user-uploaded photos.
3. **Open the app URL to testers** (after the cutover): `activity-planet-app.vercel.app` is behind Vercel Authentication, so only you, signed in to Vercel, can open it. Either attach `app.activityplanet.app` (item 1) or, in that project's Settings, Deployment Protection, set Vercel Authentication to "Only Preview Deployments". Until the cutover the deployed app points at the v1 database and sign-up there fails, so there is no hurry.
4. **Google Cloud OAuth**: console.cloud.google.com, new project "Activity Planet," APIs and Services, Credentials. Create three OAuth clients: Web, iOS (bundle id `app.activityplanet.mobile`), Android (package `app.activityplanet.mobile`; Claude will give you the SHA-1 and SHA-256). Paste the Web client ID and secret into Supabase, Authentication, Providers, Google, and add the iOS client ID under Authorized Client IDs. Set the consent screen to "In production." Then add `VITE_AUTH_GOOGLE=1` to the `activity-planet-app` project's environment variables so the button renders.
5. **Free accounts, keys into `.env.local`** (never into chat): PostHog (us.posthog.com), Sentry (sentry.io), Anthropic (console.anthropic.com; add a small prepaid credit, $5 to 10), Geoapify (geoapify.com), Sightengine (sightengine.com).
6. **Your GSU friends**: write down each current student you can reach and whether they are in or near one of these clubs: Basketball Club, Men's Volleyball Club, Swim Club, Run Club at GSU, Table Tennis at GSU, tennis clubs, Tabletop Club, Trading Card Game Club, Anime Club, Chess Club, Film Society, dance clubs, esports, PantherDev, Robotics Club. Claude pulls the PIN org directory and drafts the outreach; you send it.
7. **Migration pipeline: one token scope, then a dry run** (ten minutes; gates item 0).
   - The `github-migrate` access token needs one more permission on both projects: **Connection Pooling, Read**. GitHub runners have no IPv6 and a Supabase project's direct database host is IPv6-only, so the CLI has to reach the IPv4 pooler; it learns the pooler address from that endpoint during `supabase link`, and without it `supabase db push` fails with "IPv6 is not supported on your current network". If a scoped token cannot be edited, create a new one with the same scopes plus that one and replace the `SUPABASE_ACCESS_TOKEN` secret. The rest of the token is already enough: Project Settings Read, API Keys Read, API Key Secrets Read, Database Read-write.
   - Then Actions, "Migrate database then deploy", Run workflow, tick **dry_run**. It links both projects, lists the migration history, prints what would be pushed and applies nothing; it runs even while `MIGRATIONS_ENABLED` is unset. Green means the token, the pooler path and the passwords all work. If it fails, send Claude the log.
   - Leave `MIGRATIONS_ENABLED` unset until item 0 is approved.
8. **Supabase Auth: production, SMTP and templates** (after the cutover and Resend): follow `docs/ops/supabase-auth.md`. Production Site URL and redirect URLs; Resend SMTP on both projects, which is also what unlocks editing the four `token_hash` email templates (the dashboard refuses template edits until custom SMTP is configured). Leaked-password protection is a Pro-plan feature and stays off (D-033).
9. **Try the app**: `pnpm dev:app` then `http://localhost:3001` (it points at staging). Create an account with your Gmail and open the link in the same browser (links that work from another device wait on item 8). Walk onboarding (birthday, name and handle, hubs, campus), post a plan, tap Going, and tell Claude everything that feels wrong. Campus verification needs a `.edu` inbox you no longer have: ask a current student to try it, or ask Claude to mint a code on staging with the service-role RPC.

## Next two weeks (Nov 3 to Nov 16)

10. **Ten warm introductions** to club officers through your friends by Nov 20, using the messages Claude drafts. Pick the **sponsoring club** (PantherDev, Tabletop Club or Run Club are natural fits) by Nov 15; it reserves Student Center East tables for Jan 12 to 15 and Jan 19 to 22 and lists launch events on PIN.
11. **GSU contacts**: find current emails for Student Engagement / PIN administration and Campus Recreation program staff. Claude drafts the emails.
12. **Free legal read**: email GSU's Entrepreneurship and Innovation Institute (eni.gsu.edu) asking whether attorney office hours are open to alumni founders; Claude's document drafts will be ready by Nov 2. A paid review waits for Phase 2.
13. **Install the web app** on your iPhone home screen once the app URL is reachable (item 3), and use it every day.

## By week 4 (Nov 16)

15. **Postal address** for emails and the Play listing: a P.O. box or virtual mailbox, not your home.
16. **Support mailbox**: create `support@activityplanet.app` (a forwarder on the domain is enough) as soon as the domain exists. It is the email path on the public account-deletion page (`/account/delete`) and will be the address in the Privacy Policy; until it exists, deletion requests sent by email go nowhere.

## By week 6 (Nov 30)

17. **Stripe account** as a sole proprietor (stripe.com), then the Connect platform profile. Needs the live Terms, Privacy, Refund and Support pages (live by Nov 16).
18. **Name the second moderator** (a trusted friend who accepts a moderator role before soft launch) and set yourself as the **child safety contact** in Play Console.
19. **Discord server**: create it under your account; Claude provides the channel structure, roles, rules and onboarding flow.
20. **Three to five launch coaches**: who they are, and how they take payment today.

## December and January

21. Use release A (Dec 8) and release B (Jan 4) daily and file bugs in Discord.
22. Buy the **Rec Center degree-holding-alumni membership** ($102/semester) in January so you can be at Rec events.
23. Be downtown for **tabling Jan 12 to 15** and as many chapter events as you can Jan 11 to 29.
24. **Main Street Foundry Cohort 7**: watch eni.gsu.edu from Jan 15; the window is expected around Jan 18 to 30. The draft will be ready from week 10.

## Deferred on purpose (triggers in FINANCIAL-PLAN.md)

- Georgia LLC, EIN, business bank account, registered agent: at the first paid booking or 100 weekly actives.
- Paid attorney review: once the LLC exists.
- Supabase Pro (also unlocks leaked-password protection), Vercel Pro: on usage or revenue triggers.
- Apple Developer ($99) and Google Play ($25) accounts, Sign in with Apple email-relay registration, the Android closed test: after the evidence test passes.

## Done

- ~~Vercel second project for the app.~~ Oct 26: `activity-planet-app`, root `apps/app`, Vite preset, `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` (production values, marked sensitive) for Production and Preview; first deploy READY and the sign-in page renders. `VITE_SITE_URL` and `VITE_AUTH_GOOGLE` are not needed: the app defaults to `https://activityplanet.app` for the site links and to Google off. The Supabase marketplace integration was not added, and should not be. Claude added `apps/app/vercel.json` on Oct 27 so deep links such as `/auth/confirm` serve the app instead of a 404.
- ~~Vercel site project Root Directory `apps/web`.~~ Oct 26 (Claude, with your approval); production deploys succeed again.
- ~~Keep-alive variables (was 7a).~~ Oct 26: `SUPABASE_PROD_URL`, `SUPABASE_PROD_PUBLISHABLE_KEY`, `SUPABASE_STAGING_URL`, `SUPABASE_STAGING_PUBLISHABLE_KEY` set; manual run #27 passed (scheduled runs #1 to 26 had failed for lack of them). Production was pinged by hand on day 7 of idling.
- ~~GitHub secrets for the migration pipeline.~~ Oct 27: `SUPABASE_ACCESS_TOKEN` (scoped token `github-migrate`, never expires, both projects: Project Settings, API Keys and API Key Secrets Read, Database Read-write), `SUPABASE_STAGING_DB_PASSWORD` and `SUPABASE_PROD_DB_PASSWORD` (both freshly reset), `VERCEL_DEPLOY_HOOK_WEB` and `VERCEL_DEPLOY_HOOK_APP` (hooks named "migrate", branch main). Claude repaired staging's migration history the same day so its eight versions match the repo's filenames; the remaining scope and the dry run are item 7.
- ~~Supabase Auth settings, staging.~~ Oct 26: Site URL `http://localhost:3001`, redirect `http://localhost:3001/**`, minimum password length 8, Confirm email on. Templates and SMTP are item 8; leaked-password protection turned out to be Pro-only (D-033).
- ~~Supabase stays on Free with two active projects.~~ Production and staging; the other projects are deleted.
- ~~Confirm the GSU Spring 2027 first day of classes.~~ Classes begin Monday, January 11, 2027.
- ~~Restore the Supabase project.~~ Restored and healthy on 2026-10-19.
- ~~Confirm iPhone.~~ Yes.
- ~~Decide mobile architecture and account age minimum.~~ Option C and 18+ (D-013, D-018).

## Rules of the road

- Secrets live in `.env.local` (git-ignored) and in Vercel, Supabase and GitHub Actions settings, never in chat or committed files.
- Every change Claude makes is typechecked, linted, built, committed and pushed to `main`; migrations run before the deploy once the pipeline is on. If something on the live site looks half-done during the rebuild, that is expected until the launch go/no-go.
- You review in the browser: the site at `https://activity-planet-saimounish-s-projects.vercel.app` and the app at `https://activity-planet-app.vercel.app` (both behind Vercel Authentication until a custom domain or item 3), then `activityplanet.app` and `app.activityplanet.app`; and on your iPhone as an installed web app.
