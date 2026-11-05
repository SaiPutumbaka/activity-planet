# Runbook: suspected child sexual abuse material (CSAM)

For moderators and anyone at Activity Planet who comes across, or is told about, an image, video, message or link that may show the sexual abuse or exploitation of a minor. Written 2026-11-05 (TRUST-SAFETY-LEGAL.md section 3, 18 U.S.C. 2258A as amended by the REPORT Act; PLAN.md 4.11). This is an operating procedure, not legal advice: the attorney reviews it with the rest of the set, and when anything here and the attorney disagree, the attorney wins.

Keep it short in the moment: **do not look again, do not share, preserve, report to NCMEC, lock it down, write it down.**

## 0. When this applies

- Any report with reason `child_safety` (priority 0, due in 4 hours, in `mod_report_queue`).
- Any NCII takedown request with "the person shown may be under 18" ticked (`takedown_requests.involves_minor`, priority 0, due in 4 hours, in `mod_takedown_queue`).
- Anything a moderator, a member, a captain or a support email describes as a sexual image of someone who is or may be under 18, including drawn or AI-generated images that look like a real child, and messages that solicit images from a minor or arrange to meet one for sex.
- You do not need to be sure. "Apparent" is the standard: if it reasonably looks like it, follow this runbook.

If someone is in immediate danger, call 911 (or the local emergency number) first, then continue.

## 1. Do not view, copy or forward

- Stop looking as soon as you recognise what it is. Do not open it again to "confirm", zoom, or show a colleague.
- Never download it, screenshot it, save it to your phone or laptop, attach it to an email, paste it into Slack, Discord, a ticket, GitHub or an AI tool, or send it to the reporter, the uploader or the police by email. Possessing or distributing it is itself a crime; the only lawful path out is the CyberTipline report.
- Do not ask the reporter to send you a copy. If they already did (for example in a support email), do not forward it; leave it where it is and treat that mailbox message as part of the evidence in step 3.
- Do not contact or warn the account that posted it. Do not ban yet if banning would alert them before the content is preserved (step 3 takes minutes; do it first).

## 2. Remove it from view (minutes, not hours)

Do these from the admin tools; none of them requires opening the image.

- First, hide what carries it: `mod_moderate('profile' | 'event' | 'chapter', id, 'hide')`. A hidden profile, plan or chapter is readable only by its owner and moderators, so the image drops out of every surface without being deleted.
- Do **not** call `mod_takedown_block_image` yet: it deletes the stored object within minutes (image-guard's sweep), and the object must be preserved first (step 3). Call it right after the legal-hold copy exists; it then clears the image everywhere, blocks its hashes so copies and re-uploads are refused, and deletes the public object.
- The account: `mod_moderate('profile', id, 'hide')` now; `mod_ban_user(user, note)` once step 3 is done. A ban removes the person's roles, cancels their upcoming plans, ends sign-in and keeps their deletion record for a year.
- Messages (release B): the moderator soft delete hides the message for everyone; it is never hard-deleted while a report is open.

## 3. Preserve (one year)

The law requires the provider to preserve the reported material and the related account information for one year after the CyberTipline report (the REPORT Act extended this from 90 days). Preserve without viewing:

- **Do not delete the Storage object yet.** Before anyone calls `mod_takedown_block_image` on child-safety material, ask the engineer on call (Sai until the second engineer exists) to copy the object, server-side, into the private `legal-hold` bucket (service role only, no public URL, created when first needed; never a personal device), and to stamp the hold in the incident record. Then block the image (step 2); image-guard's sweep deletes the public object and the held copy stays. If the block already ran, say so in the incident record and preserve what remains (hashes, account and log data).
- Record, in the incident record (step 5): the object's bucket and path, its SHA-256 and perceptual hashes (from `image_hashes`, which never holds the image), the uploader's user id and handle, the times of upload and of the report, the report or request id, and the IP addresses and sign-in times Supabase Auth keeps for the account (Auth logs; export the rows for that user only).
- Put a hold on account deletion: if the account is deleted, the `account_deletions` row is kept (banned accounts keep it a year; extend `retain_evidence_until` to one year from the report for any account in this runbook). Reports and `moderation_actions` rows are already kept after deletion.
- Nothing preserved goes into the GitHub repository, Action logs, PostHog, Sentry or any analytics tool.

## 4. Report to NCMEC's CyberTipline (as soon as reasonably possible; aim for the same day)

- Report at **https://report.cybertip.org** (the online form; registered electronic service providers use the ESP reporting API, which Activity Planet registers for once volume justifies it). NCMEC's hotline is 1-800-843-5678.
- The report covers apparent CSAM and also the enticement of a child for sexual acts, child sex trafficking and the other categories NCMEC lists; when unsure, report.
- Include what you recorded in step 3: the uploader's account details (user id, handle, the email on the account, sign-in IP addresses and times), the date and time of the upload, how it came to our attention, and the hashes. Attach the file only through the CyberTipline's own upload, from the legal-hold copy, and only if the form asks for it; do not view it to do so.
- Save the CyberTipline report number in the incident record. NCMEC may forward the report to law enforcement; if law enforcement contacts us with legal process, respond through the founder and the attorney, not from the moderator's own account.
- Do not tell the uploader that a report was made.

## 5. Write it down

Create an incident record (a private note in the founder's legal folder, not in this repository) with: incident id, who found it and when, the report or request id, every action taken with its time (hide, block, ban, hold copy, CyberTipline submission and number), who did each, and the hold expiry date (one year after the CyberTipline report). Keep the record itself for at least as long as the hold. `moderation_actions` already logs the in-product steps; the incident record covers the rest.

## 6. Look after the moderator

Seeing this material is harmful. Whoever handled it hands any remaining queue items to the other moderator for the rest of the day, and can talk it through with the founder. Do not review the same material twice; nobody needs to.

## 7. After the hold

When the hold expires (one year after the CyberTipline report, unless law enforcement or the attorney asks for longer in writing), the engineer deletes the legal-hold copy and notes the date in the incident record. The hashes in `blocked_image_hashes` stay, so the image keeps being refused.

## Checklist

| Step                                                                   | Done by              | Within                                 |
| ---------------------------------------------------------------------- | -------------------- | -------------------------------------- |
| Stop viewing; do not copy or forward                                   | whoever found it     | at once                                |
| Hide the content and the account                                       | moderator            | minutes                                |
| Preserve: legal-hold copy, hashes, account and log data; deletion hold | engineer on call     | before the object is deleted, same day |
| CyberTipline report, number saved                                      | moderator or founder | same day                               |
| Block hashes and ban                                                   | moderator            | right after preservation               |
| Incident record complete                                               | moderator            | same day                               |
| Delete the hold copy                                                   | engineer             | one year after the report              |

## Contacts

- NCMEC CyberTipline: https://report.cybertip.org, 1-800-843-5678.
- Emergency: 911 (or the local emergency number).
- Activity Planet child-safety contact (named in Play Console; FOUNDER-TODO): the founder until the second moderator is named.
