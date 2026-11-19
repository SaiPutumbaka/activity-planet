# DMCA designated agent: what to enter

Prepared Nov 19, 2026. Registering a designated agent with the US Copyright Office is part of the DMCA section 512 safe harbor for content members upload (chat photos, profile photos, plan details). It takes about 20 minutes online and costs **$6**.

**Source check.** Claude's environment could not open copyright.gov, ecfr.gov or law.cornell.edu on Nov 19 (they are outside its network allowlist), so this page comes from the Copyright Office's own published walkthrough transcripts and the regulation (37 CFR 201.38) as quoted in search results, not from a live read of the form. Before you file, open https://www.copyright.gov/dmca-directory/ and check the fee and fields against this list; if anything differs, follow the form and tell Claude.

## Before you start

- The postal address must exist first (FOUNDER-TODO, "Postal address and DMCA").
- A card for the $6 fee (paid through Pay.gov).
- About 20 minutes.

## Step 1: create the registration account (free)

1. Go to https://dmca.copyright.gov (linked from the DMCA Designated Agent Directory page).
2. Click "Register" and create a user account: your name, email, phone, a password.
3. **Primary and secondary point of contact**: the Office asks for one person it can contact about the account, and optionally a second. These are **not** published. Enter yourself as primary (your email and phone). Secondary: leave empty, or your second moderator if they agree.

## Step 2: designate an agent ("Designate Agent")

The form asks for the following. What is shown publicly in the directory is marked **public**.

| Field                              | Public | What to enter                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ---------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Service provider's full legal name | Yes    | Your own full legal name (a sole proprietor's legal name is the person's name). Once the Georgia LLC exists, amend this to the LLC's exact legal name.                                                                                                                                                                                                                                                                                                                   |
| Service provider's address         | Yes    | The regulation asks for the provider's **physical street address**; a P.O. box is accepted for the provider only in exceptional cases (for example a documented personal-safety reason) through a separate request to the Office. A virtual mailbox that gives you a street address (with a suite or unit number) is the usual route; ask the attorney whether it is acceptable (packet question 9c). Never your home address if you can avoid it, because it is public. |
| Alternate names                    | Yes    | Every name the public might search for: `Activity Planet`, `ActivityPlanet`, `activityplanet.app`, `app.activityplanet.app`, `Activity Planet app`. Add the LLC name later.                                                                                                                                                                                                                                                                                              |
| Designated agent's name            | Yes    | Either your name, or a role such as "Copyright Agent" (the regulation allows an individual, a specific position or title, or an organization). "Copyright Agent, Activity Planet" keeps your name off this line; your name still appears as the provider until the LLC exists.                                                                                                                                                                                           |
| Agent's organization (if asked)    | Yes    | `Activity Planet`                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Agent's physical mail address      | Yes    | The postal address. For the **agent**, a street address **or a P.O. box** is allowed.                                                                                                                                                                                                                                                                                                                                                                                    |
| Agent's telephone number           | Yes    | A number you are willing to publish (a free Google Voice number works).                                                                                                                                                                                                                                                                                                                                                                                                  |
| Agent's email address              | Yes    | `support@activityplanet.app` (the forwarder must exist first and you must have sent it a test email), or a dedicated `copyright@activityplanet.app` alias on the same forwarder.                                                                                                                                                                                                                                                                                         |
| Attestation                        | No     | Tick that the information is accurate and that you are authorized to submit it for the service provider; type your name as the electronic signature.                                                                                                                                                                                                                                                                                                                     |

Then pay **$6** (the same fee applies to each later amendment and each renewal). The designation appears in the public directory right away and you can download a certificate (PDF); save it in your files, not in this repository.

## Step 3: keep it alive

- A designation **expires three years** after it is made or last renewed or amended. Renew from the same account before then ($6). Claude will add a reminder to the monthly checks; put one in your calendar for about Nov 2029 too.
- Amend it ($6) when the address, email or phone changes, and when the LLC replaces you as the provider.

## What Claude will publish once you are registered

Tell Claude "DMCA agent registered" and send the **public** values only (they are public in the directory anyway). Claude then:

1. Changes the Terms of Service "Copyright" section (`/terms`) so notices go to the designated agent instead of only the support email, with:
   - the agent's name (or "Copyright Agent"),
   - the service provider's name and `Activity Planet`,
   - the agent's mailing address, telephone and email,
   - the elements a valid notice must contain (already listed on the page),
   - a counter-notice paragraph, once the attorney confirms its wording (packet question 9b),
   - a link to the Copyright Office directory entry.
2. Keeps the repeat-infringer rule (three upheld copyright reports in three years) unless the attorney changes it.
3. Bumps the Terms version (from `terms 2026-11.2`) so members accept the new text at their next sign-in.
4. Adds the agent's email to the in-app copyright report path and the `/support` page.
5. Marks M14 done in `docs/ops/launch-audit-2026-11.md` and adds the renewal date to the monthly checks in `docs/ops/runbooks.md`.

## References

- DMCA Designated Agent Directory: https://www.copyright.gov/dmca-directory/
- Registration site: https://dmca.copyright.gov
- Regulation: 37 CFR 201.38 (designation contents, P.O. box rule, three-year expiration); fee schedule 37 CFR 201.3
- Copyright Office walkthroughs (transcripts): https://www.copyright.gov/dmca-directory/transcripts/register.pdf, https://www.copyright.gov/dmca-directory/transcripts/designate-an-agent.pdf, https://www.copyright.gov/dmca-directory/transcripts/renew.pdf
