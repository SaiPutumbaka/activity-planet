# Founder To-Do: things only Sai can do

Claude cannot create accounts, enter payment details, or sign legal documents. Everything below needs you. Order matters: the top items unblock the build this week.

## This week (unblocks weeks 1 and 2)

1. **Answer the five open questions** at the end of `PLAN.md` (design taste, 18+ policy, coaching fee, budget, Discord).
2. **Supabase Pro** ($25/mo) on the Activity Planet project so it never pauses again: Supabase dashboard, Organization, Billing. Also create a second free project named `activity-planet-staging` (region us-east-1) for CI migrations.
3. **Vercel Pro** ($20/mo) on the `activity-planet` project: Hobby plan terms prohibit commercial use.
4. **Buy `activityplanet.app`** (about $10/yr) from the Vercel dashboard (Domains) or any registrar; point it at the Vercel project.
5. **Google Cloud OAuth client** for Google sign-in: console.cloud.google.com, new project "Activity Planet," APIs and Services, Credentials, OAuth client (Web). Paste the Client ID and secret into Supabase, Authentication, Providers, Google. Add the Supabase callback URL Google asks for.
6. **Resend account** (resend.com) and verify the `activityplanet.app` domain once bought; create an API key and give it to Claude via `.env.local` (never paste keys into chat).
7. **PostHog** (us.posthog.com) and **Sentry** (sentry.io) free accounts; create one project each and put the keys in `.env.local`.
8. **Anthropic API key** (console.anthropic.com) for the AI features; `.env.local`.
9. **MapTiler** free account (maptiler.com) for map tiles and geocoding; `.env.local`.

## Next two weeks

10. **Apple Developer Program** ($99/yr, developer.apple.com). Enrollment can take days; start now. Needed for TestFlight, App Store, and Sign in with Apple.
11. **Google Play Console** ($25 once, play.google.com/console). Identity verification can take days.
12. **Georgia LLC**: ecorp.sos.ga.gov, "Activity Planet LLC" (check name availability there first), about $100. Then an **EIN** (free, irs.gov) and a **business bank account**.
13. **Trademark consult**: a 30-minute call with a trademark attorney about "Activity Planet" vs. "ACTIVITY PLANIT" and "PLANET APP." Budget $300 to 500.
14. **Captain candidates**: write down 25 names of people who already run something at GSU (pickup basketball at the Rec, pool in the game room, anime nights, running groups, intramural captains, org presidents) and how to reach each. Claude will draft the outreach.
15. **GSU contacts**: find the current email for Student Engagement / PIN administration and Campus Recreation program staff. Claude will draft the partnership emails.

## By week 6

16. **Stripe account** under the LLC (stripe.com), then apply for Connect (platform). Needs the live site with Terms and Privacy pages.
17. **Discord server**: create it under your account; Claude will provide the channel structure, roles, rules and onboarding flow to paste in.
18. Confirm the **GSU Spring 2027 first day of classes** from the Registrar's calendar so launch week is exact.

## Rules of the road

- Secrets live in `.env.local` (git-ignored) and in Vercel's Environment Variables, never in chat or in committed files.
- Every change Claude makes is typechecked, linted, built, committed and pushed to `main`; Vercel deploys it. If something on the live site looks half-done during the rebuild, that is expected until the launch go/no-go.
- You review in the browser at `https://activity-planet.vercel.app` (then `activityplanet.app`) and in TestFlight once the iOS build exists.
