# Founder To-Do: things only Sai can do

Claude cannot create accounts, enter payment details, or sign anything. Everything below needs you. Ordered by lead time. Total cash this week: about $16 (domain $10, DMCA agent $6). Everything else is free until the triggers in `FINANCIAL-PLAN.md` fire; the store accounts ($124) come after the evidence test.

## This week (Oct 20 to 26)

0. **Vercel second project for the app** (the first half is done: on Oct 26 Claude set the site project's Root Directory to `apps/web` with your approval and the next production deploy succeeded; the vercel.app URL is behind Vercel Authentication until a custom domain is attached, see item 1). Add a second project for the product app: Add New, Project, import the same `SaiPutumbaka/activity-planet` repo, set Root Directory to `apps/app`, framework Vite, name it `activity-planet-app`, and under Environment Variables add `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` (same values as the existing project's `NEXT_PUBLIC_` ones). Claude's Vercel access can list projects but not change them.
1. **Buy `activityplanet.app`** (about $10/yr) from the Vercel dashboard (Domains) or any registrar and point it at the Vercel project. Then start **Resend** (resend.com, free) domain verification the same day; DNS can take 24 hours.
2. **Register a DMCA designated agent** at dmca.copyright.gov ($6; individuals can register). Needed for the safe harbor on user-uploaded photos.
3. **Supabase**: stay on Free. (Done by Claude: the free `activity-planet-staging` project exists in us-east-1 for CI migrations. A free org allows two active projects, so rice-n-pie and Envi stay paused.)
4. **Google Cloud OAuth**: console.cloud.google.com, new project "Activity Planet," APIs and Services, Credentials. Create three OAuth clients: Web, iOS (bundle id `app.activityplanet.mobile`), Android (package `app.activityplanet.mobile`; Claude will give you the SHA-1 and SHA-256). Paste the Web client ID and secret into Supabase, Authentication, Providers, Google, and add the iOS client ID under Authorized Client IDs. Set the consent screen to "In production."
5. **Free accounts, keys into `.env.local`** (never into chat): PostHog (us.posthog.com), Sentry (sentry.io), Anthropic (console.anthropic.com; add a small prepaid credit, $5 to 10), Geoapify (geoapify.com), Sightengine (sightengine.com).
6. **Your GSU friends**: write down each current student you can reach and whether they are in or near one of these clubs: Basketball Club, Men's Volleyball Club, Swim Club, Run Club at GSU, Table Tennis at GSU, tennis clubs, Tabletop Club, Trading Card Game Club, Anime Club, Chess Club, Film Society, dance clubs, esports, PantherDev, Robotics Club. Claude pulls the PIN org directory and drafts the outreach; you send it.
7a. **Keep-alive variables, five minutes, soon** (the production database has had no real traffic since Oct 19 and Supabase pauses free projects after seven idle days): in the GitHub repo, Settings, Secrets and variables, Actions, *Variables* tab, add `SUPABASE_PROD_URL` and `SUPABASE_PROD_PUBLISHABLE_KEY` (Supabase dashboard, production project, Project Settings, API Keys, the `sb_publishable_` key; it is the browser key, not a secret) and the same two for staging as `SUPABASE_STAGING_URL` / `SUPABASE_STAGING_PUBLISHABLE_KEY`. Then Actions, "Keep the free-tier databases awake", Run workflow. If the production project shows as paused in the Supabase dashboard, press Restore first.
7. **GitHub secrets for the migration pipeline** (Claude will tell you exactly which three values and where): a Supabase access token and the database passwords for production and staging, added under the repo's Settings, Secrets and variables, Actions. Keep the repo public.
8. **Supabase Auth settings, staging first** (15 minutes, unblocks end-to-end testing): follow `docs/ops/supabase-auth.md`. Redirect URLs for `http://localhost:3001/**`, the four email templates switched to `token_hash` links, leaked-password protection on. Supabase's built-in mailer only delivers to organization members and two emails an hour, so until Resend SMTP is set, sign up on staging with your own Gmail.
9. **Try the app**: `pnpm dev:app` then `http://localhost:3001` (it points at staging). Create an account with your own email, open the link, walk onboarding (birthday, name and handle, hubs, campus) and tell Claude everything that feels wrong. This is the first thing you can hold in your hand.

## Next two weeks (Oct 27 to Nov 9)

10. **Ten warm introductions** to club officers through your friends by Nov 20, using the messages Claude drafts. Pick the **sponsoring club** (PantherDev, Tabletop Club or Run Club are natural fits) by Nov 15; it reserves Student Center East tables for Jan 12 to 15 and Jan 19 to 22 and lists launch events on PIN.
11. **GSU contacts**: find current emails for Student Engagement / PIN administration and Campus Recreation program staff. Claude drafts the emails.
12. **Free legal read**: email GSU's Entrepreneurship and Innovation Institute (eni.gsu.edu) asking whether attorney office hours are open to alumni founders; Claude's document drafts will be ready by Nov 2. A paid review waits for Phase 2.
13. **Install the web app** on your iPhone home screen when the first build lands in week 3, and use it every day.

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
- Supabase Pro, Vercel Pro: on usage or revenue triggers.
- Apple Developer ($99) and Google Play ($25) accounts, Sign in with Apple email-relay registration, the Android closed test: after the evidence test passes.

## Done

- ~~Confirm the GSU Spring 2027 first day of classes.~~ Classes begin Monday, January 11, 2027.
- ~~Restore the Supabase project.~~ Restored and healthy on 2026-10-19.
- ~~Confirm iPhone.~~ Yes.
- ~~Decide mobile architecture and account age minimum.~~ Option C and 18+ (D-013, D-018).

## Rules of the road

- Secrets live in `.env.local` (git-ignored) and in Vercel and Supabase environment settings, never in chat or committed files.
- Every change Claude makes is typechecked, linted, built, committed and pushed to `main`; migrations run before the deploy. If something on the live site looks half-done during the rebuild, that is expected until the launch go/no-go.
- You review in the browser at `https://activity-planet-saimounish-s-projects.vercel.app` (then `activityplanet.app`) and on your iPhone as an installed web app from week 3.
