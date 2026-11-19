# Activity Planet: questions for an attorney

Prepared Nov 19, 2026 for a first (free or low-cost) legal read. Everything below is a description of what the product does today and a list of questions. Nothing in it is a legal conclusion; where it says "we think" or "Claude's draft says", that is the reason we are asking, not an answer.

## 1. What the product is

- **Activity Planet** is a free web app (installable on a phone home screen) at `https://app.activityplanet.app`, with a public site at `https://activityplanet.app`. It helps adults (18 and over) anywhere in the world find people and things to do near them: interest groups ("hubs"), plans that members post and RSVP to, group and one-to-one chat (text and photos), a map of public places (courts, parks, stores) built from OpenStreetMap, and a feed of public events near the member.
- **Public events** come from an automated collector (`ActivityPlanetBot`): official APIs (Ticketmaster Discovery, SeatGeek Platform), public open-data portals (for example the City of Calgary, with its required attribution), public calendar feeds (ICS/RSS), and a reader for schema.org `Event` markup on public web pages. It stores facts (title, time, place), a short excerpt (up to about 300 characters) and a link back to the source; it honors robots.txt and every listing has a removal link. Since Nov 18 it also finds new public calendars by itself in new areas (outside the EU, EEA and UK; see question 1).
- **Coaching marketplace** (built, payments switched off on production): coaches list sessions, members request and book them. Payments would run through Stripe Connect Express, with a 12% platform fee (at least US$3). Until the questions in section 4 are answered, coaches arrange payment directly and the app says so.
- **Moderation**: reports, blocks, a moderator queue, automatic checks on chat photos (Sightengine), hash-blocking of removed abuse images, a CSAM reporting runbook (NCMEC CyberTipline, one-year preservation) and a Take It Down Act removal page for intimate images.
- **Operator**: the founder, Sai, as a sole proprietor, Georgia, United States. No LLC yet (planned at the first paid booking or 100 weekly active members). Postal address: a P.O. box or virtual mailbox is being set up (not a home address).
- **Where data lives**: Supabase (database, auth, file storage; United States, AWS us-west-2), Vercel (web hosting), Resend (email), GitHub (Actions for scheduled jobs; GitHub Pages for public place files). Other processors are listed on the Privacy Policy page.
- **Scale today**: pre-launch. Testing with the founder and a few friends; no revenue.

## 2. The draft pages to read

All are live with a "DRAFT: pending review by an attorney" banner. The version string is printed at the top of each page; the app records which Terms and Privacy versions each member accepted.

| Page                 | Link                                     | Version                                                                      |
| -------------------- | ---------------------------------------- | ---------------------------------------------------------------------------- |
| Terms of Service     | https://activityplanet.app/terms         | `terms 2026-11.2`                                                            |
| Privacy Policy       | https://activityplanet.app/privacy       | `privacy 2026-11.2`                                                          |
| Community Guidelines | https://activityplanet.app/guidelines    | `guidelines 2026-11`                                                         |
| Coach Terms          | https://activityplanet.app/coach-terms   | `coach-terms 2026-12`                                                        |
| Refund Policy        | https://activityplanet.app/refund-policy | `refund-policy 2026-12`                                                      |
| Collector (bot) page | https://activityplanet.app/bot           | no version (describes the collector, its User-Agent, robots.txt and removal) |

Related public pages: `/account/delete` (account deletion), `/safety/intimate-images` (Take It Down Act requests), `/support`.

When a reviewed text replaces a draft, we bump that page's version and remove its banner.

## 3. Numbered questions

### 1. EU database right and the collector

The collector can automatically find and read the public event calendars of venues and store facts, a short excerpt and a link. In the EU, the sui generis database right (Directive 96/9/EC, Article 7; the CJEU's Innoweb C-202/12 and CV-Online C-762/19) protects a "substantial part" of a database that took substantial investment. Today automatic discovery is **off** for the EU, EEA and UK (two independent switches); member-suggested sources are allowed everywhere.

- (a) May the collector read EU venues' public calendars and store facts, an excerpt of up to about 300 characters and a link, as it does in the US?
- (b) Does it matter whether it reads one venue's own calendar versus an aggregator's listings?
- (c) Does the UK database right raise anything different?
- (d) If yes with conditions, which (for example honoring an opt-out, limiting the excerpt, never copying images)?

### 2. Ticketmaster and SeatGeek terms next to paid coaching

The app shows Ticketmaster and SeatGeek events ("Shows and games") from their free developer APIs, with links to buy on their sites. Ticketmaster's Discovery API terms appear to restrict earning revenue from its content; SeatGeek's terms ask for its logo wherever its data appears (the app shows "Powered by SeatGeek" with a link) and Ticketmaster asks for removal requests to be handled within 24 hours.

- (a) Does showing these listings in an app that also has a paid coaching marketplace (with a platform fee) count as monetising their content?
- (b) What about future ads or fees elsewhere in the app?
- (c) Anything else in either API's terms that the current display or caching (listings refreshed nightly) does not meet?

### 3. The D-040 collector posture (United States)

The collector uses, in order: official APIs, public feeds (ICS/RSS) and open data, then a reader for schema.org `Event` markup on public pages. It identifies itself (`ActivityPlanetBot/0.1 (+https://activity-planet.vercel.app/bot)`), honors robots.txt, limits itself to a few requests per site, stores facts, an excerpt of up to about 300 characters and a link, and offers organizer claim and one-click removal on every item. Event cover images from sources may be shown (the Privacy Policy and Terms mention "imported covers").

- (a) Is this posture reasonable for copyright (descriptions and images can be protected even though facts are not), for website terms of use that forbid automated access, and for computer-access laws?
- (b) Are imported cover images a problem, and should they be dropped or only linked?
- (c) Is the Section 230 posture (we host and display third-party listings; we do not author them; an AI step only adds tags) described accurately in the Terms?
- (d) Should the `/bot` page or the Terms say anything more?

### 4. Coach Terms and Refund Policy

Drafts at `/coach-terms` and `/refund-policy`. Proposed launch rules (still to be confirmed by Sai): free cancellation 24 hours or more before a session, 50% refund inside 24 hours, a client no-show forfeits, a coach cancellation or no-show refunds in full. Platform fee 12%, at least US$3; the platform absorbs Stripe's processing fee. Coaches are independent; the platform is not the coach's employer.

- (a) Are these two documents enough to switch payments on (with Stripe Connect Express), and what is missing?
- (b) Coach classification: anything to watch (independent contractor language, who sets prices)?
- (c) Does the operator need to be an LLC before taking a platform fee, or is that a business choice?
- (d) Anything for sales tax or for consumer-protection rules on cancellation and refunds (Georgia, other US states, EU)?

### 5. Nominatim usage

The nightly collector geocodes the venue text of imported events with OpenStreetMap's free Nominatim service: at most 1 request every 2 seconds, an identifying User-Agent, results cached. When a Geoapify server key is present, Geoapify is used instead (up to 300 calls a day).

- (a) Is this within Nominatim's usage policy?
- (b) Does storing the resulting points bring the event table under the ODbL (share-alike), and what does that mean for the monthly public ODbL dump of places?
- (c) Related: does Geoapify's free plan ("Limited Commercial Use") allow republishing its place rows in that public dump?

### 6. GDPR and UK GDPR

The app is open to adults anywhere, so EU and UK residents can sign up. Built so far: data download (You, Download my data), immediate account deletion, a retention table in the Privacy Policy, recording of which policy versions a member accepted, location kept coarse in public views, and the statement that data is transferred to and processed in the United States.

- (a) **Controller identity and address**: is a sole proprietor's name and a P.O. box or virtual mailbox enough?
- (b) **Lawful basis per purpose**: the Privacy Policy lists the purposes; which basis fits each (contract, legitimate interests, consent), especially for chat photo checks, the evidence hold on reported content, and notification emails?
- (c) **EU and UK representative (Article 27)**: is one needed at this scale, and is there a low-cost way?
- (d) **Transfer mechanism**: what is needed for transfers to the US (processors' Data Privacy Framework certifications, Standard Contractual Clauses in their terms)?
- (e) **Response times and process**: one month for access, deletion and other requests; is the support mailbox plus the in-app tools enough?
- (f) **Device storage** (the "On your device" section: local storage for settings and the installed app; no advertising cookies): is a consent banner needed for EU/UK visitors?
- (g) Anything else the Privacy Policy must add for EU/UK members.

### 7. CAN-SPAM classification of notification emails

Every email has a working unsubscribe link and, once the postal address exists, the address in the footer. Members choose per type in the app. The emails are:

- Account and security: sign-up confirmation, magic link, password reset, email change, verification codes.
- About a member's own activity: RSVP confirmed or approved, waitlist promoted, event updated or cancelled, event reminder, check-in prompt, booking requested, confirmed, declined, cancelled, payment due, reminder, no-show, review prompt, review received or replied to, coach payout action needed, new message and message request.
- About groups the member joined: a new event in a hub, an organizer's broadcast to their attendees.
- Operations (moderators only): new report, new takedown, moderation due, health alert.
- Internal: a weekly scorecard to the founder.

Questions: (a) which of these are "transactional or relationship" messages and which are "commercial"? (b) Are the hub new-event emails and organizer broadcasts commercial? (c) Is a P.O. box or virtual mailbox a valid "physical postal address" for the footer?

### 8. Sightengine processing

Photos sent in a chat are checked by Sightengine (an image-moderation API) before anyone sees them. Our servers send it the photo only (no name, account or conversation); it returns scores; when it is unsure, unavailable or a usage limit is reached, a moderator looks first. If a photo is reported, a copy is held as evidence. Without the key, every chat photo goes to a moderator.

- (a) What should we confirm with Sightengine (where it processes, how long it keeps images, whether it trains on them, its data processing terms)?
- (b) Is this an automated decision under GDPR Article 22, given that a person reviews anything not clearly fine?
- (c) Is the Privacy Policy's description enough?

### 9. Repeat-infringer policy and DMCA

The Terms explain how to send a copyright notice (to the support email for now) and say we close the accounts of repeat infringers: three upheld copyright reports in three years. The moderation tools count upheld copyright reports per member. A DMCA designated agent registration with the Copyright Office is being prepared (`docs/legal/dmca-agent-prep.md`); it waits for the postal address.

- (a) Is "three upheld reports in three years" a reasonable repeat-infringer policy?
- (b) Is a counter-notice process needed in the Terms, and what should it say?
- (c) Can the sole proprietor be the designated agent, and is a P.O. box or virtual mailbox acceptable as the service provider's address (the Copyright Office asks for a street address for the provider)?

### 10. Liability cap and Georgia venue

The Terms say: the service is provided "as is"; no liability for indirect, incidental, special, consequential or punitive damages, or for what happens between members at plans, sessions or events; total liability capped at the greater of what the member paid in the previous 12 months and US$100; members indemnify for claims caused by their content or breach; Georgia law; state or federal courts in Fulton County, Georgia, unless the member's local law gives them the right to sue at home; 30 days of informal resolution before court. There is no arbitration clause and no class-action waiver.

- (a) Are the cap and exclusions enforceable for consumers in Georgia, other US states, the EU and the UK, given the carve-out?
- (b) Should there be an arbitration clause or class-action waiver, or is leaving them out better for a worldwide consumer app?
- (c) Meeting strangers in person is the core use: is anything more needed (assumption of risk, safety tips, an in-person disclaimer)?

## 4. Other items worth a minute if time allows

- **Georgia SB 351** (O.C.G.A. 39-6, social media age law): the app is 18+ only with a date-of-birth gate. Is that enough, or does the law require more?
- **ODbL for member-contributed places**: the Terms license members' place facts under ODbL 1.0; is that wording right?
- **Not affiliated**: the app names schools, venues and leagues in listings; is the "Not affiliated" section enough?

## 5. What we need back

For each numbered question: a short answer, or "needs a paid review". For each draft page: changes to make, or "fine to publish". Claude then updates the pages, bumps their versions and removes the DRAFT banners. Send replies to Sai.
