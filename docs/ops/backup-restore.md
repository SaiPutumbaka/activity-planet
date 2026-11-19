# Backup and restore (launch audit C2)

Production (`gtesfiqxqontescqpllo`) is on the Supabase Free plan: no daily backups and no point-in-time restore. `.github/workflows/backup.yml` makes our own. It is free: GitHub Actions minutes on a public repository, `age` for encryption, and storage that already exists (a private bucket on the staging project), optionally plus a private GitHub repository.

## What it does

Every day at 03:41 UTC, from `main` only, under the `production` GitHub Environment:

1. Checks the settings and the `age` public key (it encrypts a test string with it before anything is dumped), and that the staging bucket answers.
2. `supabase db dump` three times: roles (`--role-only`), schema, data (`--data-only --use-copy`).
3. Copies the Storage buckets `avatars`, `chat-images`, `chat-evidence` and `legal-hold` (database dumps never include files).
4. Optionally (`verify_restore` on a manual run) restores the dump into a throwaway, empty local Supabase stack on the runner (started in an empty directory, so none of this repository's migrations or seeds are applied first) and prints `RESTORE PASS`, or `RESTORE FAIL` with where it stopped (file and line; the error text only for the roles and schema files, never for data).
5. Packs everything and encrypts it with `age` to the public key in `vars.BACKUP_AGE_RECIPIENT` (`tar` writes straight into `age`, so no unencrypted archive is ever written; the plaintext folder is deleted before any upload, and the output is checked to start with the `age` header).
6. Uploads only the encrypted file to each target that is set up:
   - **Staging bucket (default):** the private bucket `prod-backups` on the staging project (`gzrscndzzggxmcwnvvcq`), created by migration 80 on staging only, with no policies (only the service role reaches it). The file is split into parts of at most 45 MB (the Free plan's per-file limit is 50 MB) and stored as `prod-backups/<stamp>/part-000`, `part-001`, ... with `<stamp>/SHA256SUMS` (the checksum of each part and of the whole file). The newest **14** stamps are kept. It needs no new token: the step reads the staging service key at run time through the Management API with the staging access token the other workflows already use (`SUPABASE_STAGING_ACCESS_TOKEN`, or `SUPABASE_ACCESS_TOKEN` until the split), and the key is masked in the log. Set the variable `BACKUP_STAGING` to `false` to turn this target off.
   - **Private repository (optional):** a release asset of the private repository `vars.BACKUP_REPO`, with `secrets.BACKUP_REPO_TOKEN`. The newest 30 releases are kept.
7. Fails the run if any target that was set up did not get the backup (GitHub then emails the repository owner).

Nothing readable reaches this public repository: every command that could print data writes to `/dev/null`, logs show sizes, counts and HTTP codes only, there are no workflow artifacts, and the plaintext is deleted from the runner before the job ends. The staging project only ever holds the encrypted parts; without the private key they cannot be read, so staging's wider access (test accounts, branch workflows) does not widen access to production data.

Storage budget: the staging project's Free plan has 1 GB of Storage in all. 14 copies must fit next to staging's own files, so while a compressed, encrypted backup is under about 50 MB this is fine. If it grows past that, lower `BACKUP_KEEP_STAGING` in the workflow or add the private repository target (a release asset may be up to 2 GB).

**Check the staging target from any branch:** Run workflow with `storage_selftest` ticked. It uploads 1 KB of random bytes (no data) to `prod-backups/selftest/`, lists it, deletes it and prints `SELFTEST PASS` or `SELFTEST FAIL`. It never reads production.

## One-time setup (Sai)

The only required step:

1. Install `age` on your own computer (`brew install age`, or the release from github.com/FiloSottile/age) and run `age-keygen -o activity-planet-backup.key`. The file holds the **private key** (`AGE-SECRET-KEY-...`): keep it offline (a password manager attachment and a USB stick); never put it in GitHub, Supabase, chat or this repository. It prints the **public key** (`age1...`).
2. In this repository, Settings, Secrets and variables, Actions, Variables: `BACKUP_AGE_RECIPIENT` = the `age1...` public key. (A value that does not start with `age1` fails the run before anything is dumped, so a pasted private key is refused.)
3. Run the workflow once by hand from `main` with `verify_restore` ticked and check that it ends with `RESTORE PASS` and `Uploaded N parts as <stamp>`.

Optional second copy off Supabase: create a **private** GitHub repository (for example `SaiPutumbaka/activity-planet-backups`), a fine-grained personal access token with access to that one repository only (Contents: Read and write, one-year expiry), then set the variable `BACKUP_REPO` = `owner/name` and the secret `BACKUP_REPO_TOKEN` (in the `production` environment).

Until `BACKUP_AGE_RECIPIENT` is set the job is a no-op that says so.

## Restore

Restore into a **new** project (or staging), never over production while it still serves users.

1. Download the newest backup:
   - from the staging bucket: in the staging dashboard, Storage, `prod-backups`, open the newest `<stamp>` folder and download every `part-*` and `SHA256SUMS` (or `supabase --experimental storage cp -r ss:///prod-backups/<stamp> . --project-ref gzrscndzzggxmcwnvvcq`). Join them: `cat part-* > activity-planet-prod-<stamp>.tar.gz.age`, then check with `sha256sum -c SHA256SUMS` (every line must say OK);
   - or the newest release asset from the private repository, when that target is set up.
2. Decrypt and unpack on your own computer: `age -d -i activity-planet-backup.key activity-planet-prod-<stamp>.tar.gz.age | tar -xzf -`. You get `ap-backup/roles.sql`, `schema.sql`, `data.sql` and `storage/<bucket>/...`.
3. Create the target project in the Supabase dashboard (same region, same extensions). Copy its database connection string (Session pooler, IPv4).
4. Restore the database in one transaction:

   ```sh
   psql "$TARGET_DB_URL" --single-transaction --variable ON_ERROR_STOP=1 \
     --file ap-backup/roles.sql --file ap-backup/schema.sql \
     --command 'SET session_replication_role = replica' --file ap-backup/data.sql
   ```

5. Restore the files bucket by bucket: `supabase --experimental storage cp -r ap-backup/storage/<bucket> ss:///<bucket> --project-ref <new ref>` (create the buckets first if the schema restore did not; their settings are in the migrations).
6. Re-create what lives outside the database: Edge Function secrets (FOUNDER-TODO "keys"), the vault secrets are inside the dump, Auth settings (Site URL, redirect URLs, SMTP, providers; `docs/ops/supabase-auth.md`), pg_cron jobs (inside the dump) and `select public.set_project_url('https://<new ref>.supabase.co')`.
7. Point the apps at the new project (Vercel environment variables), redeploy, and run the release B smoke test (`docs/ops/release-b-test-plan.md`).
8. Delete the decrypted files from your computer.

## Test a restore on staging (quarterly)

Run the workflow with `verify_restore` (it restores into a database on the runner, not staging). For a full drill, restore a backup into a fresh free project, run `supabase/tests/regression.txt` against it through a branch's `migrate.yml` pointed at that project, then delete the project.

## What a backup cannot bring back

Anything written after the last dump (up to 24 hours), Supabase Auth settings, Edge Function secrets, and the GitHub and Vercel settings. Account deletions that happened after the dump must be re-applied from the `account_deletions` ledger before the restored project serves users.
