# Trust, Safety and Legal Checklist

Compiled 2026-10-19 from the compliance critique of the v2 plan. Items marked **verified** were checked against the primary source on 2026-10-19; items marked **confirm** come from the critique and should be confirmed by the attorney or by reading the source before relying on them. Nothing here is legal advice; it is the list the attorney reviews.

## 1. App Store (Apple)

- **1.2 User-generated content**: filter objectionable material (image classification on every upload, link and profanity filter), report and block, published contact information, act on reports within 24 hours (reviewers have demanded this), and an EULA clause on objectionable content. Social apps with messaging and in-person meetups should expect an 18+ age rating under the questionnaire mandatory since January 2026.
- **4.2 Minimum functionality**: a remote web view is the "repackaged website" reviewers reject. Ship a bundled client build with native tab bar feel, offline shell, native sign-in, push, share sheet, camera, Universal Links, and in-app browser for outbound links (D-013). Provide a seeded demo account and review notes explaining imported-event cards.
- **4.8 Sign in with Apple**: required because Google sign-in is offered; equal prominence on every sign-in surface; native `ASAuthorization` flow in the app (web OAuth inside a web view is a rejection magnet).
- **5.1.1(v) Account deletion**: in-app, two taps; for Sign in with Apple users, revoke tokens via Apple's `/auth/revoke` REST endpoint (store the Apple refresh token at first sign-in; Supabase does not do this for you). **Verified** (Apple TN3194 per critique; confirm).
- **5.1.1(ix)**: apps that collect sensitive information should be submitted by a legal entity. Another reason for the LLC as seller.
- **3.1.3(d) and (e) Payments**: in-person services (any size) and online one-to-one services may use Stripe in-app; online one-to-few or one-to-many real-time services must use in-app purchase. Launch listing shapes are constrained accordingly; online group sessions open web checkout in the system browser (allowed in the US) or wait. **Verified** verbatim against the live guidelines per the feasibility critique; confirm.
- **5.2.1 Third-party marks**: no "GSU", "Georgia State" or Panther imagery in the app name, subtitle, icon, screenshots or keywords without written permission; nominative use ("events at Georgia State") in content is defensible; disclaimer shown until permission.
- **2.1 Completeness**: the reviewed build must match what is live; ship build B features behind flags until build B is approved.
- **Review timing**: Apple slows Dec 20 to 26; build A on Dec 8 leaves room for one rejection round; build B by Jan 4.

## 2. Google Play

- **Personal vs. organization account**: personal accounts created after Nov 13, 2023 must run a closed test with 12 opted-in testers for 14 continuous days before applying for production access; organization accounts (D-U-N-S) are exempt. A monetizing personal account displays the developer's legal address publicly. **Verified** per Play Help 14151465 and 13628312 (critique); confirm.
- **Child Safety Standards policy** (applies to Social category apps regardless of whether minors are allowed): publish externally accessible standards naming "Activity Planet" exactly as listed that prohibit child sexual abuse and exploitation; in-app reporting; act on actual knowledge of CSAM including removal; a process for reporting confirmed CSAM to NCMEC; a designated child safety contact in Play Console. Play Help 14747720 and 16549787 (critique); confirm.
- **UGC policy**: robust, effective, ongoing moderation; report and block; terms accepted.
- **Account deletion**: a web-accessible deletion page reachable without the app, Data safety form answers, deletion from processors, disclosed retention. Play Help 13327111 (critique).
- **Payments policy**: physical services exempt from Play billing; treat online sessions consistently with Apple.
- **App Links**: `assetlinks.json` with the Play App Signing SHA-256 (available after the app record exists).

## 3. Federal (US)

- **Take It Down Act**: notice-and-removal rules in force since May 19, 2026; a public, plain-language way to request removal of non-consensual intimate imagery; remove the image and known identical copies within 48 hours of a valid request; FTC enforcement. Build: public request page capturing the statutory elements (signature, locating information, good-faith non-consent statement, contact), a 48-hour SLA timer in the moderation queue, perceptual hashing for copies, evidence retention that survives account deletion. **Confirm** effective date and elements with the attorney.
- **18 U.S.C. 2258A (as amended by the REPORT Act)**: report apparent CSAM to NCMEC's CyberTipline on actual knowledge; preserve reported material for one year. Runbook written by week 6.
- **COPPA (amended rule in effect since April 22, 2026)**: no under-13 users; design the date-of-birth screen as a neutral free-entry field with no age hint beside it, a soft failure message, a session cookie to stop back-button retries, and no retention of failed attempts.
- **DMCA 512**: register a designated agent with the Copyright Office ($6); notice-and-takedown clause in the Terms; repeat-infringer policy.
- **Section 230 posture**: host third-party content, don't author it. Imported events are stored verbatim with source and fetched-at timestamps; display facts, a short excerpt and the link; the LLM emits tags and dedupe signals only; one-click claim/takedown for organizers.
- **CAN-SPAM**: physical postal address and working unsubscribe on every digest or marketing email; the LLC's registered agent or virtual mailbox address, never a home address.
- **Anthropic usage policy**: the assistant is labeled as AI, discloses limitations, and acts only on explicit user confirmation.

## 4. Georgia

- **SB 351 (O.C.G.A. 39-6, social media age law)**: the critique reports that on Oct 15, 2026 the Eleventh Circuit vacated the preliminary injunction in NetChoice v. Carr, making the social-media provisions enforceable (commercially reasonable age verification, parental consent for under-16 accounts, limits on targeted advertising to minors, no retention of verification data; AG enforcement, $2,500 per violation, 90-day cure). **Not independently verified; confirm with the attorney.** Mitigation regardless: hard 18+ gate, declared DOB plus `.edu` signal plus ID verification for captains and coaches, a "report underage user" path that suspends on credible report, age-gate logs, no retention of failed attempts.
- **O.C.G.A. 10-1-912**: breach notification commitment in the Privacy Policy.
- **Campus solicitation and space**: Student Center East indoor tables are for RSOs and departments only, booked 7 to 60 days ahead; off-campus vendor partnerships are not permitted; non-RSO use is an external-client rental or a paid Unity Plaza permit. The sponsoring RSO handles tabling. The Rec Center is PantherCard-only after 8 p.m. and on weekends; non-GSU users cannot attend Rec events; Sai needs the alumni membership to be present.

## 5. Stripe Connect

- Express accounts: the platform is liable for negative balances, fraud and disputes; Stripe debits the platform balance when a connected account cannot cover a dispute; application fees are not automatically refunded on refund; Stripe may hold a reserve. The Refund Policy and Coach Terms must allocate these.
- Activation requires a live site with business description, customer-service contact, and refund, dispute and cancellation policy. Legal pages live by Nov 16; Stripe account in week 6.
- Fees: $2 per monthly active connected account plus 0.25% and $0.25 per payout, on top of processing. Hence 12% plus a $3 minimum, or Standard accounts.
- 1099-K thresholds mean most coaches receive no form; Coach Terms state taxes are the coach's responsibility.
- Coach Terms: incorporate the Stripe Connected Account Agreement; coach is the independent service provider, Activity Planet the facilitator; 18+; US work authorization (F-1 international students generally cannot take off-campus paid work); venue permission is the coach's responsibility; credentials self-reported; cancellation windows (for example free 24h+, 50% inside 24h, no-show forfeits); who decides disputes; platform fee refunded proportionally; chargeback consequences.

## 6. Documents and required contents

Live on the domain by Nov 16 unless noted. Drafted by Claude in week 2, reviewed by the attorney.

- **Terms of Service**: 18+ eligibility; Georgia governing law; UGC license; DMCA process; assumption of risk and release for physical activities and for meeting other members; captains and coaches are independent; "verified" means identity check plus reference, not a background check; imported-event disclaimer (not the organizer, accuracy not guaranteed, register at the source); AI assistant disclosure; limitation of liability and indemnity; termination and ban rights; no Georgia State affiliation.
- **Privacy Policy**: every data category (name, photo, DOB, precise and coarse location, `.edu` email, messages, push tokens, RSVPs, bookings); processors by name (Supabase/AWS us-west-2, Vercel, Resend, PostHog, Sentry, Stripe, Anthropic, Geoapify, MapTiler, Sightengine); that moderators can read reported messages; retention periods including one-year preservation for child-safety reports; deletion and export rights; the no-under-18 statement; location consent; photos not used for face recognition; Georgia breach-notification commitment.
- **Community Guidelines**: harassment, hate, sexual content, solicitation, no minors, explicit CSAE ban, off-platform conduct at events counts, public-venue expectation, alcohol events are 21+ and excluded from the campus space, consequences and appeal.
- **Child Safety Standards** page (Google Play), naming "Activity Planet."
- **Non-consensual intimate imagery removal** page and in-app flow.
- **Support / Contact** page with a monitored email.
- **Account Deletion** public page.
- **Captain Program agreement** (week 4): what verification means, conduct, event safety expectations, removal.
- **Coach Terms** and **Refund / Cancellation Policy** (week 9).
- **Safety Center** page: how reporting works, response targets, NCII and DMCA links, "share your plan with a friend," local emergency resources; linked from every event page and the DM composer.

## 7. Product controls that ship with messaging (week 5 to 6)

- Image classification before any uploaded image is visible (avatars, chat, later event photos); block on high confidence, queue on medium.
- Message requests for first contact without a shared event or hub; no images or links until accepted; accounts under 24 hours old cannot send requests.
- Symmetric blocks; blocked users cannot see your attendee row or RSVPs; warning when someone you blocked RSVPs to the same event.
- Report everywhere; auto-hide after N reports pending review; moderator soft delete; account ban; rate limits on messages, event posts and joins.
- Public-venue default for member-posted events; private addresses revealed only after host approval; 21+ flag excluded from the campus space.
- Second moderator with a real role before soft launch; 24-hour report SLA and 48-hour NCII SLA visible in the admin queue.
- Trust-and-safety drill in week 12: a test report, NCII request, DMCA notice and deletion request each completed inside its SLA.

## 8. Privacy engineering

- `profile_private` split at the database level; public profile exposes no email, DOB or precise coordinates; distance shown in bands.
- PostHog session replay off (or input masking plus exclusion of chat and profile routes); Sentry PII scrubbing; no event properties containing message text or precise coordinates.
- Retention schedule written down and matched by the deletion function and the Privacy Policy.
- Geocoding provider whose terms allow stored results (Geoapify); no Mapbox temporary or Google geocodes stored.

## 9. Accessibility and institutional procurement

- WCAG 2.1 AA in the design system from week 2 (contrast tokens, focus states, labels, reduced motion, screen-reader order).
- A VPAT and readiness for a HECVAT security questionnaire before pitching GSU on official promotion; public universities face the DOJ ADA Title II web rule in 2027 and will ask.

## 10. Georgia State's name and marks

- Nominative use only: "Basketball at Georgia State Atlanta," "events at Georgia State University."
- No "GSU," "Georgia State," or Panther imagery in the app name, icon, screenshots or keyword fields.
- "Not affiliated with or endorsed by Georgia State University" on the campus space, landing page and store listings until written permission exists; the permission request is part of the week-3 Student Engagement email.

## 11. Account deletion (built 2026-10-20, on staging)

Three paths, one mechanism. In the app: You tab, Delete my account, type `delete` (`apps/app/src/routes/_app/you_.delete.tsx`). On the web without the app: `/account/delete` explains the in-app path and offers `support@activityplanet.app` for people who cannot sign in (Google Play requires the public URL). By email: support confirms the request from the address on the account, then runs the same deletion with the service role. Deletion is immediate; there is no grace period (D-031).

What happens, in order:

1. `request_account_deletion(p_reason)` (SECURITY DEFINER, authenticated only; migration 5) in one transaction: a ledger row in `account_deletions`; the profile becomes a tombstone (first name "Deleted user", empty bio, no avatar, no campus, `status = 'deleted'`, `deleted_at` stamped); the handle goes to `handle_history` and is replaced with `deleted_` plus ten random characters; the `profile_private`, `notification_prefs`, `push_devices`, `hub_members`, `chapter_members`, `org_memberships`, `verified_emails`, `email_verification_codes` and `user_roles` rows are deleted; `auth.users.banned_until` is set 100 years out and the user metadata wiped, so every sign-in and refresh grant fails from that moment.
2. The `delete-account` Edge Function (service role; the user JWT is verified against the project's JWKS; it refuses unless step 1 ran) removes avatar files from Storage, deletes `auth_provider_secrets`, soft-deletes the auth user (email and OAuth identities obfuscated so the address can sign up again, metadata wiped, every session and refresh token ended) and stamps `completed_at` on the ledger row.
3. The app signs out and returns to the sign-in screen. A token issued before step 1 is accepted by PostgREST until it expires (one hour at most); the app's route guard drops it on the next load because `profiles.deleted_at` is set.

Retention after deletion (the Privacy Policy and the Play Data safety form must say the same):

| Data                                                                                                         | Kept                       | For how long                                                                                                    | Why                                                                        |
| ------------------------------------------------------------------------------------------------------------ | -------------------------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `account_deletions` row: user id, sha256 of the login email, requested and completed times, the reason given | yes                        | 30 days (`retain_evidence_until`), then `purge_account_deletions()` removes it; a moderation hold may extend it | ties a re-registration to reports about the deleted account                |
| The released handle in `handle_history`                                                                      | yes                        | 30 days                                                                                                         | the same hold as a rename; stops immediate impersonation                   |
| The tombstone `profiles` row and the soft-deleted `auth.users` row                                           | yes, with no personal data | indefinitely                                                                                                    | content other people received keeps a "Deleted user" author; the ban holds |
| Moderation evidence (reports, takedown requests, child-safety preservation)                                  | yes                        | per section 3 (one year for child-safety reports)                                                               | legal duty; these tables arrive with messaging                             |
| Payment records                                                                                              | yes                        | as tax law requires                                                                                             | none exist yet; never touched by this flow                                 |
| Everything deleted in step 1 and 2                                                                           | no                         | removed at once                                                                                                 |                                                                            |

Not wired yet, each with a TODO block in the function: Apple token revocation (needs the Apple refresh token stored at first sign-in; Capacitor), processor fan-out (`processors_notified` stays empty until a processor holds personal data), anonymizing messages (no table yet). `purge_account_deletions()` needs a pg_cron schedule once that extension is enabled on the project; until then it is run by hand with the service role. The support mailbox is a placeholder (FOUNDER-TODO item 16).
