-- ============================================================================
-- Activity Planet schema v2 — migration 52: trust and safety, part 2: the
--   NCII 48-hour removal flow (PLAN.md 4.6 safety bullet and 4.11;
--   TRUST-SAFETY-LEGAL.md sections 3 and 7, Take It Down Act; ROADMAP week
--   6). A public request form that needs no account, a moderator queue with
--   a 48-hour timer, and perceptual hashes of removed images so copies and
--   re-uploads are blocked. Only hashes are stored, never an image.
--   Rebuilt functions start from their latest bodies and each change is
--   marked "Migration 52": request_account_deletion (migration 51).
--   Checks: supabase/tests/ncii_takedown.sql. Hashing: the image-guard Edge
--   Function (supabase/functions/image-guard).
--
--   What this file does
--     1. moderation_actions accepts the new actions (ncii_remove,
--        ncii_reject, ncii_update, image_block, image_remove) and target
--        kinds (takedown, image).
--     2. takedown_requests: one row per public request. The statutory
--        elements: the requester's name and contact email, whether they are
--        the person shown or authorized to act for them, where the image is
--        (links, handles, a description), a good-faith statement that it was
--        shared without consent, and a typed signature. due_at is 48 hours
--        after receipt (4 hours, priority 0, when the requester says the
--        person shown is under 18: the NCMEC runbook, docs/ops/ncmec-
--        runbook.md, applies). Service role only; moderators read through
--        mod_takedown_queue. No user link to the requester: it works without
--        an account and nothing in it is tied to one.
--     3. blocked_image_hashes: the SHA-256 and the 64-bit pHash and dHash of
--        every image a moderator removed under a request. image_hashes: the
--        same three hashes for every Storage object a profile photo or a
--        cover points at (one row per bucket and path), with its check
--        status. Service role only.
--     4. A match is the same SHA-256, or pHash within 10 bits and dHash
--        within 16 bits, with dHash not near-constant (a flat colour block
--        matches nothing). image_hash_close() holds the rule; the Edge
--        Function's tests (hash_test.ts) pin it against re-encoded, resized,
--        cropped, brightened, grayscale and palette copies and against
--        unrelated images.
--     5. The upload path: when profiles.avatar_url or a cover_url (events,
--        event_series, hubs, hub_chapters) starts pointing at an object in
--        this project's Storage, a trigger records it as pending and asks
--        image-guard (pg_net, vault secret image_guard_secret) to hash it.
--        image_guard_record() stores the hashes; when they match a blocked
--        hash, every reference to the object is cleared at once and the
--        object is queued for deletion (image-guard deletes it through the
--        Storage API). A reference to an object already known to be blocked
--        is refused (image_blocked). The app only uploads JPEG; an object
--        that does not decode as JPEG or PNG is treated the same as a
--        blocked one (unreadable). image_guard_tick (pg_cron, every 10
--        minutes) retries checks that got no answer and deletes what is
--        queued.
--     6. Requests: submit_takedown_request(...) (anon and authenticated; 3 a
--        day per email address, 200 an hour overall) returns a reference
--        and the due time. Moderators: mod_takedown_queue(limit, closed),
--        mod_takedown_block_image(request, image_url) (clears the image
--        everywhere at once, blocks its hashes and every stored copy within
--        the rule, or hashes it first when it was never checked), and
--        mod_takedown_resolve(request, action, note, target_user) with
--        removed | rejected | waiting | reopen. The second-moderator rule
--        holds: a moderator never acts on a request about their own image or
--        profile.
--     7. Retention: the requester's contact, signature and free text are
--        cleared one year after a request is closed (purge_takedown_contacts,
--        pg_cron daily); the reference, dates, outcome and hashes stay.
--     8. request_account_deletion: resolver stamps naming the caller are
--        cleared; the caller's image_hashes rows go, except blocked ones
--        (evidence of who uploaded a removed image). Requests about the
--        caller stay as moderation evidence, like reports.
--     * meta.schema_version 2.48.
--
--   Not here: email to the requester (the delivery worker is week 7; the
--   moderator writes from the support mailbox meanwhile), the admin panel
--   that shows this queue beside the report queue, image classification
--   (Sightengine) on upload.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. moderation_actions: new actions and target kinds
-- ---------------------------------------------------------------------------
alter table public.moderation_actions drop constraint if exists moderation_actions_action;
alter table public.moderation_actions add constraint moderation_actions_action
  check (action in ('auto_hide', 'dismiss', 'hide', 'remove', 'restore', 'ban', 'unban', 'grant_moderator',
                    'revoke_moderator', 'ncii_remove', 'ncii_reject', 'ncii_update', 'image_block', 'image_remove'));
alter table public.moderation_actions drop constraint if exists moderation_actions_kind;
alter table public.moderation_actions add constraint moderation_actions_kind
  check (target_kind in ('profile', 'event', 'chapter', 'hub', 'takedown', 'image'));

-- ---------------------------------------------------------------------------
-- 2. takedown_requests
-- ---------------------------------------------------------------------------
create table if not exists public.takedown_requests (
  id                 uuid primary key default gen_random_uuid(),
  reference          text not null unique,
  kind               text not null default 'ncii',
  requester_name     text not null,
  requester_email    text not null,
  email_hash         text not null,
  relationship       text not null,
  locations          text not null,
  description        text not null default '',
  good_faith         boolean not null,
  signature          text not null,
  involves_minor     boolean not null default false,
  status             text not null default 'open',
  priority           smallint not null default 1,
  due_at             timestamptz not null,
  target_user_id     uuid references public.profiles (id) on delete set null,
  images_blocked     integer not null default 0,
  resolved_by        uuid references public.profiles (id) on delete set null,
  resolved_at        timestamptz,
  resolution_note    text not null default '',
  contact_cleared_at timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint takedown_requests_kind check (kind in ('ncii')),
  constraint takedown_requests_relationship check (relationship in ('self', 'authorized')),
  constraint takedown_requests_status check (status in ('open', 'waiting', 'removed', 'rejected')),
  constraint takedown_requests_priority check (priority between 0 and 2),
  constraint takedown_requests_good_faith check (good_faith or contact_cleared_at is not null),
  constraint takedown_requests_lengths check (
    char_length(requester_name) <= 200 and char_length(requester_email) <= 254
    and char_length(locations) <= 4000 and char_length(description) <= 2000
    and char_length(signature) <= 200 and char_length(resolution_note) <= 1000),
  constraint takedown_requests_required check (
    contact_cleared_at is not null
    or (requester_name <> '' and requester_email <> '' and locations <> '' and signature <> ''))
);
create index if not exists takedown_requests_queue_idx on public.takedown_requests (priority, due_at)
  where status in ('open', 'waiting');
create index if not exists takedown_requests_email_idx on public.takedown_requests (email_hash, created_at);
create index if not exists takedown_requests_created_idx on public.takedown_requests (created_at);
create index if not exists takedown_requests_target_idx on public.takedown_requests (target_user_id)
  where target_user_id is not null;
create index if not exists takedown_requests_resolved_by_idx on public.takedown_requests (resolved_by)
  where resolved_by is not null;
comment on table public.takedown_requests is
  'Migration 52: public requests to remove non-consensual intimate imagery (Take It Down Act). No account needed; the requester is not linked to any account. due_at is 48 hours after receipt (4 hours when the person shown may be under 18). Service role only; moderators read through mod_takedown_queue. Contact, signature and free text are cleared a year after the request closes; the rest is kept as evidence, also after the target''s account is deleted.';

-- ---------------------------------------------------------------------------
-- 3. Hashes
-- ---------------------------------------------------------------------------
create table if not exists public.blocked_image_hashes (
  id         uuid primary key default gen_random_uuid(),
  request_id uuid references public.takedown_requests (id) on delete set null,
  sha256     text not null unique,
  phash      bigint,
  dhash      bigint,
  created_at timestamptz not null default now(),
  constraint blocked_image_hashes_sha256 check (sha256 ~ '^[0-9a-f]{64}$')
);
create index if not exists blocked_image_hashes_request_idx on public.blocked_image_hashes (request_id)
  where request_id is not null;
comment on table public.blocked_image_hashes is
  'Migration 52: hashes (SHA-256, 64-bit pHash and dHash) of images removed under a takedown request. No image is stored. Every new or re-checked upload is compared with these (image_hash_close). Service role only.';

create table if not exists public.image_hashes (
  id               uuid primary key default gen_random_uuid(),
  bucket           text not null,
  path             text not null,
  owner_id         uuid references public.profiles (id) on delete cascade,
  status           text not null default 'pending',
  sha256           text,
  phash            bigint,
  dhash            bigint,
  block_request_id uuid references public.takedown_requests (id) on delete set null,
  blocked_hash_id  uuid references public.blocked_image_hashes (id) on delete set null,
  attempts         smallint not null default 0,
  dispatched_at    timestamptz,
  checked_at       timestamptz,
  blocked_at       timestamptz,
  purged_at        timestamptz,
  created_at       timestamptz not null default now(),
  constraint image_hashes_object unique (bucket, path),
  constraint image_hashes_status check (status in ('pending', 'hashed', 'unreadable', 'missing', 'blocked')),
  constraint image_hashes_sha256 check (sha256 is null or sha256 ~ '^[0-9a-f]{64}$'),
  constraint image_hashes_hashed check (status <> 'hashed' or (sha256 is not null and phash is not null and dhash is not null))
);
create index if not exists image_hashes_owner_idx on public.image_hashes (owner_id) where owner_id is not null;
create index if not exists image_hashes_sha_idx on public.image_hashes (sha256) where sha256 is not null;
create index if not exists image_hashes_pending_idx on public.image_hashes (dispatched_at) where status = 'pending';
create index if not exists image_hashes_purge_idx on public.image_hashes (blocked_at)
  where status in ('blocked', 'unreadable') and purged_at is null;
create index if not exists image_hashes_request_idx on public.image_hashes (block_request_id)
  where block_request_id is not null;
create index if not exists image_hashes_blocked_hash_idx on public.image_hashes (blocked_hash_id)
  where blocked_hash_id is not null;
comment on table public.image_hashes is
  'Migration 52: one row per Storage object a profile photo or cover points at: its hashes (SHA-256, pHash, dHash; never the image) and check status. pending = image-guard asked; hashed = checked and allowed; blocked = matched a removed image (references cleared, object deleted once purged_at is set); unreadable = not a JPEG or PNG (treated as blocked); missing = no object at that path. Service role only.';

alter table public.takedown_requests    enable row level security;
alter table public.blocked_image_hashes enable row level security;
alter table public.image_hashes         enable row level security;
revoke all on public.takedown_requests, public.blocked_image_hashes, public.image_hashes
  from public, anon, authenticated;
grant all on public.takedown_requests, public.blocked_image_hashes, public.image_hashes to service_role;

-- ---------------------------------------------------------------------------
-- 4. Hash helpers
-- ---------------------------------------------------------------------------
-- 16 lowercase hex characters to the signed 64-bit value with the same bits.
create or replace function public.image_hash_from_hex(p_hex text)
returns bigint language plpgsql immutable set search_path = '' as $$
begin
  if p_hex is null then
    return null;
  end if;
  if p_hex !~ '^[0-9a-f]{16}$' then
    raise exception 'invalid_hash' using errcode = '22023';
  end if;
  return ('x' || p_hex)::bit(64)::bigint;
end $$;
comment on function public.image_hash_from_hex(text) is
  'Migration 52, internal: a 64-bit perceptual hash in hex (as image-guard sends it) to bigint.';

-- The match rule (see the header, point 4).
create or replace function public.image_hash_close(p_phash_a bigint, p_phash_b bigint, p_dhash_a bigint, p_dhash_b bigint)
returns boolean language sql immutable set search_path = '' as $$
  select p_phash_a is not null and p_phash_b is not null and p_dhash_a is not null and p_dhash_b is not null
     and bit_count(p_dhash_a::bit(64)) between 4 and 60
     and bit_count(p_dhash_b::bit(64)) between 4 and 60
     and bit_count((p_phash_a # p_phash_b)::bit(64)) <= 10
     and bit_count((p_dhash_a # p_dhash_b)::bit(64)) <= 16;
$$;
comment on function public.image_hash_close(bigint, bigint, bigint, bigint) is
  'Migration 52: true when two images are the same picture by perceptual hash: pHash within 10 bits and dHash within 16 bits, neither dHash near-constant. Pinned by supabase/functions/image-guard/hash_test.ts.';

-- The bucket and path of a public object URL of this project's Storage, or
-- nulls for anything else (is_own_storage_url, migration 22).
create or replace function public.storage_object_from_url(p_url text, out bucket text, out path text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_rest text;
begin
  if p_url is null or public.project_url() is null or not public.is_own_storage_url(p_url) then
    return;
  end if;
  v_rest := substr(p_url, char_length(public.project_url() || '/storage/v1/object/public/') + 1);
  bucket := split_part(v_rest, '/', 1);
  path   := substr(v_rest, char_length(bucket) + 2);
end $$;
comment on function public.storage_object_from_url(text) is
  'Migration 52, internal: (bucket, path) of a public object URL of this project''s Storage, else nulls.';

-- The profile whose folder holds the object (<uid>/...), when there is one.
create or replace function public.image_owner_from_path(p_path text)
returns uuid language sql stable security definer set search_path = '' as $$
  select p.id from public.profiles p
   where split_part(coalesce(p_path, ''), '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and p.id = split_part(p_path, '/', 1)::uuid;
$$;
comment on function public.image_owner_from_path(text) is
  'Migration 52, internal: the profile whose folder (<uid>/...) holds a Storage object, or null.';

-- Clears every profile photo and cover that points at the object. Returns the
-- number of rows changed.
create or replace function public.image_clear_references(p_bucket text, p_path text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_url text;
  v_n   integer := 0;
  v_c   integer;
begin
  if public.project_url() is null or p_bucket is null or p_path is null then
    return 0;
  end if;
  v_url := public.project_url() || '/storage/v1/object/public/' || p_bucket || '/' || p_path;
  update public.profiles set avatar_url = null where avatar_url = v_url;
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  update public.events set cover_url = null where cover_url = v_url;
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  update public.event_series set cover_url = null where cover_url = v_url;
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  update public.hubs set cover_url = null where cover_url = v_url;
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  update public.hub_chapters set cover_url = null where cover_url = v_url;
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  return v_n;
end $$;
comment on function public.image_clear_references(text, text) is
  'Migration 52, internal: nulls profiles.avatar_url and the cover_url of events, event_series, hubs and hub_chapters that point at the object. Returns the rows changed.';

-- ---------------------------------------------------------------------------
-- 5. image-guard secret and dispatch
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('vault.secrets') is null then
    raise notice 'supabase_vault is not installed; image_guard_secret not created';
  elsif not exists (select 1 from vault.secrets where name = 'image_guard_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'image_guard_secret',
                                'Shared secret between the database and the image-guard Edge Function (migration 52)');
  end if;
end $$;

create or replace function public.image_guard_verify_secret(p_secret text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_secret text;
begin
  if p_secret is null or char_length(p_secret) < 32 or to_regclass('vault.decrypted_secrets') is null then
    return false;
  end if;
  select ds.decrypted_secret into v_secret
    from vault.decrypted_secrets ds where ds.name = 'image_guard_secret' limit 1;
  return v_secret is not null and v_secret = p_secret;
end $$;
comment on function public.image_guard_verify_secret(text) is
  'Migration 52: true when p_secret is the vault secret image_guard_secret (generated in the database). Service role only; used by the image-guard Edge Function.';

-- Asks image-guard to act (pg_net, so it is sent after the transaction
-- commits and never on rollback). Returns the pg_net request id or null.
create or replace function public.image_guard_dispatch(p_body jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_base   text := public.project_url();
  v_secret text;
begin
  if v_base is null then
    raise notice 'image-guard: project_url not set; nothing sent';
    return null;
  end if;
  if to_regclass('vault.decrypted_secrets') is not null then
    select ds.decrypted_secret into v_secret
      from vault.decrypted_secrets ds where ds.name = 'image_guard_secret' limit 1;
  end if;
  if v_secret is null or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    raise notice 'image-guard: secret or pg_net missing; nothing sent';
    return null;
  end if;
  return net.http_post(
    url := v_base || '/functions/v1/image-guard',
    body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-image-guard-secret', v_secret),
    timeout_milliseconds := 60000);
end $$;
comment on function public.image_guard_dispatch(jsonb) is
  'Migration 52, internal: POSTs p_body ({op: check, bucket, path} or {op: sweep}) to the image-guard Edge Function through pg_net with the image_guard_secret header. Returns the request id or null when project_url, the secret or pg_net is missing.';

-- ---------------------------------------------------------------------------
-- 6. Blocking
-- ---------------------------------------------------------------------------
-- Marks one stored object blocked: references cleared, queued for deletion,
-- logged. Returns the references cleared.
create or replace function public.image_block_row(p_image uuid, p_blocked uuid, p_moderator uuid default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_row     public.image_hashes%rowtype;
  v_cleared integer;
  v_request uuid;
begin
  update public.image_hashes
     set status = 'blocked', blocked_at = coalesce(blocked_at, now()), blocked_hash_id = p_blocked
   where id = p_image and status <> 'blocked'
  returning * into v_row;
  if not found then
    return 0;
  end if;
  v_cleared := public.image_clear_references(v_row.bucket, v_row.path);
  select b.request_id into v_request from public.blocked_image_hashes b where b.id = p_blocked;
  if v_request is not null then
    update public.takedown_requests
       set images_blocked = images_blocked + 1, updated_at = now(),
           target_user_id = coalesce(target_user_id, v_row.owner_id)
     where id = v_request;
  end if;
  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
  values (p_moderator, 'image_remove', 'image', v_row.id, v_row.owner_id,
          'references cleared: ' || v_cleared || coalesce('; request ' || v_request::text, ''));
  return v_cleared;
end $$;
comment on function public.image_block_row(uuid, uuid, uuid) is
  'Migration 52, internal: marks one image_hashes row blocked by a blocked hash, clears every reference to the object, queues it for deletion (purged_at null), counts it on the request and logs image_remove.';

-- Blocks every stored object that matches a blocked hash. Returns how many.
create or replace function public.image_block_matches(p_blocked uuid, p_moderator uuid default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_b public.blocked_image_hashes%rowtype;
  v_r record;
  v_n integer := 0;
begin
  select * into v_b from public.blocked_image_hashes where id = p_blocked;
  if not found then
    return 0;
  end if;
  for v_r in
    select h.id from public.image_hashes h
     where h.status = 'hashed'
       and (h.sha256 = v_b.sha256 or public.image_hash_close(h.phash, v_b.phash, h.dhash, v_b.dhash))
     for update
  loop
    perform public.image_block_row(v_r.id, p_blocked, p_moderator);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
comment on function public.image_block_matches(uuid, uuid) is
  'Migration 52, internal: blocks every hashed object with the same SHA-256 as a blocked hash or within image_hash_close of it (the known copies). Returns the count.';

-- Adds (or finds) a blocked hash for a request.
create or replace function public.image_block_hash(p_request uuid, p_sha256 text, p_phash bigint, p_dhash bigint)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  insert into public.blocked_image_hashes (request_id, sha256, phash, dhash)
  values (p_request, p_sha256, p_phash, p_dhash)
  on conflict (sha256) do update
     set request_id = coalesce(public.blocked_image_hashes.request_id, excluded.request_id)
  returning id into v_id;
  return v_id;
end $$;
comment on function public.image_block_hash(uuid, text, bigint, bigint) is
  'Migration 52, internal: inserts the hashes of a removed image into blocked_image_hashes (one row per SHA-256). Returns its id.';

-- ---------------------------------------------------------------------------
-- 7. image-guard RPCs (service role)
-- ---------------------------------------------------------------------------
-- Records the outcome of one check. Returns {outcome: ok | blocked |
-- unreadable | missing, copies}.
create or replace function public.image_guard_record(
  p_bucket text, p_path text, p_status text,
  p_sha256 text default null, p_phash text default null, p_dhash text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_row     public.image_hashes%rowtype;
  v_p       bigint;
  v_d       bigint;
  v_blocked uuid;
  v_n       integer := 0;
begin
  if p_bucket is null or p_bucket !~ '^[a-z0-9][a-z0-9_-]{0,62}$'
     or p_path is null or char_length(p_path) > 400 or p_path !~ '^[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$'
     or p_path ~ '(^|/)\.\.?(/|$)' then
    raise exception 'invalid_object' using errcode = '22023';
  end if;
  if p_status not in ('hashed', 'unreadable', 'missing') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;
  if p_status = 'hashed' then
    if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then
      raise exception 'invalid_hash' using errcode = '22023';
    end if;
    v_p := public.image_hash_from_hex(p_phash);
    v_d := public.image_hash_from_hex(p_dhash);
    if v_p is null or v_d is null then
      raise exception 'invalid_hash' using errcode = '22023';
    end if;
  end if;

  insert into public.image_hashes (bucket, path, owner_id, status)
  values (p_bucket, p_path, public.image_owner_from_path(p_path), 'pending')
  on conflict (bucket, path) do nothing;
  select * into v_row from public.image_hashes where bucket = p_bucket and path = p_path for update;
  if v_row.status = 'blocked' then
    return jsonb_build_object('outcome', 'blocked', 'copies', 0);
  end if;

  update public.image_hashes
     set status = p_status, checked_at = now(),
         sha256 = case when p_status = 'hashed' then p_sha256 end,
         phash = v_p, dhash = v_d,
         purged_at = case when p_status = 'unreadable' then null else purged_at end,
         blocked_at = case when p_status = 'unreadable' then now() else blocked_at end
   where id = v_row.id;

  if p_status = 'hashed' then
    if v_row.block_request_id is not null then
      -- A moderator asked for this object to be blocked before it was hashed.
      v_blocked := public.image_block_hash(v_row.block_request_id, p_sha256, v_p, v_d);
      v_n := public.image_block_matches(v_blocked, null);
      return jsonb_build_object('outcome', 'blocked', 'copies', v_n);
    end if;
    select b.id into v_blocked from public.blocked_image_hashes b
     where b.sha256 = p_sha256 or public.image_hash_close(b.phash, v_p, b.dhash, v_d)
     order by (b.sha256 = p_sha256) desc, b.created_at
     limit 1;
    if v_blocked is not null then
      perform public.image_block_row(v_row.id, v_blocked, null);
      return jsonb_build_object('outcome', 'blocked', 'copies', 1);
    end if;
    return jsonb_build_object('outcome', 'ok', 'copies', 0);
  elsif p_status = 'unreadable' then
    v_n := public.image_clear_references(p_bucket, p_path);
    insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
    values (null, 'image_remove', 'image', v_row.id, v_row.owner_id,
            'unreadable image; references cleared: ' || v_n);
    return jsonb_build_object('outcome', 'unreadable', 'copies', 0);
  end if;
  return jsonb_build_object('outcome', 'missing', 'copies', 0);
end $$;
comment on function public.image_guard_record(text, text, text, text, text, text) is
  'Migration 52, service role (image-guard): stores one object''s hashes (p_status hashed, hex pHash and dHash) or its unreadable or missing state. Blocks it, clears its references and queues it for deletion when it matches a blocked hash or a moderator asked for it to be blocked. Returns {outcome: ok | blocked | unreadable | missing, copies}.';

create or replace function public.image_guard_purge_list(p_limit integer default 50)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'bucket', q.bucket, 'path', q.path)), '[]'::jsonb)
    from (select h.id, h.bucket, h.path from public.image_hashes h
           where h.status in ('blocked', 'unreadable') and h.purged_at is null
           order by h.blocked_at nulls first
           limit greatest(1, least(coalesce(p_limit, 50), 200))) q;
$$;
comment on function public.image_guard_purge_list(integer) is
  'Migration 52, service role (image-guard): blocked or unreadable objects not yet deleted from Storage, [{id, bucket, path}].';

create or replace function public.image_guard_mark_purged(p_ids uuid[])
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_n integer;
begin
  update public.image_hashes set purged_at = now()
   where id = any(coalesce(p_ids, '{}')) and status in ('blocked', 'unreadable') and purged_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
comment on function public.image_guard_mark_purged(uuid[]) is
  'Migration 52, service role (image-guard): stamps purged_at once the objects are deleted from Storage. Returns the count.';

-- pg_cron every 10 minutes: retries checks that got no answer (at most 5
-- tries, 20 a run) and asks for a sweep when objects wait for deletion.
create or replace function public.image_guard_tick()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_r     record;
  v_sent  integer := 0;
  v_sweep boolean;
begin
  for v_r in
    select h.id, h.bucket, h.path from public.image_hashes h
     where h.status = 'pending' and h.attempts < 5
       and (h.dispatched_at is null or h.dispatched_at < now() - interval '5 minutes')
     order by h.created_at
     limit 20
     for update skip locked
  loop
    update public.image_hashes set attempts = attempts + 1, dispatched_at = now() where id = v_r.id;
    if public.image_guard_dispatch(jsonb_build_object('op', 'check', 'bucket', v_r.bucket, 'path', v_r.path)) is not null then
      v_sent := v_sent + 1;
    end if;
  end loop;
  v_sweep := exists (select 1 from public.image_hashes h
                      where h.status in ('blocked', 'unreadable') and h.purged_at is null);
  if v_sweep then
    perform public.image_guard_dispatch(jsonb_build_object('op', 'sweep'));
  end if;
  return jsonb_build_object('checks', v_sent, 'sweep', v_sweep);
end $$;
comment on function public.image_guard_tick() is
  'Migration 52, pg_cron image-guard-tick every 10 minutes: re-sends pending checks (5 tries) and asks for a sweep when objects wait for deletion.';

-- ---------------------------------------------------------------------------
-- 8. The upload path: references to Storage objects
-- ---------------------------------------------------------------------------
-- AFTER insert or update of the image column named in tg_argv[0]. Refuses a
-- known-blocked object; otherwise records a new object as pending and asks
-- image-guard to hash it.
create or replace function public.image_guard_on_reference()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_new    text := to_jsonb(new) ->> tg_argv[0];
  v_old    text := case when tg_op = 'UPDATE' then to_jsonb(old) ->> tg_argv[0] end;
  v_bucket text;
  v_path   text;
  v_status text;
begin
  if v_new is null or v_new is not distinct from v_old then
    return null;
  end if;
  select o.bucket, o.path into v_bucket, v_path from public.storage_object_from_url(v_new) o;
  if v_bucket is null then
    return null;
  end if;
  select h.status into v_status from public.image_hashes h where h.bucket = v_bucket and h.path = v_path;
  if v_status in ('blocked', 'unreadable') then
    raise exception 'image_blocked' using errcode = 'check_violation', constraint = 'image_blocked',
      hint = 'This image cannot be used on Activity Planet.';
  end if;
  if v_status is null then
    insert into public.image_hashes (bucket, path, owner_id, status, attempts, dispatched_at)
    values (v_bucket, v_path, public.image_owner_from_path(v_path), 'pending', 1, now())
    on conflict (bucket, path) do nothing;
  elsif v_status = 'missing' then
    update public.image_hashes set status = 'pending', attempts = 1, dispatched_at = now()
     where bucket = v_bucket and path = v_path;
  else
    return null;
  end if;
  perform public.image_guard_dispatch(jsonb_build_object('op', 'check', 'bucket', v_bucket, 'path', v_path));
  return null;
end $$;
comment on function public.image_guard_on_reference() is
  'Migration 52, trigger: when an image column (tg_argv[0]) starts pointing at a Storage object, refuses it if the object is blocked (image_blocked), else records a new or missing object as pending and asks image-guard to hash it.';

drop trigger if exists profiles_image_guard on public.profiles;
create trigger profiles_image_guard after insert or update of avatar_url on public.profiles
  for each row execute function public.image_guard_on_reference('avatar_url');
drop trigger if exists events_image_guard on public.events;
create trigger events_image_guard after insert or update of cover_url on public.events
  for each row execute function public.image_guard_on_reference('cover_url');
drop trigger if exists event_series_image_guard on public.event_series;
create trigger event_series_image_guard after insert or update of cover_url on public.event_series
  for each row execute function public.image_guard_on_reference('cover_url');
drop trigger if exists hubs_image_guard on public.hubs;
create trigger hubs_image_guard after insert or update of cover_url on public.hubs
  for each row execute function public.image_guard_on_reference('cover_url');
drop trigger if exists hub_chapters_image_guard on public.hub_chapters;
create trigger hub_chapters_image_guard after insert or update of cover_url on public.hub_chapters
  for each row execute function public.image_guard_on_reference('cover_url');

-- ---------------------------------------------------------------------------
-- 9. Public request
-- ---------------------------------------------------------------------------
create or replace function public.submit_takedown_request(
  p_name text, p_email text, p_relationship text, p_locations text, p_good_faith boolean, p_signature text,
  p_description text default '', p_involves_minor boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_name      text := left(btrim(coalesce(p_name, '')), 200);
  v_email     text := lower(btrim(coalesce(p_email, '')));
  v_locations text := btrim(coalesce(p_locations, ''));
  v_desc      text := btrim(coalesce(p_description, ''));
  v_sig       text := btrim(coalesce(p_signature, ''));
  v_minor     boolean := coalesce(p_involves_minor, false);
  v_hash      text;
  v_ref       text;
  v_due       timestamptz;
begin
  if char_length(v_name) < 2 then
    raise exception 'name_required' using errcode = '22023';
  end if;
  if char_length(v_email) > 254 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'invalid_email' using errcode = '22023';
  end if;
  if coalesce(p_relationship, '') not in ('self', 'authorized') then
    raise exception 'invalid_relationship' using errcode = '22023';
  end if;
  if char_length(v_locations) < 3 then
    raise exception 'location_required' using errcode = '22023';
  end if;
  if char_length(v_locations) > 4000 or char_length(v_desc) > 2000 then
    raise exception 'too_long' using errcode = '22023';
  end if;
  if not coalesce(p_good_faith, false) then
    raise exception 'good_faith_required' using errcode = '22023';
  end if;
  if char_length(v_sig) < 2 or char_length(v_sig) > 200 then
    raise exception 'signature_required' using errcode = '22023';
  end if;

  v_hash := encode(extensions.digest(v_email, 'sha256'), 'hex');
  if (select count(*) from public.takedown_requests t
       where t.email_hash = v_hash and t.created_at > now() - interval '1 day') >= 3
     or (select count(*) from public.takedown_requests t where t.created_at > now() - interval '1 hour') >= 200 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  loop
    v_ref := 'NCII-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.takedown_requests t where t.reference = v_ref);
  end loop;
  v_due := now() + case when v_minor then interval '4 hours' else interval '48 hours' end;

  insert into public.takedown_requests (reference, requester_name, requester_email, email_hash, relationship,
                                        locations, description, good_faith, signature, involves_minor,
                                        priority, due_at)
  values (v_ref, v_name, v_email, v_hash, p_relationship, v_locations, v_desc, true, v_sig, v_minor,
          case when v_minor then 0 else 1 end, v_due);
  return jsonb_build_object('reference', v_ref, 'due_at', v_due);
end $$;
comment on function public.submit_takedown_request(text, text, text, text, boolean, text, text, boolean) is
  'Migration 52, public (anon and authenticated): files a request to remove non-consensual intimate imagery. Requires a name, a contact email, relationship self | authorized, where the image is, the good-faith statement and a typed signature. 3 a day per email address, 200 an hour overall (rate_limited). Returns {reference, due_at}: 48 hours, or 4 hours when the person shown may be under 18.';

-- ---------------------------------------------------------------------------
-- 10. Moderator RPCs
-- ---------------------------------------------------------------------------
create or replace function public.mod_takedown_queue(p_limit integer default 100, p_closed boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id,
             'reference', t.reference,
             'status', t.status,
             'priority', t.priority,
             'received_at', t.created_at,
             'due_at', t.due_at,
             'overdue', t.status in ('open', 'waiting') and t.due_at < now(),
             'minutes_left', case when t.status in ('open', 'waiting')
                                  then floor(extract(epoch from (t.due_at - now())) / 60)::integer end,
             'involves_minor', t.involves_minor,
             'requester', jsonb_build_object('name', t.requester_name, 'email', t.requester_email,
                                             'relationship', t.relationship),
             'signature', t.signature,
             'locations', t.locations,
             'description', t.description,
             'images_blocked', t.images_blocked,
             'images', (select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'bucket', h.bucket, 'path', h.path,
                                                                      'status', h.status, 'deleted', h.purged_at is not null)
                                                   order by h.created_at), '[]'::jsonb)
                          from public.image_hashes h
                         where h.block_request_id = t.id
                            or h.blocked_hash_id in (select b.id from public.blocked_image_hashes b where b.request_id = t.id)),
             'target_user', (select jsonb_build_object('id', p.id, 'handle', p.handle, 'first_name', p.first_name,
                                                       'status', p.status)
                               from public.profiles p where p.id = t.target_user_id),
             'resolution_note', t.resolution_note,
             'resolved_at', t.resolved_at,
             'can_act', t.target_user_id is distinct from uid
           ) order by t.priority, t.due_at)
      from (select * from public.takedown_requests r
             where case when coalesce(p_closed, false) then r.status in ('removed', 'rejected')
                        else r.status in ('open', 'waiting') end
             order by r.priority, r.due_at
             limit greatest(1, least(coalesce(p_limit, 100), 500))) t), '[]'::jsonb);
end $$;
comment on function public.mod_takedown_queue(integer, boolean) is
  'Migration 52, moderators: NCII takedown requests, most urgent first (priority, then due_at; 48 hours, 4 when a minor may be shown). Open and waiting by default, closed with p_closed. Each item: id, reference, status, priority, received_at, due_at, overdue, minutes_left, involves_minor, requester {name, email, relationship}, signature, locations, description, images_blocked, images [{id, bucket, path, status, deleted}], target_user, resolution_note, resolved_at, can_act (false under the second-moderator rule).';

create or replace function public.mod_takedown_block_image(p_request uuid, p_image_url text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  v_req     public.takedown_requests%rowtype;
  v_bucket  text;
  v_path    text;
  v_owner   uuid;
  v_row     public.image_hashes%rowtype;
  v_cleared integer;
  v_blocked uuid;
  v_copies  integer := 0;
  v_state   text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_req from public.takedown_requests where id = p_request for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_req.status not in ('open', 'waiting') then
    raise exception 'request_closed' using errcode = 'P0001';
  end if;
  select o.bucket, o.path into v_bucket, v_path from public.storage_object_from_url(btrim(p_image_url)) o;
  if v_bucket is null then
    raise exception 'invalid_image_url' using errcode = '22023';
  end if;
  v_owner := public.image_owner_from_path(v_path);
  if v_owner = uid or v_req.target_user_id = uid then
    raise exception 'own_item' using errcode = '42501';
  end if;

  -- Off every surface at once, whatever the hashing does next.
  v_cleared := public.image_clear_references(v_bucket, v_path);
  update public.takedown_requests
     set target_user_id = coalesce(target_user_id, v_owner), updated_at = now()
   where id = p_request;

  insert into public.image_hashes (bucket, path, owner_id, status)
  values (v_bucket, v_path, v_owner, 'pending')
  on conflict (bucket, path) do nothing;
  select * into v_row from public.image_hashes where bucket = v_bucket and path = v_path for update;

  if v_row.status = 'hashed' then
    v_blocked := public.image_block_hash(p_request, v_row.sha256, v_row.phash, v_row.dhash);
    v_copies := public.image_block_matches(v_blocked, uid);
    v_state := 'blocked';
  elsif v_row.status = 'blocked' then
    if v_row.sha256 is not null then
      v_blocked := public.image_block_hash(p_request, v_row.sha256, v_row.phash, v_row.dhash);
      v_copies := public.image_block_matches(v_blocked, uid);
    end if;
    v_state := 'blocked';
  elsif v_row.status = 'unreadable' then
    v_state := 'removed';
  else
    update public.image_hashes
       set status = 'pending', block_request_id = p_request, attempts = 1, dispatched_at = now()
     where id = v_row.id;
    perform public.image_guard_dispatch(jsonb_build_object('op', 'check', 'bucket', v_bucket, 'path', v_path));
    v_state := 'hashing';
  end if;
  if v_state <> 'hashing' then
    perform public.image_guard_dispatch(jsonb_build_object('op', 'sweep'));
  end if;

  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
  values (uid, 'image_block', 'takedown', p_request, v_owner,
          left(v_state || ': ' || v_bucket || '/' || v_path || '; copies ' || v_copies || '; references cleared ' || v_cleared, 500));
  return jsonb_build_object('state', v_state, 'copies', v_copies, 'references_cleared', v_cleared);
end $$;
comment on function public.mod_takedown_block_image(uuid, text) is
  'Migration 52, moderators: removes the image at p_image_url (this project''s Storage) under a request. Clears every photo or cover pointing at it at once; when its hashes are known, blocks them and every stored copy within image_hash_close (state blocked), otherwise asks image-guard to hash it first (state hashing; the block follows on its answer). image-guard deletes the objects. Second-moderator rule: own_item for the moderator''s own image or a request about them. Returns {state, copies, references_cleared}.';

create or replace function public.mod_takedown_resolve(p_request uuid, p_action text, p_note text default null,
                                                       p_target_user uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_req  public.takedown_requests%rowtype;
  v_note text := left(btrim(coalesce(p_note, '')), 1000);
  v_new  text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_action not in ('removed', 'rejected', 'waiting', 'reopen') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if p_action in ('rejected', 'waiting') and v_note = '' then
    raise exception 'note_required' using errcode = '22023';
  end if;
  select * into v_req from public.takedown_requests where id = p_request for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if p_target_user is not null and not exists (select 1 from public.profiles p where p.id = p_target_user) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if coalesce(p_target_user, v_req.target_user_id) = uid then
    raise exception 'own_item' using errcode = '42501';
  end if;
  if p_action = 'reopen' then
    if v_req.status not in ('removed', 'rejected') then
      raise exception 'request_open' using errcode = 'P0001';
    end if;
  elsif v_req.status not in ('open', 'waiting') then
    raise exception 'request_closed' using errcode = 'P0001';
  end if;
  if v_req.contact_cleared_at is not null then
    raise exception 'request_closed' using errcode = 'P0001';
  end if;

  v_new := case p_action when 'reopen' then 'open' else p_action end;
  update public.takedown_requests
     set status          = v_new,
         target_user_id  = coalesce(p_target_user, target_user_id),
         resolution_note = case when v_note <> '' then v_note else resolution_note end,
         resolved_by     = case when v_new in ('removed', 'rejected') then uid end,
         resolved_at     = case when v_new in ('removed', 'rejected') then now() end,
         updated_at      = now()
   where id = p_request;
  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
  values (uid, case p_action when 'removed' then 'ncii_remove' when 'rejected' then 'ncii_reject' else 'ncii_update' end,
          'takedown', p_request, coalesce(p_target_user, v_req.target_user_id),
          nullif(left(p_action || case when v_note <> '' then ': ' || v_note else '' end, 500), ''));
  return jsonb_build_object('id', p_request, 'status', v_new);
end $$;
comment on function public.mod_takedown_resolve(uuid, text, text, uuid) is
  'Migration 52, moderators: removed (the image and its copies are gone; use mod_takedown_block_image for images on Activity Planet and mod_moderate for other content), rejected (not a valid request; note required), waiting (more information asked for by email; note required; the 48-hour clock keeps running) or reopen. p_target_user links the profile the request is about. Logged in moderation_actions. Second-moderator rule: own_item.';

-- ---------------------------------------------------------------------------
-- 11. Retention
-- ---------------------------------------------------------------------------
create or replace function public.purge_takedown_contacts()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_n integer;
begin
  update public.takedown_requests
     set requester_name = '', requester_email = '', email_hash = '', signature = '', locations = '', description = '',
         resolution_note = '', contact_cleared_at = now(), updated_at = now()
   where status in ('removed', 'rejected') and resolved_at < now() - interval '365 days'
     and contact_cleared_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
comment on function public.purge_takedown_contacts() is
  'Migration 52, pg_cron takedown-contacts-purge daily: clears the requester''s name, email, signature and the free text of requests closed more than a year ago. The email hash (used only for the daily rate limit) goes too. The reference, dates, outcome and image hashes stay.';

-- ---------------------------------------------------------------------------
-- 12. Account deletion (migration 51 body plus the takedown rows)
-- ---------------------------------------------------------------------------
create or replace function public.request_account_deletion(p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid       uuid := (select auth.uid());
  v_profile public.profiles%rowtype;
  v_email   text;
  v_handle  text;
  v_reason  text := nullif(left(btrim(coalesce(p_reason, '')), 500), '');
  v_event   uuid;
  v_ids     uuid[];
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where id = uid for update;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;
  -- Idempotent: a retry after a lost response must not fail.
  if v_profile.status = 'deleted' then
    return;
  end if;

  select lower(email) into v_email from auth.users where id = uid;

  -- Evidence ledger first; it has no foreign key and outlives everything below.
  insert into public.account_deletions (user_id, email_hash, requested_at, retain_evidence_until, reason)
  values (
    uid,
    encode(extensions.digest(coalesce(v_email, uid::text), 'sha256'), 'hex'),
    now(),
    -- Migration 51: a banned account's ledger row is kept for a year.
    now() + case when v_profile.status = 'banned' then interval '365 days' else interval '30 days' end,
    v_reason
  )
  on conflict (user_id) do update
     set requested_at          = excluded.requested_at,
         retain_evidence_until = excluded.retain_evidence_until,
         reason                = coalesce(excluded.reason, public.account_deletions.reason),
         completed_at          = null;

  -- Release the handle (30-day hold, same as a rename) and pick a tombstone handle that
  -- cannot collide: 'deleted' itself is reserved and the suffix is random.
  insert into public.handle_history (user_id, handle) values (uid, v_profile.handle);
  loop
    v_handle := 'deleted_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
    exit when not exists (select 1 from public.profiles where lower(handle) = v_handle);
  end loop;

  perform set_config('ap.account_deletion', 'on', true);
  update public.profiles
     set handle                 = v_handle,
         first_name             = 'Deleted user',
         bio                    = '',
         avatar_url             = null,
         home_org_id            = null,
         home_campus_id         = null,
         guidelines_accepted_at = null,
         status                 = 'deleted',
         deletion_requested_at  = now(),
         deleted_at             = now()
   where id = uid;
  perform set_config('ap.account_deletion', 'off', true);

  -- Events: hosted series and future events are cancelled (past ones stay as
  -- history under "Deleted user"), their addresses go, private venues go,
  -- public venues lose the creator link.
  update public.event_series
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host_deleted',
         location_text = '', address_note = ''
   where host_id = uid and status = 'published';
  update public.event_series
     set location_text = '', address_note = ''
   where host_id = uid and (location_text <> '' or address_note <> '');
  with u as (
    update public.events
       set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host_deleted'
     where host_id = uid and status = 'published' and starts_at > now()
    returning id
  )
  select coalesce(array_agg(id), '{}') into v_ids from u;
  -- Their attendees hear about it (migration 18); the caller's own profile is
  -- already a tombstone, so nothing is queued for the caller.
  foreach v_event in array v_ids loop
    perform public.notify_event_audience(
      v_event, 'event_cancelled', array['going', 'waitlisted', 'interested']::public.rsvp_status[],
      v_event::text, null, jsonb_build_object('reason', 'host_deleted'));
  end loop;
  v_event := null;
  delete from public.event_addresses
   where event_id in (select id from public.events where host_id = uid)
      or venue_id in (select id from public.venues where created_by = uid and not is_public);
  delete from public.venues where created_by = uid and not is_public;
  update public.venues set created_by = null where created_by = uid;

  -- Places (migration 27): the caller's private pins and still-pending
  -- requests go; places a moderator reviewed stay as ODbL place facts with
  -- no creator link (D-041).
  delete from public.places
   where created_by = uid and source = 'user' and (not is_public or status = 'pending');
  update public.places set created_by = null where created_by = uid;

  -- Place corrections and reports (migration 34): pending edits go; the
  -- rest of the caller's edits and every report they made lose the author
  -- and the note (a report keeps its reason, so a place it hid stays in the
  -- moderation queue); reviewer stamps and moderation log entries naming the caller are
  -- cleared.
  delete from public.place_edits where proposed_by = uid and status = 'pending';
  update public.place_edits set proposed_by = null, note = '' where proposed_by = uid;
  update public.place_edits set reviewed_by = null where reviewed_by = uid;
  update public.place_reports set reporter_id = null, note = '' where reporter_id = uid;
  update public.place_reports set resolved_by = null where resolved_by = uid;
  update public.place_mod_actions set moderator_id = null where moderator_id = uid;
  -- Migration 36: the caller's add and edit rate log.
  delete from public.place_rate_log where user_id = uid;

  -- Attendance (migration 20): the caller's reports and every meet that
  -- names the caller, in either direction. (Reports would also go with the
  -- RSVP rows below; deleted here so the order does not matter.)
  delete from public.event_meets              where user_id = uid or met_user_id = uid;
  delete from public.event_attendance_reports where user_id = uid;

  -- RSVPs: every row goes (the counters trigger fixes the counts); seats on
  -- future events are handed to the waitlist.
  for v_event in
    select event_id from public.rsvps r
      join public.events e on e.id = r.event_id
     where r.user_id = uid and r.status = 'going' and e.status = 'published' and e.ends_at > now()
  loop
    delete from public.rsvps where event_id = v_event and user_id = uid;
    perform public.rsvp_promote_waitlist(v_event);
  end loop;
  delete from public.rsvps where user_id = uid;
  update public.rsvps set removed_by = null where removed_by = uid;
  update public.rsvps set checked_in_by = null where checked_in_by = uid;

  -- Chapters: the caller's claims (reference contacts included) go; stamps
  -- that point at the caller are cleared. The chapter_members row goes below
  -- (the last-organizer guard lets a deleted profile leave).
  delete from public.chapter_claims where user_id = uid;
  update public.chapter_claims set reviewed_by = null where reviewed_by = uid;
  update public.hub_chapters set claimed_by = null where claimed_by = uid;

  -- Notifications (migration 18): the caller's inbox goes; rows that name the
  -- caller as the actor keep their text and lose the link; broadcasts the
  -- caller sent stay with the event, unattributed.
  delete from public.notifications where user_id = uid;
  update public.notifications set actor_id = null where actor_id = uid;
  update public.event_broadcasts set sender_id = null where sender_id = uid;

  -- Trust and safety (migration 51): blocks and mutes in either direction
  -- go; reports the caller filed lose the reporter and the note; resolver
  -- and moderator stamps naming the caller are cleared, and so are profile
  -- snapshots about the caller. Reports about the caller and the action log
  -- stay as moderation evidence.
  delete from public.blocks where blocker_id = uid or blocked_id = uid;
  delete from public.mutes  where muter_id = uid or muted_id = uid;
  update public.reports set reporter_id = null, note = '' where reporter_id = uid;
  update public.reports set resolved_by = null where resolved_by = uid;
  update public.moderation_actions set moderator_id = null where moderator_id = uid;
  update public.moderation_actions set snapshot = null where target_user_id = uid and snapshot is not null;

  -- Migration 52: NCII takedowns. Resolver stamps naming the caller are
  -- cleared; the caller's image hashes go, except blocked ones (evidence of
  -- who uploaded a removed image). Requests about the caller stay, like
  -- reports.
  update public.takedown_requests set resolved_by = null where resolved_by = uid;
  delete from public.image_hashes where owner_id = uid and status <> 'blocked';

  -- Personal data and memberships go now. Avatar files are removed by the Edge Function
  -- through the Storage API (deleting storage.objects rows here would orphan the files).
  delete from public.profile_private          where user_id = uid;
  delete from public.notification_prefs       where user_id = uid;
  delete from public.push_devices             where user_id = uid;
  delete from public.hub_members              where user_id = uid;
  delete from public.chapter_members          where user_id = uid;
  delete from public.org_memberships          where user_id = uid;
  delete from public.verified_emails          where user_id = uid;
  delete from public.email_verification_codes where user_id = uid;
  delete from public.user_roles               where user_id = uid;
  delete from public.area_waitlist            where user_id = uid;
  -- auth_provider_secrets stays until the Edge Function has revoked the Apple token.
  -- hub_requests keep pointing at the tombstone (they read as "Deleted user").

  -- Stop sign-in at once: password, OAuth, magic-link and refresh grants all check
  -- banned_until. Sessions are ended by the Edge Function's soft delete; an access token
  -- issued before this call lasts at most jwt_expiry (one hour), and the app drops it on
  -- its next route load (profiles.deleted_at).
  update auth.users
     set banned_until       = now() + interval '100 years',
         raw_user_meta_data = '{}'::jsonb
   where id = uid;
end $$;

-- ---------------------------------------------------------------------------
-- 13. pg_cron jobs
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; image-guard-tick and takedown-contacts-purge not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'image-guard-tick') then
    perform cron.unschedule('image-guard-tick');
  end if;
  perform cron.schedule('image-guard-tick', '4,14,24,34,44,54 * * * *', 'select public.image_guard_tick()');
  if exists (select 1 from cron.job where jobname = 'takedown-contacts-purge') then
    perform cron.unschedule('takedown-contacts-purge');
  end if;
  perform cron.schedule('takedown-contacts-purge', '19 5 * * *', 'select public.purge_takedown_contacts()');
end $$;

-- ---------------------------------------------------------------------------
-- 14. Privileges (explicit)
-- ---------------------------------------------------------------------------
-- Internal helpers: nobody but the definer functions (service_role for the tests' sake where noted).
revoke all on function public.image_hash_from_hex(text) from public, anon, authenticated;
grant execute on function public.image_hash_from_hex(text) to service_role;
revoke all on function public.image_hash_close(bigint, bigint, bigint, bigint) from public, anon, authenticated;
grant execute on function public.image_hash_close(bigint, bigint, bigint, bigint) to service_role;
revoke all on function public.storage_object_from_url(text) from public, anon, authenticated;
grant execute on function public.storage_object_from_url(text) to service_role;
revoke all on function public.image_owner_from_path(text) from public, anon, authenticated;
revoke all on function public.image_clear_references(text, text) from public, anon, authenticated;
revoke all on function public.image_guard_dispatch(jsonb) from public, anon, authenticated;
revoke all on function public.image_block_row(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.image_block_matches(uuid, uuid) from public, anon, authenticated;
revoke all on function public.image_block_hash(uuid, text, bigint, bigint) from public, anon, authenticated;
revoke all on function public.image_guard_on_reference() from public, anon, authenticated;
revoke all on function public.image_guard_tick() from public, anon, authenticated;
revoke all on function public.purge_takedown_contacts() from public, anon, authenticated;
-- image-guard (service role).
revoke all on function public.image_guard_verify_secret(text) from public, anon, authenticated;
grant execute on function public.image_guard_verify_secret(text) to service_role;
revoke all on function public.image_guard_record(text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.image_guard_record(text, text, text, text, text, text) to service_role;
revoke all on function public.image_guard_purge_list(integer) from public, anon, authenticated;
grant execute on function public.image_guard_purge_list(integer) to service_role;
revoke all on function public.image_guard_mark_purged(uuid[]) from public, anon, authenticated;
grant execute on function public.image_guard_mark_purged(uuid[]) to service_role;
-- The public form.
revoke all on function public.submit_takedown_request(text, text, text, text, boolean, text, text, boolean) from public;
grant execute on function public.submit_takedown_request(text, text, text, text, boolean, text, text, boolean)
  to anon, authenticated;
-- Moderators (each refuses non-moderators with forbidden).
revoke all on function public.mod_takedown_queue(integer, boolean) from public, anon;
grant execute on function public.mod_takedown_queue(integer, boolean) to authenticated;
revoke all on function public.mod_takedown_block_image(uuid, text) from public, anon;
grant execute on function public.mod_takedown_block_image(uuid, text) to authenticated;
revoke all on function public.mod_takedown_resolve(uuid, text, text, uuid) from public, anon;
grant execute on function public.mod_takedown_resolve(uuid, text, text, uuid) to authenticated;
-- Rebuilt.
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 15. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.48')
  on conflict (key) do update set value = excluded.value, updated_at = now();
