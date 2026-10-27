# Production cutover: schema v1 to v2

**Status: approved by Sai on 2026-10-27 (D-034); waiting on the token scopes and a green dry run.**
Nothing in this document has run against production yet. Sai adds the token scopes and runs the
dry run; when it is green, steps 1 to 4 run in order, with Sai executing the SQL in the dashboard and
pasting each result to Claude, who checks it before the next step. An adversarial review panel went
over the first draft on Oct 27; this is the corrected plan.

## Where things stand

- **Production** (`gtesfiqxqontescqpllo`, us-west-2): the v1 schema (`public.profiles`, `events`,
  `rsvps`, `hub_messages`, 0 rows each), five test accounts in `auth.users`, and an empty
  `supabase_migrations.schema_migrations`. The deployed app (`activity-planet-app.vercel.app`) and
  the site already point here; a sign-up there creates an auth user and then fails at onboarding,
  because the v2 tables do not exist.
- **Staging** (`gzrscndzzggxmcwnvvcq`): schema 2.8. Since Oct 27 its migration history records the
  eight repo files under their file versions (`20261019000100` … `20261026000200`), so
  `supabase db push` sees it as up to date.
- **Pipeline**: `.github/workflows/migrate.yml`. Secrets set Oct 27. `MIGRATIONS_ENABLED` unset.
  The workflow has a `dry_run` input, a rehearsal job, and the CLI pinned to 2.122.0.

## What migration 1 does on its own, and why step 2 still runs

`20261019000100_v2_foundation.sql` carries its own guarded v1 reset (lines 29 to 44): when
`public.profiles.selected_hobbies` exists, which it does on v1, it drops `hub_messages`, `rsvps`,
`events` and `profiles` with cascade before creating the v2 tables. It also replaces the
`on_auth_user_created` trigger and `handle_new_user()` (lines 549 and 577), sweeps every storage
policy named `avatars…` and recreates the v2 set (lines 1012 to 1018), upserts the `avatars` bucket,
creates its own extensions (`pgcrypto`, `postgis`, `pg_trgm` in `extensions`), and backfills a
profile with a generated `member_…` handle for every row in `auth.users` (lines 593 to 601).

So a plain push would succeed. Step 2 exists for what the migration does not touch:

- the five test accounts, which would otherwise get generated handles and tombstone-style profiles;
- any files in the `avatars` bucket (the migration only rewrites policies);
- anything added outside the repo's v1 files: a function, trigger, view, enum or storage policy that
  the inventory in step 1 lists. The v1 migrations in `legacy/v1/supabase/migrations/` created none
  of those, so any that appear were added by hand and must be understood before they are dropped.

Step 2 also removes the one state the migration refuses: a `public.profiles` table **without**
`selected_hobbies` makes migration 1 raise "schema v2 already present". After step 2 there is no
`profiles` table at all, so the guard passes.

## Before anything: token scopes, pinned CLI, dry run (founder to-do 7)

The pipeline runs the Supabase CLI (2.122.0, the TypeScript rewrite, pinned in the workflow) on a
GitHub-hosted runner. Runners have no IPv6, and a project's direct database host
(`db.<ref>.supabase.co`) is IPv6-only, so the CLI must reach the IPv4 pooler. It learns the pooler
address from `GET /v1/projects/{ref}/config/database/pooler` during `supabase link` (best-effort
there) and then needs it for `migration list`, `db push` and `db query`. That endpoint requires the
**Connection Pooling, Read** permission, which the `github-migrate` token does not have. Without it
the job fails with:

```
IPv6 is not supported on your current network
Run supabase link --project-ref <ref> to setup IPv4 connection.
```

While the token is being edited, also add **Edge Functions, Read-write**: the workflow deploys the
`delete-account` function to production after the push (see "After the cutover"). That step is
marked `continue-on-error`, so a token without the scope only logs a failure there; nothing else
breaks.

What each command calls, from the CLI source:

| Command | Management API | Permission |
| --- | --- | --- |
| `supabase link` | `GET /v1/projects/{ref}` (fatal, except a 404 is tolerated) | Project Settings, Read (have) |
| `supabase link` | `GET /v1/projects/{ref}/api-keys?reveal=true` (fatal) | API Keys Read + API Key Secrets Read (have) |
| `supabase link` | `GET …/config/database/pooler` (best-effort; saves the pooler URL) | **Connection Pooling, Read (add)** |
| `supabase link` | `GET …/config/storage` (best-effort, ignored) | Storage Config, Read (not needed) |
| `db push`, `migration list` | none; Postgres through the pooler with `SUPABASE_DB_PASSWORD` | the database passwords (have) |
| `db query --linked` | resolves the same pooler connection first (probe only), then `POST /v1/projects/{ref}/database/query` | Database, Read-write (have) |
| `functions deploy --use-api` | `POST /v1/projects/{ref}/functions/deploy` | Edge Functions, Read-write (add) |

With the password set, the CLI never mints a temporary login role, so the Database JIT and
Migrations permissions are not needed. The CLI version is pinned so the cutover runs exactly the
binary the dry run proved; bump it only after a fresh dry run.

**The dry run.** Actions, "Migrate database then deploy", Run workflow, tick **dry_run**. It does,
in order, applying nothing to production:

1. `rehearse` job: starts a throwaway Supabase stack on the runner (Docker) and runs
   `supabase db reset`, which applies all eight migration files and `supabase/seed/hubs.sql`
   through the CLI's own statement splitter and transaction batching. This is the first time the
   files run through the CLI rather than the management API, and it happens here, not on production.
2. `migrate` job: links staging, prints `migration list` (eight versions, all present), probes the
   query path with `db query --linked "select 1"`, seeds staging (idempotent; this exercises the
   66 KB body on the Management API query endpoint), then `db push --dry-run`, which prints
   `DRY RUN: migrations will *not* be pushed to the database.` and `Remote database is up to date.`
3. The same for production: `migration list` shows the eight versions absent, the probe passes,
   and `db push --dry-run` prints `Would push these migrations:` followed by the eight file names.
   Seeding, function deploys and the Vercel hooks are skipped.

Green means the pinned CLI, the token's five permissions, the pooler path, both passwords, the
files and the seed all work. Send Claude the log if anything is red.

## Step 1: inventory production (read-only, five minutes)

In the Supabase dashboard, open project `gtesfiqxqontescqpllo` (check the ref in the URL), SQL
Editor, and run the four queries. Paste all four results to Claude.

**A. Objects**

```sql
select 'table' as kind, table_name as name from information_schema.tables
  where table_schema = 'public' and table_type = 'BASE TABLE'
union all select 'view', table_name from information_schema.views where table_schema = 'public'
union all select 'function', p.oid::regprocedure::text from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
union all select 'enum', t.typname from pg_type t join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public' and t.typtype = 'e'
union all select 'trigger on auth.users', tg.tgname from pg_trigger tg
  join pg_class c on c.oid = tg.tgrelid join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'auth' and c.relname = 'users' and not tg.tgisinternal
union all select 'extension', extname from pg_extension
union all select 'bucket', id from storage.buckets
union all select 'storage policy', policyname from pg_policies where schemaname = 'storage'
union all select 'profiles.selected_hobbies', column_name from information_schema.columns
  where table_schema = 'public' and table_name = 'profiles' and column_name = 'selected_hobbies'
order by 1, 2;
```

**B. Counts**

```sql
select (select count(*) from auth.users)                              as auth_users,
       (select count(*) from storage.objects)                         as storage_objects,
       (select count(*) from supabase_migrations.schema_migrations)   as migration_rows,
       (select count(*) from public.profiles)                         as profiles,
       (select count(*) from public.events)                           as events,
       (select count(*) from public.rsvps)                            as rsvps,
       (select count(*) from public.hub_messages)                     as hub_messages;
```

**C. The accounts that will be deleted**

```sql
select u.email, u.created_at,
       (select array_agg(i.provider) from auth.identities i where i.user_id = u.id) as providers
from auth.users u order by u.created_at;
```

**D. Foreign keys into auth.users** (anything that could block the delete)

```sql
select conrelid::regclass as child, conname, confdeltype
from pg_constraint where contype = 'f' and confrelid = 'auth.users'::regclass order by 1;
```

**Expected, from the v1 files in `legacy/v1/supabase/migrations/`:** tables `profiles`, `events`,
`rsvps`, `hub_messages`; no views, functions, enums or triggers on `auth.users`; extensions include
`pgcrypto` (plus Supabase's own, such as `pg_graphql`, `pg_stat_statements`, `pgjwt`, `plpgsql`,
`supabase_vault`, `uuid-ossp`); one bucket `avatars`; storage policies exactly
`avatars_public_read`, `avatars_insert_own_folder`, `avatars_update_own_folder`,
`avatars_delete_own_folder`; the `selected_hobbies` row present; counts 5 / 0 / 0 / 0 / 0 / 0 / 0;
D lists only `public.profiles` with `confdeltype = c` (plus Supabase's own `auth.*` and
`storage.*` children, all `c`).

**Stop and ask Claude if:** any of the four table counts is not 0; `migration_rows` is not 0;
`profiles` exists but the `selected_hobbies` row is missing; any function, view, enum or trigger
appears (added by hand; identify it before it goes in step 2); D shows a child outside `auth.*`,
`storage.*` and the four v1 tables with `confdeltype` `a` or `r` (that delete would abort step 2).
And confirm in writing that all five accounts in C can go.

## Step 2: drop v1 and the test accounts (SQL editor; the only destructive step)

Do step 2 and step 3 in the same sitting. A sign-up that lands in between is harmless (migration 1
backfills every auth user) and the keep-alive keeps passing (it accepts 404 until `public.meta`
exists), but there is no reason to leave production half-done.

1. If B showed `storage_objects` above 0: open Storage, bucket `avatars`, select all files, delete.
   Deleting `storage.objects` rows by SQL would leave the files behind as orphans, so it is not in
   the script.
2. Run this script. Fill in the commented lines only with what step 1 listed, one line per object,
   exactly as printed (functions come out of A as `name(argtypes)`, ready to paste).

```sql
begin;
-- One line per hand-added object from step 1 A, or delete these comment lines:
-- drop trigger if exists <trigger> on auth.users;
-- drop function if exists public.<name(argtypes)> cascade;
-- drop view if exists public.<view> cascade;
-- drop type if exists public.<enum> cascade;
-- drop policy if exists "<any storage policy not named avatars_...>" on storage.objects;
drop table if exists public.hub_messages, public.rsvps, public.events, public.profiles cascade;
delete from auth.users;   -- the five test accounts from step 1 C
commit;

select (select count(*) from auth.users) as auth_users,
       (select count(*) from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE') as public_tables,
       (select count(*) from supabase_migrations.schema_migrations) as migration_rows;
```

The last query must print `0 | 0 | 0`. If the editor reports an error, the whole `begin … commit`
rolled back: paste the error to Claude and do not continue. Keep the `avatars` bucket and its
policies: migration 1 upserts the bucket and rewrites the policies.

## Step 3: enable and run

1. GitHub, repository Settings, Secrets and variables, Actions, **Variables** tab: set
   `MIGRATIONS_ENABLED` to `true`.
2. Actions, "Migrate database then deploy", Run workflow, leave `dry_run` off.
3. Expected log, in order: staging links, `migration list`, probe, `Remote database is up to date.`,
   staging seed; production links, `migration list` (eight absent), probe, then `Applying migration
   …` for each of the eight files (the confirm prompt is answered by `--yes`), production seed,
   `delete-account` deploy, both Vercel deploy hooks.

**If something fails**

| Where | State of production | What to do |
| --- | --- | --- |
| `rehearse` job or any staging step | untouched | send Claude the log; after the fix, Run workflow again |
| production `db push`, at file N | files before N are applied and recorded; N and later are not; nothing half-applied (each file runs as one transaction with its history row) | fix forward (below); never re-run step 2 |
| production seed, function deploy, deploy hooks | all eight migrations applied | Run workflow again; the seed is idempotent and the hooks are harmless to repeat |
| a transient error anywhere (network, rate limit) | as above for that step | Run workflow again; no file change needed |

**Fix forward.** Prefer a follow-up migration with a timestamp after `20261026000200`; it runs on
staging first, then production, like any other. If the failing file itself has to change, apply the
same change to staging by hand and say so in the commit, so staging and the repo stay equal.

**Never re-run step 2 after a partial push.** Once any version is recorded, step 2 would drop v2's
`profiles` graph and the triggers migration 1 created, while the history still says those files are
applied; the next push would resume at the failed file against a half-destroyed schema. The old
draft of this plan said the opposite; it was wrong.

**Deliberate full restart** (only before launch, only with Claude on the call): a full v2 teardown,
not step 2.

```sql
begin;
drop schema public cascade;
create schema public;
grant usage on schema public to postgres, anon, authenticated, service_role;
grant all on schema public to postgres, service_role;
alter default privileges in schema public grant all on tables to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to postgres, anon, authenticated, service_role;
delete from supabase_migrations.schema_migrations;
delete from auth.users;
commit;
```

Dropping `public` with cascade also removes the `auth.users` triggers (they depend on
`public.handle_new_user`); migration 8 rewrites the storage policies. Then Run workflow again.

## Step 4: verify

In the production SQL editor (read-only):

```sql
select value from public.meta where key = 'schema_version';                     -- 2.8
select version from supabase_migrations.schema_migrations order by 1;           -- the eight versions
select (select count(*) from public.hub_categories) as categories,              -- 27
       (select count(*) from public.hubs) as hubs;                              -- 613
select tablename from pg_tables where schemaname = 'public' and not rowsecurity; -- no rows
select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%'); -- no rows
select policyname from pg_policies where schemaname = 'storage' order by 1;     -- exactly the four avatars_* policies
select table_name, string_agg(privilege_type, ',' order by privilege_type)
  from information_schema.role_table_grants
  where grantee = 'anon' and table_schema = 'public' group by 1 order by 1;      -- same rows as staging
```

Run the last query on staging as well; the two outputs must match line for line. Then:

- Database, Advisors: Security and Performance show nothing that staging does not.
- The keep-alive workflow's next run (or Run workflow) reports 200 for production instead of 404.
- `curl -i https://gtesfiqxqontescqpllo.supabase.co/functions/v1/delete-account` returns **401**
  (deployed, JWT verification on). A **404** means the deploy step failed: see "After the cutover".
- Authentication, URL Configuration: apply `docs/ops/supabase-auth.md` section 1 for production.
  Until the domain exists the Site URL can be `https://activity-planet-app.vercel.app`.
- Once founder to-do 3 makes the app URL reachable: sign up with the Gmail address, open the link in
  the same browser, finish onboarding, post a plan, tap Going.

## After the cutover

- **Edge Functions.** The workflow deploys `delete-account` to production right after the push (it
  calls `request_account_deletion`, which the migrations create). If that step failed for a missing
  token scope, run it from the laptop later or re-run the workflow after adding the scope. Until it
  is deployed, an account deletion in the app closes the account in the database and then fails at
  the function call, leaving an account to finish by hand from the `account_deletions` ledger.
  `send-verification-code` is deployed to production only together with its `RESEND_API_KEY`
  secret: without the key it would log the code instead of emailing it while the app reports it as
  sent, whereas an undeployed function fails honestly. Campus verification therefore stays staging-
  only until Resend exists.
- **Email before testers.** Supabase's built-in mailer sends two emails an hour to organization
  members only. Set Resend SMTP on production (`docs/ops/supabase-auth.md` section 4) before opening
  the app URL to anyone else.
- **Scheduled jobs** (`refresh_hub_stats`, `materialize_all_event_series`) arrive with the week-4
  migration that adds `pg_cron`.
- **Process from here.** A migration is a file in `supabase/migrations/`. Claude applies a new one
  to staging first (runs the SQL, then records the file's version in `schema_migrations`), verifies
  the app against staging, and commits; the push to main runs it on production and then deploys.
  Staging is never ahead of the repo, and production is never ahead of staging.
