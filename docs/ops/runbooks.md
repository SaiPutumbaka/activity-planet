# Operations runbooks (launch audit, November 2026)

Short procedures for the things that will go wrong. Each names who acts and where. Not legal advice; where the attorney's read differs, the attorney wins. The child-safety procedure is its own document: `docs/ops/ncmec-runbook.md`. Backups: `docs/ops/backup-restore.md`.

## 1. Alerts you will get

All go to every active moderator and admin (`user_roles`), in the app inbox, by push and by email (moderation and operations alerts skip the plan-email cap but count against the account-wide email budget, migration 77).

| Alert                         | When                                                                                                                                                       | Do                                        |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| New child-safety report       | A `child_safety` report is filed (due in 4 hours)                                                                                                          | `docs/ops/ncmec-runbook.md`               |
| New report to review          | Any other report (at most one an hour)                                                                                                                     | `/admin/reports` within 24 hours          |
| New intimate-image takedown   | An NCII request (48 hours; 4 hours when a minor may be shown)                                                                                              | Section 3                                 |
| New listing removal request   | A listing or source removal request (at most one an hour)                                                                                                  | `/admin/takedowns`, listing tab           |
| Moderation queue needs a look | Hourly: reports or takedowns due within 4 hours or overdue, chat photos queued over 12 hours, deletions unfinished over an hour, removals open over 3 days | Open `/admin`; each count names its queue |
| Health alert                  | Daily 13:17 UTC: failed server calls, failed scheduled jobs, or no upcoming plans                                                                          | Section 6                                 |
| Event collector needs a look  | Hourly: stale or failing sources and jobs                                                                                                                  | `/admin/health`                           |

## 2. Incident or outage

1. Check: the site's `/api/health`, the app, the Supabase dashboard (Project status, Logs: logs on the Free plan last one day, so look now), Vercel deployments, GitHub Actions.
2. A bad deploy: in Vercel, Deployments, promote the previous deployment (instant rollback). A bad migration: never edit it; write a fix-forward migration and push it through `migrate.yml` (staging first). If data was damaged, restore from backup into a new project (`backup-restore.md`) and copy back only the damaged rows.
3. Supabase paused the project (7 idle days on Free): Dashboard, Restore project. `keepalive.yml` should prevent it; check it is still scheduled (section 8).
4. Tell members if it lasts over an hour or touched their data: a status line on the site's home page, and email only if personal data was affected (section 7).
5. Write down what happened, when and what you changed, in a dated note in `docs/ops/`.

## 3. Intimate-image (NCII) takedown

1. Open `/admin/takedowns`. Due 48 hours after receipt (Take It Down Act), 4 hours when "may be under 18" is ticked: then follow `ncmec-runbook.md` first.
2. Find each location given. Remove with "Block image" (the image is deleted, its hashes block re-uploads, and every copy found is removed). Do not download or forward the image.
3. Mark the request removed or rejected with a short note. The requester's contact details are cleared a year after it closes.
4. If the uploader is a member, consider a ban; their account's photos are held as evidence if they delete it (migration 77).

## 4. Copyright (DMCA) notice

1. Notices come to `support@activityplanet.app` (and, once registered, the designated agent address in FOUNDER-TODO). Check it has the six elements listed on `/terms` ("Copyright").
2. Remove or hide the material, tell the poster (with the notice, redacting the complainant's personal details if they ask), and file an in-app report on it with reason `copyright`, then action it, so it counts as a strike.
3. Repeat infringers: `mod_copyright_strikes(user)`; three upheld in three years closes the account (Terms).
4. A counter-notice: forward it to the complainant; restore after 10 to 14 business days unless they tell you they filed suit.

## 5. Finishing an incomplete account deletion

The sweep (`account-deletion-sweep`, every 15 minutes) retries any deletion left unfinished over 10 minutes, up to 20 times, 30 minutes apart; the hourly moderation alert counts the ones still open after an hour.

1. In the SQL editor (read-only first): `select user_id, requested_at, attempts, last_attempt_at, last_error from public.account_deletions where completed_at is null;`. `last_error` is a code from `supabase/functions/delete-account/finish.ts`.
2. Fix the cause (for example a Storage outage, or a legal-hold copy that failed: `legal_hold_copy_failed`).
3. Retry now: `select public.account_deletion_dispatch(true);` and check the row's `completed_at` a minute later. For a row past 20 attempts, reset it first: `update public.account_deletions set attempts = 0 where user_id = '<id>';`.
4. Never delete the ledger row by hand; it is the deletion's evidence (D-031).

## 6. Health alerts

- `http_errors`: in the SQL editor, `select status_code, count(*) from net._http_response where created > now() - interval '1 day' group by 1;` then the Edge Function logs for the failing function.
- `cron_failures`: `select jobname, status, return_message, start_time from cron.job_run_details d join cron.job j using (jobid) where d.status = 'failed' order by start_time desc limit 20;`
- `no_upcoming_events`: `/admin/health`; check the nightly `collector-ingest.yml` run on main.

## 7. Law-enforcement and legal requests

1. Requests come by email or post. Do not answer from the moderator account; forward to Sai.
2. Verify it is genuine (call the agency on a number you look up yourself).
3. US: we disclose content only with a search warrant, and basic subscriber records with a subpoena; an emergency request (imminent danger of death or serious injury) can be answered at once with the minimum needed. Outside the US, ask the attorney.
4. Preserve on request (18 U.S.C. 2703(f)) for 90 days: make a dated note of what is preserved; the ban plus the evidence hold keep account data from being deleted.
5. Log every request, what was disclosed and when, in a private document (not this repository).

## 8. Key rotation and monthly checks

Rotate when someone leaves, a key may have leaked, or yearly:

| Key                                                                                                                               | Where it lives                                                               | Rotate                                                                                                                     |
| --------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Supabase database passwords                                                                                                       | GitHub secrets (production environment)                                      | Dashboard, Database, Reset password; update the secret                                                                     |
| `SUPABASE_STAGING_ACCESS_TOKEN`, `SUPABASE_PROD_ACCESS_TOKEN` (H5; the old `SUPABASE_ACCESS_TOKEN` is the fallback until deleted) | GitHub secret (staging: repository; production: production environment only) | supabase.com account tokens; one token per project, new token, update, revoke old                                          |
| Service role key (site)                                                                                                           | Vercel env                                                                   | Dashboard, API keys; new secret key, update Vercel, revoke old                                                             |
| Resend, Sightengine, Geoapify, Ticketmaster, SeatGeek, VAPID                                                                      | Edge Function secrets                                                        | Provider dashboard; VAPID rotation unsubscribes every push device                                                          |
| Turnstile secret (`TURNSTILE_SECRET_KEY`; optional `TURNSTILE_HOSTNAMES`, extra allowed hosts, comma separated)                   | Vercel env                                                                   | Cloudflare dashboard                                                                                                       |
| `BACKUP_REPO_TOKEN`                                                                                                               | GitHub secret                                                                | Yearly, before it expires                                                                                                  |
| Database-generated secrets (collector, image guard, deletion sweep)                                                               | Vault                                                                        | `select vault.update_secret(id, encode(extensions.gen_random_bytes(32), 'hex')) from vault.secrets where name = '<name>';` |

Monthly (first Monday): GitHub disables scheduled workflows after 60 days without repository activity, so open Actions and check that `keepalive`, `backup`, `collector-ingest` and `discovery` ran in the last day; re-enable any that GitHub switched off. Check the backup release list in the private repository.

## 9. When a free-tier cap is hit

| Cap                                                                     | What happens                                                                                                                                                                                                                  | Do                                                                                                                                                     |
| ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Resend (100 a day, 3,000 a month, shared with Auth email)               | Database budget (`email_daily_cap_total`, `email_monthly_cap_total`) stops our emails first, keeping a reserve for sign-up and password email; plan emails skip with `daily_cap` or `email_budget` (in-app and push still go) | Lower `notify_email_daily_cap` in `meta`; if sign-up emails fail, check Supabase Auth rate limits; a paid Resend plan is the trigger in FINANCIAL-PLAN |
| Sightengine (2,000 operations a month)                                  | Past `chat_classifier_daily_cap`, `chat_classifier_user_daily` or the monthly cap, chat photos wait for a moderator                                                                                                           | Work the photo queue (`/admin/reports`, photos); lower the caps in `meta`                                                                              |
| Geoapify (3,000 credits a day)                                          | Server: places fill and geocoding stop for the day (database budget). Browser key: address search fails                                                                                                                       | Restrict the browser key to the app's origins (FOUNDER-TODO)                                                                                           |
| Ticketmaster, SeatGeek                                                  | Collector budget stops the lane for the day                                                                                                                                                                                   | Nothing; it resumes the next day                                                                                                                       |
| Supabase Free (500 MB database, 1 GB storage, 2 GB egress, 7-day pause) | Writes fail near the limit; the project pauses when idle                                                                                                                                                                      | Dashboard usage page; the Pro plan is the FINANCIAL-PLAN trigger                                                                                       |
| Vercel Hobby                                                            | Non-commercial use only; function and bandwidth limits                                                                                                                                                                        | Move to Pro before charging anyone (FINANCIAL-PLAN)                                                                                                    |
| GitHub Actions                                                          | Public repository minutes are free; artifacts and logs are public                                                                                                                                                             | Never print data in a workflow                                                                                                                         |
