# Financial Plan (lean)

Written 2026-10-19 at Sai's direction: spend as little as possible until there is evidence the idea has a future, then reinvest revenue and seek funding. Every dollar below has a trigger. Amounts are list prices on 2026-10-19; free-tier limits change, so re-check before relying on one.

## Principle

Phase 0 and Phase 1 run on free tiers plus the one cost that cannot be avoided for an iPhone app (Apple's $99 developer fee). The LLC, the attorney, paid hosting tiers and paid tooling wait for evidence. Evidence is defined in advance (section 3) so the decision to spend is made by numbers, not mood.

## 1. Phase 0: Build (Oct 20, 2026 to Jan 10, 2027)

Target: under $15 per month, about $134 one-time.

| Service | Tier | Cost | Limit that matters | Mitigation |
|---------|------|------|--------------------|------------|
| Supabase | Free | $0 | Pauses after 7 idle days; 500 MB database; 1 GB storage; 2 active free projects per org | A GitHub Actions cron pings `/api/health` every 6 hours so it never idles. Staging is the second free project; the rice-n-pie and Envi projects stay paused. |
| Vercel | Hobby | $0 | Terms allow personal, non-commercial use only | Pre-revenue beta is a gray area. Upgrade to Pro ($20) at first revenue or the day Vercel asks. |
| Resend | Free | $0 | 3,000 emails per month, 100 per day | Enough for a few hundred users. Daily digests wait for Phase 2. |
| PostHog | Free | $0 | 1M events per month | Fine. |
| Sentry | Free | $0 | 5,000 errors per month | Fine. |
| Geoapify (geocoding) | Free | $0 | 3,000 requests per day | Venues are cached; imports mostly carry coordinates. |
| Sightengine (image moderation) | Free | $0 | Low monthly operation cap | Enough for beta uploads; confirm the cap when the account is created. |
| MapTiler | Free | $0 | 100,000 tile loads per month | Fine. |
| Supabase embeddings (gte-small) | Free | $0 | On-platform | No vendor. |
| Claude API | Pay as you go | $5 to 15 | Tagging imported events plus the assistant | Cache tags; batch nightly. |
| GitHub Actions | Free | $0 | Free for public repos, including macOS runners for iOS builds | Repo stays public. |
| Domain `activityplanet.app` | | $10 per year | | Buy once. |
| Apple Developer Program | Individual | $99 per year | Required for TestFlight and the App Store | The one unavoidable cost. Seller shows as Sai's name. |
| Google Play Console | Personal | $25 once | 12 testers for 14 days before production | Pay when the Android build is ready (week 4). |
| DMCA designated agent | | $6 once | Individuals can register | Register before launch. |

Deferred until a trigger in section 4: LLC and registered agent, attorney, Supabase Pro, Vercel Pro, paid moderation volume, Stripe Connect's per-coach fee (only charged once coaches are active).

## 2. Phase 1: Beta (Jan 11 to about Mar 14, 2027)

Same run rate. The only new spend is whatever Stripe charges per booking once coaching payments are live (section 5), which is funded by the bookings themselves.

## 3. The evidence test (measured about Mar 8, 2027, eight weeks after launch)

The idea has grounds for a future if, in a single week:

| Signal | Target |
|--------|--------|
| Signups since launch | 300 |
| Weekly active users | 150 |
| Human-hosted events per week | 20 |
| Attendees who attended a second event within 30 days | 30% |
| Active chapters | 10 |
| Coaches with 3 or more completed bookings | 5 |
| Imported-shelf click-through | above 2% (or the shelf is hidden) |

Hit most of these and we move to Phase 2 and start spending. Miss most and we diagnose, change the product, and keep the run rate flat; nothing in this plan requires money to iterate.

## 4. Phase 2: Evidence, then commit (spring 2027)

Each spend has a trigger. Do them in this order as triggers fire.

| Trigger | Spend | Why then |
|---------|-------|----------|
| First paid booking, or 100 weekly actives, whichever first | Georgia LLC (about $100 plus $50 per year), EIN, business bank account, registered agent or virtual mailbox ($100 to 300 per year) | Money or scale is when personal liability starts to matter. Stripe can start under Sai as a sole proprietor and move to the LLC later. |
| First $500 of cumulative revenue | Vercel Pro ($20 per month) | Clears the non-commercial terms with revenue to show for it. |
| Database over 400 MB, or free-tier pauses causing complaints, or 500 monthly actives | Supabase Pro ($25 per month) | Only when the free tier actually constrains. |
| LLC exists | Attorney review of Terms, Privacy, Coach Terms and the Georgia age-law question ($1,500 to 3,000) | Until then: template documents plus free legal office hours (GSU's Entrepreneurship and Innovation Institute ran attorney office hours for Foundry founders; ask ENI; several Atlanta firms give a free first consult). |
| Monthly uploads exceed the free moderation cap | Paid moderation tier ($0 to 20 per month) | Volume-driven. |
| Three or more coaches active | Nothing new; Stripe's $2 per active connected account per month is netted against their bookings | See section 5. |

## 5. Revenue lines, in order

1. **Coaching platform fee.** Coaches set their own services and prices. Activity Planet keeps a platform fee of 12% of each booking with a $3 minimum, deducted automatically; the coach receives the rest. Worked example on a $40 session: fee = max(12% of $40, $3) = $4.80. Stripe's processing is 2.9% plus $0.30 = $1.46; if the platform absorbs it the platform nets $3.34 and the coach receives $35.20; if the coach absorbs it the platform nets $4.80 and the coach receives $33.74 (decide in Coach Terms; proposal: platform absorbs it, coaches like round numbers). Stripe also charges the platform $2 per coach per month in which that coach has a payout, so one booking a month per coach covers it. Fifty bookings a month at $40 is about $167 of platform revenue, more than ten times the Phase 0 run rate.
2. **Local business sponsorship (spring).** Downtown businesses within walking distance of campus (bars with trivia nights, Puttshack, bowling and arcade venues, coffee shops near the residence halls) sponsor a hub or offer a perk to people marked Going. Target $100 to 300 per sponsor per month; five sponsors cover a full Phase 2 run rate. This is a phone call and a landing page, not code.
3. **Promoted events (spring).** A chapter, coach or business pays to pin an event to the top of a hub for a week. $10 to 25 each.
4. **Campus or organization licensing (summer).** An institution pays for an official space with admin tools, analytics and verified-domain onboarding. Requires a VPAT and a security questionnaire; price after the first conversation with GSU.
5. **Premium member features (later).** Only after the free loop is proven.

Reinvestment rule: 100% of app revenue stays in the business until it covers the run rate plus growth spend; no founder salary until Phase 3.

## 6. Non-dilutive money and programs

- **Main Street Foundry Cohort 7** (GSU ENI): application expected around Jan 18 to 30, 2027; drafted in week 10 with launch numbers pasted in. Mentorship, legal office hours, and historically seed money for some founders.
- **Atlanta Tech Village Pre-Accelerator**: next cohort opens around December to January; on-site 1 to 2 days per week in Buckhead; confirm eligibility with ATV.
- **ATDC Educate** (Georgia Tech): $25 per quarter for Georgia residents; workshops and coaching; the Accelerate tier needs an MVP with traction, which is exactly what Phase 1 produces.
- **Goodie Nation**: rolling, equity-free community and investor access.
- **GSU pitch competitions and ENI micro-grants**: watch eni.gsu.edu.
- Not counting on: Techstars Atlanta (dormant) or the Atlanta Innovation Cup (student competition; check eligibility as a May 2026 graduate before applying).

## 7. Phase 3: Fund or bootstrap (summer 2027)

Decide from Phase 2 numbers. Bootstrap if sponsorships plus coaching cover the run rate and a modest growth budget; the business stays an LLC. Raise a pre-seed from Atlanta angels if growth outpaces revenue; that usually means converting to a Delaware C-corp, which is why the LLC is not rushed now. Either way, the pitch is the one-campus numbers from Phase 1 and 2, not the 2025 deck.

## 8. What the lean path costs us, honestly

- A free database can pause after seven idle days; the keep-alive cron prevents it, and a cold start if it ever happens is about a minute.
- Hosting on a hobby tier is against the letter of Vercel's terms for a startup; the fix is an upgrade the day there is revenue or a notice.
- No attorney before launch means template documents and higher legal exposure until Phase 2; free office hours reduce it.
- An individual Apple account puts Sai's name as the App Store seller; the LLC can take over the account later.
- A personal Google Play account needs 12 friends to install a test build and keep it for 14 days before the Android app can go public.
- Stripe under a sole proprietor means Sai personally is the platform of record for disputes until the LLC exists; keep coaching volume small until then.
