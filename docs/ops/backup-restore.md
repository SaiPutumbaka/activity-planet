# Backup and restore (launch audit C2)

Production (`gtesfiqxqontescqpllo`) is on the Supabase Free plan: no daily backups and no point-in-time restore. `.github/workflows/backup.yml` makes our own. It is free: GitHub Actions minutes on a public repository, a private GitHub repository for the files, and `age` for encryption.

## What it does

Every day at 03:41 UTC, from `main` only, under the `production` GitHub Environment:

1. `supabase db dump` three times: roles (`--role-only`), schema, data (`--data-only --use-copy`).
2. Copies the Storage buckets `avatars`, `chat-images`, `chat-evidence` and `legal-hold` (database dumps never include files).
3. Optionally (`verify_restore` on a manual run) restores the dump into a throwaway, empty local Supabase stack on the runner (started in an empty directory, so none of this repository's migrations or seeds are applied first) and prints `RESTORE PASS`, or `RESTORE FAIL` with where it stopped (file and line; the error text only for the roles and schema files, never for data).
4. Packs everything, encrypts it with `age` to the public key in `vars.BACKUP_AGE_RECIPIENT`, and uploads only the encrypted file as a release asset of the private repository `vars.BACKUP_REPO`. The newest 30 releases are kept.

Nothing readable reaches this public repository: every command that could print data writes to `/dev/null`, there are no workflow artifacts, and the plaintext is deleted from the runner before the job ends.

## One-time setup (Sai)

1. Install `age` on your own computer (`brew install age`, or the release from github.com/FiloSottile/age) and run `age-keygen -o activity-planet-backup.key`. The file holds the **private key**: keep it offline (a password manager attachment and a USB stick). It prints the **public key** (`age1...`).
2. Create a **private** GitHub repository, for example `SaiPutumbaka/activity-planet-backups`. Nothing else goes in it.
3. Create a fine-grained personal access token with access to that one repository only, permission Contents: Read and write, expiry one year (calendar a reminder to rotate it).
4. In this repository, Settings, Secrets and variables, Actions:
   - Variables: `BACKUP_AGE_RECIPIENT` = the `age1...` public key; `BACKUP_REPO` = `owner/name` of the private repository.
   - Secrets (in the `production` environment): `BACKUP_REPO_TOKEN` = the token.
5. Run the workflow once by hand from `main` with `verify_restore` ticked and check that it ends with `RESTORE PASS` and a new release in the private repository.

Until all three are set the job is a no-op that names what is missing.

## Restore

Restore into a **new** project (or staging), never over production while it still serves users.

1. Download the newest release asset from the private repository.
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
