-- TEMPORARY staging precheck (removed before merge): migration 67 and its three test files in one
-- transaction that rolls back, so the migration is exercised on staging before it is applied.
begin;
-- ============================================================================
-- Activity Planet schema v2 — migration 67: recommendations, slice 1 (D-045,
-- docs/design/recommendations/RECS_DESIGN.md sections 2 to 7, 10 to 12).
--   Builds on migrations 1 to 66, which reached staging and are not edited.
--
--     * pgvector (extensions schema); halfvec(384) embeddings of hubs, events
--       and coach listings from Supabase's built-in gte-small model, made by
--       the recs-embed Edge Function from a trigger-fed queue (pg_cron
--       recs-embed every minute, capped per run and per day, a 5-minute lease,
--       5 attempts) and a one-call backfill (recs_backfill, run once below).
--     * A member's taste vector (rec_taste, readable by no client role): a
--       weighted, time-decayed average of the embeddings of their
--       non-sensitive hubs, RSVPs, check-ins and completed coaching sessions,
--       minus "Not interested". recs_taste_refresh through recs_tick.
--     * Recommendation RPCs, all security invoker, re-ranking a set the
--       caller can already read: recs_for_you and recs_similar_events
--       (feed_events_v2), recs_hubs (hubs_read), recs_coaches
--       (search_coaches), recs_people (shared context only). The only
--       definer helpers are the private scorers, which return numbers and
--       reason codes for ids the caller passes in, after re-checking that the
--       caller can read each one. No RPC returns a vector, a score, a
--       distance or a coordinate.
--     * rec_dismiss / rec_undismiss, my_recommendation_prefs /
--       set_recommendation_prefs (personalize, people_suggestions opt-out),
--       public_week_near (landing page, anon), recs_status (moderators).
--     * Weekly scorecard: scorecard_week (counts only), scorecard_runs,
--       scorecard_dispatch (pg_cron weekly-scorecard, Monday 12:07 UTC) to the
--       weekly-scorecard Edge Function, which skips without RESEND_API_KEY and
--       SCORECARD_TO.
--     * Vault secrets recs_embed_secret and scorecard_secret, generated here
--       and in no file.
--     * request_account_deletion (migration 62 body), changes marked
--       "Migration 67": the caller's taste, prefs and dismissals go, and so do
--       other members' "Not interested" in the caller.
--     * meta.schema_version 2.63.
--
--   Account deletion: rec_taste, rec_prefs and rec_dismissals (both
--   directions) are deleted by request_account_deletion. The embedding and
--   queue tables hold no user id; scorecard_runs holds counts only.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Extension, enum, tables, meta keys
-- ---------------------------------------------------------------------------
create extension if not exists vector with schema extensions;

do $$ begin
  create type public.rec_subject_kind as enum ('hub', 'event', 'coach', 'person');
exception when duplicate_object then null; end $$;

create table if not exists public.hub_embeddings (
  hub_id       uuid primary key references public.hubs (id) on delete cascade,
  embedding    extensions.halfvec(384) not null,
  content_hash text not null,
  model        text not null default 'gte-small',
  embedded_at  timestamptz not null default now()
);
create table if not exists public.event_embeddings (
  event_id     uuid primary key references public.events (id) on delete cascade,
  embedding    extensions.halfvec(384) not null,
  content_hash text not null,
  model        text not null default 'gte-small',
  embedded_at  timestamptz not null default now()
);
create table if not exists public.coach_listing_embeddings (
  listing_id   uuid primary key references public.coach_listings (id) on delete cascade,
  embedding    extensions.halfvec(384) not null,
  content_hash text not null,
  model        text not null default 'gte-small',
  embedded_at  timestamptz not null default now()
);
create index if not exists hub_embeddings_embedded_at_idx on public.hub_embeddings (embedded_at);
create index if not exists event_embeddings_embedded_at_idx on public.event_embeddings (embedded_at);
create index if not exists coach_listing_embeddings_embedded_at_idx on public.coach_listing_embeddings (embedded_at);

-- Work queue: one row per subject that needs (re)embedding. No user id.
create table if not exists public.rec_embed_queue (
  subject_kind public.rec_subject_kind not null check (subject_kind in ('hub', 'event', 'coach')),
  subject_id   uuid not null,
  queued_at    timestamptz not null default now(),
  priority     smallint not null default 5,
  claimed_at   timestamptz,
  attempts     smallint not null default 0,
  last_error   text check (last_error is null or char_length(last_error) <= 80),
  failed_at    timestamptz,
  primary key (subject_kind, subject_id)
);
create index if not exists rec_embed_queue_due_idx on public.rec_embed_queue (priority, queued_at)
  where failed_at is null;

-- A member's taste. The owner cannot read it either.
create table if not exists public.rec_taste (
  user_id     uuid primary key references public.profiles (id) on delete cascade,
  embedding   extensions.halfvec(384),
  inputs      integer not null default 0,
  stale       boolean not null default true,
  computed_at timestamptz
);
create index if not exists rec_taste_stale_idx on public.rec_taste (user_id) where stale;

create table if not exists public.rec_prefs (
  user_id            uuid primary key references public.profiles (id) on delete cascade,
  personalize        boolean not null default true,
  people_suggestions boolean not null default true,
  updated_at         timestamptz not null default now()
);

create table if not exists public.rec_dismissals (
  user_id      uuid not null references public.profiles (id) on delete cascade,
  subject_kind public.rec_subject_kind not null,
  subject_id   uuid not null,
  created_at   timestamptz not null default now(),
  primary key (user_id, subject_kind, subject_id)
);
create index if not exists rec_dismissals_subject_idx on public.rec_dismissals (subject_kind, subject_id);
create index if not exists rec_dismissals_created_idx on public.rec_dismissals (user_id, created_at);

create table if not exists public.scorecard_runs (
  week_start date primary key,
  counts     jsonb not null,
  status     text not null check (status in ('sent', 'skipped_no_key', 'failed')),
  sent_at    timestamptz,
  error      text check (error is null or char_length(error) <= 80)
);

comment on table public.hub_embeddings is
  'Migration 67 (D-045): gte-small embedding (halfvec 384, normalized) of an eligible hub''s text (private.rec_text). Written only by recs_embed_record; readable by no client role.';
comment on table public.event_embeddings is
  'Migration 67 (D-045): gte-small embedding of an event''s text. Kept up to 365 days after the start for taste vectors, then purged (purge_recs). Readable by no client role.';
comment on table public.coach_listing_embeddings is
  'Migration 67 (D-045): gte-small embedding of an active coach listing''s text. Readable by no client role.';
comment on table public.rec_embed_queue is
  'Migration 67 (D-045): subjects to (re)embed, filled by triggers, recs_tick and recs_backfill, drained by recs-embed (recs_embed_claim / recs_embed_record / recs_embed_fail). priority 0 to 9 (lower first), claimed_at is a 5-minute lease, failed_at after 5 attempts; last_error is an error code, never text. No user id.';
comment on table public.rec_taste is
  'Migration 67 (D-045): a member''s taste vector (null without usable input or with personalize off). Readable by no client role, not even the owner.';
comment on table public.rec_prefs is
  'Migration 67 (D-045): personalize (off: rules-only rows, no taste vector) and people_suggestions (off: never suggested to anyone, no People row). Owner read; written through set_recommendation_prefs.';
comment on table public.rec_dismissals is
  'Migration 67 (D-045): "Not interested" (rec_dismiss). Owner read; at most 500 a member; purged after 180 days.';
comment on table public.scorecard_runs is
  'Migration 67 (D-045): one row per scorecard week (Monday, America/New_York): counts only, never a row or a name. Moderator read.';

alter table public.hub_embeddings           enable row level security;
alter table public.event_embeddings         enable row level security;
alter table public.coach_listing_embeddings enable row level security;
alter table public.rec_embed_queue          enable row level security;
alter table public.rec_taste                enable row level security;
alter table public.rec_prefs                enable row level security;
alter table public.rec_dismissals           enable row level security;
alter table public.scorecard_runs           enable row level security;

revoke all on table public.hub_embeddings, public.event_embeddings, public.coach_listing_embeddings,
                    public.rec_embed_queue, public.rec_taste, public.rec_prefs, public.rec_dismissals,
                    public.scorecard_runs
  from public, anon, authenticated;
grant select on table public.rec_prefs, public.rec_dismissals, public.scorecard_runs to authenticated;

drop policy if exists rec_prefs_select_own on public.rec_prefs;
create policy rec_prefs_select_own on public.rec_prefs
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists rec_dismissals_select_own on public.rec_dismissals;
create policy rec_dismissals_select_own on public.rec_dismissals
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists scorecard_runs_select_mod on public.scorecard_runs;
create policy scorecard_runs_select_mod on public.scorecard_runs
  for select to authenticated using ((select public.is_moderator()));

insert into public.meta (key, value) values
  ('recs', 'on'),
  ('recs_text_version', '1'),
  ('recs_embed_batch', '24'),
  ('recs_embed_daily_cap', '20000'),
  ('recs_weights', '{"sim":0.5,"time":0.25,"dist":0.25,"hub":0.10,"met":0.05,"imported":-0.05}'),
  ('recs_similar_floor', '0.82'),
  ('recs_hub_floor', '0.80')
on conflict (key) do nothing;

-- Vault secrets, generated here and in no file.
do $$
begin
  if to_regclass('vault.secrets') is null then
    raise notice 'supabase_vault is not installed; recs_embed_secret and scorecard_secret not created';
    return;
  end if;
  if not exists (select 1 from vault.secrets where name = 'recs_embed_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'recs_embed_secret',
                                'Shared secret between the database and the recs-embed Edge Function (migration 67)');
  end if;
  if not exists (select 1 from vault.secrets where name = 'scorecard_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'scorecard_secret',
                                'Shared secret between the database and the weekly-scorecard Edge Function (migration 67)');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Private helpers: settings, text, eligibility, hashing
-- ---------------------------------------------------------------------------
create or replace function private.recs_on()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select m.value from public.meta m where m.key = 'recs'), 'on') = 'on';
$$;

create or replace function private.rec_meta_num(p_key text, p_default double precision)
returns double precision language plpgsql stable security definer set search_path = '' as $$
begin
  return coalesce((select m.value::double precision from public.meta m where m.key = p_key), p_default);
exception when others then
  return p_default;
end $$;

create or replace function private.rec_weights()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_def jsonb := '{"sim":0.5,"time":0.25,"dist":0.25,"hub":0.10,"met":0.05,"imported":-0.05}';
begin
  return v_def || coalesce((select m.value::jsonb from public.meta m where m.key = 'recs_weights'), '{}'::jsonb);
exception when others then
  return v_def;
end $$;

-- Inner product of two normalized vectors (= cosine similarity).
create or replace function private.rec_ip(p_a extensions.halfvec, p_b extensions.halfvec)
returns real language sql immutable parallel safe set search_path = '' as $$
  select case when p_a is null or p_b is null then null
              else extensions.inner_product(p_a::extensions.vector, p_b::extensions.vector)::real end;
$$;

create or replace function private.rec_hub_sensitive(p_hub uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select c.is_sensitive from public.hubs h join public.hub_categories c on c.slug = h.category_slug
                    where h.id = p_hub), true);
$$;

create or replace function private.rec_personalize(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select rp.personalize from public.rec_prefs rp where rp.user_id = p_user), true);
$$;

-- URLs, email addresses and phone numbers out, whitespace collapsed.
create or replace function private.rec_strip(p_text text)
returns text language sql immutable parallel safe set search_path = '' as $$
  select btrim(regexp_replace(
           regexp_replace(
             regexp_replace(
               regexp_replace(coalesce(p_text, ''), '(https?://|www\.)\S+', ' ', 'gi'),
               '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', ' ', 'g'),
             '\+?\d[\d\s().-]{7,}\d', ' ', 'g'),
           '\s+', ' ', 'g'));
$$;

-- The text that is embedded (at most 1,600 characters), or null when the subject is gone.
create or replace function private.rec_text(p_kind public.rec_subject_kind, p_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select left(private.rec_strip(t.body), 1600)
    from (
      select concat_ws('. ', h.name, nullif(array_to_string(h.aliases, ', '), ''), c.name, nullif(btrim(h.description), '')) as body
        from public.hubs h join public.hub_categories c on c.slug = h.category_slug
       where p_kind = 'hub' and h.id = p_id
      union all
      select h.name || ': ' || concat_ws('. ', e.title, nullif(btrim(e.description), ''))
        from public.events e join public.hubs h on h.id = e.hub_id
       where p_kind = 'event' and e.id = p_id
      union all
      select coalesce(h.name || ': ', '') || concat_ws('. ', l.title, nullif(btrim(l.description), ''), nullif(btrim(cp.headline), ''))
        from public.coach_listings l
        join public.coach_profiles cp on cp.user_id = l.coach_id
        left join public.hubs h on h.id = l.hub_id
       where p_kind = 'coach' and l.id = p_id
    ) t
   limit 1;
$$;

-- Eligible to be embedded now (design section 2).
create or replace function private.rec_embeddable(p_kind public.rec_subject_kind, p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select case p_kind
    when 'hub' then exists (
      select 1 from public.hubs h join public.hub_categories c on c.slug = h.category_slug
       where h.id = p_id and h.is_active and h.moderation_state is null and not c.is_sensitive and h.scope = 'general')
    when 'event' then exists (
      select 1 from public.events e join public.hubs h on h.id = e.hub_id join public.hub_categories c on c.slug = h.category_slug
       where e.id = p_id and e.status = 'published' and e.moderation_state is null and not c.is_sensitive
         and e.starts_at >= now() - interval '1 day'
         and e.starts_at < now() + case when e.kind = 'imported' then interval '60 days' else interval '120 days' end)
    when 'coach' then exists (
      select 1 from public.coach_listings l join public.coach_profiles cp on cp.user_id = l.coach_id
       where l.id = p_id and l.status = 'active' and l.moderation_state is null and cp.status = 'active'
         and (l.hub_id is null or not private.rec_hub_sensitive(l.hub_id)))
    else false end;
$$;

-- An existing embedding may stay (purge_recs): events up to 365 days after the start.
create or replace function private.rec_keep(p_kind public.rec_subject_kind, p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select case p_kind
    when 'event' then exists (
      select 1 from public.events e join public.hubs h on h.id = e.hub_id join public.hub_categories c on c.slug = h.category_slug
       where e.id = p_id and e.status = 'published' and e.moderation_state is null and not c.is_sensitive
         and e.starts_at > now() - interval '365 days')
    else private.rec_embeddable(p_kind, p_id) end;
$$;

create or replace function private.rec_hash(p_text text)
returns text language sql stable security definer set search_path = '' as $$
  select case when p_text is null then null else
    md5(p_text || '|v' || coalesce((select m.value from public.meta m where m.key = 'recs_text_version'), '1')) end;
$$;

create or replace function private.rec_stored_hash(p_kind public.rec_subject_kind, p_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case p_kind
    when 'hub'   then (select x.content_hash from public.hub_embeddings x where x.hub_id = p_id)
    when 'event' then (select x.content_hash from public.event_embeddings x where x.event_id = p_id)
    when 'coach' then (select x.content_hash from public.coach_listing_embeddings x where x.listing_id = p_id)
  end;
$$;

create or replace function private.rec_drop_embedding(p_kind public.rec_subject_kind, p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_kind = 'hub' then
    delete from public.hub_embeddings where hub_id = p_id;
  elsif p_kind = 'event' then
    delete from public.event_embeddings where event_id = p_id;
  elsif p_kind = 'coach' then
    delete from public.coach_listing_embeddings where listing_id = p_id;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Queue and taste-stale triggers (cheap: no text building, no HTTP)
-- ---------------------------------------------------------------------------
create or replace function private.rec_enqueue(p_kind public.rec_subject_kind, p_id uuid, p_priority smallint)
returns void language sql security definer set search_path = '' as $$
  insert into public.rec_embed_queue (subject_kind, subject_id, priority)
  values (p_kind, p_id, p_priority)
  on conflict (subject_kind, subject_id) do update
     set queued_at = now(), claimed_at = null, attempts = 0, failed_at = null, last_error = null,
         priority = least(public.rec_embed_queue.priority, excluded.priority);
$$;

create or replace function private.rec_mark_stale(p_user uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.rec_taste (user_id, stale)
  select p_user, true where p_user is not null and exists (select 1 from public.profiles p where p.id = p_user)
  on conflict (user_id) do update set stale = true where not public.rec_taste.stale;
$$;

create or replace function private.rec_enqueue_hub()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.rec_enqueue('hub', new.id, 1::smallint);
  return null;
end $$;

create or replace function private.rec_enqueue_event()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (new.status = 'published' and new.moderation_state is null
      and new.starts_at >= now() - interval '1 day' and new.starts_at < now() + interval '120 days')
     or exists (select 1 from public.event_embeddings x where x.event_id = new.id) then
    perform private.rec_enqueue('event', new.id, case when new.kind = 'imported' then 5 else 2 end::smallint);
  end if;
  return null;
end $$;

create or replace function private.rec_enqueue_listing()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.rec_enqueue('coach', new.id, 3::smallint);
  return null;
end $$;

create or replace function private.rec_enqueue_coach()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.rec_enqueue('coach', l.id, 3::smallint)
     from public.coach_listings l where l.coach_id = new.user_id;
  return null;
end $$;

drop trigger if exists rec_enqueue_hub_ins on public.hubs;
create trigger rec_enqueue_hub_ins after insert on public.hubs
  for each row execute function private.rec_enqueue_hub();
drop trigger if exists rec_enqueue_hub_upd on public.hubs;
create trigger rec_enqueue_hub_upd after update of name, aliases, description, category_slug, is_active, moderation_state, scope
  on public.hubs for each row
  when (old.name is distinct from new.name or old.aliases is distinct from new.aliases
        or old.description is distinct from new.description or old.category_slug is distinct from new.category_slug
        or old.is_active is distinct from new.is_active or old.moderation_state is distinct from new.moderation_state
        or old.scope is distinct from new.scope)
  execute function private.rec_enqueue_hub();

drop trigger if exists rec_enqueue_event_ins on public.events;
create trigger rec_enqueue_event_ins after insert on public.events
  for each row execute function private.rec_enqueue_event();
drop trigger if exists rec_enqueue_event_upd on public.events;
create trigger rec_enqueue_event_upd after update of title, description, hub_id, status, moderation_state
  on public.events for each row
  when (old.title is distinct from new.title or old.description is distinct from new.description
        or old.hub_id is distinct from new.hub_id or old.status is distinct from new.status
        or old.moderation_state is distinct from new.moderation_state)
  execute function private.rec_enqueue_event();

drop trigger if exists rec_enqueue_listing_ins on public.coach_listings;
create trigger rec_enqueue_listing_ins after insert on public.coach_listings
  for each row execute function private.rec_enqueue_listing();
drop trigger if exists rec_enqueue_listing_upd on public.coach_listings;
create trigger rec_enqueue_listing_upd after update of title, description, hub_id, status, moderation_state
  on public.coach_listings for each row
  when (old.title is distinct from new.title or old.description is distinct from new.description
        or old.hub_id is distinct from new.hub_id or old.status is distinct from new.status
        or old.moderation_state is distinct from new.moderation_state)
  execute function private.rec_enqueue_listing();

drop trigger if exists rec_enqueue_coach_upd on public.coach_profiles;
create trigger rec_enqueue_coach_upd after update of headline, status on public.coach_profiles
  for each row
  when (old.headline is distinct from new.headline or old.status is distinct from new.status)
  execute function private.rec_enqueue_coach();

create or replace function private.rec_stale_hub_member()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.rec_mark_stale(case when tg_op = 'DELETE' then old.user_id else new.user_id end);
  return null;
end $$;
create or replace function private.rec_stale_rsvp()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.rec_mark_stale(new.user_id);
  return null;
end $$;
create or replace function private.rec_stale_booking()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.rec_mark_stale(new.client_id);
  return null;
end $$;
create or replace function private.rec_stale_dismissal()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.rec_mark_stale(new.user_id);
  return null;
end $$;

drop trigger if exists rec_stale_hub_members on public.hub_members;
create trigger rec_stale_hub_members after insert or delete on public.hub_members
  for each row execute function private.rec_stale_hub_member();
drop trigger if exists rec_stale_rsvps_ins on public.rsvps;
create trigger rec_stale_rsvps_ins after insert on public.rsvps
  for each row execute function private.rec_stale_rsvp();
drop trigger if exists rec_stale_rsvps_upd on public.rsvps;
create trigger rec_stale_rsvps_upd after update of status, checked_in_at on public.rsvps
  for each row
  when (old.status is distinct from new.status or old.checked_in_at is distinct from new.checked_in_at)
  execute function private.rec_stale_rsvp();
drop trigger if exists rec_stale_bookings on public.bookings;
create trigger rec_stale_bookings after update of status on public.bookings
  for each row
  when (new.status = 'completed' and old.status is distinct from new.status)
  execute function private.rec_stale_booking();
drop trigger if exists rec_stale_dismissals on public.rec_dismissals;
create trigger rec_stale_dismissals after insert on public.rec_dismissals
  for each row execute function private.rec_stale_dismissal();

-- ---------------------------------------------------------------------------
-- 4. Embedding jobs (service role): dispatch, claim, record, fail, secret, backfill
-- ---------------------------------------------------------------------------
create or replace function private.rec_embedded_today()
returns bigint language sql stable security definer set search_path = '' as $$
  select (select count(*) from public.hub_embeddings x where x.embedded_at >= date_trunc('day', now() at time zone 'UTC') at time zone 'UTC')
       + (select count(*) from public.event_embeddings x where x.embedded_at >= date_trunc('day', now() at time zone 'UTC') at time zone 'UTC')
       + (select count(*) from public.coach_listing_embeddings x where x.embedded_at >= date_trunc('day', now() at time zone 'UTC') at time zone 'UTC');
$$;

create or replace function public.recs_embed_verify_secret(p_secret text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_secret text := public.notify_vault_secret('recs_embed_secret');
begin
  return p_secret is not null and char_length(p_secret) >= 32 and v_secret is not null and v_secret = p_secret;
end $$;

create or replace function public.recs_embed_dispatch()
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_base   text;
  v_secret text;
begin
  if not private.recs_on() then
    return null;
  end if;
  if not exists (select 1 from public.rec_embed_queue q
                  where q.failed_at is null
                    and (q.claimed_at is null or q.claimed_at < now() - interval '5 minutes')) then
    return null;
  end if;
  if private.rec_embedded_today() >= private.rec_meta_num('recs_embed_daily_cap', 20000) then
    return null;
  end if;
  v_base := public.project_url();
  v_secret := public.notify_vault_secret('recs_embed_secret');
  if v_base is null or v_secret is null
     or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    raise notice 'recs-embed: project_url, secret or pg_net missing; nothing sent';
    return null;
  end if;
  return net.http_post(
    url := v_base || '/functions/v1/recs-embed',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-recs-secret', v_secret),
    timeout_milliseconds := 60000);
end $$;

create or replace function public.recs_embed_claim(p_limit integer default 24)
returns table (subject_kind public.rec_subject_kind, subject_id uuid, content_hash text, text text)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 24), private.rec_meta_num('recs_embed_batch', 24)::integer, 200));
  v_n     integer := 0;
  r       record;
  v_text  text;
  v_hash  text;
begin
  for r in
    select q.subject_kind as k, q.subject_id as id, q.attempts as attempts
      from public.rec_embed_queue q
     where q.failed_at is null
       and (q.claimed_at is null or q.claimed_at < now() - interval '5 minutes')
     order by q.priority, q.queued_at
     limit v_limit * 4
       for update skip locked
  loop
    exit when v_n >= v_limit;
    if not private.rec_embeddable(r.k, r.id) then
      -- No longer eligible: off the queue; an embedding that may not stay goes too.
      delete from public.rec_embed_queue q where q.subject_kind = r.k and q.subject_id = r.id;
      if not private.rec_keep(r.k, r.id) then
        perform private.rec_drop_embedding(r.k, r.id);
      end if;
      continue;
    end if;
    if r.attempts >= 5 then
      -- Leased five times without an answer.
      update public.rec_embed_queue q set failed_at = now(), last_error = 'lease_expired'
       where q.subject_kind = r.k and q.subject_id = r.id;
      continue;
    end if;
    v_text := private.rec_text(r.k, r.id);
    v_hash := private.rec_hash(v_text);
    if v_text is null or v_text = '' then
      delete from public.rec_embed_queue q where q.subject_kind = r.k and q.subject_id = r.id;
      continue;
    end if;
    if v_hash is not distinct from private.rec_stored_hash(r.k, r.id) then
      -- Unchanged: done without the model.
      delete from public.rec_embed_queue q where q.subject_kind = r.k and q.subject_id = r.id;
      continue;
    end if;
    update public.rec_embed_queue q set claimed_at = now(), attempts = q.attempts + 1
     where q.subject_kind = r.k and q.subject_id = r.id;
    v_n := v_n + 1;
    subject_kind := r.k;
    subject_id := r.id;
    content_hash := v_hash;
    text := v_text;
    return next;
  end loop;
end $$;

create or replace function public.recs_embed_fail(p_kind public.rec_subject_kind, p_id uuid, p_error text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_err text := left(coalesce(nullif(regexp_replace(lower(coalesce(p_error, '')), '[^a-z0-9_]', '', 'g'), ''), 'error'), 80);
begin
  -- The lease stays (retried after 5 minutes); after 5 attempts the row is failed.
  update public.rec_embed_queue q
     set last_error = v_err,
         claimed_at = now(),
         failed_at = case when q.attempts >= 5 then now() else q.failed_at end
   where q.subject_kind = p_kind and q.subject_id = p_id;
end $$;

create or replace function public.recs_embed_record(p_rows jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  r       jsonb;
  v_kind  public.rec_subject_kind;
  v_id    uuid;
  v_hash  text;
  v_arr   jsonb;
  v_ok    boolean;
  v_norm  double precision;
  v_vec   extensions.halfvec(384);
  v_n     integer := 0;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'invalid_rows' using errcode = '22023';
  end if;
  for r in select x from jsonb_array_elements(p_rows) x loop
    begin
      v_kind := (r ->> 'kind')::public.rec_subject_kind;
      v_id := (r ->> 'id')::uuid;
    exception when others then
      continue;
    end;
    if v_kind not in ('hub', 'event', 'coach') or v_id is null then
      continue;
    end if;
    v_hash := r ->> 'hash';
    v_arr := r -> 'embedding';
    -- 384 finite numbers, normalized within 1e-3.
    v_ok := jsonb_typeof(v_arr) = 'array' and jsonb_array_length(v_arr) = 384
            and not exists (select 1 from jsonb_array_elements(v_arr) e where jsonb_typeof(e) <> 'number');
    if v_ok then
      select sqrt(sum(((e #>> '{}')::double precision) ^ 2)), bool_and(abs((e #>> '{}')::double precision) <= 1.001)
        into v_norm, v_ok
        from jsonb_array_elements(v_arr) e;
      v_ok := coalesce(v_ok, false) and abs(v_norm - 1) <= 1e-3;
    end if;
    if not v_ok then
      perform public.recs_embed_fail(v_kind, v_id, 'bad_vector');
      continue;
    end if;
    if not private.rec_embeddable(v_kind, v_id) then
      delete from public.rec_embed_queue q where q.subject_kind = v_kind and q.subject_id = v_id;
      continue;
    end if;
    if v_hash is null or v_hash is distinct from private.rec_hash(private.rec_text(v_kind, v_id)) then
      -- A newer edit wins: the row is claimed again with the current text.
      update public.rec_embed_queue q set claimed_at = null
       where q.subject_kind = v_kind and q.subject_id = v_id;
      continue;
    end if;
    v_vec := (select array_agg(((e #>> '{}')::real) order by i) from jsonb_array_elements(v_arr) with ordinality t(e, i))
               ::real[]::extensions.vector(384)::extensions.halfvec(384);
    if v_kind = 'hub' then
      insert into public.hub_embeddings (hub_id, embedding, content_hash, model, embedded_at)
      values (v_id, v_vec, v_hash, 'gte-small', now())
      on conflict (hub_id) do update set embedding = excluded.embedding, content_hash = excluded.content_hash,
                                         model = excluded.model, embedded_at = excluded.embedded_at;
      insert into public.rec_taste (user_id, stale)
      select hm.user_id, true from public.hub_members hm where hm.hub_id = v_id
      on conflict (user_id) do update set stale = true where not public.rec_taste.stale;
    elsif v_kind = 'event' then
      insert into public.event_embeddings (event_id, embedding, content_hash, model, embedded_at)
      values (v_id, v_vec, v_hash, 'gte-small', now())
      on conflict (event_id) do update set embedding = excluded.embedding, content_hash = excluded.content_hash,
                                           model = excluded.model, embedded_at = excluded.embedded_at;
      insert into public.rec_taste (user_id, stale)
      select distinct rv.user_id, true from public.rsvps rv where rv.event_id = v_id and rv.status <> 'cancelled'
      on conflict (user_id) do update set stale = true where not public.rec_taste.stale;
    else
      insert into public.coach_listing_embeddings (listing_id, embedding, content_hash, model, embedded_at)
      values (v_id, v_vec, v_hash, 'gte-small', now())
      on conflict (listing_id) do update set embedding = excluded.embedding, content_hash = excluded.content_hash,
                                             model = excluded.model, embedded_at = excluded.embedded_at;
      insert into public.rec_taste (user_id, stale)
      select distinct b.client_id, true from public.bookings b where b.listing_id = v_id and b.status = 'completed'
      on conflict (user_id) do update set stale = true where not public.rec_taste.stale;
    end if;
    delete from public.rec_embed_queue q where q.subject_kind = v_kind and q.subject_id = v_id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Every eligible subject of a kind (all kinds when null) at priority 9; failed rows retried.
create or replace function public.recs_backfill(p_kind public.rec_subject_kind default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_n integer := 0;
  v_c integer;
begin
  if not coalesce(public.is_privileged(), false) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.rec_embed_queue q
     set failed_at = null, attempts = 0, last_error = null, claimed_at = null, queued_at = now()
   where q.failed_at is not null and (p_kind is null or q.subject_kind = p_kind);
  if p_kind is null or p_kind = 'hub' then
    insert into public.rec_embed_queue (subject_kind, subject_id, priority)
    select 'hub', h.id, 9 from public.hubs h where private.rec_embeddable('hub', h.id)
    on conflict (subject_kind, subject_id) do nothing;
    get diagnostics v_c = row_count; v_n := v_n + v_c;
  end if;
  if p_kind is null or p_kind = 'event' then
    insert into public.rec_embed_queue (subject_kind, subject_id, priority)
    select 'event', e.id, 9 from public.events e
     where e.status = 'published' and e.moderation_state is null
       and e.starts_at >= now() - interval '1 day' and e.starts_at < now() + interval '120 days'
       and private.rec_embeddable('event', e.id)
    on conflict (subject_kind, subject_id) do nothing;
    get diagnostics v_c = row_count; v_n := v_n + v_c;
  end if;
  if p_kind is null or p_kind = 'coach' then
    insert into public.rec_embed_queue (subject_kind, subject_id, priority)
    select 'coach', l.id, 9 from public.coach_listings l where private.rec_embeddable('coach', l.id)
    on conflict (subject_kind, subject_id) do nothing;
    get diagnostics v_c = row_count; v_n := v_n + v_c;
  end if;
  return v_n;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Taste vectors, tick, purge
-- ---------------------------------------------------------------------------
create or replace function private.rec_taste_compute(p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_sum extensions.vector;
  v_n   integer;
  v_emb extensions.halfvec(384);
begin
  if p_user is null or not exists (select 1 from public.profiles p where p.id = p_user) then
    return;
  end if;
  if not private.rec_personalize(p_user) then
    insert into public.rec_taste (user_id, embedding, inputs, stale, computed_at)
    values (p_user, null, 0, false, now())
    on conflict (user_id) do update set embedding = null, inputs = 0, stale = false, computed_at = now();
    return;
  end if;

  with inp as (
    -- Joined hubs: 1.0, no decay.
    select he.embedding as emb, 1.0::double precision as w
      from public.hub_members hm
      join public.hub_embeddings he on he.hub_id = hm.hub_id
      join public.hubs h on h.id = hm.hub_id
      join public.hub_categories c on c.slug = h.category_slug
     where hm.user_id = p_user and not c.is_sensitive and h.moderation_state is null
    union all
    -- RSVPs and check-ins: half-life 90 days from the start.
    select ee.embedding,
           (case when r.checked_in_at is not null then 2.5
                 when r.status in ('going', 'waitlisted') then 1.5
                 else 0.75 end)
           * power(0.5, greatest(0, extract(epoch from (now() - e.starts_at)) / 86400.0) / 90.0)
      from public.rsvps r
      join public.events e on e.id = r.event_id
      join public.event_embeddings ee on ee.event_id = e.id
      join public.hubs h on h.id = e.hub_id
      join public.hub_categories c on c.slug = h.category_slug
     where r.user_id = p_user and r.status <> 'cancelled'
       and e.status = 'published' and e.moderation_state is null and not c.is_sensitive
       and e.starts_at > now() - interval '365 days'
    union all
    -- Completed coaching sessions: 2.0, half-life 90 days.
    select le.embedding,
           2.0 * power(0.5, greatest(0, extract(epoch from (now() - b.starts_at)) / 86400.0) / 90.0)
      from public.bookings b
      join public.coach_listings l on l.id = b.listing_id
      join public.coach_listing_embeddings le on le.listing_id = l.id
     where b.client_id = p_user and b.status = 'completed' and b.starts_at > now() - interval '365 days'
       and l.moderation_state is null and (l.hub_id is null or not private.rec_hub_sensitive(l.hub_id))
    union all
    -- "Not interested": -0.5, half-life 30 days.
    select ee.embedding,
           -0.5 * power(0.5, greatest(0, extract(epoch from (now() - d.created_at)) / 86400.0) / 30.0)
      from public.rec_dismissals d
      join public.event_embeddings ee on ee.event_id = d.subject_id
     where d.user_id = p_user and d.subject_kind = 'event'
    union all
    select he.embedding,
           -0.5 * power(0.5, greatest(0, extract(epoch from (now() - d.created_at)) / 86400.0) / 30.0)
      from public.rec_dismissals d
      join public.hub_embeddings he on he.hub_id = d.subject_id
     where d.user_id = p_user and d.subject_kind = 'hub'
  )
  select extensions.sum(extensions.vector_mul(inp.emb::extensions.vector,
                                              array_fill(inp.w::real, array[384])::extensions.vector)),
         count(*) filter (where inp.w > 0)
    into v_sum, v_n
    from inp;

  if coalesce(v_n, 0) = 0 or v_sum is null or extensions.vector_norm(v_sum) < 1e-6 then
    v_emb := null;
    v_n := 0;
  else
    v_emb := extensions.l2_normalize(v_sum)::extensions.halfvec(384);
  end if;
  insert into public.rec_taste (user_id, embedding, inputs, stale, computed_at)
  values (p_user, v_emb, v_n, false, now())
  on conflict (user_id) do update set embedding = excluded.embedding, inputs = excluded.inputs,
                                      stale = false, computed_at = excluded.computed_at;
end $$;

create or replace function public.recs_taste_refresh(p_limit integer default 300)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid;
  v_n    integer := 0;
begin
  for v_user in
    select t.user_id from public.rec_taste t
     where t.stale
     order by t.computed_at nulls first
     limit greatest(1, least(coalesce(p_limit, 300), 2000))
       for update skip locked
  loop
    perform private.rec_taste_compute(v_user);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Embeddings whose stored hash no longer matches the current text go back on the queue.
create or replace function private.recs_rehash()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_n integer := 0;
  v_c integer;
begin
  insert into public.rec_embed_queue (subject_kind, subject_id, priority)
  select 'hub', x.hub_id, 9 from public.hub_embeddings x
   where x.content_hash is distinct from private.rec_hash(private.rec_text('hub', x.hub_id))
     and private.rec_embeddable('hub', x.hub_id)
  on conflict (subject_kind, subject_id) do nothing;
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  insert into public.rec_embed_queue (subject_kind, subject_id, priority)
  select 'event', x.event_id, 9 from public.event_embeddings x
   where private.rec_embeddable('event', x.event_id)
     and x.content_hash is distinct from private.rec_hash(private.rec_text('event', x.event_id))
  on conflict (subject_kind, subject_id) do nothing;
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  insert into public.rec_embed_queue (subject_kind, subject_id, priority)
  select 'coach', x.listing_id, 9 from public.coach_listing_embeddings x
   where x.content_hash is distinct from private.rec_hash(private.rec_text('coach', x.listing_id))
     and private.rec_embeddable('coach', x.listing_id)
  on conflict (subject_kind, subject_id) do nothing;
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  return v_n;
end $$;

create or replace function public.recs_tick()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_tastes integer;
  v_new    integer := 0;
  v_c      integer;
  v_rehash integer;
begin
  v_tastes := public.recs_taste_refresh(300);
  -- Subjects that became eligible (an event entering its 60 or 120 day horizon) and have
  -- neither an embedding nor a queue row.
  insert into public.rec_embed_queue (subject_kind, subject_id, priority)
  select 'event', e.id, case when e.kind = 'imported' then 5 else 2 end
    from public.events e
   where e.status = 'published' and e.moderation_state is null
     and e.starts_at >= now() - interval '1 day' and e.starts_at < now() + interval '120 days'
     and not exists (select 1 from public.event_embeddings x where x.event_id = e.id)
     and not exists (select 1 from public.rec_embed_queue q where q.subject_kind = 'event' and q.subject_id = e.id)
     and private.rec_embeddable('event', e.id)
   limit 2000
  on conflict (subject_kind, subject_id) do nothing;
  get diagnostics v_c = row_count; v_new := v_new + v_c;
  insert into public.rec_embed_queue (subject_kind, subject_id, priority)
  select 'hub', h.id, 1 from public.hubs h
   where not exists (select 1 from public.hub_embeddings x where x.hub_id = h.id)
     and not exists (select 1 from public.rec_embed_queue q where q.subject_kind = 'hub' and q.subject_id = h.id)
     and private.rec_embeddable('hub', h.id)
  on conflict (subject_kind, subject_id) do nothing;
  get diagnostics v_c = row_count; v_new := v_new + v_c;
  insert into public.rec_embed_queue (subject_kind, subject_id, priority)
  select 'coach', l.id, 3 from public.coach_listings l
   where not exists (select 1 from public.coach_listing_embeddings x where x.listing_id = l.id)
     and not exists (select 1 from public.rec_embed_queue q where q.subject_kind = 'coach' and q.subject_id = l.id)
     and private.rec_embeddable('coach', l.id)
  on conflict (subject_kind, subject_id) do nothing;
  get diagnostics v_c = row_count; v_new := v_new + v_c;
  -- Nightly at 03:00 UTC (the job runs every 5 minutes): changed texts are queued again.
  if extract(hour from now() at time zone 'UTC') = 3 and extract(minute from now() at time zone 'UTC') < 5 then
    v_rehash := private.recs_rehash();
  end if;
  return jsonb_build_object('tastes', v_tastes, 'queued', v_new, 'rehashed', coalesce(v_rehash, 0));
end $$;

create or replace function public.purge_recs()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ev integer; v_hub integer; v_co integer; v_dis integer; v_q integer;
begin
  delete from public.event_embeddings x where not private.rec_keep('event', x.event_id);
  get diagnostics v_ev = row_count;
  delete from public.hub_embeddings x where not private.rec_keep('hub', x.hub_id);
  get diagnostics v_hub = row_count;
  delete from public.coach_listing_embeddings x where not private.rec_keep('coach', x.listing_id);
  get diagnostics v_co = row_count;
  delete from public.rec_dismissals d where d.created_at < now() - interval '180 days';
  get diagnostics v_dis = row_count;
  delete from public.rec_embed_queue q where q.failed_at is not null and q.failed_at < now() - interval '30 days';
  get diagnostics v_q = row_count;
  return jsonb_build_object('events', v_ev, 'hubs', v_hub, 'listings', v_co, 'dismissals', v_dis, 'failed', v_q);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Private scorers (definer; numbers and reason codes for ids the caller passes,
--    each re-checked as readable by the caller; never a vector)
-- ---------------------------------------------------------------------------
-- sim: inner product with the caller's taste (or with the anchor event when given and
-- readable); null when either side has no embedding. reasons: like_hub / like_plan
-- candidates (personal only; never a sensitive hub).
create or replace function private.rec_event_scores(p_ids uuid[], p_anchor uuid default null)
returns table (event_id uuid, sim real, reasons jsonb)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid        uuid := (select auth.uid());
  v_on       boolean := private.recs_on();
  v_q        extensions.halfvec;
  v_personal boolean := false;
  v_hub_fl   double precision := private.rec_meta_num('recs_hub_floor', 0.80);
  v_plan_fl  double precision := private.rec_meta_num('recs_similar_floor', 0.82);
begin
  if uid is null or not public.viewer_is_adult() or p_ids is null then
    return;
  end if;
  if p_anchor is not null then
    if v_on and public.can_read_event(p_anchor) and not private.rec_hub_sensitive((select e.hub_id from public.events e where e.id = p_anchor)) then
      select x.embedding into v_q from public.event_embeddings x where x.event_id = p_anchor;
    end if;
  else
    v_personal := v_on and private.rec_personalize(uid);
    if v_personal then
      select t.embedding into v_q from public.rec_taste t where t.user_id = uid;
    end if;
  end if;

  return query
  with ids as (
    select distinct i as id from unnest(p_ids) i where i is not null
  ), ok as (
    select ids.id, e.hub_id, ee.embedding
      from ids
      join public.events e on e.id = ids.id
      left join public.event_embeddings ee on ee.event_id = ids.id
     where public.can_read_event(ids.id) and not private.rec_hub_sensitive(e.hub_id)
  ), jh as (
    select h.id as hub_id, h.name, he.embedding
      from public.hub_members hm
      join public.hubs h on h.id = hm.hub_id
      join public.hub_categories c on c.slug = h.category_slug
      join public.hub_embeddings he on he.hub_id = h.id
     where v_personal and hm.user_id = uid and h.is_active and h.moderation_state is null and not c.is_sensitive
  ), went as (
    select e.id, e.title, ee.embedding
      from public.rsvps r
      join public.events e on e.id = r.event_id
      join public.hubs h on h.id = e.hub_id
      join public.hub_categories c on c.slug = h.category_slug
      join public.event_embeddings ee on ee.event_id = e.id
     where v_personal and r.user_id = uid
       and (r.checked_in_at is not null or (r.status = 'going' and e.ends_at < now()))
       and e.starts_at > now() - interval '180 days' and e.starts_at < now()
       and e.status = 'published' and e.moderation_state is null and not c.is_sensitive
  )
  select ok.id,
         private.rec_ip(ok.embedding, v_q),
         coalesce((
           select jsonb_agg(x.r order by x.o)
             from (
               select 1 as o, (select jsonb_build_object('code', 'like_hub', 'hub_name', jh.name)
                                 from jh
                                where ok.embedding is not null and jh.hub_id <> ok.hub_id
                                  and private.rec_ip(jh.embedding, ok.embedding) >= v_hub_fl
                                order by private.rec_ip(jh.embedding, ok.embedding) desc, jh.hub_id
                                limit 1) as r
               union all
               select 2, (select jsonb_build_object('code', 'like_plan', 'title', w.title)
                            from went w
                           where ok.embedding is not null and w.id <> ok.id
                             and private.rec_ip(w.embedding, ok.embedding) >= v_plan_fl
                           order by private.rec_ip(w.embedding, ok.embedding) desc, w.id
                           limit 1)
             ) x
            where x.r is not null), '[]'::jsonb)
    from ok;
end $$;

-- Hubs: sim of each readable hub with the caller's taste; like_hub from a joined hub.
create or replace function private.rec_hub_scores(p_ids uuid[])
returns table (hub_id uuid, sim real, reasons jsonb)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid        uuid := (select auth.uid());
  v_personal boolean;
  v_q        extensions.halfvec;
  v_age      integer := coalesce((select public.viewer_age()), 0);
  v_hub_fl   double precision := private.rec_meta_num('recs_hub_floor', 0.80);
begin
  if uid is null or not public.viewer_is_adult() or p_ids is null then
    return;
  end if;
  v_personal := private.recs_on() and private.rec_personalize(uid);
  if v_personal then
    select t.embedding into v_q from public.rec_taste t where t.user_id = uid;
  end if;
  return query
  with ok as (
    select h.id, he.embedding
      from (select distinct i from unnest(p_ids) i) ids
      join public.hubs h on h.id = ids.i
      join public.hub_categories c on c.slug = h.category_slug
      left join public.hub_embeddings he on he.hub_id = h.id
     where h.is_active and h.moderation_state is null and not c.is_sensitive and h.min_age <= v_age
  ), jh as (
    select h.id as hub_id, h.name, he.embedding
      from public.hub_members hm
      join public.hubs h on h.id = hm.hub_id
      join public.hub_categories c on c.slug = h.category_slug
      join public.hub_embeddings he on he.hub_id = h.id
     where v_personal and hm.user_id = uid and h.is_active and h.moderation_state is null and not c.is_sensitive
  )
  select ok.id,
         private.rec_ip(ok.embedding, v_q),
         coalesce((select jsonb_build_array(jsonb_build_object('code', 'like_hub', 'hub_name', jh.name))
                     from jh
                    where ok.embedding is not null and jh.hub_id <> ok.id
                      and private.rec_ip(jh.embedding, ok.embedding) >= v_hub_fl
                    order by private.rec_ip(jh.embedding, ok.embedding) desc, jh.hub_id
                    limit 1), '[]'::jsonb)
    from ok;
end $$;

-- Coaches: the best sim over each visible coach's visible listing embeddings.
create or replace function private.rec_coach_scores(p_ids uuid[])
returns table (coach_id uuid, sim real)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid uuid := (select auth.uid());
  v_q extensions.halfvec;
begin
  if uid is null or not public.viewer_is_adult() or p_ids is null then
    return;
  end if;
  if private.recs_on() and private.rec_personalize(uid) then
    select t.embedding into v_q from public.rec_taste t where t.user_id = uid;
  end if;
  return query
  select ids.i,
         (select max(private.rec_ip(le.embedding, v_q))
            from public.coach_listings l
            join public.coach_listing_embeddings le on le.listing_id = l.id
           where l.coach_id = ids.i and private.coach_listing_visible(l.id))
    from (select distinct i from unnest(p_ids) i) ids
   where ids.i <> uid and private.coach_visible(ids.i);
end $$;

-- People: only ids both of whom may be suggested (section 7); sim between the two tastes.
create or replace function private.rec_people_scores(p_ids uuid[])
returns table (user_id uuid, sim real)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid  uuid := (select auth.uid());
  v_on boolean := private.recs_on();
  v_q  extensions.halfvec;
begin
  if uid is null or not public.viewer_is_adult() or p_ids is null then
    return;
  end if;
  if not coalesce((select rp.people_suggestions from public.rec_prefs rp where rp.user_id = uid), true) then
    return;
  end if;
  if v_on and private.rec_personalize(uid) then
    select t.embedding into v_q from public.rec_taste t where t.user_id = uid;
  end if;
  return query
  select ids.i,
         case when v_q is not null and private.rec_personalize(ids.i)
              then private.rec_ip(v_q, (select t.embedding from public.rec_taste t where t.user_id = ids.i)) end
    from (select distinct i from unnest(p_ids) i where i is not null) ids
   where ids.i <> uid
     and private.chat_user_ok(ids.i)
     and coalesce((select rp.people_suggestions from public.rec_prefs rp where rp.user_id = ids.i), true)
     and not public.users_blocked(uid, ids.i)
     and not exists (select 1 from public.mutes m where m.muter_id = uid and m.muted_id = ids.i)
     and not exists (select 1 from public.rec_dismissals d
                      where d.user_id = uid and d.subject_kind = 'person' and d.subject_id = ids.i)
     and not exists (select 1 from public.conversations cv
                      where cv.kind = 'dm' and cv.dm_key = private.chat_dm_key(uid, ids.i)
                        and cv.last_message_at > now() - interval '30 days');
end $$;

-- ---------------------------------------------------------------------------
-- 7. Shared ranking pieces
-- ---------------------------------------------------------------------------
create or replace function private.rec_band_score(p_band text)
returns double precision language sql immutable parallel safe set search_path = '' as $$
  select case p_band when '<1 mi' then 1.0 when '1-5 mi' then 0.85 when '5-10 mi' then 0.65
                     when '10-25 mi' then 0.4 when '25+ mi' then 0.2 else 0.5 end;
$$;

-- "Tonight", "today", "tomorrow" or "this_weekend" for a start in the viewer's zone, else null.
create or replace function private.rec_when(p_starts timestamptz, p_tz text)
returns text language sql stable set search_path = '' as $$
  with t as (
    select (p_starts at time zone p_tz) as local_start, (now() at time zone p_tz)::date as today
  )
  select case
           when t.local_start::date = t.today and extract(hour from t.local_start) >= 17 then 'tonight'
           when t.local_start::date = t.today then 'today'
           when t.local_start::date = t.today + 1 then 'tomorrow'
           when t.local_start::date > t.today and t.local_start::date <= t.today + 6
                and extract(isodow from t.local_start) in (6, 7) then 'this_weekend'
         end
    from t;
$$;

-- The viewer's zone: p_timezone when it is a known IANA name, else the saved one, else null.
create or replace function private.rec_viewer_tz(p_timezone text)
returns text language sql stable security definer set search_path = '' as $$
  select t.tz
    from (values (1, nullif(btrim(coalesce(p_timezone, '')), '')),
                 (2, (select pp.timezone from public.profile_private pp where pp.user_id = (select auth.uid())))) t(o, tz)
   where t.tz is not null and char_length(t.tz) <= 64 and t.tz like '%/%'
     and exists (select 1 from pg_catalog.pg_timezone_names z where z.name = t.tz)
   order by t.o
   limit 1;
$$;

-- ---------------------------------------------------------------------------
-- 8. recs_for_you (invoker)
-- ---------------------------------------------------------------------------
create or replace function public.recs_for_you(
  p_lat       double precision default null,
  p_lng       double precision default null,
  p_radius_km integer default null,
  p_timezone  text default null,
  p_limit     integer default 10
)
returns table (
  id uuid, kind public.event_kind, hub_id uuid, hub_slug text, hub_name text, hub_emoji text,
  chapter_id uuid, campus_id uuid, host_id uuid, series_id uuid, occurrence_date date, title text,
  description text, cover_url text, starts_at timestamptz, ends_at timestamptz, timezone text,
  min_age smallint, capacity integer, waitlist_enabled boolean, min_headcount integer,
  members_only boolean, is_free boolean, price_text text, status public.event_status,
  visibility public.event_visibility, address_visibility public.address_visibility,
  location_hint text, going_count integer, waitlist_count integer, interested_count integer,
  external_url text, source_name text, created_at timestamptz, updated_at timestamptz,
  distance_band text, section text, is_imported boolean, matched_by text,
  reasons jsonb, rank integer
)
language plpgsql stable set search_path = '' as $$
#variable_conflict use_column
declare
  uid      uuid := (select auth.uid());
  v_limit  integer := greatest(1, least(coalesce(p_limit, 10), 30));
  v_impcap integer;
  v_w      jsonb := private.rec_weights();
  v_ws     double precision; v_wt double precision; v_wd double precision;
  v_wh     double precision; v_wm double precision; v_wi double precision;
  v_tz     text := private.rec_viewer_tz(p_timezone);
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.viewer_is_adult() then
    return;
  end if;
  v_impcap := greatest(3, ceil(v_limit * 0.3)::integer);
  v_ws := coalesce((v_w ->> 'sim')::double precision, 0.5);
  v_wt := coalesce((v_w ->> 'time')::double precision, 0.25);
  v_wd := coalesce((v_w ->> 'dist')::double precision, 0.25);
  v_wh := coalesce((v_w ->> 'hub')::double precision, 0.10);
  v_wm := coalesce((v_w ->> 'met')::double precision, 0.05);
  v_wi := coalesce((v_w ->> 'imported')::double precision, -0.05);

  return query
  with recursive f as (
    select * from public.feed_events_v2(now(), now() + interval '14 days', p_lat, p_lng, p_radius_km,
                                        null, false, 200, p_timezone, 'plan')
  ), c as (
    -- Exclusions: own, RSVP'd, dismissed, blocked host, a blocked person going, sensitive
    -- hubs, full without a waitlist. (Shows are another listing kind; cancelled rows are
    -- not in the feed.)
    select f.*
      from f
      join public.hubs h on h.id = f.hub_id
      join public.hub_categories hc on hc.slug = h.category_slug
     where f.host_id is distinct from uid
       and not hc.is_sensitive
       and not exists (select 1 from public.rsvps r where r.event_id = f.id and r.user_id = uid and r.status <> 'cancelled')
       and not exists (select 1 from public.rec_dismissals d
                        where d.user_id = uid and d.subject_kind = 'event' and d.subject_id = f.id)
       and not private.is_blocked_with(f.host_id)
       and public.event_block_warning(f.id) = 0
       and not (f.capacity is not null and f.going_count >= f.capacity and not f.waitlist_enabled)
  ), sc as (
    select s.event_id, s.sim, s.reasons from private.rec_event_scores(array(select c.id from c)) s
  ), met as (
    select m.user_id from public.people_you_met(null, 100) m
  ), mg as (
    select r.event_id, count(*)::integer as n
      from public.rsvps r
     where r.event_id in (select c.id from c) and r.status = 'going' and r.user_id <> uid
       and r.user_id in (select met.user_id from met)
     group by r.event_id
  ), my_hubs as (
    select hm.hub_id from public.hub_members hm where hm.user_id = uid
  ), j as (
    select c.*, sc.sim, coalesce(sc.reasons, '[]'::jsonb) as sreasons, coalesce(mg.n, 0) as met_n,
           (c.hub_id in (select my_hubs.hub_id from my_hubs)) as in_hub
      from c
      join sc on sc.event_id = c.id
      left join mg on mg.event_id = c.id
  ), r1 as (
    select j.*,
           count(j.sim) over () as n_sim,
           percent_rank() over (partition by (j.sim is null) order by j.sim) as pr
      from j
  ), scored as (
    select r1.*,
           (case when r1.n_sim > 0
                 then v_ws * (case when r1.sim is null or r1.n_sim <= 1 then 0.5 else r1.pr end)
                      + v_wt * exp(-greatest(0, extract(epoch from (r1.starts_at - now())) / 86400.0) / 5.0)
                      + v_wd * private.rec_band_score(r1.distance_band)
                 else (v_wt * exp(-greatest(0, extract(epoch from (r1.starts_at - now())) / 86400.0) / 5.0)
                       + v_wd * private.rec_band_score(r1.distance_band))
                      * (v_ws + v_wt + v_wd) / nullif(v_wt + v_wd, 0)
            end)
           + case when r1.in_hub then v_wh else 0 end
           + v_wm * least(3, r1.met_n)
           + case when r1.is_imported then v_wi else 0 end as score
      from r1
  ), ordered as (
    select scored.*,
           row_number() over (order by scored.score desc, scored.is_imported, scored.starts_at, scored.id) as rn
      from scored
  ), walk as (
    -- Greedy diversity: at most 2 per hub, 1 per series, v_impcap imported.
    select 0::bigint as rn, '{}'::jsonb as hubs, '{}'::uuid[] as series, 0 as imp, 0 as kept,
           false as ok, null::uuid as id
    union all
    select o.rn,
           case when d.ok then w.hubs || jsonb_build_object(o.hub_id::text, coalesce((w.hubs ->> o.hub_id::text)::integer, 0) + 1)
                else w.hubs end,
           case when d.ok and o.series_id is not null then w.series || o.series_id else w.series end,
           w.imp + case when d.ok and o.is_imported then 1 else 0 end,
           w.kept + case when d.ok then 1 else 0 end,
           d.ok, o.id
      from walk w
      join ordered o on o.rn = w.rn + 1
      cross join lateral (
        select (coalesce((w.hubs ->> o.hub_id::text)::integer, 0) < 2
                and (o.series_id is null or not (o.series_id = any (w.series)))
                and (not o.is_imported or w.imp < v_impcap)) as ok) d
     where w.kept < v_limit
  ), kept as (
    select o.*, row_number() over (order by w.rn)::integer as k_rank
      from walk w join ordered o on o.id = w.id
     where w.ok
  ), chips as (
    select k.id as cid,
           (select coalesce(jsonb_agg(x.r order by x.o), '[]'::jsonb)
              from (select v.o, v.r
                      from (values
                        (1, case when k.met_n >= 1 then jsonb_build_object('code', 'people_met_going', 'n', k.met_n) end),
                        (2, (select e from jsonb_array_elements(k.sreasons) e where e ->> 'code' = 'like_hub' limit 1)),
                        (3, (select e from jsonb_array_elements(k.sreasons) e where e ->> 'code' = 'like_plan' limit 1)),
                        (4, case when k.in_hub then jsonb_build_object('code', 'in_your_hub', 'hub_name', k.hub_name) end),
                        (5, (select jsonb_build_object('code', 'when', 'when', w2)
                               from private.rec_when(k.starts_at, coalesce(v_tz, k.timezone)) w2 where w2 is not null)),
                        (6, case when k.distance_band is not null and k.distance_band <> 'approximate'
                                 then jsonb_build_object('code', 'near', 'band', k.distance_band) end),
                        (7, case when k.is_free then jsonb_build_object('code', 'free') end),
                        (8, case when k.going_count >= 5
                                      or (k.capacity is not null and k.capacity - k.going_count between 0 and 3)
                                 then jsonb_build_object('code', 'popular') end)
                      ) v(o, r)
                     where v.r is not null
                     order by v.o
                     limit 2) x) as base
      from kept k
  )
  select k.id, k.kind, k.hub_id, k.hub_slug, k.hub_name, k.hub_emoji, k.chapter_id, k.campus_id, k.host_id,
         k.series_id, k.occurrence_date, k.title, k.description, k.cover_url, k.starts_at, k.ends_at,
         k.timezone, k.min_age, k.capacity, k.waitlist_enabled, k.min_headcount, k.members_only,
         k.is_free, k.price_text, k.status, k.visibility, k.address_visibility, k.location_hint,
         k.going_count, k.waitlist_count, k.interested_count, k.external_url, k.source_name,
         k.created_at, k.updated_at, k.distance_band, k.section, k.is_imported, k.matched_by,
         (case when jsonb_array_length(ch.base) = 0 then jsonb_build_array(jsonb_build_object('code', 'coming_up'))
               else ch.base end)
         || case when k.is_imported and k.source_name is not null
                 then jsonb_build_array(jsonb_build_object('code', 'from_source', 'source_name', k.source_name))
                 else '[]'::jsonb end,
         k.k_rank
    from kept k
    join chips ch on ch.cid = k.id
   where (select count(*) from kept) >= 3
   order by k.k_rank;
end $$;

-- ---------------------------------------------------------------------------
-- 9. recs_similar_events (invoker; not personal)
-- ---------------------------------------------------------------------------
create or replace function public.recs_similar_events(
  p_event_id  uuid,
  p_lat       double precision default null,
  p_lng       double precision default null,
  p_radius_km integer default null,
  p_timezone  text default null,
  p_limit     integer default 6
)
returns table (
  id uuid, kind public.event_kind, hub_id uuid, hub_slug text, hub_name text, hub_emoji text,
  chapter_id uuid, campus_id uuid, host_id uuid, series_id uuid, occurrence_date date, title text,
  description text, cover_url text, starts_at timestamptz, ends_at timestamptz, timezone text,
  min_age smallint, capacity integer, waitlist_enabled boolean, min_headcount integer,
  members_only boolean, is_free boolean, price_text text, status public.event_status,
  visibility public.event_visibility, address_visibility public.address_visibility,
  location_hint text, going_count integer, waitlist_count integer, interested_count integer,
  external_url text, source_name text, created_at timestamptz, updated_at timestamptz,
  distance_band text, section text, is_imported boolean, matched_by text,
  reasons jsonb, rank integer
)
language plpgsql stable set search_path = '' as $$
#variable_conflict use_column
declare
  uid       uuid := (select auth.uid());
  v_limit   integer := greatest(1, least(coalesce(p_limit, 6), 20));
  v_impcap  integer;
  v_floor   double precision := private.rec_meta_num('recs_similar_floor', 0.82);
  v_tz      text := private.rec_viewer_tz(p_timezone);
  v_hub     uuid;
  v_series  uuid;
  v_has_emb boolean;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.viewer_is_adult() then
    return;
  end if;
  if p_event_id is null or not public.can_read_event(p_event_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  select e.hub_id, e.series_id into v_hub, v_series from public.events e where e.id = p_event_id;
  if v_hub is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  v_impcap := greatest(2, ceil(v_limit * 0.3)::integer);
  -- Does the anchor have an embedding the scorer will use? (One probe: the anchor scored against itself.)
  select (s.sim is not null) into v_has_emb from private.rec_event_scores(array[p_event_id], p_event_id) s;
  v_has_emb := coalesce(v_has_emb, false);

  return query
  with recursive f as (
    select * from public.feed_events_v2(now(), now() + interval '30 days', p_lat, p_lng, p_radius_km,
                                        null, false, 200, p_timezone, 'plan')
  ), c as (
    select f.*
      from f
      join public.hubs h on h.id = f.hub_id
      join public.hub_categories hc on hc.slug = h.category_slug
     where f.id <> p_event_id
       and (v_series is null or f.series_id is distinct from v_series)
       and f.host_id is distinct from uid
       and not hc.is_sensitive
       and not exists (select 1 from public.rsvps r where r.event_id = f.id and r.user_id = uid and r.status <> 'cancelled')
       and not exists (select 1 from public.rec_dismissals d
                        where d.user_id = uid and d.subject_kind = 'event' and d.subject_id = f.id)
       and not private.is_blocked_with(f.host_id)
       and public.event_block_warning(f.id) = 0
       and not (f.capacity is not null and f.going_count >= f.capacity and not f.waitlist_enabled)
  ), sc as (
    select s.event_id, s.sim from private.rec_event_scores(array(select c.id from c), p_event_id) s
  ), j as (
    select c.*, sc.sim
      from c join sc on sc.event_id = c.id
     where (v_has_emb and sc.sim >= v_floor) or (not v_has_emb and c.hub_id = v_hub)
  ), r1 as (
    select j.*, count(j.sim) over () as n_sim,
           percent_rank() over (partition by (j.sim is null) order by j.sim) as pr
      from j
  ), scored as (
    select r1.*,
           (case when r1.n_sim > 0
                 then 0.6 * (case when r1.sim is null or r1.n_sim <= 1 then 0.5 else r1.pr end)
                      + 0.2 * exp(-greatest(0, extract(epoch from (r1.starts_at - now())) / 86400.0) / 5.0)
                      + 0.2 * private.rec_band_score(r1.distance_band)
                 else 0.5 * exp(-greatest(0, extract(epoch from (r1.starts_at - now())) / 86400.0) / 5.0)
                      + 0.5 * private.rec_band_score(r1.distance_band)
            end) as score
      from r1
  ), ordered as (
    select scored.*,
           row_number() over (order by scored.score desc, scored.is_imported, scored.starts_at, scored.id) as rn
      from scored
  ), walk as (
    select 0::bigint as rn, '{}'::jsonb as hubs, '{}'::uuid[] as series, 0 as imp, 0 as kept,
           false as ok, null::uuid as id
    union all
    select o.rn,
           case when d.ok then w.hubs || jsonb_build_object(o.hub_id::text, coalesce((w.hubs ->> o.hub_id::text)::integer, 0) + 1)
                else w.hubs end,
           case when d.ok and o.series_id is not null then w.series || o.series_id else w.series end,
           w.imp + case when d.ok and o.is_imported then 1 else 0 end,
           w.kept + case when d.ok then 1 else 0 end,
           d.ok, o.id
      from walk w
      join ordered o on o.rn = w.rn + 1
      cross join lateral (
        select (coalesce((w.hubs ->> o.hub_id::text)::integer, 0) < (case when o.hub_id = v_hub then v_limit else 2 end)
                and (o.series_id is null or not (o.series_id = any (w.series)))
                and (not o.is_imported or w.imp < v_impcap)) as ok) d
     where w.kept < v_limit
  ), kept as (
    select o.*, row_number() over (order by w.rn)::integer as k_rank
      from walk w join ordered o on o.id = w.id
     where w.ok
  ), chips as (
    select k.id as cid,
           (select coalesce(jsonb_agg(x.r order by x.o), '[]'::jsonb)
              from (select v.o, v.r
                      from (values
                        (1, case when k.hub_id = v_hub then jsonb_build_object('code', 'same_hub', 'hub_name', k.hub_name) end),
                        (2, (select jsonb_build_object('code', 'when', 'when', w2)
                               from private.rec_when(k.starts_at, coalesce(v_tz, k.timezone)) w2 where w2 is not null)),
                        (3, case when k.distance_band is not null and k.distance_band <> 'approximate'
                                 then jsonb_build_object('code', 'near', 'band', k.distance_band) end),
                        (4, case when k.is_free then jsonb_build_object('code', 'free') end),
                        (5, case when k.going_count >= 5
                                      or (k.capacity is not null and k.capacity - k.going_count between 0 and 3)
                                 then jsonb_build_object('code', 'popular') end)
                      ) v(o, r)
                     where v.r is not null
                     order by v.o
                     limit 2) x) as base
      from kept k
  )
  select k.id, k.kind, k.hub_id, k.hub_slug, k.hub_name, k.hub_emoji, k.chapter_id, k.campus_id, k.host_id,
         k.series_id, k.occurrence_date, k.title, k.description, k.cover_url, k.starts_at, k.ends_at,
         k.timezone, k.min_age, k.capacity, k.waitlist_enabled, k.min_headcount, k.members_only,
         k.is_free, k.price_text, k.status, k.visibility, k.address_visibility, k.location_hint,
         k.going_count, k.waitlist_count, k.interested_count, k.external_url, k.source_name,
         k.created_at, k.updated_at, k.distance_band, k.section, k.is_imported, k.matched_by,
         (case when jsonb_array_length(ch.base) = 0 then jsonb_build_array(jsonb_build_object('code', 'coming_up'))
               else ch.base end)
         || case when k.is_imported and k.source_name is not null
                 then jsonb_build_array(jsonb_build_object('code', 'from_source', 'source_name', k.source_name))
                 else '[]'::jsonb end,
         k.k_rank
    from kept k
    join chips ch on ch.cid = k.id
   order by k.k_rank;
end $$;

-- ---------------------------------------------------------------------------
-- 10. recs_hubs (invoker)
-- ---------------------------------------------------------------------------
create or replace function public.recs_hubs(
  p_lat       double precision default null,
  p_lng       double precision default null,
  p_radius_km integer default null,
  p_limit     integer default 8
)
returns table (id uuid, slug text, name text, emoji text, category_slug text, member_count integer,
               nearby_plans integer, reasons jsonb, rank integer)
language plpgsql stable set search_path = '' as $$
#variable_conflict use_column
declare
  uid     uuid := (select auth.uid());
  v_limit integer := greatest(1, least(coalesce(p_limit, 8), 30));
  v_age   integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.viewer_is_adult() then
    return;
  end if;
  v_age := coalesce((select public.viewer_age()), 0);
  return query
  with cand as (
    select h.id, h.slug, h.name, h.emoji, h.category_slug
      from public.hubs h
      join public.hub_categories c on c.slug = h.category_slug
     where h.is_active and h.moderation_state is null and not c.is_sensitive and h.scope = 'general'
       and h.min_age <= v_age
       and not exists (select 1 from public.hub_members hm where hm.hub_id = h.id and hm.user_id = uid)
       and not exists (select 1 from public.rec_dismissals d
                        where d.user_id = uid and d.subject_kind = 'hub' and d.subject_id = h.id)
  ), near as (
    select f.hub_id, count(*)::integer as n
      from public.feed_events_v2(now(), now() + interval '30 days', p_lat, p_lng, p_radius_km,
                                 null, false, 200, null, 'plan') f
     group by f.hub_id
  ), sc as (
    select s.hub_id, s.sim, s.reasons from private.rec_hub_scores(array(select cand.id from cand)) s
  ), j as (
    select cand.*, sc.sim, sc.reasons as sreasons, coalesce(near.n, 0) as n_near,
           coalesce((select max(hs.member_count) from public.hub_stats hs where hs.hub_id = cand.id and hs.campus_id is null), 0) as members
      from cand
      join sc on sc.hub_id = cand.id
      left join near on near.hub_id = cand.id
  ), r1 as (
    select j.*, count(j.sim) over () as n_sim,
           percent_rank() over (partition by (j.sim is null) order by j.sim) as pr,
           max(j.n_near) over () as max_near, max(j.members) over () as max_members
      from j
  ), scored as (
    select r1.*,
           (case when r1.max_near > 0 then ln(1 + r1.n_near) / ln(1 + r1.max_near) else 0 end) as s_local,
           (case when r1.max_members > 0 then ln(1 + r1.members) / ln(1 + r1.max_members) else 0 end) as s_size
      from r1
  ), ranked as (
    select scored.*,
           (case when scored.n_sim > 0
                 then 0.6 * (case when scored.sim is null or scored.n_sim <= 1 then 0.5 else scored.pr end)
                      + 0.3 * scored.s_local + 0.1 * scored.s_size
                 else 0.75 * scored.s_local + 0.25 * scored.s_size end) as score
      from scored
  )
  select ranked.id, ranked.slug, ranked.name, ranked.emoji, ranked.category_slug, ranked.members, ranked.n_near,
         (select coalesce(jsonb_agg(x.r order by x.o), '[]'::jsonb)
            from (select 1 as o, e as r from jsonb_array_elements(ranked.sreasons) e
                  union all
                  select 2, jsonb_build_object('code', 'nearby_plans', 'n', ranked.n_near) where ranked.n_near >= 1) x),
         (row_number() over (order by ranked.score desc, ranked.n_near desc, ranked.members desc, ranked.id))::integer
    from ranked
   order by ranked.score desc, ranked.n_near desc, ranked.members desc, ranked.id
   limit v_limit;
end $$;

-- ---------------------------------------------------------------------------
-- 11. recs_coaches (invoker)
-- ---------------------------------------------------------------------------
create or replace function public.recs_coaches(
  p_lat       double precision default null,
  p_lng       double precision default null,
  p_radius_km integer default null,
  p_limit     integer default 6
)
returns table (user_id uuid, handle text, first_name text, avatar_url text, headline text, area_label text,
               distance_band text, in_person boolean, online boolean, rating_avg numeric, rating_count integer,
               completed_count integer, from_price_minor integer, from_currency text, hub_ids uuid[],
               reasons jsonb, rank integer)
language plpgsql stable set search_path = '' as $$
#variable_conflict use_column
declare
  uid     uuid := (select auth.uid());
  v_limit integer := greatest(1, least(coalesce(p_limit, 6), 20));
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.viewer_is_adult() then
    return;
  end if;
  return query
  with s as (
    select * from public.search_coaches(p_lat, p_lng, p_radius_km, null, null, null, null, null, null, 50) x
     where x.user_id <> uid
       and not exists (select 1 from public.rec_dismissals d
                        where d.user_id = uid and d.subject_kind = 'coach' and d.subject_id = x.user_id)
  ), sc as (
    select z.coach_id, z.sim from private.rec_coach_scores(array(select s.user_id from s)) z
  ), my_hubs as (
    select h.id, h.name
      from public.hub_members hm
      join public.hubs h on h.id = hm.hub_id
      join public.hub_categories c on c.slug = h.category_slug
     where hm.user_id = uid and not c.is_sensitive
  ), j as (
    select s.*, sc.sim,
           (select mh.name from my_hubs mh where mh.id = any (s.hub_ids) order by mh.name limit 1) as my_hub_name
      from s join sc on sc.coach_id = s.user_id
  ), r1 as (
    select j.*, count(j.sim) over () as n_sim,
           percent_rank() over (partition by (j.sim is null) order by j.sim) as pr
      from j
  ), ranked as (
    select r1.*,
           (case when r1.n_sim > 0 then 0.55 * (case when r1.sim is null or r1.n_sim <= 1 then 0.5 else r1.pr end) else 0 end)
           + (case when r1.n_sim > 0 then 1.0 else 1.0 / 0.45 end)
             * (0.25 * private.rec_band_score(r1.distance_band)
                + 0.1 * (case when r1.my_hub_name is not null then 1 else 0 end)
                + 0.1 * (case when r1.rating_count >= 3 then coalesce(r1.rating_avg, 0) / 5.0 else 0 end)) as score
      from r1
  )
  select ranked.user_id, ranked.handle, ranked.first_name, ranked.avatar_url, ranked.headline, ranked.area_label,
         ranked.distance_band, ranked.in_person, ranked.online, ranked.rating_avg, ranked.rating_count,
         ranked.completed_count, ranked.from_price_minor, ranked.from_currency, ranked.hub_ids,
         (select coalesce(jsonb_agg(x.r order by x.o), '[]'::jsonb)
            from (select v.o, v.r
                    from (values
                      (1, case when ranked.my_hub_name is not null
                               then jsonb_build_object('code', 'teaches_your_hub', 'hub_name', ranked.my_hub_name) end),
                      (2, case when ranked.rating_count >= 3 and ranked.rating_avg is not null
                               then jsonb_build_object('code', 'rated', 'avg', round(ranked.rating_avg, 1), 'n', ranked.rating_count) end),
                      (3, case when ranked.distance_band = 'online' then jsonb_build_object('code', 'online')
                               when ranked.distance_band is not null then jsonb_build_object('code', 'near', 'band', ranked.distance_band) end)
                    ) v(o, r)
                   where v.r is not null
                   order by v.o
                   limit 2) x),
         (row_number() over (order by ranked.score desc, ranked.user_id))::integer
    from ranked
   order by ranked.score desc, ranked.user_id
   limit v_limit;
end $$;

-- ---------------------------------------------------------------------------
-- 12. recs_people (invoker; shared context only, section 7)
-- ---------------------------------------------------------------------------
create or replace function public.recs_people(p_limit integer default 8)
returns table (user_id uuid, handle text, first_name text, avatar_url text, reasons jsonb, rank integer)
language plpgsql stable set search_path = '' as $$
#variable_conflict use_column
declare
  uid     uuid := (select auth.uid());
  v_limit integer := greatest(1, least(coalesce(p_limit, 8), 30));
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.viewer_is_adult() then
    return;
  end if;
  if not coalesce((select rp.people_suggestions from public.rec_prefs rp where rp.user_id = uid), true) then
    return;
  end if;
  return query
  with ctx as (
    -- 1. Met (mutual picks or both checked in); the shared plan is never in a sensitive hub.
    select m.user_id as other, 'went_to_same'::text as code, 3 as strength,
           jsonb_build_object('code', 'went_to_same', 'title', m.last_plan ->> 'title') as r,
           (m.last_plan ->> 'starts_at')::timestamptz as at
      from public.people_you_met(null, 100) m
      join public.events e on e.id = (m.last_plan ->> 'id')::uuid
      join public.hubs h on h.id = e.hub_id
      join public.hub_categories c on c.slug = h.category_slug
     where not c.is_sensitive
    union all
    -- 2. The same chapter (read through chapter_members; sensitive chapters never count).
    select b.user_id, 'same_chapter', 1,
           jsonb_build_object('code', 'same_chapter', 'chapter_name', ch.name), null::timestamptz
      from public.chapter_members a
      join public.chapter_members b on b.chapter_id = a.chapter_id and b.user_id <> uid
      join public.hub_chapters ch on ch.id = a.chapter_id
      join public.hubs h on h.id = ch.hub_id
      join public.hub_categories c on c.slug = h.category_slug
     where a.user_id = uid and ch.is_active and ch.moderation_state is null and not c.is_sensitive
    union all
    -- 3. Going to the same upcoming plan (read through rsvps_select).
    select r2.user_id, 'going_to_same', 2,
           jsonb_build_object('code', 'going_to_same', 'title', e.title), e.starts_at
      from public.rsvps r1
      join public.events e on e.id = r1.event_id
      join public.rsvps r2 on r2.event_id = e.id and r2.user_id <> uid and r2.status = 'going'
      join public.hubs h on h.id = e.hub_id
      join public.hub_categories c on c.slug = h.category_slug
     where r1.user_id = uid and r1.status = 'going' and e.status = 'published' and e.starts_at > now()
       and e.moderation_state is null and not c.is_sensitive
  ), per as (
    select ctx.other,
           sum(distinct ctx.strength) as strength,
           max(ctx.at) as latest,
           (select coalesce(jsonb_agg(y.r order by y.o), '[]'::jsonb)
              from (select distinct on (x.code) x.code, x.r,
                           case x.code when 'went_to_same' then 1 when 'same_chapter' then 2 else 3 end as o
                      from ctx x
                     where x.other = ctx.other
                     order by x.code, x.at desc nulls last) y) as all_reasons
      from ctx
     where ctx.other is not null and ctx.other <> uid
     group by ctx.other
  ), sc as (
    select z.user_id, z.sim from private.rec_people_scores(array(select per.other from per)) z
  ), j as (
    select per.*, sc.sim,
           count(sc.sim) over () as n_sim,
           percent_rank() over (partition by (sc.sim is null) order by sc.sim) as pr
      from per join sc on sc.user_id = per.other
  ), ranked as (
    select j.*, (case when j.sim is null or j.n_sim <= 1 then 0.5 else j.pr end) as s_sim from j
  )
  select p.id, p.handle, p.first_name, p.avatar_url,
         (select coalesce(jsonb_agg(e order by o), '[]'::jsonb)
            from jsonb_array_elements(ranked.all_reasons) with ordinality t(e, o) where o <= 2),
         (row_number() over (order by ranked.strength desc, ranked.s_sim desc, ranked.latest desc nulls last, ranked.other))::integer
    from ranked
    join public.profiles p on p.id = ranked.other
   where p.status = 'active' and p.deleted_at is null
   order by ranked.strength desc, ranked.s_sim desc, ranked.latest desc nulls last, ranked.other
   limit v_limit;
end $$;

-- ---------------------------------------------------------------------------
-- 13. Dismissals and preferences (definer, own rows only)
-- ---------------------------------------------------------------------------
create or replace function public.rec_dismiss(p_kind public.rec_subject_kind, p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_kind is null or p_id is null or (p_kind = 'person' and p_id = uid) then
    raise exception 'invalid_subject' using errcode = '22023';
  end if;
  if (select count(*) from public.rec_dismissals d
       where d.user_id = uid and d.created_at > now() - interval '1 hour') >= 60 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  insert into public.rec_dismissals (user_id, subject_kind, subject_id)
  values (uid, p_kind, p_id)
  on conflict (user_id, subject_kind, subject_id) do nothing;
  -- At most 500 a member: the oldest go.
  delete from public.rec_dismissals d
   where d.user_id = uid
     and (d.subject_kind, d.subject_id) in (
       select x.subject_kind, x.subject_id from public.rec_dismissals x
        where x.user_id = uid
        order by x.created_at desc, x.subject_kind, x.subject_id
       offset 500);
end $$;

create or replace function public.rec_undismiss(p_kind public.rec_subject_kind, p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  delete from public.rec_dismissals d where d.user_id = uid and d.subject_kind = p_kind and d.subject_id = p_id;
  if found then
    perform private.rec_mark_stale(uid);
  end if;
end $$;

create or replace function public.my_recommendation_prefs()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  r   public.rec_prefs%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into r from public.rec_prefs rp where rp.user_id = uid;
  return jsonb_build_object('personalize', coalesce(r.personalize, true),
                            'people_suggestions', coalesce(r.people_suggestions, true));
end $$;

create or replace function public.set_recommendation_prefs(p_personalize boolean default null,
                                                           p_people_suggestions boolean default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_was  boolean;
  v_now  boolean;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p where p.id = uid and p.deleted_at is null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_was := private.rec_personalize(uid);
  insert into public.rec_prefs (user_id, personalize, people_suggestions, updated_at)
  values (uid, coalesce(p_personalize, true), coalesce(p_people_suggestions, true), now())
  on conflict (user_id) do update
     set personalize = coalesce(p_personalize, public.rec_prefs.personalize),
         people_suggestions = coalesce(p_people_suggestions, public.rec_prefs.people_suggestions),
         updated_at = now();
  v_now := private.rec_personalize(uid);
  if not v_now then
    -- Off: the taste vector goes at once and is never recomputed.
    insert into public.rec_taste (user_id, embedding, inputs, stale, computed_at)
    values (uid, null, 0, false, now())
    on conflict (user_id) do update set embedding = null, inputs = 0, stale = false, computed_at = now();
  elsif not v_was then
    perform private.rec_mark_stale(uid);
  end if;
  return public.my_recommendation_prefs();
end $$;

-- ---------------------------------------------------------------------------
-- 14. public_week_near (landing page; anon allowed)
-- ---------------------------------------------------------------------------
create or replace function public.public_week_near(p_lat double precision default null,
                                                   p_lng double precision default null,
                                                   p_limit integer default 12)
returns table (id uuid, title text, hub jsonb, starts_at timestamptz, timezone text, is_free boolean,
               price_text text, going_bucket text, distance_band text, is_imported boolean, source_name text)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_limit  integer := greatest(1, least(coalesce(p_limit, 12), 24));
  v_origin extensions.geography;
begin
  if p_lat is not null and p_lng is not null
     and p_lat between -90 and 90 and p_lng between -180 and 180 then
    -- About 11 km: the point is never finer than 0.1 degree.
    v_origin := extensions.ST_SetSRID(extensions.ST_MakePoint(
                  round(p_lng::numeric, 1)::double precision,
                  round(p_lat::numeric, 1)::double precision), 4326)::extensions.geography;
  else
    v_origin := (select a.center from public.areas a where a.slug = 'atlanta');
  end if;
  if v_origin is null then
    return;
  end if;
  return query
  select e.id, e.title,
         jsonb_build_object('name', h.name, 'emoji', h.emoji, 'slug', h.slug),
         e.starts_at, e.timezone, e.is_free, e.price_text,
         case when e.going_count >= 10 then '10+' when e.going_count >= 3 then '3+' end,
         case when e.address_visibility = 'approved_only' then 'approximate'
              when x.d < 1609.344 then '<1 mi'
              when x.d < 8046.72 then '1-5 mi'
              when x.d < 16093.44 then '5-10 mi'
              when x.d < 40233.6 then '10-25 mi'
              else '25+ mi' end,
         (e.kind = 'imported'),
         e.source_name
    from public.events e
    join public.hubs h on h.id = e.hub_id
    join public.hub_categories c on c.slug = h.category_slug
    left join public.profiles hp on hp.id = e.host_id
    cross join lateral (select extensions.ST_Distance(e.approx_point, v_origin) as d) x
   where e.status = 'published'
     and e.starts_at >= now() and e.starts_at < now() + interval '7 days'
     and e.visibility = 'public' and e.min_age = 18 and e.moderation_state is null
     and not e.members_only and e.listing_kind = 'plan'
     and h.is_active and h.moderation_state is null and not c.is_sensitive
     and (e.host_id is null or (hp.status = 'active' and hp.deleted_at is null and hp.moderation_state is null))
     and e.approx_point is not null
     and extensions.ST_DWithin(e.approx_point, v_origin, 40000)
   order by (e.kind = 'imported'), e.starts_at, e.id
   limit v_limit;
end $$;

-- ---------------------------------------------------------------------------
-- 15. recs_status (moderators; counts only)
-- ---------------------------------------------------------------------------
create or replace function public.recs_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not coalesce(public.is_moderator(), false) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return private.recs_counts();
end $$;

create or replace function private.recs_counts()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'on', private.recs_on(),
    'queue', (select coalesce(jsonb_object_agg(k.kind, jsonb_build_object(
                 'due', (select count(*) from public.rec_embed_queue q where q.subject_kind::text = k.kind and q.failed_at is null
                           and (q.claimed_at is null or q.claimed_at < now() - interval '5 minutes')),
                 'claimed', (select count(*) from public.rec_embed_queue q where q.subject_kind::text = k.kind and q.failed_at is null
                               and q.claimed_at >= now() - interval '5 minutes'),
                 'failed', (select count(*) from public.rec_embed_queue q where q.subject_kind::text = k.kind and q.failed_at is not null))),
                 '{}'::jsonb)
                from unnest(array['hub', 'event', 'coach']) k(kind)),
    'embeddings', jsonb_build_object(
       'hub', (select count(*) from public.hub_embeddings),
       'event', (select count(*) from public.event_embeddings),
       'coach', (select count(*) from public.coach_listing_embeddings)),
    'embedded_today', private.rec_embedded_today(),
    'tastes_with_vector', (select count(*) from public.rec_taste t where t.embedding is not null),
    'tastes_stale', (select count(*) from public.rec_taste t where t.stale),
    'last_embedded_at', (select max(x.embedded_at) from (
                        select max(embedded_at) as embedded_at from public.hub_embeddings
                        union all select max(embedded_at) from public.event_embeddings
                        union all select max(embedded_at) from public.coach_listing_embeddings) x));
$$;

-- ---------------------------------------------------------------------------
-- 16. Weekly scorecard (counts only)
-- ---------------------------------------------------------------------------
-- The Monday of the last full week in America/New_York.
create or replace function private.scorecard_last_week()
returns date language sql stable set search_path = '' as $$
  select ((now() at time zone 'America/New_York')::date
          - (extract(isodow from (now() at time zone 'America/New_York')::date)::integer - 1)) - 7;
$$;

create or replace function public.scorecard_week(p_week_start date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz     text := 'America/New_York';
  v_start  date := coalesce(p_week_start, private.scorecard_last_week());
  v_from   timestamptz;
  v_to     timestamptz;
  v_health jsonb;
  v_gate   jsonb;
begin
  if not coalesce(public.is_privileged(), false) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if extract(isodow from v_start) <> 1 then
    raise exception 'invalid_week' using errcode = '22023', hint = 'A Monday.';
  end if;
  v_from := v_start::timestamp at time zone v_tz;
  v_to := (v_start + 7)::timestamp at time zone v_tz;
  v_health := public.collector_health_snapshot();

  select jsonb_object_agg(g.k, jsonb_build_object(
           'recurring', (select count(*) from public.events e
                          where e.kind <> 'imported' and e.status = 'published' and e.series_id is not null
                            and e.moderation_state is null
                            and e.starts_at >= (g.d::timestamp at time zone v_tz)
                            and e.starts_at < ((g.d + 7)::timestamp at time zone v_tz)),
           'target', 10))
    into v_gate
    from (values ('week_2027_01_11', date '2027-01-11'), ('week_2027_01_18', date '2027-01-18')) g(k, d);
  v_gate := v_gate || jsonb_build_object('chapters_live', jsonb_build_object(
    'count', (select count(*) from public.hub_chapters ch
               where ch.is_active and ch.moderation_state is null
                 and exists (select 1 from public.events e
                              where e.chapter_id = ch.id and e.status = 'published' and e.moderation_state is null
                                and e.starts_at > now() - interval '30 days' and e.starts_at < now() + interval '30 days')),
    'target', 5));

  return jsonb_build_object(
    'week_start', v_start,
    'people', jsonb_build_object(
       'signups', (select count(*) from public.profiles p where p.created_at >= v_from and p.created_at < v_to),
       'onboarded', (select count(*) from public.profiles p
                      where p.onboarding_completed_at >= v_from and p.onboarding_completed_at < v_to),
       'wau', (select count(*) from public.profile_private pp where pp.last_seen_at >= v_from and pp.last_seen_at < v_to),
       'members', (select count(*) from public.profiles p
                    where p.status = 'active' and p.deleted_at is null and p.onboarding_completed_at is not null
                      and p.created_at < v_to)),
    'plans', jsonb_build_object(
       'human_hosted_held', (select count(*) from public.events e
                              where e.kind <> 'imported' and e.status = 'published'
                                and e.starts_at >= v_from and e.starts_at < v_to),
       'human_hosted_next_7d', (select count(*) from public.events e
                                 where e.kind <> 'imported' and e.status = 'published'
                                   and e.starts_at >= v_to and e.starts_at < v_to + interval '7 days'),
       'four_plus_checked_in', (select count(*) from (
                                  select r.event_id from public.rsvps r join public.events e on e.id = r.event_id
                                   where e.kind <> 'imported' and e.status = 'published'
                                     and e.starts_at >= v_from and e.starts_at < v_to and r.checked_in_at is not null
                                   group by r.event_id having count(*) >= 4) x),
       'unique_attendees', (select count(distinct r.user_id) from public.rsvps r join public.events e on e.id = r.event_id
                             where e.kind <> 'imported' and e.status = 'published'
                               and e.starts_at >= v_from and e.starts_at < v_to and r.checked_in_at is not null),
       'second_attendance_rate', (select case when count(*) = 0 then 0
                                              else round(count(*) filter (where x.n >= 2)::numeric / count(*), 3) end
                                    from (select r.user_id, count(*) as n
                                            from public.rsvps r join public.events e on e.id = r.event_id
                                           where e.status = 'published' and r.checked_in_at is not null
                                             and e.starts_at >= v_to - interval '28 days' and e.starts_at < v_to
                                           group by r.user_id) x)),
    'chapters_active', (select count(distinct e.chapter_id) from public.events e
                         where e.chapter_id is not null and e.status = 'published'
                           and e.starts_at >= v_from and e.starts_at < v_to),
    'messages', jsonb_build_object(
       'sent', (select count(*) from public.messages m where m.created_at >= v_from and m.created_at < v_to),
       'active_conversations', (select count(distinct m.conversation_id) from public.messages m
                                 where m.created_at >= v_from and m.created_at < v_to)),
    'coaching', jsonb_build_object(
       'requested', (select count(*) from public.bookings b where b.requested_at >= v_from and b.requested_at < v_to),
       'confirmed', (select count(*) from public.bookings b where b.confirmed_at >= v_from and b.confirmed_at < v_to),
       'completed', (select count(*) from public.bookings b where b.completed_at >= v_from and b.completed_at < v_to),
       'gmv_minor', coalesce((select jsonb_object_agg(x.currency, x.total)
                                from (select b.currency::text as currency, sum(b.price_minor) as total
                                        from public.bookings b
                                       where b.status = 'completed' and b.completed_at >= v_from and b.completed_at < v_to
                                       group by b.currency) x), '{}'::jsonb)),
    'collector', jsonb_build_object(
       'imported_upcoming', (select count(*) from public.events e
                              where e.kind = 'imported' and e.status = 'published' and e.starts_at > now()),
       'sources_ok', greatest(0, coalesce((select sum((s ->> 'count')::integer) from jsonb_array_elements(v_health -> 'sources') s
                                            where s ->> 'state' = 'enabled'), 0)
                                 - coalesce(jsonb_array_length(v_health -> 'stale'), 0)),
       'sources_stale', coalesce(jsonb_array_length(v_health -> 'stale'), 0)),
    'recs', jsonb_build_object(
       'tastes_with_vector', (select count(*) from public.rec_taste t where t.embedding is not null),
       'embeddings', jsonb_build_object(
          'hub', (select count(*) from public.hub_embeddings),
          'event', (select count(*) from public.event_embeddings),
          'coach', (select count(*) from public.coach_listing_embeddings)),
       'queue_due', (select count(*) from public.rec_embed_queue q where q.failed_at is null),
       'failed', (select count(*) from public.rec_embed_queue q where q.failed_at is not null)),
    'trust', jsonb_build_object(
       'reports_open', (select count(*) from (select 1 from public.reports r where r.status = 'open'
                                               group by r.target_kind, r.target_id) x),
       'reports_overdue', (select count(*) from (select 1 from public.reports r where r.status = 'open'
                                                  group by r.target_kind, r.target_id having min(r.due_at) < now()) x),
       'takedowns_open', (select count(*) from public.takedown_requests t where t.status in ('open', 'waiting'))),
    'launch_gate', v_gate);
end $$;

create or replace function public.scorecard_verify_secret(p_secret text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_secret text := public.notify_vault_secret('scorecard_secret');
begin
  return p_secret is not null and char_length(p_secret) >= 32 and v_secret is not null and v_secret = p_secret;
end $$;

-- For the function: the week's run status and the previous week's stored counts.
create or replace function public.scorecard_run_state(p_week_start date default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  with w as (select coalesce(p_week_start, private.scorecard_last_week()) as d)
  select jsonb_build_object(
    'week_start', w.d,
    'status', (select s.status from public.scorecard_runs s where s.week_start = w.d),
    'previous_counts', (select s.counts from public.scorecard_runs s where s.week_start = w.d - 7 and s.status = 'sent'))
    from w;
$$;

create or replace function public.scorecard_record(p_week_start date, p_counts jsonb, p_status text, p_error text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_week date := coalesce(p_week_start, private.scorecard_last_week());
  v_err  text := nullif(left(regexp_replace(lower(coalesce(p_error, '')), '[^a-z0-9_]', '', 'g'), 80), '');
begin
  if p_status not in ('sent', 'skipped_no_key', 'failed') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;
  if extract(isodow from v_week) <> 1 then
    raise exception 'invalid_week' using errcode = '22023';
  end if;
  insert into public.scorecard_runs (week_start, counts, status, sent_at, error)
  values (v_week, coalesce(p_counts, '{}'::jsonb), p_status, case when p_status = 'sent' then now() end, v_err)
  on conflict (week_start) do update
     set counts = excluded.counts, status = excluded.status, sent_at = excluded.sent_at, error = excluded.error
   where public.scorecard_runs.status <> 'sent';
  return jsonb_build_object('week_start', v_week,
                            'status', (select s.status from public.scorecard_runs s where s.week_start = v_week));
end $$;

create or replace function public.scorecard_dispatch()
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_week   date := private.scorecard_last_week();
  v_base   text := public.project_url();
  v_secret text := public.notify_vault_secret('scorecard_secret');
begin
  if exists (select 1 from public.scorecard_runs s where s.week_start = v_week and s.status = 'sent') then
    return null;
  end if;
  if v_base is null or v_secret is null
     or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    raise notice 'weekly-scorecard: project_url, secret or pg_net missing; nothing sent';
    return null;
  end if;
  return net.http_post(
    url := v_base || '/functions/v1/weekly-scorecard',
    body := jsonb_build_object('week_start', v_week),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-scorecard-secret', v_secret),
    timeout_milliseconds := 60000);
end $$;

-- ---------------------------------------------------------------------------
-- 17. request_account_deletion (migration 62 body; changes marked "Migration 67")
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
  v_conv    uuid;   -- Migration 58
  v_b       record; -- Migration 60
  v_src     uuid;   -- Migration 62
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

  -- Migration 53: admin panel lookups the caller made lose the moderator
  -- link; lookups about the caller stay (a year, like the rest of the log).
  update public.admin_lookups set moderator_id = null where moderator_id = uid;

  -- Migration 58: messaging. Pending requests the caller sent go with their
  -- one message (the DM existed only for them); requests to the caller go.
  -- Groups the caller owns pass to the oldest admin, else the oldest member.
  -- DMs with the caller close. The caller's member rows go; a dm or group
  -- nobody is left in goes with its messages. Messages others received stay
  -- under the tombstone ("Deleted user"), without the device key or a kept
  -- deleted text; images are removed (the Edge Function deletes the files).
  -- Report evidence stays until its retain_until.
  delete from public.conversations c
   using public.message_requests r
   where r.conversation_id = c.id and r.from_user = uid and r.status = 'pending';
  for v_conv in
    select cm.conversation_id from public.conversation_members cm
      join public.conversations c on c.id = cm.conversation_id
     where cm.user_id = uid and c.kind = 'group' and cm.role = 'owner' and cm.left_at is null
  loop
    update public.conversation_members set role = 'owner'
     where conversation_id = v_conv
       and user_id = (select cm.user_id from public.conversation_members cm
                       where cm.conversation_id = v_conv and cm.user_id <> uid
                         and cm.left_at is null and cm.removed_at is null
                       order by (cm.role = 'admin') desc, cm.joined_at, cm.user_id
                       limit 1);
  end loop;
  update public.conversations set closed_at = coalesce(closed_at, now())
   where kind = 'dm' and (split_part(dm_key, ':', 1) = uid::text or split_part(dm_key, ':', 2) = uid::text);
  delete from public.message_requests where from_user = uid or to_user = uid;
  delete from public.conversation_members where user_id = uid;
  update public.conversation_members set removed_by = null where removed_by = uid;
  update public.conversations set created_by = null where created_by = uid;
  delete from public.conversations c
   where c.kind in ('dm', 'group')
     and not exists (select 1 from public.conversation_members cm
                      where cm.conversation_id = c.id and cm.left_at is null and cm.removed_at is null);
  update public.messages
     set client_id = null, deleted_body = null,
         image_state = case when kind = 'image' then 'removed' else image_state end
   where author_id = uid;
  delete from public.chat_filter_strikes where user_id = uid;

  -- Migration 60: coaching (design section 13). Open requests and upcoming confirmed bookings
  -- end: as the coach with full refunds, as the client as a client cancellation now; the other
  -- side is told. Reports on reviews by or about the caller keep the text in the report note;
  -- those reviews go (ratings are recomputed). Bookings with the caller lose the client note and
  -- the meeting details. The coach profile goes with its credentials, photo rows, hubs, listings
  -- and their private notes, availability, exceptions and sessions; past bookings keep their own
  -- snapshot (listing_id and session_id are set null) under "Deleted user", as payment and tax
  -- records. booking_payments and coach_stripe_accounts stay (the delete-account function closes
  -- the Stripe account). Photo files go with the avatars/<uid>/ folder.
  for v_b in select b.id, b.coach_id from public.bookings b
              where (b.coach_id = uid or b.client_id = uid)
                and (b.status = 'requested' or (b.status = 'confirmed' and b.starts_at > now())) loop
    perform private.booking_cancel(v_b.id, 'system', 'account_deleted',
                                   case when v_b.coach_id = uid then 'full' else 'policy' end, true);
  end loop;
  update public.reports r
     set note = left(btrim(r.note || ' [text] ' || case when r.target_kind = 'coach_review' then cr.body
                                                         else coalesce(cr.reply, '') end), 1000)
    from public.coach_reviews cr
   where r.target_id = cr.booking_id and r.target_kind in ('coach_review', 'coach_review_reply')
     and (cr.client_id = uid or cr.coach_id = uid);
  delete from public.coach_reviews where client_id = uid or coach_id = uid;
  update public.bookings set client_note = '' where (coach_id = uid or client_id = uid) and client_note <> '';
  delete from public.booking_private bp using public.bookings b
   where b.id = bp.booking_id and (b.coach_id = uid or b.client_id = uid);
  delete from public.coach_profiles where user_id = uid;

  -- Migration 62: organizer claims and connected feeds. Feeds the caller connected (organizer
  -- origin) stop, their upcoming items are withdrawn, and they lose the owner; claimed sources the
  -- collector found itself stay on without an owner. Claims, OAuth states and the Eventbrite token
  -- in the vault go. Listing removal requests hold no account link; resolver stamps are cleared.
  for v_src in
    select f.id from public.feed_sources f
     where f.origin = 'organizer'
       and (f.organizer_id = uid
            or f.organizer_claim_id in (select c.id from public.organizer_claims c where c.user_id = uid))
  loop
    perform public.feed_source_withdraw(v_src, 'stop');
    update public.feed_sources
       set enabled = false, organizer_stopped_at = coalesce(organizer_stopped_at, now()),
           organizer_id = null, organizer_verified_at = null
     where id = v_src;
  end loop;
  update public.feed_sources
     set organizer_id = null, organizer_verified_at = null, organizer_hub_id = null
   where organizer_id = uid;
  delete from public.organizer_claims where user_id = uid;
  delete from public.organizer_oauth_states where user_id = uid;
  begin
    delete from vault.secrets where name = 'eventbrite:' || uid::text;
  exception when insufficient_privilege then
    -- Where the definer may not delete vault rows, the token is overwritten instead.
    perform vault.update_secret(s.id, 'revoked') from vault.secrets s where s.name = 'eventbrite:' || uid::text;
  end;
  update public.listing_removal_requests set resolved_by = null where resolved_by = uid;

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
  -- Migration 67: recommendations. The caller's taste vector, prefs and dismissals go (after
  -- the hub_members delete above, whose trigger marks the taste stale), and so does every other
  -- member's "Not interested" in the caller.
  delete from public.rec_taste                where user_id = uid;
  delete from public.rec_prefs                where user_id = uid;
  delete from public.rec_dismissals           where user_id = uid;
  delete from public.rec_dismissals           where subject_kind = 'person' and subject_id = uid;
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
-- 18. Comments
-- ---------------------------------------------------------------------------
comment on function public.recs_for_you(double precision, double precision, integer, text, integer) is
  'Migration 67 (D-045), invoker: For you. Candidates are feed_events_v2(now, now + 14 days, ..., 200, p_timezone, plan) as the caller, minus own, RSVP''d, dismissed, blocked hosts, plans a blocked person is going to, sensitive hubs and full plans without a waitlist; re-ranked by similarity to the caller''s taste (rank within the set), time, distance band, joined hub, people met going and imported (meta recs_weights), then at most 2 per hub, 1 per series and 3 imported in 10. Returns the feed columns plus reasons (at most two chips by precedence, plus from_source on imported rows) and rank; no rows when fewer than 3. Empty for a member who is not an onboarded adult. Errors: not_authenticated and the feed''s own.';
comment on function public.recs_similar_events(uuid, double precision, double precision, integer, text, integer) is
  'Migration 67 (D-045), invoker: Similar plans. not_found unless can_read_event(p_event_id). Candidates feed_events_v2(now, now + 30 days) minus the anchor and its series; kept above meta recs_similar_floor against the anchor''s embedding (with none, same hub only); sim 0.6, time 0.2, distance 0.2. Not personal.';
comment on function public.recs_hubs(double precision, double precision, integer, integer) is
  'Migration 67 (D-045), invoker: Hubs you may like. Active, unmoderated, general, non-sensitive hubs within the caller''s age that the caller has not joined or dismissed; 0.6 similarity + 0.3 nearby plans in 30 days (log) + 0.1 members (log). reasons like_hub, nearby_plans.';
comment on function public.recs_coaches(double precision, double precision, integer, integer) is
  'Migration 67 (D-045), invoker: Coaches for you. Candidates search_coaches(..., 50) (its own blocks, age, area and online rules), minus the caller and dismissed coaches; 0.55 similarity (best listing) + 0.25 band + 0.1 hub overlap + 0.1 rating (3 or more). reasons teaches_your_hub, rated, online or near.';
comment on function public.recs_people(integer) is
  'Migration 67 (D-045), invoker: People you might click with, from shared context only: met (people_you_met), the same chapter, going to the same upcoming plan; never a sensitive hub or chapter; hub co-membership alone is not context. Both sides active adults with people_suggestions on, no block either way, not muted or dismissed by the caller, no DM in the last 30 days. Order: context strength (met 3, same plan 2, chapter 1), then taste similarity, then the latest shared plan. Returns user_id, handle, first_name, avatar_url, reasons, rank; never a score, hub, RSVP or location. Empty when the caller turned people_suggestions off.';
comment on function public.rec_dismiss(public.rec_subject_kind, uuid) is
  'Migration 67 (D-045): "Not interested" for the caller (at most 60 an hour, rate_limited; at most 500 kept); marks the caller''s taste stale.';
comment on function public.set_recommendation_prefs(boolean, boolean) is
  'Migration 67 (D-045): the caller''s personalize and people_suggestions (null keeps a value). personalize off nulls the taste vector at once; on marks it stale. Returns my_recommendation_prefs().';
comment on function public.public_week_near(double precision, double precision, integer) is
  'Migration 67 (D-045), anon allowed: the landing page''s "this week near you". Origin the point rounded to 0.1 degree, else the Atlanta area centre; published public 18+ unmoderated non-members-only plans (listing_kind plan) in active non-sensitive hubs with an active host or none, starting in the next 7 days within 40 km; human-hosted first, then start time; at most p_limit (12, cap 24). Columns id, title, hub {name, emoji, slug}, starts_at, timezone, is_free, price_text, going_bucket (3+, 10+), distance_band, is_imported, source_name; never a host, description, hint, coordinate or address.';
comment on function public.recs_status() is
  'Migration 67 (D-045), moderators: queue due / claimed / failed by kind, embeddings by kind, embedded today, tastes with a vector, stale tastes, the latest embedding time. Counts only.';
comment on function public.recs_embed_claim(integer) is
  'Migration 67, service role (recs-embed): up to least(p_limit, recs_embed_batch) due rows by priority, with a 5-minute lease; ineligible subjects leave the queue (and their embedding when it may not stay), unchanged texts complete without the model. Returns subject_kind, subject_id, content_hash, text.';
comment on function public.recs_embed_record(jsonb) is
  'Migration 67, service role (recs-embed): [{kind, id, hash, embedding (384 numbers)}]. Refuses a wrong length or a vector not normalized within 1e-3 (bad_vector) and a stale hash (claimed again); upserts the embedding, completes the queue row and marks the owners'' tastes stale. Returns the count stored.';
comment on function public.recs_backfill(public.rec_subject_kind) is
  'Migration 67, service role or moderators: queues every eligible subject of a kind (all when null) at priority 9 and retries failed rows. Returns the count queued.';
comment on function public.scorecard_week(date) is
  'Migration 67 (D-045), service role or moderators: counts only for the Monday-to-Sunday week in America/New_York (the last full week when null): people, plans, chapters_active, messages, coaching, collector, recs, trust, launch_gate. Errors: forbidden, invalid_week.';

-- ---------------------------------------------------------------------------
-- 19. pg_cron
-- ---------------------------------------------------------------------------
do $$
declare
  j record;
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; recs-embed, recs-tick, purge-recs and weekly-scorecard not scheduled';
    return;
  end if;
  for j in select * from (values
             ('recs-embed', '* * * * *', 'select public.recs_embed_dispatch()'),
             ('recs-tick', '*/5 * * * *', 'select public.recs_tick()'),
             ('purge-recs', '23 4 * * *', 'select public.purge_recs()'),
             ('weekly-scorecard', '7 12 * * 1', 'select public.scorecard_dispatch()')) v(name, sched, cmd)
  loop
    if exists (select 1 from cron.job where jobname = j.name) then
      perform cron.unschedule(j.name);
    end if;
    perform cron.schedule(j.name, j.sched, j.cmd);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 20. Privileges (explicit), the backfill, version stamp (last)
-- ---------------------------------------------------------------------------
-- Internal helpers: no client role.
revoke all on function private.recs_on() from public, anon, authenticated;
revoke all on function private.rec_ip(extensions.halfvec, extensions.halfvec) from public, anon, authenticated;
revoke all on function private.rec_hub_sensitive(uuid) from public, anon, authenticated;
revoke all on function private.rec_personalize(uuid) from public, anon, authenticated;
revoke all on function private.rec_strip(text) from public, anon, authenticated;
revoke all on function private.rec_text(public.rec_subject_kind, uuid) from public, anon, authenticated;
revoke all on function private.rec_embeddable(public.rec_subject_kind, uuid) from public, anon, authenticated;
revoke all on function private.rec_keep(public.rec_subject_kind, uuid) from public, anon, authenticated;
revoke all on function private.rec_hash(text) from public, anon, authenticated;
revoke all on function private.rec_stored_hash(public.rec_subject_kind, uuid) from public, anon, authenticated;
revoke all on function private.rec_drop_embedding(public.rec_subject_kind, uuid) from public, anon, authenticated;
revoke all on function private.rec_enqueue(public.rec_subject_kind, uuid, smallint) from public, anon, authenticated;
revoke all on function private.rec_mark_stale(uuid) from public, anon, authenticated;
revoke all on function private.rec_enqueue_hub() from public, anon, authenticated;
revoke all on function private.rec_enqueue_event() from public, anon, authenticated;
revoke all on function private.rec_enqueue_listing() from public, anon, authenticated;
revoke all on function private.rec_enqueue_coach() from public, anon, authenticated;
revoke all on function private.rec_stale_hub_member() from public, anon, authenticated;
revoke all on function private.rec_stale_rsvp() from public, anon, authenticated;
revoke all on function private.rec_stale_booking() from public, anon, authenticated;
revoke all on function private.rec_stale_dismissal() from public, anon, authenticated;
revoke all on function private.rec_embedded_today() from public, anon, authenticated;
revoke all on function private.rec_taste_compute(uuid) from public, anon, authenticated;
revoke all on function private.recs_rehash() from public, anon, authenticated;
revoke all on function private.recs_counts() from public, anon, authenticated;
revoke all on function private.scorecard_last_week() from public, anon, authenticated;

-- Used by the invoker RPCs (numbers and settings only; the scorers re-check readability).
revoke all on function private.rec_meta_num(text, double precision) from public, anon;
grant execute on function private.rec_meta_num(text, double precision) to authenticated;
revoke all on function private.rec_weights() from public, anon;
grant execute on function private.rec_weights() to authenticated;
revoke all on function private.rec_band_score(text) from public, anon;
grant execute on function private.rec_band_score(text) to authenticated;
revoke all on function private.rec_when(timestamptz, text) from public, anon;
grant execute on function private.rec_when(timestamptz, text) to authenticated;
revoke all on function private.rec_viewer_tz(text) from public, anon;
grant execute on function private.rec_viewer_tz(text) to authenticated;
revoke all on function private.rec_event_scores(uuid[], uuid) from public, anon;
grant execute on function private.rec_event_scores(uuid[], uuid) to authenticated;
revoke all on function private.rec_hub_scores(uuid[]) from public, anon;
grant execute on function private.rec_hub_scores(uuid[]) to authenticated;
revoke all on function private.rec_coach_scores(uuid[]) from public, anon;
grant execute on function private.rec_coach_scores(uuid[]) to authenticated;
revoke all on function private.rec_people_scores(uuid[]) from public, anon;
grant execute on function private.rec_people_scores(uuid[]) to authenticated;

-- Member RPCs.
revoke all on function public.recs_for_you(double precision, double precision, integer, text, integer) from public, anon;
grant execute on function public.recs_for_you(double precision, double precision, integer, text, integer) to authenticated;
revoke all on function public.recs_similar_events(uuid, double precision, double precision, integer, text, integer) from public, anon;
grant execute on function public.recs_similar_events(uuid, double precision, double precision, integer, text, integer) to authenticated;
revoke all on function public.recs_hubs(double precision, double precision, integer, integer) from public, anon;
grant execute on function public.recs_hubs(double precision, double precision, integer, integer) to authenticated;
revoke all on function public.recs_coaches(double precision, double precision, integer, integer) from public, anon;
grant execute on function public.recs_coaches(double precision, double precision, integer, integer) to authenticated;
revoke all on function public.recs_people(integer) from public, anon;
grant execute on function public.recs_people(integer) to authenticated;
revoke all on function public.rec_dismiss(public.rec_subject_kind, uuid) from public, anon;
grant execute on function public.rec_dismiss(public.rec_subject_kind, uuid) to authenticated;
revoke all on function public.rec_undismiss(public.rec_subject_kind, uuid) from public, anon;
grant execute on function public.rec_undismiss(public.rec_subject_kind, uuid) to authenticated;
revoke all on function public.my_recommendation_prefs() from public, anon;
grant execute on function public.my_recommendation_prefs() to authenticated;
revoke all on function public.set_recommendation_prefs(boolean, boolean) from public, anon;
grant execute on function public.set_recommendation_prefs(boolean, boolean) to authenticated;
revoke all on function public.recs_status() from public, anon;
grant execute on function public.recs_status() to authenticated;
revoke all on function public.public_week_near(double precision, double precision, integer) from public;
grant execute on function public.public_week_near(double precision, double precision, integer) to anon, authenticated;

-- Service role, or moderators checked inside.
revoke all on function public.recs_backfill(public.rec_subject_kind) from public, anon;
grant execute on function public.recs_backfill(public.rec_subject_kind) to authenticated, service_role;
revoke all on function public.scorecard_week(date) from public, anon;
grant execute on function public.scorecard_week(date) to authenticated, service_role;

-- Service role only.
revoke all on function public.recs_embed_dispatch() from public, anon, authenticated;
grant execute on function public.recs_embed_dispatch() to service_role;
revoke all on function public.recs_embed_claim(integer) from public, anon, authenticated;
grant execute on function public.recs_embed_claim(integer) to service_role;
revoke all on function public.recs_embed_record(jsonb) from public, anon, authenticated;
grant execute on function public.recs_embed_record(jsonb) to service_role;
revoke all on function public.recs_embed_fail(public.rec_subject_kind, uuid, text) from public, anon, authenticated;
grant execute on function public.recs_embed_fail(public.rec_subject_kind, uuid, text) to service_role;
revoke all on function public.recs_embed_verify_secret(text) from public, anon, authenticated;
grant execute on function public.recs_embed_verify_secret(text) to service_role;
revoke all on function public.recs_taste_refresh(integer) from public, anon, authenticated;
grant execute on function public.recs_taste_refresh(integer) to service_role;
revoke all on function public.recs_tick() from public, anon, authenticated;
grant execute on function public.recs_tick() to service_role;
revoke all on function public.purge_recs() from public, anon, authenticated;
grant execute on function public.purge_recs() to service_role;
revoke all on function public.scorecard_verify_secret(text) from public, anon, authenticated;
grant execute on function public.scorecard_verify_secret(text) to service_role;
revoke all on function public.scorecard_run_state(date) from public, anon, authenticated;
grant execute on function public.scorecard_run_state(date) to service_role;
revoke all on function public.scorecard_record(date, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.scorecard_record(date, jsonb, text, text) to service_role;
revoke all on function public.scorecard_dispatch() from public, anon, authenticated;
grant execute on function public.scorecard_dispatch() to service_role;

-- Unchanged grant of the rebuilt function.
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- The backfill (section 4.4): drained by the recs-embed job under its caps.
select public.recs_backfill();

insert into public.meta (key, value) values ('schema_version', '2.63')
  on conflict (key) do update set value = excluded.value, updated_at = now();

-- ============================================================================
-- Staging check for migration 20261231000100_recommendations.sql (migration 67,
-- D-045 recommendations slice 1). One transaction: throwaway accounts, events
-- far out in the Atlantic (no other plans nearby) and synthetic one-hot
-- 384-dimension vectors written as the test owner; DO blocks that raise on
-- failure, then ROLLBACK. Prints pass/fail only (no user rows; the accounts
-- are invented).
--
--   1 static: schema_version, RLS, grants, invoker RPCs, service-only jobs.
--   2 For you: excludes RSVP'd, dismissed, own, blocked host, blocked attendee,
--     21+ for a 19-year-old, sensitive hub, campus-only to a non-member,
--     moderated, shows, another city's plans; orders by similarity at equal
--     distance and by distance at equal similarity; at most 2 per hub; chips
--     never name a sensitive hub; people met going.
--   3 Similar plans: refuses an unreadable anchor; keeps only similar plans.
--   4 Hubs: excludes joined, sensitive, campus-scope, 21+, moderated, dismissed.
--   5 Coaches: excludes blocked coaches and the caller.
--   6 Taste: weights, decay, sensitive and moderated inputs ignored,
--     personalize off; no client reads a taste vector.
--   7 Queue: triggers on insert and edit; claim builds text (no URL, email or
--     phone), skips an unchanged hash, drops ineligible subjects; record
--     validates length and norm and refuses a stale hash; fail after 5.
--   8 Account deletion: the member's taste, prefs and dismissals go, and
--     others' "Not interested" in them.
-- ============================================================================

create or replace function pg_temp.uid(p_name text) returns uuid language sql stable as $$
  select current_setting('test.' || p_name)::uuid;
$$;
create or replace function pg_temp.act(p_name text) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', current_setting('test.' || p_name), 'role', 'authenticated')::text, true);
$$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;
-- A unit-ish vector from {"dim": value} (dimensions 1 to 384; values already normalized).
create or replace function pg_temp.vec(p jsonb) returns extensions.halfvec language sql immutable as $$
  select (select array_agg(coalesce((p ->> g::text)::real, 0) order by g) from generate_series(1, 384) g)
           ::real[]::extensions.vector(384)::extensions.halfvec(384);
$$;
create or replace function pg_temp.vjson(p jsonb, p_len integer default 384) returns jsonb language sql immutable as $$
  select jsonb_agg(coalesce((p ->> g::text)::double precision, 0) order by g) from generate_series(1, p_len) g;
$$;
-- The test events in a For you answer (ids in rank order) and their reasons.
create or replace function pg_temp.fy(p_lat double precision, p_lng double precision) returns uuid[] language sql as $$
  select coalesce(array_agg(f.id order by f.rank), '{}')
    from public.recs_for_you(p_lat, p_lng, 25, 'UTC', 30) f
   where f.id = any (string_to_array(current_setting('test.events'), ',')::uuid[]);
$$;
create or replace function pg_temp.pos(p_arr uuid[], p_name text) returns integer language sql as $$
  select array_position(p_arr, pg_temp.uid(p_name));
$$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 63] then
    raise exception 'FAIL 1 schema_version is older than 2.63';
  end if;
  if not exists (select 1 from pg_extension where extname = 'vector') then
    raise exception 'FAIL 1 vector extension missing';
  end if;
  foreach t in array array['hub_embeddings', 'event_embeddings', 'coach_listing_embeddings', 'rec_embed_queue',
                           'rec_taste', 'rec_prefs', 'rec_dismissals', 'scorecard_runs'] loop
    if not coalesce((select c.relrowsecurity from pg_class c where c.oid = ('public.' || t)::regclass), false) then
      raise exception 'FAIL 1 RLS is off on %', t;
    end if;
    if has_table_privilege('anon', 'public.' || t, 'select')
       or has_table_privilege('authenticated', 'public.' || t, 'insert')
       or has_table_privilege('authenticated', 'public.' || t, 'update')
       or has_table_privilege('authenticated', 'public.' || t, 'delete') then
      raise exception 'FAIL 1 clients can write or anon can read %', t;
    end if;
  end loop;
  foreach t in array array['hub_embeddings', 'event_embeddings', 'coach_listing_embeddings', 'rec_embed_queue', 'rec_taste'] loop
    if has_table_privilege('authenticated', 'public.' || t, 'select') then
      raise exception 'FAIL 1 authenticated can read %', t;
    end if;
  end loop;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public'
                and table_name in ('hub_embeddings', 'event_embeddings', 'coach_listing_embeddings', 'rec_embed_queue', 'scorecard_runs')
                and (column_name ~ 'user|profile|created_by')) then
    raise exception 'FAIL 1 an embedding, queue or scorecard table has a user column';
  end if;
  foreach t in array array['public.recs_for_you(double precision,double precision,integer,text,integer)',
                           'public.recs_similar_events(uuid,double precision,double precision,integer,text,integer)',
                           'public.recs_hubs(double precision,double precision,integer,integer)',
                           'public.recs_coaches(double precision,double precision,integer,integer)',
                           'public.recs_people(integer)'] loop
    if (select prosecdef from pg_proc where oid = t::regprocedure) then
      raise exception 'FAIL 1 % is security definer', t;
    end if;
    if has_function_privilege('anon', t, 'execute') or not has_function_privilege('authenticated', t, 'execute') then
      raise exception 'FAIL 1 % grants', t;
    end if;
  end loop;
  foreach t in array array['public.recs_embed_dispatch()', 'public.recs_embed_claim(integer)', 'public.recs_embed_record(jsonb)',
                           'public.recs_embed_fail(public.rec_subject_kind,uuid,text)', 'public.recs_embed_verify_secret(text)',
                           'public.recs_taste_refresh(integer)', 'public.recs_tick()', 'public.purge_recs()',
                           'public.scorecard_dispatch()', 'public.scorecard_verify_secret(text)',
                           'public.scorecard_record(date,jsonb,text,text)', 'public.scorecard_run_state(date)',
                           'private.rec_taste_compute(uuid)', 'private.rec_text(public.rec_subject_kind,uuid)'] loop
    if has_function_privilege('authenticated', t, 'execute') or has_function_privilege('anon', t, 'execute') then
      raise exception 'FAIL 1 a client can run %', t;
    end if;
    if not (select prosecdef from pg_proc where oid = t::regprocedure)
       or not exists (select 1 from pg_proc where oid = t::regprocedure and proconfig @> array['search_path=""']) then
      raise exception 'FAIL 1 % is not definer with an empty search_path', t;
    end if;
  end loop;
  if not has_function_privilege('service_role', 'public.recs_embed_claim(integer)', 'execute')
     or has_function_privilege('anon', 'private.rec_event_scores(uuid[],uuid)', 'execute')
     or not has_function_privilege('authenticated', 'private.rec_event_scores(uuid[],uuid)', 'execute')
     or not has_function_privilege('anon', 'public.public_week_near(double precision,double precision,integer)', 'execute') then
    raise exception 'FAIL 1 scorer, service or landing grants';
  end if;
  if (select count(*) from cron.job where jobname in ('recs-embed', 'recs-tick', 'purge-recs', 'weekly-scorecard')) <> 4 then
    raise exception 'FAIL 1 a pg_cron job is missing';
  end if;
  if not exists (select 1 from vault.secrets where name = 'recs_embed_secret')
     or not exists (select 1 from vault.secrets where name = 'scorecard_secret') then
    raise exception 'FAIL 1 a vault secret is missing';
  end if;
  if public.recs_embed_verify_secret('x') or public.recs_embed_verify_secret(null) then
    raise exception 'FAIL 1 a wrong secret was accepted';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  -- m: main member. y: 19 years old. t: taste test. b: blocks m. x: blocked by m. h: host.
  -- p: met m. l: lives in London. c1, c2: coaches. z: deletes the account. u: RSVPs to a queued plan.
  v_names text[] := array['m', 'y', 't', 'b', 'x', 'h', 'p', 'l', 'c1', 'c2', 'z', 'u'];
  v_id    uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_h     uuid[];
  v_sens  uuid;
  v_camph uuid;
  v_h21   uuid;
  v_camp  uuid;
  v_pt    extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-30.0, 47.0), 4326)::extensions.geography;
  v_pt7   extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-29.908, 47.0), 4326)::extensions.geography;
  v_atl   extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-84.388, 33.776), 4326)::extensions.geography;
  v_t     timestamptz := date_trunc('hour', now()) + interval '2 days';
  v_ev    uuid[] := '{}';
  v_e     uuid;
  r       record;
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'recs-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private
       set birth_date = case when v_names[i] = 'y' then (current_date - interval '19 years')::date else date '1990-04-04' end,
           home_area_id = null, home_point = null
     where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), first_name = 'Tester', guidelines_accepted_at = now(),
           created_at = now() - interval '3 days'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  update public.profile_private
     set home_point = extensions.ST_SetSRID(extensions.ST_MakePoint(-0.13, 51.53), 4326)::extensions.geography
   where user_id = pg_temp.uid('l');

  select array_agg(s.id order by s.slug) into v_h
    from (select h.id, h.slug from public.hubs h join public.hub_categories c on c.slug = h.category_slug
           where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
           order by h.slug limit 7) s;
  if coalesce(array_length(v_h, 1), 0) < 7 then raise exception 'FAIL setup: fewer than 7 general hubs'; end if;
  select h.id into v_sens from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and c.is_sensitive and h.moderation_state is null order by h.slug limit 1;
  select h.id into v_camph from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.scope = 'campus' and not c.is_sensitive and h.moderation_state is null and h.min_age = 18
   order by h.slug limit 1;
  select h.id into v_h21 from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 21 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
   order by h.slug limit 1;
  select oc.id into v_camp from public.org_campuses oc order by oc.slug limit 1;
  if v_sens is null or v_camph is null or v_h21 is null or v_camp is null then
    raise exception 'FAIL setup: no sensitive, campus-scope or 21+ hub, or no campus';
  end if;
  for i in 1..7 loop perform set_config('test.h' || i, v_h[i]::text, true); end loop;
  perform set_config('test.hs', v_sens::text, true);
  perform set_config('test.hc', v_camph::text, true);
  perform set_config('test.h21', v_h21::text, true);
  perform set_config('test.hs_name', (select name from public.hubs where id = v_sens), true);
  perform set_config('test.h6_name', (select name from public.hubs where id = v_h[6]), true);

  -- Events at the Atlantic point P (or 7 km east of it, or Atlanta), all starting at v_t.
  for r in select * from (values
      ('eA',      1, 'h',  'p',   'plan', 18, 'public', false),
      ('eB',      2, 'h',  'p',   'plan', 18, 'public', false),
      ('eC',      3, 'h',  'p',   'plan', 18, 'public', false),
      ('eD1',     4, 'h',  'p',   'plan', 18, 'public', false),
      ('eD2',     4, 'h',  'p7',  'plan', 18, 'public', false),
      ('eF1',     5, 'h',  'p',   'plan', 18, 'public', false),
      ('eF2',     5, 'h',  'p',   'plan', 18, 'public', false),
      ('eF3',     5, 'h',  'p',   'plan', 18, 'public', false),
      ('eRsvp',   1, 'h',  'p',   'plan', 18, 'public', false),
      ('eDism',   1, 'h',  'p',   'plan', 18, 'public', false),
      ('eOwn',    2, 'm',  'p',   'plan', 18, 'public', false),
      ('eBHost',  2, 'b',  'p',   'plan', 18, 'public', false),
      ('eBAtt',   2, 'h',  'p',   'plan', 18, 'public', false),
      ('e21',     3, 'h',  'p',   'plan', 21, 'public', false),
      ('eSens',   0, 'h',  'p',   'plan', 18, 'public', false),
      ('eCampus', 3, 'h',  'p',   'plan', 18, 'campus', false),
      ('eMod',    3, 'h',  'p',   'plan', 18, 'public', true),
      ('eShow',   3, 'h',  'p',   'show', 18, 'public', false),
      ('eAtl',    1, 'h',  'atl', 'plan', 18, 'public', false)
    ) v(name, hub, host, place, lk, age, vis, moderated)
  loop
    insert into public.events (hub_id, host_id, title, description, starts_at, ends_at, approx_point, min_age,
                               visibility, campus_id, listing_kind, moderation_state, moderated_at)
    values (case when r.hub = 0 then v_sens else v_h[r.hub] end, pg_temp.uid(r.host),
            'Recs test ' || r.name, 'A test plan.', v_t, v_t + interval '2 hours',
            case r.place when 'p' then v_pt when 'p7' then v_pt7 else v_atl end,
            r.age, r.vis::public.event_visibility, case when r.vis = 'campus' then v_camp end, r.lk,
            case when r.moderated then 'hidden' end, case when r.moderated then now() end)
    returning id into v_e;
    perform set_config('test.' || r.name, v_e::text, true);
    v_ev := v_ev || v_e;
  end loop;
  perform set_config('test.events', array_to_string(v_ev, ','), true);

  -- Embeddings: m's taste is dimension 1.
  insert into public.event_embeddings (event_id, embedding, content_hash) values
    (pg_temp.uid('eA'),  pg_temp.vec('{"1":1}'), 'test'),
    (pg_temp.uid('eB'),  pg_temp.vec('{"1":0.8,"2":0.6}'), 'test'),
    (pg_temp.uid('eC'),  pg_temp.vec('{"2":1}'), 'test'),
    (pg_temp.uid('eD1'), pg_temp.vec('{"3":1}'), 'test'),
    (pg_temp.uid('eD2'), pg_temp.vec('{"3":1}'), 'test'),
    (pg_temp.uid('eF1'), pg_temp.vec('{"1":1}'), 'test'),
    (pg_temp.uid('eF2'), pg_temp.vec('{"1":1}'), 'test'),
    (pg_temp.uid('eF3'), pg_temp.vec('{"1":1}'), 'test'),
    (pg_temp.uid('eSens'), pg_temp.vec('{"1":1}'), 'test'),
    (pg_temp.uid('eMod'), pg_temp.vec('{"1":1}'), 'test')
  on conflict (event_id) do update set embedding = excluded.embedding;
  insert into public.hub_embeddings (hub_id, embedding, content_hash) values
    (v_h[5], pg_temp.vec('{"1":1}'), 'test'),
    (v_h[6], pg_temp.vec('{"1":1}'), 'test'),
    (v_sens, pg_temp.vec('{"1":1}'), 'test')
  on conflict (hub_id) do update set embedding = excluded.embedding;

  -- m: in the sensitive hub and in hub 6; RSVP'd, dismissed, blocked by b, blocks x (who is going).
  insert into public.hub_members (user_id, hub_id) values (pg_temp.uid('m'), v_sens), (pg_temp.uid('m'), v_h[6])
  on conflict do nothing;
  insert into public.rsvps (event_id, user_id, status) values
    (pg_temp.uid('eRsvp'), pg_temp.uid('m'), 'going'),
    (pg_temp.uid('eBAtt'), pg_temp.uid('x'), 'going'),
    (pg_temp.uid('eC'), pg_temp.uid('p'), 'going');
  insert into public.rec_dismissals (user_id, subject_kind, subject_id) values (pg_temp.uid('m'), 'event', pg_temp.uid('eDism'));
  insert into public.blocks (blocker_id, blocked_id) values (pg_temp.uid('b'), pg_temp.uid('m')), (pg_temp.uid('m'), pg_temp.uid('x'));
  -- m and p met (mutual picks) at a past plan.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_h[7], pg_temp.uid('h'), 'Recs test past', now() - interval '10 days', now() - interval '10 days' + interval '2 hours', v_pt)
  returning id into v_e;
  insert into public.event_meets (event_id, user_id, met_user_id) values
    (v_e, pg_temp.uid('m'), pg_temp.uid('p')), (v_e, pg_temp.uid('p'), pg_temp.uid('m'));

  -- Coaches near P: c1 (listing embedding dimension 1), c2 (blocked by m), m itself.
  insert into public.coach_profiles (user_id, status, headline, timezone, in_person, service_point, service_radius_km, area_label)
  select u, 'active', 'Recs test coach', 'Europe/London', true, v_pt, 20, 'Test'
    from unnest(array[pg_temp.uid('c1'), pg_temp.uid('c2'), pg_temp.uid('m')]) u;
  for r in select u from unnest(array['c1', 'c2', 'm']) u loop
    insert into public.coach_listings (coach_id, hub_id, title, delivery, format, duration_minutes, price_minor, currency)
    values (pg_temp.uid(r.u), v_h[1], 'Recs test lessons', 'in_person', 'one_on_one', 60, 0, 'usd')
    returning id into v_e;
    insert into public.coach_listing_embeddings (listing_id, embedding, content_hash) values (v_e, pg_temp.vec('{"1":1}'), 'test');
  end loop;
  insert into public.blocks (blocker_id, blocked_id) values (pg_temp.uid('m'), pg_temp.uid('c2'));

  -- Hub 7 is moderated (for the hubs row).
  update public.hubs set moderation_state = 'hidden', moderated_at = now() where id = v_h[7];

  -- m's taste: dimension 1 (written last, after the stale triggers).
  insert into public.rec_taste (user_id, embedding, inputs, stale, computed_at)
  values (pg_temp.uid('m'), pg_temp.vec('{"1":1}'), 1, false, now())
  on conflict (user_id) do update set embedding = excluded.embedding, inputs = 1, stale = false;
end $$;

-- ---------------------------------------------------------------------------
-- 2. For you
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v   uuid[];
  n   text;
  rs  jsonb;
begin
  perform pg_temp.act('m');
  v := pg_temp.fy(47.0, -30.0);
  foreach n in array array['eRsvp', 'eDism', 'eOwn', 'eBHost', 'eBAtt', 'eSens', 'eCampus', 'eMod', 'eShow', 'eAtl'] loop
    if pg_temp.pos(v, n) is not null then
      raise exception 'FAIL 2 For you shows the excluded plan %', n;
    end if;
  end loop;
  foreach n in array array['eA', 'eB', 'eC', 'eD1', 'eD2'] loop
    if pg_temp.pos(v, n) is null then
      raise exception 'FAIL 2 For you misses %', n;
    end if;
  end loop;
  if not (pg_temp.pos(v, 'eA') < pg_temp.pos(v, 'eB') and pg_temp.pos(v, 'eB') < pg_temp.pos(v, 'eC')) then
    raise exception 'FAIL 2 not ordered by similarity at equal distance';
  end if;
  if not (pg_temp.pos(v, 'eD1') < pg_temp.pos(v, 'eD2')) then
    raise exception 'FAIL 2 not ordered by distance at equal similarity';
  end if;
  if (select count(*) from unnest(v) i where i in (pg_temp.uid('eF1'), pg_temp.uid('eF2'), pg_temp.uid('eF3'))) <> 2 then
    raise exception 'FAIL 2 the per-hub cap of 2 does not hold';
  end if;
  -- Chips: never a sensitive hub; like_hub names the joined hub 6; people met going on eC.
  select jsonb_agg(f.reasons) into rs from public.recs_for_you(47.0, -30.0, 25, 'UTC', 30) f;
  if rs::text like '%' || current_setting('test.hs_name') || '%' then
    raise exception 'FAIL 2 a chip names a sensitive hub';
  end if;
  if not exists (select 1 from public.recs_for_you(47.0, -30.0, 25, 'UTC', 30) f
                  where f.id = pg_temp.uid('eA')
                    and f.reasons @> jsonb_build_array(jsonb_build_object('code', 'like_hub', 'hub_name', current_setting('test.h6_name')))) then
    raise exception 'FAIL 2 eA has no like_hub chip for the joined hub';
  end if;
  if not exists (select 1 from public.recs_for_you(47.0, -30.0, 25, 'UTC', 30) f
                  where f.id = pg_temp.uid('eC') and f.reasons @> '[{"code":"people_met_going","n":1}]') then
    raise exception 'FAIL 2 eC has no people_met_going chip';
  end if;
  if exists (select 1 from public.recs_for_you(47.0, -30.0, 25, 'UTC', 30) f
              where jsonb_array_length(f.reasons) = 0
                 or (select count(*) from jsonb_array_elements(f.reasons) e where e ->> 'code' <> 'from_source') > 2) then
    raise exception 'FAIL 2 a card has no chip or more than two';
  end if;
  -- Dismissing removes a card.
  perform public.rec_dismiss('event', pg_temp.uid('eD2'));
  if pg_temp.pos(pg_temp.fy(47.0, -30.0), 'eD2') is not null then
    raise exception 'FAIL 2 a dismissed plan is still recommended';
  end if;

  -- A 19-year-old never gets the 21+ plan.
  perform pg_temp.act('y');
  v := pg_temp.fy(47.0, -30.0);
  if pg_temp.pos(v, 'e21') is not null then
    raise exception 'FAIL 2 a 19-year-old gets a 21+ plan';
  end if;

  -- The London member: the Atlanta plan never, the plans at P only with a point there.
  perform pg_temp.act('l');
  if pg_temp.pos(pg_temp.fy(51.53, -0.13), 'eAtl') is not null or pg_temp.pos(pg_temp.fy(51.53, -0.13), 'eA') is not null then
    raise exception 'FAIL 2 a London member gets another city''s plan';
  end if;
  -- (Rules only: ties go by start time and id, and at most 2 per hub, so any 3 of the plans at P.)
  if coalesce(array_length(pg_temp.fy(47.0, -30.0), 1), 0) < 3 then
    raise exception 'FAIL 2 a member with a point at P does not get the plans there (rules only)';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Similar plans
-- ---------------------------------------------------------------------------
do $$
declare
  v uuid[];
begin
  perform pg_temp.act('m');
  if pg_temp.err(format('select * from public.recs_similar_events(%L, 47.0, -30.0, 25, %L, 6)', pg_temp.uid('eMod'), 'UTC'))
     <> 'not_found' then
    raise exception 'FAIL 3 Similar plans accepts a moderated anchor';
  end if;
  select coalesce(array_agg(s.id order by s.rank), '{}') into v
    from public.recs_similar_events(pg_temp.uid('eA'), 47.0, -30.0, 25, 'UTC', 10) s;
  if not (pg_temp.uid('eF1') = any (v) or pg_temp.uid('eF2') = any (v) or pg_temp.uid('eF3') = any (v)) then
    raise exception 'FAIL 3 Similar plans misses a similar plan';
  end if;
  if pg_temp.uid('eB') = any (v) or pg_temp.uid('eC') = any (v) or pg_temp.uid('eA') = any (v)
     or pg_temp.uid('eSens') = any (v) or pg_temp.uid('eMod') = any (v) then
    raise exception 'FAIL 3 Similar plans shows the anchor, a plan below the floor, a sensitive or a moderated plan';
  end if;
  perform pg_temp.act('y');
  if pg_temp.err(format('select * from public.recs_similar_events(%L)', pg_temp.uid('e21'))) <> 'not_found' then
    raise exception 'FAIL 3 Similar plans accepts an anchor the caller cannot read';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Hubs you may like
-- ---------------------------------------------------------------------------
do $$
declare
  v uuid[];
begin
  perform pg_temp.act('m');
  perform public.rec_dismiss('hub', pg_temp.uid('h2'));
  select array_agg(h.id) into v from public.recs_hubs(47.0, -30.0, 25, 30) h;
  if pg_temp.uid('h6') = any (v) or pg_temp.uid('hs') = any (v) or pg_temp.uid('hc') = any (v)
     or pg_temp.uid('h7') = any (v) or pg_temp.uid('h2') = any (v) then
    raise exception 'FAIL 4 hubs shows a joined, sensitive, campus-scope, moderated or dismissed hub';
  end if;
  if not (pg_temp.uid('h5') = any (v)) then
    raise exception 'FAIL 4 hubs misses the similar hub with nearby plans';
  end if;
  if not exists (select 1 from public.recs_hubs(47.0, -30.0, 25, 30) h
                  where h.id = pg_temp.uid('h5') and h.reasons @> '[{"code":"nearby_plans","n":3}]') then
    raise exception 'FAIL 4 the nearby_plans chip is wrong';
  end if;
  perform pg_temp.act('y');
  if exists (select 1 from public.recs_hubs(47.0, -30.0, 25, 30) h where h.id = pg_temp.uid('h21')) then
    raise exception 'FAIL 4 a 19-year-old gets a 21+ hub';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Coaches for you
-- ---------------------------------------------------------------------------
do $$
declare
  v uuid[];
begin
  perform pg_temp.act('m');
  select coalesce(array_agg(c.user_id), '{}') into v from public.recs_coaches(47.0, -30.0, 25, 20) c;
  if not (pg_temp.uid('c1') = any (v)) then
    raise exception 'FAIL 5 coaches misses the nearby coach';
  end if;
  if pg_temp.uid('c2') = any (v) or pg_temp.uid('m') = any (v) then
    raise exception 'FAIL 5 coaches shows a blocked coach or the caller';
  end if;
  perform pg_temp.act('c2');
  if exists (select 1 from public.recs_coaches(47.0, -30.0, 25, 20) c where c.user_id = pg_temp.uid('m')) then
    raise exception 'FAIL 5 a blocked member is shown as a coach';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Taste vectors
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.act('m');
  if pg_temp.err('select count(*) from public.rec_taste') not like '%permission denied%' then
    raise exception 'FAIL 6 a member can read rec_taste';
  end if;
  if pg_temp.err('select count(*) from public.event_embeddings') not like '%permission denied%' then
    raise exception 'FAIL 6 a member can read embeddings';
  end if;
  if pg_temp.err(format('select private.rec_taste_compute(%L)', pg_temp.uid('m'))) not like '%permission denied%' then
    raise exception 'FAIL 6 a member can run the taste computation';
  end if;
end $$;
reset role;
do $$ begin perform set_config('request.jwt.claims', '{}', true); end $$;

do $$
declare
  v_h   uuid[];
  v_e   uuid;
  v_pt  extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-30.0, 47.0), 4326)::extensions.geography;
  v_arr real[];
  v_n   integer;
begin
  v_h := array[pg_temp.uid('h1'), pg_temp.uid('h2'), pg_temp.uid('h3')];
  -- Joined hub 1 (dimension 10): weight 1.
  insert into public.hub_embeddings (hub_id, embedding, content_hash) values (v_h[1], pg_temp.vec('{"10":1}'), 'test')
  on conflict (hub_id) do update set embedding = excluded.embedding;
  insert into public.hub_members (user_id, hub_id) values (pg_temp.uid('t'), v_h[1]), (pg_temp.uid('t'), pg_temp.uid('hs'))
  on conflict do nothing;
  -- Going 90 days ago (dimension 11): 1.5 x 0.5.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_h[2], pg_temp.uid('h'), 'Recs test going', now() - interval '90 days', now() - interval '90 days' + interval '1 hour', v_pt)
  returning id into v_e;
  insert into public.event_embeddings (event_id, embedding, content_hash) values (v_e, pg_temp.vec('{"11":1}'), 'test');
  insert into public.rsvps (event_id, user_id, status) values (v_e, pg_temp.uid('t'), 'going');
  -- Checked in an hour ago (dimension 12): 2.5.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_h[3], pg_temp.uid('h'), 'Recs test checked in', now() - interval '1 hour', now() + interval '1 hour', v_pt)
  returning id into v_e;
  insert into public.event_embeddings (event_id, embedding, content_hash) values (v_e, pg_temp.vec('{"12":1}'), 'test');
  insert into public.rsvps (event_id, user_id, status, checked_in_at) values (v_e, pg_temp.uid('t'), 'going', now());
  -- Ignored: a moderated plan (dimension 13) and a plan in a sensitive hub (dimension 14).
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_h[2], pg_temp.uid('h'), 'Recs test moderated', now() - interval '5 days', now() - interval '5 days' + interval '1 hour', v_pt)
  returning id into v_e;
  insert into public.event_embeddings (event_id, embedding, content_hash) values (v_e, pg_temp.vec('{"13":1}'), 'test');
  insert into public.rsvps (event_id, user_id, status, checked_in_at) values (v_e, pg_temp.uid('t'), 'going', now());
  update public.events set moderation_state = 'hidden', moderated_at = now() where id = v_e;
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (pg_temp.uid('hs'), pg_temp.uid('h'), 'Recs test sensitive', now() - interval '5 days', now() - interval '5 days' + interval '1 hour', v_pt)
  returning id into v_e;
  insert into public.event_embeddings (event_id, embedding, content_hash) values (v_e, pg_temp.vec('{"14":1}'), 'test');
  insert into public.rsvps (event_id, user_id, status, checked_in_at) values (v_e, pg_temp.uid('t'), 'going', now());

  if not (select stale from public.rec_taste where user_id = pg_temp.uid('t')) then
    raise exception 'FAIL 6 joining a hub or an RSVP did not mark the taste stale';
  end if;
  perform private.rec_taste_compute(pg_temp.uid('t'));
  select embedding::extensions.vector::real[], inputs into v_arr, v_n from public.rec_taste where user_id = pg_temp.uid('t');
  -- (1, 0.75, 2.5) normalized: 0.3578, 0.2683, 0.8944.
  if v_n <> 3 or v_arr is null
     or abs(v_arr[10] - 0.3578) > 0.01 or abs(v_arr[11] - 0.2683) > 0.01 or abs(v_arr[12] - 0.8944) > 0.01
     or abs(v_arr[1]) > 0.001 or abs(v_arr[13]) > 0.001 or abs(v_arr[14]) > 0.001 then
    raise exception 'FAIL 6 taste weights or decay are wrong, or a sensitive or moderated input counted';
  end if;
  if (select stale from public.rec_taste where user_id = pg_temp.uid('t')) then
    raise exception 'FAIL 6 the taste is still stale after the refresh';
  end if;
end $$;

set local role authenticated;
do $$
begin
  perform pg_temp.act('t');
  if (public.set_recommendation_prefs(false, null) ->> 'personalize')::boolean is distinct from false
     or (public.my_recommendation_prefs() ->> 'people_suggestions')::boolean is distinct from true then
    raise exception 'FAIL 6 set_recommendation_prefs did not save';
  end if;
end $$;
reset role;
do $$ begin perform set_config('request.jwt.claims', '{}', true); end $$;
do $$
begin
  if (select embedding from public.rec_taste where user_id = pg_temp.uid('t')) is not null then
    raise exception 'FAIL 6 personalize off did not clear the taste';
  end if;
  perform private.rec_taste_compute(pg_temp.uid('t'));
  if (select embedding from public.rec_taste where user_id = pg_temp.uid('t')) is not null then
    raise exception 'FAIL 6 a taste was computed with personalize off';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Queue, claim, record, fail (as the owner, i.e. the service role's rights)
-- ---------------------------------------------------------------------------
do $$
declare
  v_pt    extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-30.0, 47.0), 4326)::extensions.geography;
  v_q     uuid; v_gone uuid; v_same uuid; v_fail uuid;
  v_t     timestamptz := now() + interval '3 days';
  v_hash  text;
  v_text  text;
  v_ids   uuid[];
  v_n     integer;
begin
  -- Insert queues; an edit resets the row.
  insert into public.events (hub_id, host_id, title, description, starts_at, ends_at, approx_point)
  values (pg_temp.uid('h1'), pg_temp.uid('h'), 'Queue test run',
          'Join us at https://example.com/join or www.example.org, mail someone@example.com, call +1 404 555 0100.',
          v_t, v_t + interval '1 hour', v_pt)
  returning id into v_q;
  if not exists (select 1 from public.rec_embed_queue where subject_kind = 'event' and subject_id = v_q and priority = 2) then
    raise exception 'FAIL 7 an inserted plan was not queued';
  end if;
  update public.rec_embed_queue set attempts = 3, claimed_at = now(), last_error = 'x' where subject_kind = 'event' and subject_id = v_q;
  update public.events set title = 'Queue test run again' where id = v_q;
  if not exists (select 1 from public.rec_embed_queue where subject_kind = 'event' and subject_id = v_q
                    and attempts = 0 and claimed_at is null and last_error is null) then
    raise exception 'FAIL 7 an edit did not reset the queue row';
  end if;
  update public.events set going_count = going_count where id = v_q;
  if not exists (select 1 from public.rec_embed_queue where subject_kind = 'event' and subject_id = v_q) then
    raise exception 'FAIL 7 queue row lost';
  end if;
  if not exists (select 1 from public.rec_embed_queue where subject_kind = 'hub' and subject_id = pg_temp.uid('h7')) then
    raise exception 'FAIL 7 moderating a hub did not queue it';
  end if;

  -- A cancelled plan with an embedding; a plan whose embedding matches its text.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (pg_temp.uid('h1'), pg_temp.uid('h'), 'Queue test gone', v_t, v_t + interval '1 hour', v_pt) returning id into v_gone;
  insert into public.event_embeddings (event_id, embedding, content_hash) values (v_gone, pg_temp.vec('{"5":1}'), 'old');
  update public.events set status = 'cancelled', cancelled_at = now() where id = v_gone;
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (pg_temp.uid('h1'), pg_temp.uid('h'), 'Queue test same', v_t, v_t + interval '1 hour', v_pt) returning id into v_same;
  insert into public.event_embeddings (event_id, embedding, content_hash)
  values (v_same, pg_temp.vec('{"5":1}'), private.rec_hash(private.rec_text('event', v_same)));
  update public.rec_embed_queue set priority = 0, queued_at = now() - interval '1 day'
   where subject_kind = 'event' and subject_id in (v_q, v_gone, v_same);
  if (select count(*) from public.rec_embed_queue where subject_id in (v_q, v_gone, v_same)) <> 3 then
    raise exception 'FAIL 7 setup: the three queue rows are not there';
  end if;

  select array_agg(c.subject_id), max(c.text) filter (where c.subject_id = v_q),
         max(c.content_hash) filter (where c.subject_id = v_q)
    into v_ids, v_text, v_hash
    from public.recs_embed_claim(24) c;
  if not (v_q = any (v_ids)) or v_gone = any (v_ids) or v_same = any (v_ids) then
    raise exception 'FAIL 7 claim returned the wrong rows';
  end if;
  if v_text not like (select name from public.hubs where id = pg_temp.uid('h1')) || ': Queue test run again. Join us%'
     or v_text ~ '(https?://|www\.|@|555)' then
    raise exception 'FAIL 7 claim text is wrong or keeps a URL, an email or a phone number';
  end if;
  if exists (select 1 from public.rec_embed_queue where subject_id in (v_gone, v_same))
     or exists (select 1 from public.event_embeddings where event_id = v_gone)
     or not exists (select 1 from public.event_embeddings where event_id = v_same) then
    raise exception 'FAIL 7 claim did not drop the ineligible row and its embedding, or the unchanged row';
  end if;
  if not exists (select 1 from public.rec_embed_queue where subject_id = v_q and attempts = 1 and claimed_at is not null) then
    raise exception 'FAIL 7 claim did not lease the row';
  end if;
  if exists (select 1 from public.recs_embed_claim(24) c where c.subject_id = v_q) then
    raise exception 'FAIL 7 a leased row was claimed again';
  end if;

  -- Record: wrong length, not normalized, stale hash, then the real one.
  insert into public.rsvps (event_id, user_id, status) values (v_q, pg_temp.uid('u'), 'going');
  update public.rec_taste set stale = false where user_id = pg_temp.uid('u');
  v_n := public.recs_embed_record(jsonb_build_array(jsonb_build_object(
           'kind', 'event', 'id', v_q, 'hash', v_hash, 'embedding', pg_temp.vjson('{"1":1}', 383))));
  if v_n <> 0 or exists (select 1 from public.event_embeddings where event_id = v_q)
     or (select last_error from public.rec_embed_queue where subject_id = v_q) is distinct from 'bad_vector' then
    raise exception 'FAIL 7 a 383-number vector was stored';
  end if;
  v_n := public.recs_embed_record(jsonb_build_array(jsonb_build_object(
           'kind', 'event', 'id', v_q, 'hash', v_hash, 'embedding', pg_temp.vjson('{"1":0.5,"2":0.5}'))));
  if v_n <> 0 or exists (select 1 from public.event_embeddings where event_id = v_q) then
    raise exception 'FAIL 7 a vector that is not normalized was stored';
  end if;
  v_n := public.recs_embed_record(jsonb_build_array(jsonb_build_object(
           'kind', 'event', 'id', v_q, 'hash', 'stale', 'embedding', pg_temp.vjson('{"1":1}'))));
  if v_n <> 0 or exists (select 1 from public.event_embeddings where event_id = v_q)
     or (select claimed_at from public.rec_embed_queue where subject_id = v_q) is not null then
    raise exception 'FAIL 7 a stale hash was stored or the row was not released';
  end if;
  v_n := public.recs_embed_record(jsonb_build_array(jsonb_build_object(
           'kind', 'event', 'id', v_q, 'hash', v_hash, 'embedding', pg_temp.vjson('{"1":0.6,"2":0.8}'))));
  if v_n <> 1 or not exists (select 1 from public.event_embeddings where event_id = v_q and content_hash = v_hash)
     or exists (select 1 from public.rec_embed_queue where subject_id = v_q) then
    raise exception 'FAIL 7 a valid vector was not stored or the queue row stayed';
  end if;
  if abs(private.rec_ip((select embedding from public.event_embeddings where event_id = v_q), pg_temp.vec('{"2":1}')) - 0.8) > 0.01 then
    raise exception 'FAIL 7 the stored vector is not the recorded one';
  end if;
  if not (select stale from public.rec_taste where user_id = pg_temp.uid('u')) then
    raise exception 'FAIL 7 recording did not mark the attendee''s taste stale';
  end if;

  -- Fail: a code only; failed after 5 attempts.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (pg_temp.uid('h1'), pg_temp.uid('h'), 'Queue test fail', v_t, v_t + interval '1 hour', v_pt) returning id into v_fail;
  update public.rec_embed_queue set attempts = 2 where subject_kind = 'event' and subject_id = v_fail;
  perform public.recs_embed_fail('event', v_fail, 'Some Error! with text');
  if (select failed_at from public.rec_embed_queue where subject_id = v_fail) is not null
     or (select last_error from public.rec_embed_queue where subject_id = v_fail) <> 'someerrorwithtext' then
    raise exception 'FAIL 7 fail before 5 attempts';
  end if;
  update public.rec_embed_queue set attempts = 5 where subject_kind = 'event' and subject_id = v_fail;
  perform public.recs_embed_fail('event', v_fail, 'model_error');
  if (select failed_at from public.rec_embed_queue where subject_id = v_fail) is null then
    raise exception 'FAIL 7 not failed after 5 attempts';
  end if;
  -- The backfill retries failed rows.
  perform public.recs_backfill('event');
  if (select failed_at from public.rec_embed_queue where subject_id = v_fail) is not null then
    raise exception 'FAIL 7 the backfill did not retry a failed row';
  end if;
  -- recs_tick and purge_recs run.
  perform public.recs_tick();
  perform public.purge_recs();
end $$;

-- ---------------------------------------------------------------------------
-- 8. Account deletion
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
begin
  perform pg_temp.act('z');
  perform public.set_recommendation_prefs(true, false);
  perform public.rec_dismiss('event', pg_temp.uid('eC'));
  perform pg_temp.act('m');
  perform public.rec_dismiss('person', pg_temp.uid('z'));
  if pg_temp.err(format('select public.recs_backfill()')) <> 'forbidden' then
    raise exception 'FAIL 8 a member ran the backfill';
  end if;
  perform pg_temp.act('z');
  perform public.request_account_deletion('recs test');
end $$;
reset role;
do $$ begin perform set_config('request.jwt.claims', '{}', true); end $$;
do $$
begin
  if exists (select 1 from public.rec_taste where user_id = pg_temp.uid('z'))
     or exists (select 1 from public.rec_prefs where user_id = pg_temp.uid('z'))
     or exists (select 1 from public.rec_dismissals where user_id = pg_temp.uid('z'))
     or exists (select 1 from public.rec_dismissals where subject_kind = 'person' and subject_id = pg_temp.uid('z')) then
    raise exception 'FAIL 8 account deletion left recommendation rows';
  end if;
end $$;

select 'PASS recommendations' as result;

reset role;
do $$ begin perform set_config('request.jwt.claims', '{}', true); end $$;
-- ============================================================================
-- Staging check for migration 20261231000100_recommendations.sql (migration 67):
-- recs_people, "People you might click with" (RECS_DESIGN.md section 7). One
-- transaction: throwaway accounts, DO blocks that raise on failure, then
-- ROLLBACK. Prints pass/fail only (the accounts are invented).
--
--   Only shared context counts: met, the same chapter, going to the same plan.
--   Hub co-membership alone gives nothing; a sensitive chapter or plan gives
--   nothing. Opt-out on either side; blocks either way; mutes; a recent DM.
--   No score, hub or location in the result.
-- ============================================================================

create or replace function pg_temp.uid(p_name text) returns uuid language sql stable as $$
  select current_setting('test.' || p_name)::uuid;
$$;
create or replace function pg_temp.act(p_name text) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', current_setting('test.' || p_name), 'role', 'authenticated')::text, true);
$$;
create or replace function pg_temp.people() returns uuid[] language sql as $$
  select coalesce(array_agg(r.user_id order by r.rank), '{}') from public.recs_people(30) r;
$$;
create or replace function pg_temp.pos(p_arr uuid[], p_name text) returns integer language sql as $$
  select array_position(p_arr, pg_temp.uid(p_name));
$$;

-- ---------------------------------------------------------------------------
-- Static: the result carries no score, hub, RSVP or location
-- ---------------------------------------------------------------------------
do $$
declare
  v text := pg_get_function_result('public.recs_people(integer)'::regprocedure);
begin
  if v ~* '(score|sim|hub|rsvp|lat|lng|location|distance|point|band)' then
    raise exception 'FAIL static: recs_people returns %', v;
  end if;
  if (select prosecdef from pg_proc where oid = 'public.recs_people(integer)'::regprocedure)
     or not (select prosecdef from pg_proc where oid = 'private.rec_people_scores(uuid[])'::regprocedure) then
    raise exception 'FAIL static: recs_people must be invoker and its scorer definer';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  -- a: the caller. met1: met a. ch1: same chapter. go1: going to the same plan. hub1: same hub
  -- only. sch: same sensitive chapter. splan: going to the same sensitive plan. opt: same chapter,
  -- opted out. blk1: same chapter, blocked a. blk2: same chapter, blocked by a. mut: same chapter,
  -- muted by a. dm: same chapter, recent DM. h: host.
  v_names text[] := array['a', 'met1', 'ch1', 'go1', 'hub1', 'sch', 'splan', 'opt', 'blk1', 'blk2', 'mut', 'dm', 'h'];
  v_id    uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_hub   uuid;
  v_sens  uuid;
  v_area  uuid;
  v_ch    uuid;
  v_sch   uuid;
  v_up    uuid;
  v_sup   uuid;
  v_past  uuid;
  v_pt    extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-30.0, 47.0), 4326)::extensions.geography;
  v_t     timestamptz := now() + interval '3 days';
  n       text;
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'recsp-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private set birth_date = date '1990-04-04' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), first_name = 'Tester', guidelines_accepted_at = now(),
           created_at = now() - interval '3 days'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;

  select h.id into v_hub from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
   order by h.slug limit 1;
  select h.id into v_sens from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and c.is_sensitive and h.moderation_state is null order by h.slug limit 1;
  if v_hub is null or v_sens is null then raise exception 'FAIL setup: no general or sensitive hub'; end if;
  perform set_config('test.hub_name', (select name from public.hubs where id = v_hub), true);

  insert into public.areas (slug, name, kind, center)
  values ('recsp-' || v_tag, 'Recs test area', 'neighborhood', v_pt) returning id into v_area;
  insert into public.hub_chapters (hub_id, area_id, slug, name)
  values (v_hub, v_area, 'recsp-' || v_tag, 'Recs test chapter') returning id into v_ch;
  insert into public.hub_chapters (hub_id, area_id, slug, name)
  values (v_sens, v_area, 'recsp-s-' || v_tag, 'Recs test sensitive chapter') returning id into v_sch;

  -- The same chapter: ch1, opt, blk1, blk2, mut, dm; the sensitive chapter: sch.
  insert into public.chapter_members (user_id, chapter_id, role) values (pg_temp.uid('a'), v_ch, 'member'), (pg_temp.uid('a'), v_sch, 'member');
  foreach n in array array['ch1', 'opt', 'blk1', 'blk2', 'mut', 'dm'] loop
    insert into public.chapter_members (user_id, chapter_id, role) values (pg_temp.uid(n), v_ch, 'member');
  end loop;
  insert into public.chapter_members (user_id, chapter_id, role) values (pg_temp.uid('sch'), v_sch, 'member');
  -- The same hub only.
  insert into public.hub_members (user_id, hub_id) values (pg_temp.uid('a'), v_hub), (pg_temp.uid('hub1'), v_hub)
  on conflict do nothing;

  -- Going to the same upcoming plan (go1), and to the same sensitive plan (splan).
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub, pg_temp.uid('h'), 'Recs people upcoming', v_t, v_t + interval '2 hours', v_pt) returning id into v_up;
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_sens, pg_temp.uid('h'), 'Recs people sensitive', v_t, v_t + interval '2 hours', v_pt) returning id into v_sup;
  insert into public.rsvps (event_id, user_id, status) values
    (v_up, pg_temp.uid('a'), 'going'), (v_up, pg_temp.uid('go1'), 'going'),
    (v_sup, pg_temp.uid('a'), 'going'), (v_sup, pg_temp.uid('splan'), 'going');

  -- Met: mutual picks at a past plan.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub, pg_temp.uid('h'), 'Recs people past', now() - interval '10 days', now() - interval '10 days' + interval '2 hours', v_pt)
  returning id into v_past;
  insert into public.event_meets (event_id, user_id, met_user_id) values
    (v_past, pg_temp.uid('a'), pg_temp.uid('met1')), (v_past, pg_temp.uid('met1'), pg_temp.uid('a'));

  -- Opt-out, blocks, a mute and a recent DM.
  insert into public.rec_prefs (user_id, people_suggestions) values (pg_temp.uid('opt'), false);
  insert into public.blocks (blocker_id, blocked_id) values (pg_temp.uid('blk1'), pg_temp.uid('a')), (pg_temp.uid('a'), pg_temp.uid('blk2'));
  insert into public.mutes (muter_id, muted_id) values (pg_temp.uid('a'), pg_temp.uid('mut'));
  insert into public.conversations (kind, dm_key, last_message_at)
  values ('dm', private.chat_dm_key(pg_temp.uid('a'), pg_temp.uid('dm')), now() - interval '2 days');
end $$;

-- ---------------------------------------------------------------------------
-- The caller's row
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v uuid[];
  n text;
  r jsonb;
begin
  perform pg_temp.act('a');
  v := pg_temp.people();
  foreach n in array array['met1', 'go1', 'ch1'] loop
    if pg_temp.pos(v, n) is null then
      raise exception 'FAIL people misses the shared-context person %', n;
    end if;
  end loop;
  if not (pg_temp.pos(v, 'met1') < pg_temp.pos(v, 'go1') and pg_temp.pos(v, 'go1') < pg_temp.pos(v, 'ch1')) then
    raise exception 'FAIL people not ordered by context strength (met, same plan, chapter)';
  end if;
  foreach n in array array['hub1', 'sch', 'splan', 'opt', 'blk1', 'blk2', 'mut', 'dm', 'a'] loop
    if pg_temp.pos(v, n) is not null then
      raise exception 'FAIL people suggests % (no shared context, sensitive, opted out, blocked, muted, DM or self)', n;
    end if;
  end loop;
  -- Reasons: only the people codes, never a hub name.
  select jsonb_agg(p.reasons) into r from public.recs_people(30) p;
  if exists (select 1 from jsonb_array_elements(r) x, jsonb_array_elements(x) e
              where e ->> 'code' not in ('went_to_same', 'same_chapter', 'going_to_same'))
     or r::text like '%' || current_setting('test.hub_name') || '%' then
    raise exception 'FAIL people reasons carry another code or a hub name';
  end if;
  if not exists (select 1 from public.recs_people(30) p
                  where p.user_id = pg_temp.uid('ch1') and p.reasons @> '[{"code":"same_chapter","chapter_name":"Recs test chapter"}]')
     or not exists (select 1 from public.recs_people(30) p
                     where p.user_id = pg_temp.uid('go1') and p.reasons @> '[{"code":"going_to_same","title":"Recs people upcoming"}]')
     or not exists (select 1 from public.recs_people(30) p
                     where p.user_id = pg_temp.uid('met1') and p.reasons @> '[{"code":"went_to_same","title":"Recs people past"}]') then
    raise exception 'FAIL people reasons are wrong';
  end if;
  -- Dismissing a person removes them.
  perform public.rec_dismiss('person', pg_temp.uid('ch1'));
  if pg_temp.pos(pg_temp.people(), 'ch1') is not null then
    raise exception 'FAIL people shows a dismissed person';
  end if;

  -- The other side opts out: ch1's view of a; then a opts out: no row, and a is in nobody's row.
  perform pg_temp.act('go1');
  if pg_temp.pos(pg_temp.people(), 'a') is null then
    raise exception 'FAIL people: go1 does not get a';
  end if;
  perform pg_temp.act('a');
  perform public.set_recommendation_prefs(null, false);
  if coalesce(array_length(pg_temp.people(), 1), 0) <> 0 then
    raise exception 'FAIL people: a member who opted out still gets a row';
  end if;
  perform pg_temp.act('go1');
  if pg_temp.pos(pg_temp.people(), 'a') is not null then
    raise exception 'FAIL people: a member who opted out is still suggested';
  end if;
end $$;

select 'PASS recommendations_people' as result;

reset role;
do $$ begin perform set_config('request.jwt.claims', '{}', true); end $$;
-- ============================================================================
-- Staging check for migration 20261231000100_recommendations.sql (migration 67):
-- the weekly scorecard (scorecard_week, scorecard_runs, scorecard_record) and
-- the landing page's public_week_near. One transaction: throwaway accounts
-- and plans, DO blocks that raise on failure, then ROLLBACK. Prints pass/fail
-- only; the scorecard is checked by differences, never printed.
-- ============================================================================

create or replace function pg_temp.uid(p_name text) returns uuid language sql stable as $$
  select current_setting('test.' || p_name)::uuid;
$$;
create or replace function pg_temp.act(p_name text) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', current_setting('test.' || p_name), 'role', 'authenticated')::text, true);
$$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;
create or replace function pg_temp.n(p jsonb, p_path text[]) returns numeric language sql immutable as $$
  select (p #>> p_path)::numeric;
$$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['mod', 'mem', 'host', 'a1', 'a2', 'a3', 'a4', 'banned'];
  v_id    uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_week  date := (now() at time zone 'America/New_York')::date
                  - (extract(isodow from (now() at time zone 'America/New_York')::date)::integer - 1);
  v_before jsonb;
  v_hub   uuid;
  v_sens  uuid;
  v_e     uuid;
  v_q     extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-30.0, 47.0), 4326)::extensions.geography;
  v_qfar  extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-29.34, 47.0), 4326)::extensions.geography;
  v_atl   extensions.geography;
  v_t     timestamptz := now() + interval '1 day';
  v_held  timestamptz;
  v_camp  uuid;
  r       record;
begin
  perform set_config('test.week', v_week::text, true);
  v_held := greatest((v_week::timestamp at time zone 'America/New_York') + interval '1 minute', now() - interval '2 hours');
  -- The counts before anything is seeded (as the owner: is_privileged).
  v_before := public.scorecard_week(v_week);
  perform set_config('test.before', v_before::text, true);

  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'recss-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private set birth_date = date '1990-04-04' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), first_name = 'Tester', guidelines_accepted_at = now()
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  insert into public.user_roles (user_id, role) values (pg_temp.uid('mod'), 'moderator');

  select h.id into v_hub from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
   order by h.slug limit 1;
  select h.id into v_sens from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and c.is_sensitive and h.moderation_state is null order by h.slug limit 1;
  select oc.id into v_camp from public.org_campuses oc order by oc.slug limit 1;
  v_atl := (select a.center from public.areas a where a.slug = 'atlanta');
  if v_hub is null or v_sens is null or v_atl is null or v_camp is null then
    raise exception 'FAIL setup: no general or sensitive hub, Atlanta area or campus';
  end if;

  -- A human-hosted plan held this week with four check-ins.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub, pg_temp.uid('host'), 'Scorecard held', v_held, v_held + interval '1 hour', v_q) returning id into v_e;
  insert into public.rsvps (event_id, user_id, status, checked_in_at)
  select v_e, u, 'going', now() from unnest(array[pg_temp.uid('a1'), pg_temp.uid('a2'), pg_temp.uid('a3'), pg_temp.uid('a4')]) u;

  -- Landing plans at the Atlantic point Q (pOK is the only one that may show).
  for r in select * from (values
      ('pOK',   'hub',  'q',    '1 day',  'public', 18, false, null::text, 'plan', 'host'),
      ('pCamp', 'hub',  'q',    '1 day',  'campus', 18, false, null,       'plan', 'host'),
      ('p21',   'hub',  'q',    '1 day',  'public', 21, false, null,       'plan', 'host'),
      ('pMod',  'hub',  'q',    '1 day',  'public', 18, false, 'hidden',   'plan', 'host'),
      ('pMem',  'hub',  'q',    '1 day',  'public', 18, true,  null,       'plan', 'host'),
      ('pSens', 'sens', 'q',    '1 day',  'public', 18, false, null,       'plan', 'host'),
      ('pLate', 'hub',  'q',    '8 days', 'public', 18, false, null,       'plan', 'host'),
      ('pFar',  'hub',  'qfar', '1 day',  'public', 18, false, null,       'plan', 'host'),
      ('pShow', 'hub',  'q',    '1 day',  'public', 18, false, null,       'show', 'host'),
      ('pBan',  'hub',  'q',    '1 day',  'public', 18, false, null,       'plan', 'banned'),
      ('pAtl',  'hub',  'atl',  '5 minutes', 'public', 18, false, null,    'plan', 'host')
    ) v(name, hub, place, start_in, vis, age, mem, moderated, lk, host)
  loop
    insert into public.events (hub_id, host_id, title, description, location_hint, starts_at, ends_at, approx_point,
                               visibility, campus_id, min_age, members_only, moderation_state, moderated_at, listing_kind)
    values (case when r.hub = 'sens' then v_sens else v_hub end, pg_temp.uid(r.host),
            'Landing ' || r.name, 'A private description', 'Behind the blue door',
            now() + r.start_in::interval, now() + r.start_in::interval + interval '1 hour',
            case r.place when 'q' then v_q when 'qfar' then v_qfar else v_atl end,
            r.vis::public.event_visibility, case when r.vis = 'campus' then v_camp end, r.age, r.mem,
            r.moderated, case when r.moderated is not null then now() end, r.lk)
    returning id into v_e;
    perform set_config('test.' || r.name, v_e::text, true);
  end loop;
  update public.profiles set status = 'banned' where id = pg_temp.uid('banned');

  insert into public.scorecard_runs (week_start, counts, status) values (date '2020-01-06', '{"people":{"signups":1}}', 'sent')
  on conflict (week_start) do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- scorecard_week: counts on the seeded rows (as the owner)
-- ---------------------------------------------------------------------------
do $$
declare
  b jsonb := current_setting('test.before')::jsonb;
  a jsonb := public.scorecard_week(current_setting('test.week')::date);
begin
  if a ->> 'week_start' <> current_setting('test.week') then
    raise exception 'FAIL scorecard week_start';
  end if;
  if pg_temp.n(a, '{people,signups}') - pg_temp.n(b, '{people,signups}') <> 8
     or pg_temp.n(a, '{people,onboarded}') - pg_temp.n(b, '{people,onboarded}') <> 8 then
    raise exception 'FAIL scorecard signups or onboarded';
  end if;
  if pg_temp.n(a, '{plans,human_hosted_held}') - pg_temp.n(b, '{plans,human_hosted_held}') < 1
     or pg_temp.n(a, '{plans,four_plus_checked_in}') - pg_temp.n(b, '{plans,four_plus_checked_in}') <> 1
     or pg_temp.n(a, '{plans,unique_attendees}') - pg_temp.n(b, '{plans,unique_attendees}') <> 4 then
    raise exception 'FAIL scorecard plans counts';
  end if;
  if not (a ? 'people' and a ? 'plans' and a ? 'chapters_active' and a ? 'messages' and a ? 'coaching'
          and a ? 'collector' and a ? 'recs' and a ? 'trust' and a ? 'launch_gate') then
    raise exception 'FAIL scorecard sections missing';
  end if;
  if (a #>> '{launch_gate,week_2027_01_11,target}')::integer <> 10
     or (a #>> '{launch_gate,chapters_live,target}')::integer <> 5 then
    raise exception 'FAIL scorecard launch gate';
  end if;
  -- Counts only: no uuid, no email address anywhere.
  if a::text ~ '[0-9a-f]{8}-[0-9a-f]{4}-' or a::text like '%@%' then
    raise exception 'FAIL scorecard carries an id or an address';
  end if;
  if pg_temp.err($q$select public.scorecard_week(date '2026-11-03')$q$) <> 'invalid_week' then
    raise exception 'FAIL scorecard accepts a week that does not start on Monday';
  end if;
  -- scorecard_record never overwrites a sent week.
  perform public.scorecard_record(date '2020-01-06', '{}'::jsonb, 'failed', 'x');
  if (select status from public.scorecard_runs where week_start = date '2020-01-06') <> 'sent' then
    raise exception 'FAIL scorecard_record overwrote a sent week';
  end if;
  if (public.scorecard_run_state(date '2020-01-13') -> 'previous_counts') is null then
    raise exception 'FAIL scorecard_run_state misses the previous week';
  end if;
end $$;

set local role authenticated;
do $$
begin
  perform pg_temp.act('mem');
  if pg_temp.err('select public.scorecard_week()') <> 'forbidden' then
    raise exception 'FAIL scorecard_week allowed for a member';
  end if;
  if (select count(*) from public.scorecard_runs) <> 0 then
    raise exception 'FAIL scorecard_runs readable by a member';
  end if;
  if pg_temp.err('select public.recs_status()') <> 'forbidden' then
    raise exception 'FAIL recs_status allowed for a member';
  end if;
  perform pg_temp.act('mod');
  if pg_temp.err('select public.scorecard_week()') <> 'ok' then
    raise exception 'FAIL scorecard_week refused for a moderator';
  end if;
  if not exists (select 1 from public.scorecard_runs where week_start = date '2020-01-06') then
    raise exception 'FAIL scorecard_runs not readable by a moderator';
  end if;
  if (public.recs_status() -> 'embeddings') is null then
    raise exception 'FAIL recs_status for a moderator';
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- public_week_near as anon
-- ---------------------------------------------------------------------------
do $$
declare
  v text := pg_get_function_result('public.public_week_near(double precision,double precision,integer)'::regprocedure);
begin
  if v ~* '(host|description|location_hint|lat|lng|point|address|venue)' then
    raise exception 'FAIL public_week_near returns %', v;
  end if;
end $$;

set local role anon;
do $$
declare
  ids uuid[];
  n   text;
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  if pg_temp.err('select count(*) from public.scorecard_runs') not like '%permission denied%' then
    raise exception 'FAIL anon can read scorecard_runs';
  end if;
  select coalesce(array_agg(w.id), '{}') into ids from public.public_week_near(47.03, -30.04, 24) w;
  if not (pg_temp.uid('pOK') = any (ids)) then
    raise exception 'FAIL public_week_near misses the public plan near the point';
  end if;
  foreach n in array array['pCamp', 'p21', 'pMod', 'pMem', 'pSens', 'pLate', 'pFar', 'pShow', 'pBan', 'pAtl'] loop
    if pg_temp.uid(n) = any (ids) then
      raise exception 'FAIL public_week_near shows %', n;
    end if;
  end loop;
  if not exists (select 1 from public.public_week_near(47.03, -30.04, 24) w
                  where w.id = pg_temp.uid('pOK') and w.distance_band = '<1 mi' and not w.is_imported
                    and (w.hub ->> 'name') is not null and w.going_bucket is null) then
    raise exception 'FAIL public_week_near columns for the public plan';
  end if;
  -- No point: Atlanta.
  select coalesce(array_agg(w.id), '{}') into ids from public.public_week_near(null, null, 24) w;
  if not (pg_temp.uid('pAtl') = any (ids)) or pg_temp.uid('pOK') = any (ids) then
    raise exception 'FAIL public_week_near without a point is not Atlanta';
  end if;
  if (select count(*) from public.public_week_near(null, null, 500)) > 24 then
    raise exception 'FAIL public_week_near returns more than 24';
  end if;
end $$;
reset role;

select 'PASS scorecard_landing' as result;

reset role;
do $$ begin perform set_config('request.jwt.claims', '{}', true); end $$;
rollback;
