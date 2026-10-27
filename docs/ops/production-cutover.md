# Production cutover: schema v1 to v2

**Status: proposed on 2026-10-27, waiting for Sai's go.** Nothing in this document has run against
production. Once approved, the steps run in order; each has a check before the next.

## Where things stand

- **Production** (`gtesfiqxqontescqpllo`, us-west-2): the v1 schema (`public.profiles`, `events`,
  `rsvps`, `hub_messages`, 0 rows each), five test accounts in `auth.users`, and an empty
  `supabase_migrations.schema_migrations`. The deployed app (`activity-planet-app.vercel.app`) already
  points here, so sign-up there fails until this cutover.
- **Staging** (`gzrscndzzggxmcwnvvcq`): schema 2.8. Since Oct 27 its migration history records the
  eight repo files under their file versions (`20261019000100` … `20261026000200`), so
  `supabase db push` sees it as up to date.
- **Pipeline**: `.github/workflows/migrate.yml`. Secrets set Oct 27. `MIGRATIONS_ENABLED` unset.
  A `dry_run` input was added Oct 27 so the whole path can be exercised without applying anything.

## Why a plain push would fail

`20261019000100_v2_foundation.sql` starts with `create table if not exists public.profiles`. With the
v1 table in place that statement is a no-op, and every later statement that expects v2 columns
fails. The v1 objects must be dropped first. Nothing in them is worth keeping: every table has
0 rows. The five test accounts can go as well; keeping them would only give them generated handles
through the migration's backfill and send them through onboarding.

The migrations create their own extensions (`pgcrypto`, `postgis`, `pg_trgm` in `extensions`) and
upsert the `avatars` bucket, so production needs no dashboard preparation beyond the drop.

## Before anything: token scope and a dry run (founder to-do 7)

The pipeline runs the Supabase CLI (2.122, the TypeScript rewrite) on a GitHub-hosted runner.
Runners have no IPv6, and a project's direct database host (`db.<ref>.supabase.co`) is IPv6-only, so
the CLI must reach the IPv4 pooler. It learns the pooler address from `GET
/v1/projects/{ref}/config/database/pooler` during `supabase link` (best-effort there) and then needs
it in `db push`, `migration list` and `db query`. That endpoint requires the **Connection Pooling,
Read** permission, which the `github-migrate` token does not have. Without it `db push` fails with
"IPv6 is not supported on your current network. Run supabase link to setup IPv4 connection."

What each command calls, from the CLI source:

| Command | Management API | Permission |
| --- | --- | --- |
| `supabase link` | `GET /v1/projects/{ref}` (fatal on error) | Project Settings, Read (have) |
| `supabase link` | `GET /v1/projects/{ref}/api-keys?reveal=true` (fatal) | API Keys Read + API Key Secrets Read (have) |
| `supabase link` | `GET …/config/database/pooler` (best-effort, saves the pooler URL) | **Connection Pooling, Read (add)** |
| `supabase link` | `GET …/config/storage` (best-effort, ignored) | Storage Config, Read (not needed) |
| `db push`, `migration list`, `migration repair` | none; Postgres through the pooler with `SUPABASE_DB_PASSWORD` | the database passwords (have) |
| `db query --linked` | `POST /v1/projects/{ref}/database/query` | Database, Read-write (have) |

With the password set, the CLI never mints a temporary login role, so the Database JIT and
Migrations permissions are not needed.

Then: Actions, "Migrate database then deploy", Run workflow, tick **dry_run**. Expected log: both
projects link; `migration list` shows the eight versions present on staging and absent on
production; "Would push these migrations:" lists all eight for production and nothing for staging.
Green here means the token, the pooler path and both passwords work.

## Step 1: inventory production (read-only, two minutes)

Run in the SQL editor on production, or approve Claude's read through the MCP server:

```sql
select 'table' as kind, table_name as name from information_schema.tables where table_schema = 'public'
union all select 'view', table_name from information_schema.views where table_schema = 'public'
union all select 'function', routine_name from information_schema.routines where routine_schema = 'public'
union all select 'enum', t.typname from pg_type t join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public' and t.typtype = 'e'
union all select 'trigger on auth.users', tg.tgname from pg_trigger tg
  join pg_class c on c.oid = tg.tgrelid join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'auth' and c.relname = 'users' and not tg.tgisinternal
union all select 'bucket', id from storage.buckets
union all select 'storage policy', policyname from pg_policies where schemaname = 'storage'
order by 1, 2;

select (select count(*) from auth.users) as auth_users,
       (select count(*) from storage.objects) as storage_objects,
       (select count(*) from supabase_migrations.schema_migrations) as migration_rows;
```

Expected: the four v1 tables, a few v1 functions (`handle_new_user` and whatever v1 added), one
trigger on `auth.users`, possibly an `avatars` bucket with its v1 policies, five auth users, no
migration rows. Anything else pauses the plan until it is understood.

## Step 2: drop v1 (the only destructive step)

Run in the SQL editor on production after step 1, filling in any extra function or type the
inventory listed:

```sql
begin;
drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_user() cascade;
-- drop function if exists public.<other v1 function>(<args>) cascade;
drop table if exists public.hub_messages, public.rsvps, public.events, public.profiles cascade;
-- drop type if exists public.<v1 enum>;
delete from storage.objects where bucket_id = 'avatars';   -- v1 test uploads, if any
delete from auth.users;                                     -- the five test accounts
commit;
```

Keep the `avatars` bucket itself: migration 1 upserts its limits and migration 8 replaces its
policies. `cascade` removes the v1 RLS policies, indexes and foreign keys with the tables.

## Step 3: enable and run

1. Repository variable `MIGRATIONS_ENABLED` = `true`.
2. Actions, "Migrate database then deploy", Run workflow with `dry_run` off.
3. Expected log, in order: staging links, "Remote database is up to date", staging seed runs
   (`hubs.sql` is idempotent), production links, "Do you want to push these migrations" answered by
   `--yes`, the eight files apply, production seed runs, both Vercel deploy hooks fire.

If a migration fails midway on production the CLI stops at that file and records nothing for it.
Fix forward: correct the file (or add a follow-up migration), push to main, and the workflow runs
again. Before launch there is no data to protect, so re-running step 2 and the push is also fine.

## Step 4: verify

- `select value from public.meta where key = 'schema_version'` on production returns `2.8`. The
  keep-alive workflow reads this row, so its next scheduled run shows 200 instead of 404.
- `select count(*) from public.hub_categories`, `select count(*) from public.hubs` match staging.
- Security and performance advisors on production show nothing new compared with staging.
- Once founder to-do 8 (production Auth URLs) and 3 (reachable app URL) are done: sign up on the
  deployed app with the Gmail address, finish onboarding, post a plan.

## After the cutover

- **Edge Functions**: `delete-account` and `send-verification-code` are deployed on staging only.
  Recommended: add a `supabase functions deploy` step to the same workflow, which needs the
  **Edge Functions, Read-write** permission on the token (worth adding while the token is being
  edited for Connection Pooling). The alternative is a one-off deploy through the management API.
  Their secrets (`RESEND_API_KEY`) are set in the dashboard once Resend exists.
- **Auth settings on production**: `docs/ops/supabase-auth.md` section 1 and 3.
- **Scheduled jobs** (`refresh_hub_stats`, `materialize_all_event_series`) arrive with the week-4
  migration that adds `pg_cron`.
- **Process from here**: a migration is a file in `supabase/migrations/`. Claude applies a new one
  to staging first (runs the SQL, then records the file's version in `schema_migrations`), verifies
  the app against staging, and commits; the push to main runs it on production and then deploys.
  Staging is never ahead of the repo, and production is never ahead of staging.
