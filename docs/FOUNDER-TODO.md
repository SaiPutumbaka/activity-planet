# Founder To-Do: things only Sai can do

Claude cannot create accounts, enter payment details, file with the state, or sign legal documents. Everything below needs you. The order matters: this week's items have lead times that decide whether the apps can be in the stores by January.

## This week (Oct 20 to 26)

1. **Answer the ten open questions** at the end of `PLAN.md` section 12 (design taste, 18+, store seller identity, mobile architecture and iPhone, coaching shapes and fee, second moderator, alcohol and private venues, budget, named GSU students, your hours).
2. **File the Georgia LLC** at ecorp.sos.ga.gov as "Activity Planet LLC" (check name availability there first); pay for expedited processing (2 business days). Same day: **EIN** at irs.gov (free). Use a **registered agent or virtual mailbox** address, not your home; it will appear on emails and store listings.
3. **Request a D-U-N-S number** the day the LLC is approved (free; Apple's lookup tool at developer.apple.com/enroll/duns-lookup; 5 or more business days). Apple and Google both need it to enroll the LLC as the developer. Without it the App Store seller is your personal name and Google Play shows your legal address.
4. **Register a DMCA designated agent** at dmca.copyright.gov ($6). Needed for the safe harbor on user-uploaded photos.
5. **Buy `activityplanet.app`** (about $10/yr) from the Vercel dashboard (Domains) or any registrar and point it at the Vercel project. Then start **Resend** (resend.com) domain verification the same day; DNS can take 24 hours.
6. **Supabase Pro** ($25/mo) on the Activity Planet project (dashboard, Organization, Billing) so it never pauses again. Create a second project named `activity-planet-staging` (region us-east-1) for CI migrations.
7. **Vercel Pro** ($20/mo) on the `activity-planet` project; Hobby terms prohibit commercial use.
8. **Google Cloud OAuth**: console.cloud.google.com, new project "Activity Planet," APIs and Services, Credentials. Create three OAuth clients: Web (for the site), iOS (bundle id `app.activityplanet.mobile`), Android (package `app.activityplanet.mobile`; Claude will give you the SHA-1 and SHA-256). Paste the Web client ID and secret into Supabase, Authentication, Providers, Google, and add the iOS client ID under Authorized Client IDs. Set the consent screen to "In production."
9. **Free accounts, keys into `.env.local`** (never into chat): PostHog (us.posthog.com), Sentry (sentry.io), Anthropic (console.anthropic.com), Geoapify (geoapify.com, geocoding), Sightengine (sightengine.com, image moderation).
10. **Pull your student network**: write down every current GSU student you can reach, and for each whether they are in or near one of these RSOs: Basketball Club, Men's Volleyball Club, Swim Club, Run Club at GSU, Table Tennis at GSU, tennis clubs, Tabletop Club, Trading Card Game Club, Anime Club, Chess Club, Film Society, dance clubs, esports, PantherDev, Robotics Club. Claude will pull the PIN org directory and draft the outreach; you send it from your account.
11. **Confirm you have an iPhone** on current iOS (TestFlight and Apple's enrollment identity check need one) and that the repo stays public through launch (GitHub's macOS build runners are free only for public repos).

## Next two weeks (Oct 27 to Nov 9)

12. **Apple Developer Program** ($99/yr, developer.apple.com) and **Google Play Console** ($25, play.google.com/console), both enrolled as **Activity Planet LLC** once the D-U-N-S arrives. Apple's organization verification can take 1 to 3 weeks and includes a phone call. If the D-U-N-S has not arrived by Nov 13, decide: enroll Apple as an individual (your name as seller) and move Android to February.
13. **Book the attorney**: a Georgia-licensed attorney for the document set (Terms, Privacy, Community Guidelines, Coach Terms, Refund Policy, Captain agreement), the "Activity Planet" trademark question, and Georgia's social-media age law (SB 351). Budget $1,500 to 3,000. Claude's drafts will be ready for review by Nov 2.
14. **Ten warm introductions** to RSO officers through your student friends by Nov 20, using the messages Claude drafts. Pick the **sponsoring RSO** (PantherDev, Tabletop Club or Run Club are natural fits) by Nov 15; it reserves Student Center East tables for Jan 12 to 15 and Jan 19 to 22 and lists launch events on PIN.
15. **GSU contacts**: find current emails for Student Engagement / PIN administration and Campus Recreation program staff. Claude drafts the emails (Engage API key, permission to reference Georgia State, RSS courtesy notice, intramural schedules).
16. After Resend verifies the domain, **register `activityplanet.app` and Resend's bounce subdomain** under Apple Developer, Services, Sign in with Apple for Email Communication, so users who choose Hide My Email receive our mail.

## By week 6 (Nov 30)

17. **Stripe account** under the LLC (stripe.com), then the Connect platform profile. Needs the live Terms, Privacy, Refund and Support pages (live by Nov 16).
18. **Name the second moderator** (a trusted friend who accepts a moderator role before soft launch) and set yourself as the **child safety contact** in Play Console.
19. **Discord server**: create it under your account; Claude provides the channel structure, roles, rules and onboarding flow.
20. **Three to five launch coaches**: who they are, and how they take payment today.

## December and January

21. Respond to App Review messages within hours during Dec 8 to 14 and Jan 4 to 8.
22. Buy the **Rec Center degree-holding-alumni membership** ($102/semester) in January so you can be at Rec events.
23. Be downtown for **tabling Jan 12 to 15** and as many chapter events as you can Jan 11 to 29.
24. **Main Street Foundry Cohort 7**: watch eni.gsu.edu from Jan 15; the application window is expected around Jan 18 to 30. The draft will be ready from week 10.

## Done

- ~~Confirm the GSU Spring 2027 first day of classes.~~ Classes begin Monday, January 11, 2027 (University System of Georgia calendar).
- ~~Restore the Supabase project.~~ Restored and healthy on 2026-10-19.

## Rules of the road

- Secrets live in `.env.local` (git-ignored) and in Vercel and Supabase environment settings, never in chat or committed files.
- Every change Claude makes is typechecked, linted, built, committed and pushed to `main`; migrations run before the deploy. If something on the live site looks half-done during the rebuild, that is expected until the launch go/no-go.
- You review in the browser at `https://activity-planet.vercel.app` (then `activityplanet.app`) and on your iPhone via TestFlight from week 3.
