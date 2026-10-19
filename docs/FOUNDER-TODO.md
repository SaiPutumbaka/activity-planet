# Founder To-Do: things only Sai can do

Claude cannot create accounts, enter payment details, or sign anything. Everything below needs you. Ordered by lead time. Total cash this week: about $115 (Apple $99, domain $10, DMCA agent $6). Everything else is free until the triggers in `FINANCIAL-PLAN.md` fire.

## This week (Oct 20 to 26)

1. **Decide the two open questions** in `PLAN.md` section 12: mobile architecture and account age minimum. Explanations are in the conversation of 2026-10-19.
2. **Apple Developer Program, individual** ($99/yr, developer.apple.com, enroll from the Apple Developer app on your iPhone; identity check takes about 48 hours). Needed for TestFlight, Sign in with Apple and the App Store. The seller name will be yours until the LLC exists.
3. **Buy `activityplanet.app`** (about $10/yr) from the Vercel dashboard (Domains) or any registrar and point it at the Vercel project. Then start **Resend** (resend.com, free) domain verification the same day; DNS can take 24 hours.
4. **Register a DMCA designated agent** at dmca.copyright.gov ($6; individuals can register). Needed for the safe harbor on user-uploaded photos.
5. **Supabase**: stay on Free. Create a second free project named `activity-planet-staging` (region us-east-1) for CI migrations. Note: a free org allows two active projects, so rice-n-pie and Envi stay paused.
6. **Google Cloud OAuth**: console.cloud.google.com, new project "Activity Planet," APIs and Services, Credentials. Create three OAuth clients: Web, iOS (bundle id `app.activityplanet.mobile`), Android (package `app.activityplanet.mobile`; Claude will give you the SHA-1 and SHA-256). Paste the Web client ID and secret into Supabase, Authentication, Providers, Google, and add the iOS client ID under Authorized Client IDs. Set the consent screen to "In production."
7. **Free accounts, keys into `.env.local`** (never into chat): PostHog (us.posthog.com), Sentry (sentry.io), Anthropic (console.anthropic.com; add a small prepaid credit, $5 to 10), Geoapify (geoapify.com), Sightengine (sightengine.com).
8. **Your GSU friends**: write down each current student you can reach and whether they are in or near one of these clubs: Basketball Club, Men's Volleyball Club, Swim Club, Run Club at GSU, Table Tennis at GSU, tennis clubs, Tabletop Club, Trading Card Game Club, Anime Club, Chess Club, Film Society, dance clubs, esports, PantherDev, Robotics Club. Claude pulls the PIN org directory and drafts the outreach; you send it.
9. **Keep the repo public** through launch (GitHub's macOS build runners for the iOS app are free only for public repos).

## Next two weeks (Oct 27 to Nov 9)

10. **Ten warm introductions** to club officers through your friends by Nov 20, using the messages Claude drafts. Pick the **sponsoring club** (PantherDev, Tabletop Club or Run Club are natural fits) by Nov 15; it reserves Student Center East tables for Jan 12 to 15 and Jan 19 to 22 and lists launch events on PIN.
11. **GSU contacts**: find current emails for Student Engagement / PIN administration and Campus Recreation program staff. Claude drafts the emails.
12. **Free legal read**: email GSU's Entrepreneurship and Innovation Institute (eni.gsu.edu) asking whether attorney office hours are open to alumni founders; Claude's document drafts will be ready by Nov 2. A paid review waits for Phase 2.
13. After Resend verifies the domain, **register `activityplanet.app` and Resend's bounce subdomain** under Apple Developer, Services, Sign in with Apple for Email Communication, so users who choose Hide My Email receive our mail.
14. **Install TestFlight** on your iPhone; the first build arrives in week 3.

## By week 4 (Nov 16)

15. **Google Play Console, personal** ($25, play.google.com/console; identity verification can take days). Then recruit **12 friends with Android phones** to install the closed-test build by Nov 24 and keep it installed for 14 days. Without this, the Android app cannot go public in January.
16. **Postal address** for emails and the Play listing: a P.O. box or virtual mailbox, not your home.

## By week 6 (Nov 30)

17. **Stripe account** as a sole proprietor (stripe.com), then the Connect platform profile. Needs the live Terms, Privacy, Refund and Support pages (live by Nov 16).
18. **Name the second moderator** (a trusted friend who accepts a moderator role before soft launch) and set yourself as the **child safety contact** in Play Console.
19. **Discord server**: create it under your account; Claude provides the channel structure, roles, rules and onboarding flow.
20. **Three to five launch coaches**: who they are, and how they take payment today.

## December and January

21. Respond to App Review messages within hours during Dec 8 to 14 and Jan 4 to 8.
22. Buy the **Rec Center degree-holding-alumni membership** ($102/semester) in January so you can be at Rec events.
23. Be downtown for **tabling Jan 12 to 15** and as many chapter events as you can Jan 11 to 29.
24. **Main Street Foundry Cohort 7**: watch eni.gsu.edu from Jan 15; the window is expected around Jan 18 to 30. The draft will be ready from week 10.

## Deferred on purpose (triggers in FINANCIAL-PLAN.md)

- Georgia LLC, EIN, business bank account, registered agent: at the first paid booking or 100 weekly actives.
- Paid attorney review: once the LLC exists.
- Supabase Pro, Vercel Pro: on usage or revenue triggers.

## Done

- ~~Confirm the GSU Spring 2027 first day of classes.~~ Classes begin Monday, January 11, 2027.
- ~~Restore the Supabase project.~~ Restored and healthy on 2026-10-19.
- ~~Confirm iPhone.~~ Yes.

## Rules of the road

- Secrets live in `.env.local` (git-ignored) and in Vercel and Supabase environment settings, never in chat or committed files.
- Every change Claude makes is typechecked, linted, built, committed and pushed to `main`; migrations run before the deploy. If something on the live site looks half-done during the rebuild, that is expected until the launch go/no-go.
- You review in the browser at `https://activity-planet.vercel.app` (then `activityplanet.app`) and on your iPhone via TestFlight from week 3.
