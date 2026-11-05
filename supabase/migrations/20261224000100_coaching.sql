-- ============================================================================
-- Activity Planet schema v2 — migration 60: coaching, slice 1 (database)
--   (D-044, docs/design/coaching/COACHING_DESIGN.md; PLAN.md 4.7;
--   TRUST-SAFETY-LEGAL.md sections 1, 2, 5, 6 and 11; ROADMAP weeks 9-10).
--   Builds on migration 59 (20261223000100_messaging_review_fixes.sql), which
--   reached staging and is not edited. Rebuilt functions start from their
--   latest bodies and each change is marked "Migration 60":
--   private.chat_shared_context, enqueue_notification,
--   claim_pending_notifications, moderation_set_state, moderation_is_own,
--   report_content, mod_moderate, mod_queue, block_user,
--   image_clear_references, request_account_deletion (migration 58) and
--   mod_ban_user (migration 54). Checks: supabase/tests/coaching.sql,
--   coaching_rules.sql and coaching_payments.sql.
--
--   What this file does
--     1. btree_gist; enums coach_status, listing_delivery, listing_format,
--        listing_status, booking_status, booking_payment_state,
--        coach_session_status; notification_kind gains the booking kinds;
--        the reports and moderation_actions checks accept coach_listing,
--        coach_review, coach_review_reply and booking (reasons no_show and
--        payment for booking reports).
--     2. Tables: coach_profiles, coach_credentials, coach_photos, coach_hubs,
--        coach_listings (coach_listings_launch_shape refuses online + group),
--        coach_listing_private, coach_availability_rules,
--        coach_availability_exceptions, coach_sessions (exclusion constraint
--        coach_sessions_no_overlap: no double booking), bookings,
--        booking_private, coach_reviews, and the service-role payment tables
--        coach_stripe_accounts, booking_payments, stripe_events,
--        coach_fee_minimums (usd 300), stripe_jobs. RLS on every one; clients
--        never write them. notification_prefs.bookings.
--     3. Triggers: service point rounding and time zone check, the busy range
--        of a session, the image-guard reference trigger on coach_photos.url,
--        rating and completed counts.
--     4. Helpers, server-side slot generation (coach_slots), the booking
--        state machine and every RPC of design section 7; service-role RPCs
--        for the stripe-connect, stripe-checkout and stripe-webhook Edge
--        Functions; moderator RPCs; coaching_tick and purge_coaching.
--     5. stripe_dispatch with the vault secret stripe_dispatch_secret
--        (generated in the database, as migration 52 does for image-guard).
--     6. pg_cron coaching-tick (every 5 minutes) and purge-coaching (daily).
--     * meta.coach_payments = 'off' (requests only until an operator turns
--       payments on after the Stripe keys exist), meta.schema_version 2.56.
--
--   Account deletion (design section 13): request_account_deletion cancels
--   the person's open bookings (refunds queued), deletes the coach profile
--   and everything under it, clears notes and meeting details of bookings
--   with them, and deletes the reviews they wrote; past bookings and payment
--   records stay under "Deleted user". coach_stripe_accounts stays until the
--   delete-account function has closed the Stripe account.
--
--   Idempotent: safe to re-run.
-- ============================================================================

create extension if not exists btree_gist with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 1. Enums and kind checks
-- ---------------------------------------------------------------------------
do $$ begin create type public.coach_status as enum ('draft', 'active', 'paused', 'suspended');
exception when duplicate_object then null; end $$;
do $$ begin create type public.listing_delivery as enum ('in_person', 'online');
exception when duplicate_object then null; end $$;
do $$ begin create type public.listing_format as enum ('one_on_one', 'group');
exception when duplicate_object then null; end $$;
do $$ begin create type public.listing_status as enum ('active', 'paused', 'archived');
exception when duplicate_object then null; end $$;
do $$ begin create type public.booking_status as enum
  ('requested', 'confirmed', 'declined', 'expired', 'cancelled', 'completed', 'no_show');
exception when duplicate_object then null; end $$;
do $$ begin create type public.booking_payment_state as enum
  ('none', 'off_platform', 'due', 'processing', 'paid', 'refund_pending', 'partially_refunded', 'refunded',
   'disputed', 'failed');
exception when duplicate_object then null; end $$;
do $$ begin create type public.coach_session_status as enum ('scheduled', 'cancelled', 'done');
exception when duplicate_object then null; end $$;

alter type public.notification_kind add value if not exists 'booking_requested';
alter type public.notification_kind add value if not exists 'booking_confirmed';
alter type public.notification_kind add value if not exists 'booking_declined';
alter type public.notification_kind add value if not exists 'booking_cancelled';
alter type public.notification_kind add value if not exists 'booking_payment_due';
alter type public.notification_kind add value if not exists 'booking_reminder_day';
alter type public.notification_kind add value if not exists 'booking_reminder_2h';
alter type public.notification_kind add value if not exists 'booking_review_prompt';
alter type public.notification_kind add value if not exists 'booking_no_show';
alter type public.notification_kind add value if not exists 'review_received';
alter type public.notification_kind add value if not exists 'review_reply';
alter type public.notification_kind add value if not exists 'coach_payout_action';

alter table public.reports drop constraint if exists reports_target_kind;
alter table public.reports add constraint reports_target_kind
  check (target_kind in ('profile', 'event', 'chapter', 'hub', 'message',
                         'coach_listing', 'coach_review', 'coach_review_reply', 'booking'));
alter table public.reports drop constraint if exists reports_reason;
alter table public.reports add constraint reports_reason
  check (reason in ('harassment', 'hate', 'sexual_content', 'violence', 'spam', 'scam', 'impersonation',
                    'underage', 'unsafe', 'ncii', 'child_safety', 'other', 'no_show', 'payment'));
alter table public.moderation_actions drop constraint if exists moderation_actions_kind;
alter table public.moderation_actions add constraint moderation_actions_kind
  check (target_kind in ('profile', 'event', 'chapter', 'hub', 'takedown', 'image', 'message',
                         'coach_listing', 'coach_review', 'coach_review_reply', 'booking'));
alter table public.moderation_actions drop constraint if exists moderation_actions_action;
alter table public.moderation_actions add constraint moderation_actions_action
  check (action in ('auto_hide', 'dismiss', 'hide', 'remove', 'restore', 'ban', 'unban', 'grant_moderator',
                    'revoke_moderator', 'ncii_remove', 'ncii_reject', 'ncii_update', 'image_block', 'image_remove',
                    'coach_suspend', 'coach_restore', 'cancel_refund', 'uphold_no_show', 'reject_no_show',
                    'complete'));

alter table public.notification_prefs add column if not exists bookings boolean not null default true;
grant update (bookings) on public.notification_prefs to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.coach_profiles (
  user_id            uuid primary key references public.profiles (id) on delete cascade,
  status             public.coach_status not null default 'draft',
  headline           text not null default '',
  about              text not null default '',
  timezone           text not null,
  in_person          boolean not null default true,
  online             boolean not null default false,
  service_point      extensions.geography(Point, 4326),
  service_radius_km  smallint,
  area_label         text not null default '',
  rating_avg         numeric(3,2),
  rating_count       integer not null default 0,
  completed_count    integer not null default 0,
  terms_version      text,
  terms_accepted_at  timestamptz,
  published_at       timestamptz,
  suspended_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint coach_profiles_delivery check (in_person or online),
  constraint coach_profiles_area check (not in_person or (service_point is not null and service_radius_km between 1 and 50)),
  constraint coach_profiles_headline check (char_length(headline) <= 80),
  constraint coach_profiles_about check (char_length(about) <= 2000),
  constraint coach_profiles_area_label check (char_length(area_label) <= 80)
);
create index if not exists coach_profiles_point_idx on public.coach_profiles using gist (service_point) where status = 'active';
comment on table public.coach_profiles is
  'Migration 60 (D-044): a member who coaches. service_point is rounded to 0.01 degree and never granted to clients; search returns distance bands only. Written only by the coaching RPCs.';

create table if not exists public.coach_credentials (
  id        uuid primary key default gen_random_uuid(),
  coach_id  uuid not null references public.coach_profiles (user_id) on delete cascade,
  title     text not null check (char_length(title) between 2 and 80),
  issuer    text not null default '' check (char_length(issuer) <= 80),
  year      smallint check (year between 1950 and 2100),
  position  smallint not null default 0
);
create index if not exists coach_credentials_coach_idx on public.coach_credentials (coach_id, position);
comment on table public.coach_credentials is 'Migration 60: self-reported credentials (always shown as "Self-reported"); at most 10 per coach.';

create table if not exists public.coach_photos (
  id         uuid primary key default gen_random_uuid(),
  coach_id   uuid not null references public.coach_profiles (user_id) on delete cascade,
  url        text not null,
  position   smallint not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists coach_photos_coach_idx on public.coach_photos (coach_id, position);
create index if not exists coach_photos_url_idx on public.coach_photos (url);
comment on table public.coach_photos is 'Migration 60: public avatars URLs under <uid>/coach/; image-guard reference trigger; at most 6 per coach.';

create table if not exists public.coach_hubs (
  coach_id  uuid not null references public.coach_profiles (user_id) on delete cascade,
  hub_id    uuid not null references public.hubs (id) on delete cascade,
  primary key (coach_id, hub_id)
);
create index if not exists coach_hubs_hub_idx on public.coach_hubs (hub_id);

create table if not exists public.coach_listings (
  id                uuid primary key default gen_random_uuid(),
  coach_id          uuid not null references public.coach_profiles (user_id) on delete cascade,
  hub_id            uuid references public.hubs (id) on delete set null,
  title             text not null check (char_length(title) between 3 and 80),
  description       text not null default '' check (char_length(description) <= 2000),
  delivery          public.listing_delivery not null,
  format            public.listing_format not null,
  capacity          smallint not null default 1,
  duration_minutes  smallint not null check (duration_minutes between 15 and 480),
  price_minor       integer not null check (price_minor between 0 and 10000000),
  currency          char(3) not null check (currency ~ '^[a-z]{3}$'),
  buffer_minutes    smallint not null default 0 check (buffer_minutes between 0 and 120),
  min_notice_hours  smallint not null default 12 check (min_notice_hours between 1 and 336),
  max_advance_days  smallint not null default 60 check (max_advance_days between 1 and 180),
  slot_step_minutes smallint not null default 30 check (slot_step_minutes in (15, 30, 60)),
  auto_confirm      boolean not null default false,
  min_age           smallint not null default 18 check (min_age in (18, 21)),
  status            public.listing_status not null default 'active',
  moderation_state  text check (moderation_state is null or moderation_state in ('hidden', 'removed')),
  moderated_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  -- Launch listing shapes (PLAN 4.7 B, TRUST-SAFETY-LEGAL 1 and 2): online group sessions are an
  -- in-app-purchase product under App Store 3.1.3(d) and wait for P.
  constraint coach_listings_launch_shape check (not (delivery = 'online' and format = 'group')),
  constraint coach_listings_capacity check (
    (format = 'one_on_one' and capacity = 1) or (format = 'group' and capacity between 2 and 50))
);
create index if not exists coach_listings_coach_idx on public.coach_listings (coach_id) where status = 'active';
create index if not exists coach_listings_hub_idx on public.coach_listings (hub_id) where status = 'active';
comment on table public.coach_listings is
  'Migration 60: a coach''s service. coach_listings_launch_shape refuses online + group (App Store 3.1.3(d)); removing it is a P decision. Price in the currency''s minor unit.';

create table if not exists public.coach_listing_private (
  listing_id   uuid primary key references public.coach_listings (id) on delete cascade,
  meeting_note text not null default '' check (char_length(meeting_note) <= 500),
  online_link  text check (online_link is null or online_link ~ '^https://')
);

create table if not exists public.coach_availability_rules (
  id          uuid primary key default gen_random_uuid(),
  coach_id    uuid not null references public.coach_profiles (user_id) on delete cascade,
  weekday     smallint not null check (weekday between 1 and 7),
  start_local time not null,
  end_local   time not null,
  listing_id  uuid references public.coach_listings (id) on delete cascade,
  valid_from  date,
  valid_until date,
  constraint coach_availability_rules_order check (end_local > start_local),
  constraint coach_availability_rules_dates check (valid_until is null or valid_from is null or valid_until >= valid_from)
);
create index if not exists coach_availability_rules_coach_idx on public.coach_availability_rules (coach_id, weekday);

create table if not exists public.coach_availability_exceptions (
  id         uuid primary key default gen_random_uuid(),
  coach_id   uuid not null references public.coach_profiles (user_id) on delete cascade,
  kind       text not null check (kind in ('unavailable', 'available')),
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  note       text not null default '' check (char_length(note) <= 120),
  constraint coach_availability_exceptions_order check (ends_at > starts_at and ends_at <= starts_at + interval '31 days')
);
create index if not exists coach_availability_exceptions_coach_idx on public.coach_availability_exceptions (coach_id, starts_at);

create table if not exists public.coach_sessions (
  id           uuid primary key default gen_random_uuid(),
  coach_id     uuid not null references public.coach_profiles (user_id) on delete cascade,
  listing_id   uuid not null references public.coach_listings (id) on delete cascade,
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  busy         tstzrange not null,
  capacity     smallint not null,
  status       public.coach_session_status not null default 'scheduled',
  created_at   timestamptz not null default now(),
  cancelled_at timestamptz,
  constraint coach_sessions_order check (ends_at > starts_at),
  constraint coach_sessions_no_overlap exclude using gist (coach_id with =, busy with &&) where (status = 'scheduled')
);
create index if not exists coach_sessions_listing_idx on public.coach_sessions (listing_id, starts_at) where status = 'scheduled';
comment on table public.coach_sessions is
  'Migration 60: the coach''s held time. busy = [starts_at, ends_at + listing buffer), set by trigger; the exclusion constraint coach_sessions_no_overlap refuses two scheduled sessions of one coach that overlap, so double booking cannot commit.';

create table if not exists public.bookings (
  id                   uuid primary key default gen_random_uuid(),
  listing_id           uuid references public.coach_listings (id) on delete set null,
  session_id           uuid references public.coach_sessions (id) on delete set null,
  coach_id             uuid not null references public.profiles (id),
  client_id            uuid not null references public.profiles (id),
  starts_at            timestamptz not null,
  ends_at              timestamptz not null,
  status               public.booking_status not null default 'requested',
  title                text not null,
  delivery             public.listing_delivery not null,
  format               public.listing_format not null,
  price_minor          integer not null,
  currency             char(3) not null,
  fee_minor            integer not null default 0,
  payment_mode         text not null check (payment_mode in ('none', 'off_platform', 'stripe')),
  payment_state        public.booking_payment_state not null,
  policy_version       text not null,
  free_cancel_until    timestamptz not null,
  client_note          text not null default '' check (char_length(client_note) <= 500),
  client_request_id    uuid not null,
  requested_at         timestamptz not null default now(),
  expires_at           timestamptz not null,
  confirmed_at         timestamptz,
  declined_at          timestamptz,
  expired_at           timestamptz,
  pay_by               timestamptz,
  paid_at              timestamptz,
  cancelled_at         timestamptz,
  cancelled_by         text check (cancelled_by in ('client', 'coach', 'system', 'moderator')),
  cancel_reason        text check (cancel_reason in ('client', 'coach', 'unpaid', 'slot_taken', 'blocked',
                                                     'banned', 'account_deleted', 'listing_removed', 'moderator')),
  completed_at         timestamptz,
  no_show_at           timestamptz,
  no_show_party        text check (no_show_party in ('client', 'coach')),
  no_show_contested_at timestamptz,
  no_show_settled_at   timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint bookings_order check (ends_at > starts_at),
  constraint bookings_not_self check (coach_id <> client_id),
  constraint bookings_states check (
    (status <> 'confirmed' or confirmed_at is not null) and
    (status <> 'declined'  or declined_at  is not null) and
    (status <> 'expired'   or expired_at   is not null) and
    (status <> 'cancelled' or (cancelled_at is not null and cancelled_by is not null)) and
    (status <> 'completed' or completed_at is not null) and
    (status <> 'no_show'   or (no_show_at is not null and no_show_party is not null)))
);
create unique index if not exists bookings_client_request_uq on public.bookings (client_id, client_request_id);
create index if not exists bookings_coach_idx  on public.bookings (coach_id, starts_at desc);
create index if not exists bookings_client_idx on public.bookings (client_id, starts_at desc);
create index if not exists bookings_open_idx   on public.bookings (status, expires_at) where status in ('requested', 'confirmed');
create index if not exists bookings_listing_idx on public.bookings (listing_id) where listing_id is not null;
create index if not exists bookings_session_idx on public.bookings (session_id) where session_id is not null;
create unique index if not exists bookings_seat_uq on public.bookings (session_id, client_id) where status in ('requested', 'confirmed');
comment on table public.bookings is
  'Migration 60: a client''s booking with a coach, with the snapshot the client agreed to and a timestamp per state. Kept (with the snapshot) after either account is deleted: payment and tax records. Parties read it (no client_request_id); written only by the coaching RPCs.';

create table if not exists public.booking_private (
  booking_id   uuid primary key references public.bookings (id) on delete cascade,
  meeting_note text not null default '' check (char_length(meeting_note) <= 500),
  online_link  text check (online_link is null or online_link ~ '^https://')
);

create table if not exists public.coach_reviews (
  booking_id             uuid primary key references public.bookings (id) on delete cascade,
  coach_id               uuid not null references public.profiles (id) on delete cascade,
  client_id              uuid not null references public.profiles (id) on delete cascade,
  rating                 smallint not null check (rating between 1 and 5),
  body                   text not null default '' check (char_length(body) <= 1000),
  created_at             timestamptz not null default now(),
  edited_at              timestamptz,
  reply                  text check (reply is null or char_length(reply) between 1 and 1000),
  replied_at             timestamptz,
  moderation_state       text check (moderation_state is null or moderation_state in ('hidden', 'removed')),
  reply_moderation_state text check (reply_moderation_state is null or reply_moderation_state in ('hidden', 'removed')),
  moderated_at           timestamptz
);
create index if not exists coach_reviews_coach_idx on public.coach_reviews (coach_id, created_at desc);
create index if not exists coach_reviews_client_idx on public.coach_reviews (client_id);

create table if not exists public.coach_stripe_accounts (
  coach_id          uuid primary key references public.profiles (id) on delete cascade,
  stripe_account_id text not null unique check (stripe_account_id ~ '^acct_[A-Za-z0-9]+$'),
  country           char(2) not null,
  default_currency  char(3),
  charges_enabled   boolean not null default false,
  payouts_enabled   boolean not null default false,
  details_submitted boolean not null default false,
  requirements_due  text[] not null default '{}',
  disabled_reason   text,
  updated_at        timestamptz not null default now()
);

create table if not exists public.booking_payments (
  booking_id             uuid primary key references public.bookings (id) on delete restrict,
  checkout_session_id    text unique,
  payment_intent_id      text unique,
  amount_minor           integer not null,
  fee_minor              integer not null,
  currency               char(3) not null,
  stripe_account_id      text not null,
  checkout_attempts      smallint not null default 0,
  refunded_minor         integer not null default 0,
  refund_requested_minor integer not null default 0,
  disputed_at            timestamptz,
  dispute_status         text,
  last_error             text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

create table if not exists public.stripe_events (
  id           text primary key check (id ~ '^evt_[A-Za-z0-9]+$'),
  type         text not null,
  account      text,
  object_id    text,
  livemode     boolean not null,
  received_at  timestamptz not null default now(),
  processed_at timestamptz,
  error        text
);

create table if not exists public.coach_fee_minimums (
  currency      char(3) primary key check (currency ~ '^[a-z]{3}$'),
  min_fee_minor integer not null check (min_fee_minor > 0)
);
insert into public.coach_fee_minimums (currency, min_fee_minor) values ('usd', 300) on conflict (currency) do nothing;

create table if not exists public.stripe_jobs (
  id                bigserial primary key,
  booking_id        uuid references public.bookings (id) on delete restrict,
  stripe_account_id text,
  op                text not null check (op in ('refund', 'expire_checkout', 'close_account')),
  amount_minor      integer,
  idempotency_key   text not null unique,
  status            text not null default 'pending' check (status in ('pending', 'sent', 'done', 'failed')),
  attempts          smallint not null default 0,
  next_at           timestamptz not null default now(),
  last_error        text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint stripe_jobs_target check ((op = 'close_account') = (booking_id is null))
);
create index if not exists stripe_jobs_due_idx on public.stripe_jobs (next_at) where status = 'pending';

-- RLS on, nothing for anon, explicit grants.
alter table public.coach_profiles                enable row level security;
alter table public.coach_credentials             enable row level security;
alter table public.coach_photos                  enable row level security;
alter table public.coach_hubs                    enable row level security;
alter table public.coach_listings                enable row level security;
alter table public.coach_listing_private         enable row level security;
alter table public.coach_availability_rules      enable row level security;
alter table public.coach_availability_exceptions enable row level security;
alter table public.coach_sessions                enable row level security;
alter table public.bookings                      enable row level security;
alter table public.booking_private               enable row level security;
alter table public.coach_reviews                 enable row level security;
alter table public.coach_stripe_accounts         enable row level security;
alter table public.booking_payments              enable row level security;
alter table public.stripe_events                 enable row level security;
alter table public.coach_fee_minimums            enable row level security;
alter table public.stripe_jobs                   enable row level security;
revoke all on public.coach_profiles, public.coach_credentials, public.coach_photos, public.coach_hubs,
              public.coach_listings, public.coach_listing_private, public.coach_availability_rules,
              public.coach_availability_exceptions, public.coach_sessions, public.bookings, public.booking_private,
              public.coach_reviews, public.coach_stripe_accounts, public.booking_payments, public.stripe_events,
              public.coach_fee_minimums, public.stripe_jobs
  from public, anon, authenticated;
revoke all on sequence public.stripe_jobs_id_seq from public, anon, authenticated;
grant all on public.coach_profiles, public.coach_credentials, public.coach_photos, public.coach_hubs,
             public.coach_listings, public.coach_listing_private, public.coach_availability_rules,
             public.coach_availability_exceptions, public.coach_sessions, public.bookings, public.booking_private,
             public.coach_reviews, public.coach_stripe_accounts, public.booking_payments, public.stripe_events,
             public.coach_fee_minimums, public.stripe_jobs
  to service_role;
grant usage, select on sequence public.stripe_jobs_id_seq to service_role;
-- Column lists: no service_point, terms_* or suspended_at; no client_request_id; no review reply
-- (replies are read through get_coach and coach_reviews_page, which hide a moderated reply).
grant select (user_id, status, headline, about, timezone, in_person, online, service_radius_km, area_label,
              rating_avg, rating_count, completed_count, published_at, created_at, updated_at)
  on public.coach_profiles to authenticated;
grant select on public.coach_credentials, public.coach_photos, public.coach_hubs, public.coach_listings,
                public.coach_listing_private, public.coach_availability_rules, public.coach_availability_exceptions
  to authenticated;
grant select (id, listing_id, session_id, coach_id, client_id, starts_at, ends_at, status, title, delivery, format,
              price_minor, currency, fee_minor, payment_mode, payment_state, policy_version, free_cancel_until,
              client_note, requested_at, expires_at, confirmed_at, declined_at, expired_at, pay_by, paid_at,
              cancelled_at, cancelled_by, cancel_reason, completed_at, no_show_at, no_show_party,
              no_show_contested_at, created_at, updated_at)
  on public.bookings to authenticated;
grant select (booking_id, coach_id, client_id, rating, body, created_at, edited_at, replied_at, moderation_state)
  on public.coach_reviews to authenticated;

insert into public.meta (key, value) values ('coach_payments', 'off') on conflict (key) do nothing;
insert into public.meta (key, value) values ('coach_terms_version', '2026-12') on conflict (key) do nothing;
insert into public.meta (key, value) values ('refund_policy_version', '2026-12') on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 3. Private helpers
-- ---------------------------------------------------------------------------
create or replace function private.coach_meta(p_key text, p_default text)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce((select nullif(m.value, '') from public.meta m where m.key = p_key), p_default);
$$;

-- What the app shows (the database flag). The Edge Functions also need their secrets.
create or replace function private.coach_payments_on()
returns boolean language sql stable security definer set search_path = '' as $$
  select private.coach_meta('coach_payments', 'off') = 'on';
$$;

create or replace function private.coach_terms_version()
returns text language sql stable security definer set search_path = '' as $$
  select private.coach_meta('coach_terms_version', '2026-12');
$$;

create or replace function private.refund_policy_version()
returns text language sql stable security definer set search_path = '' as $$
  select private.coach_meta('refund_policy_version', '2026-12');
$$;

-- The application fee (D-026): max(12% rounded, the currency's minimum). Null when the currency
-- has no minimum (not payable in the app). Mirrored by supabase/functions/stripe-checkout/fees.ts.
create or replace function private.coach_fee(p_price integer, p_currency text)
returns integer language sql stable security definer set search_path = '' as $$
  select greatest(round(p_price * 0.12)::integer, m.min_fee_minor)
    from public.coach_fee_minimums m
   where m.currency = lower(p_currency) and p_price is not null and p_price >= 0;
$$;

-- Refund for a cancellation now (design section 3.7): 'full', 'none', or 'policy' (a client
-- cancellation: full at least 24 hours before the start, else half). Mirrored by fees.ts refundFor.
create or replace function private.booking_refund_minor(p_amount integer, p_mode text, p_free_until timestamptz,
                                                        p_at timestamptz)
returns integer language sql immutable set search_path = '' as $$
  select case
           when p_amount is null or p_amount <= 0 or p_mode = 'none' then 0
           when p_mode = 'full' then p_amount
           when p_at < p_free_until then p_amount
           else round(p_amount * 0.5)::integer end;
$$;

-- Why p_user may not coach or book now, or null (design section 2). Order matters: the first
-- failing rule is the answer.
create or replace function private.coach_member_error(p_user uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when p_user is null then 'not_authenticated'
    when not exists (select 1 from public.profiles p where p.id = p_user) then 'onboarding_required'
    when exists (select 1 from public.profiles p where p.id = p_user and p.status in ('banned', 'suspended'))
      then 'forbidden'
    when not private.chat_user_ok(p_user) then 'onboarding_required'
    when not private.chat_has_photo(p_user) then 'photo_required'
    when (select p.created_at from public.profiles p where p.id = p_user) > now() - interval '24 hours'
      then 'account_too_new'
    when (select p.guidelines_accepted_at from public.profiles p where p.id = p_user) is null
      then 'guidelines_required'
  end;
$$;

create or replace function private.coach_raise(p_code text)
returns void language plpgsql set search_path = '' as $$
begin
  if p_code is null then
    return;
  end if;
  if p_code = 'not_authenticated' or p_code = 'forbidden' then
    raise exception '%', p_code using errcode = '42501';
  elsif p_code = 'not_found' then
    raise exception 'not_found' using errcode = 'P0002';
  elsif p_code = 'photo_required' then
    raise exception 'photo_required' using errcode = 'check_violation', hint = 'Add a profile photo first.';
  else
    raise exception '%', p_code using errcode = 'check_violation';
  end if;
end $$;

-- A coach the caller may see: the caller's own profile, or an active coach whose account is
-- active, onboarded, adult and not held by moderators, with no block either way, for an adult viewer.
create or replace function private.coach_visible(p_coach uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_coach is not null and (select auth.uid()) is not null and (
    p_coach = (select auth.uid())
    or (public.viewer_is_adult()
        and exists (select 1 from public.coach_profiles cp
                     where cp.user_id = p_coach and cp.status = 'active')
        and private.chat_user_ok(p_coach)
        and not private.is_blocked_with(p_coach)));
$$;

-- A listing the caller may see and book (own listings always).
create or replace function private.coach_listing_visible(p_listing uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.coach_listings l
     where l.id = p_listing
       and (l.coach_id = (select auth.uid())
            or (l.status = 'active' and l.moderation_state is null
                and coalesce((select public.viewer_age()) >= l.min_age, false)
                and private.coach_visible(l.coach_id))));
$$;

-- In-app payment is possible for this listing now (design section 3.3).
create or replace function private.coach_listing_payable(p_listing uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.coach_payments_on() and exists (
    select 1 from public.coach_listings l
      join public.coach_stripe_accounts a on a.coach_id = l.coach_id
      join public.coach_fee_minimums m on m.currency = l.currency
     where l.id = p_listing and l.price_minor > 0
       and a.charges_enabled and lower(a.default_currency) = l.currency
       and l.price_minor >= 2 * m.min_fee_minor);
$$;

-- Text a coach or client writes: no slur-list term (the messaging filter).
create or replace function private.coach_text_ok(p_text text)
returns boolean language sql stable security definer set search_path = '' as $$
  select not private.chat_filtered(coalesce(p_text, ''), false);
$$;

-- A booking notice (design section 11). Payload: ids, title, time, the recipient's zone; never
-- the client's note. The other party is the actor (first name in the delivery worker).
create or replace function private.booking_notify(p_booking uuid, p_to uuid, p_kind text,
                                                  p_extra jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  b        public.bookings%rowtype;
  v_tz     text;
  v_handle text;
begin
  select * into b from public.bookings where id = p_booking;
  if not found or p_to is null or p_to not in (b.coach_id, b.client_id) then
    return;
  end if;
  select pp.timezone into v_tz from public.profile_private pp where pp.user_id = p_to;
  if not coalesce(public.is_valid_timezone(v_tz), false) then
    select cp.timezone into v_tz from public.coach_profiles cp where cp.user_id = b.coach_id;
  end if;
  select p.handle into v_handle from public.profiles p where p.id = b.coach_id and p.status = 'active';
  perform public.enqueue_notification(
    p_to, p_kind::public.notification_kind,
    p_kind || ':' || b.id::text || ':' || p_to::text || coalesce(':' || (p_extra ->> 'key'), ''),
    null, null, null,
    case when p_to = b.coach_id then b.client_id else b.coach_id end,
    jsonb_build_object('booking_id', b.id, 'title', b.title, 'starts_at', b.starts_at, 'timezone', v_tz,
                       'role', case when p_to = b.coach_id then 'coach' else 'client' end,
                       'coach_handle', v_handle)
      || (coalesce(p_extra, '{}'::jsonb) - 'key'));
end $$;

-- ---------------------------------------------------------------------------
-- 4. Triggers
-- ---------------------------------------------------------------------------
create or replace function private.coach_profiles_before()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not coalesce(public.is_valid_timezone(new.timezone), false) then
    raise exception 'timezone_invalid' using errcode = 'check_violation';
  end if;
  -- About 1 km: the saved point is never finer than the feed's origin.
  if new.service_point is not null then
    new.service_point := extensions.ST_SetSRID(extensions.ST_MakePoint(
      round(extensions.ST_X(new.service_point::extensions.geometry)::numeric, 2)::double precision,
      round(extensions.ST_Y(new.service_point::extensions.geometry)::numeric, 2)::double precision), 4326)::extensions.geography;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists coach_profiles_before on public.coach_profiles;
create trigger coach_profiles_before before insert or update on public.coach_profiles
  for each row execute function private.coach_profiles_before();

create or replace function private.coach_sessions_busy()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_buf smallint;
begin
  select l.buffer_minutes into v_buf from public.coach_listings l where l.id = new.listing_id;
  new.busy := tstzrange(new.starts_at, new.ends_at + make_interval(mins => coalesce(v_buf, 0)), '[)');
  return new;
end $$;
drop trigger if exists coach_sessions_busy on public.coach_sessions;
create trigger coach_sessions_busy before insert or update of starts_at, ends_at, listing_id on public.coach_sessions
  for each row execute function private.coach_sessions_busy();

drop trigger if exists coach_listings_set_updated_at on public.coach_listings;
create trigger coach_listings_set_updated_at before update on public.coach_listings
  for each row execute function public.set_updated_at();
drop trigger if exists bookings_set_updated_at on public.bookings;
create trigger bookings_set_updated_at before update on public.bookings
  for each row execute function public.set_updated_at();

-- Photos are checked like profile photos (migration 52).
drop trigger if exists coach_photos_image_guard on public.coach_photos;
create trigger coach_photos_image_guard after insert or update of url on public.coach_photos
  for each row execute function public.image_guard_on_reference('url');

-- Ratings count unmoderated reviews only; blocks never change them.
create or replace function private.coach_refresh_counts(p_coach uuid)
returns void language sql security definer set search_path = '' as $$
  update public.coach_profiles cp
     set rating_avg = (select round(avg(r.rating)::numeric, 2) from public.coach_reviews r
                        where r.coach_id = p_coach and r.moderation_state is null),
         rating_count = (select count(*) from public.coach_reviews r
                          where r.coach_id = p_coach and r.moderation_state is null),
         completed_count = (select count(*) from public.bookings b
                             where b.coach_id = p_coach and b.status = 'completed')
   where cp.user_id = p_coach;
$$;

create or replace function private.coach_reviews_counts()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.coach_refresh_counts(case when tg_op = 'DELETE' then old.coach_id else new.coach_id end);
  return null;
end $$;
drop trigger if exists coach_reviews_counts on public.coach_reviews;
create trigger coach_reviews_counts after insert or delete or update of rating, moderation_state on public.coach_reviews
  for each row execute function private.coach_reviews_counts();

create or replace function private.bookings_counts()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (new.status = 'completed') is distinct from (old.status = 'completed') then
    perform private.coach_refresh_counts(new.coach_id);
  end if;
  return null;
end $$;
drop trigger if exists bookings_counts on public.bookings;
create trigger bookings_counts after update of status on public.bookings
  for each row execute function private.bookings_counts();

-- ---------------------------------------------------------------------------
-- 5. Slot generation (design section 4)
-- ---------------------------------------------------------------------------
-- Every one-on-one start for a listing on the coach-local dates p_first..p_last: weekly rules in
-- the coach's zone (wall-clock, so "Tuesdays 6 to 9 pm" stays 6 to 9 pm across a daylight-saving
-- change; a local time that does not exist is skipped and an ambiguous one takes its first
-- occurrence), plus available exceptions, minus unavailable exceptions and the coach's scheduled
-- sessions (any listing, with the buffer). No notice or advance limit here (coach_open_slots).
create or replace function private.coach_slot_candidates(p_listing uuid, p_first date, p_last date)
returns table (starts_at timestamptz, ends_at timestamptz)
language sql stable security definer set search_path = '' as $$
  with l as (
    select cl.id, cl.coach_id, cl.duration_minutes::integer as dur, cl.buffer_minutes::integer as buf,
           cl.slot_step_minutes::integer as step, cp.timezone as tz
      from public.coach_listings cl
      join public.coach_profiles cp on cp.user_id = cl.coach_id
     where cl.id = p_listing and cl.format = 'one_on_one'
       and p_first is not null and p_last is not null and p_last >= p_first and p_last - p_first <= 400
  ), local_cands as (
    select l.coach_id, l.dur, l.buf, l.tz, d.d + make_interval(mins => m.m) as local_ts
      from l
      cross join lateral generate_series(p_first::timestamp, p_last::timestamp, interval '1 day') d(d)
      join public.coach_availability_rules r
        on r.coach_id = l.coach_id
       and r.weekday = extract(isodow from d.d)::smallint
       and (r.listing_id is null or r.listing_id = l.id)
       and (r.valid_from is null or d.d::date >= r.valid_from)
       and (r.valid_until is null or d.d::date <= r.valid_until)
      cross join lateral generate_series((extract(epoch from r.start_local) / 60)::integer,
                                         (extract(epoch from r.end_local) / 60)::integer - l.dur,
                                         l.step) m(m)
  ), rule_cands as (
    select c.coach_id, c.dur, c.buf, c.tz,
           case
             when ((c.local_ts at time zone c.tz) - interval '1 hour') at time zone c.tz = c.local_ts
               then (c.local_ts at time zone c.tz) - interval '1 hour'
             when ((c.local_ts at time zone c.tz) - interval '30 minutes') at time zone c.tz = c.local_ts
               then (c.local_ts at time zone c.tz) - interval '30 minutes'
             else c.local_ts at time zone c.tz
           end as s
      from local_cands c
     where (c.local_ts at time zone c.tz) at time zone c.tz = c.local_ts
  ), extra_cands as (
    select l.coach_id, l.dur, l.buf, l.tz, e.starts_at + make_interval(mins => k.k * l.step) as s
      from l
      join public.coach_availability_exceptions e
        on e.coach_id = l.coach_id and e.kind = 'available'
       and e.ends_at > (p_first::timestamp at time zone l.tz)
       and e.starts_at < ((p_last + 1)::timestamp at time zone l.tz)
      cross join lateral generate_series(0, (extract(epoch from (e.ends_at - e.starts_at)) / 60)::integer / l.step) k(k)
     where e.starts_at + make_interval(mins => k.k * l.step + l.dur) <= e.ends_at
  ), cands as (
    select * from rule_cands
    union
    select * from extra_cands
  )
  select distinct c.s, c.s + make_interval(mins => c.dur)
    from cands c
   where (c.s at time zone c.tz)::date between p_first and p_last
     and not exists (select 1 from public.coach_availability_exceptions u
                      where u.coach_id = c.coach_id and u.kind = 'unavailable'
                        and u.starts_at < c.s + make_interval(mins => c.dur) and u.ends_at > c.s)
     and not exists (select 1 from public.coach_sessions x
                      where x.coach_id = c.coach_id and x.status = 'scheduled'
                        and x.busy && tstzrange(c.s, c.s + make_interval(mins => c.dur + c.buf), '[)'))
   order by 1;
$$;

-- Live seats of a session (requests hold a seat in a group session).
create or replace function private.coach_session_seats(p_session uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select count(*)::integer from public.bookings b
   where b.session_id = p_session and b.status in ('requested', 'confirmed');
$$;

-- What can be booked now: coach-local dates from today to the advance limit, starts after the
-- minimum notice. One-on-one: the candidates above. Group: the listing's scheduled sessions with
-- a free seat.
create or replace function private.coach_open_slots(p_listing uuid, p_from date, p_to date)
returns table (starts_at timestamptz, ends_at timestamptz, seats_left smallint, session_id uuid)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  l       public.coach_listings%rowtype;
  v_tz    text;
  v_today date;
  v_first date;
  v_last  date;
  v_min   timestamptz;
begin
  select * into l from public.coach_listings x where x.id = p_listing;
  if not found or p_from is null or p_to is null then
    return;
  end if;
  select cp.timezone into v_tz from public.coach_profiles cp where cp.user_id = l.coach_id;
  v_today := (now() at time zone v_tz)::date;
  v_first := greatest(p_from, v_today);
  v_last  := least(p_to, v_today + l.max_advance_days);
  v_min   := now() + make_interval(hours => l.min_notice_hours);
  if v_first > v_last then
    return;
  end if;
  if l.format = 'group' then
    return query
      select s.starts_at, s.ends_at, (s.capacity - private.coach_session_seats(s.id))::smallint, s.id
        from public.coach_sessions s
       where s.listing_id = l.id and s.status = 'scheduled' and s.starts_at >= v_min
         and (s.starts_at at time zone v_tz)::date between v_first and v_last
         and s.capacity > private.coach_session_seats(s.id)
       order by s.starts_at;
  else
    return query
      select c.starts_at, c.ends_at, 1::smallint, null::uuid
        from private.coach_slot_candidates(l.id, v_first, v_last) c
       where c.starts_at >= v_min
       order by c.starts_at;
  end if;
end $$;

create or replace function public.coach_slots(p_listing uuid, p_from date, p_to date)
returns table (starts_at timestamptz, ends_at timestamptz, seats_left smallint)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.viewer_is_adult() then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'invalid_range' using errcode = 'check_violation';
  end if;
  if p_to - p_from > 31 then
    raise exception 'range_too_long' using errcode = 'check_violation', hint = 'Up to 31 days.';
  end if;
  if not private.coach_listing_visible(p_listing) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  return query select s.starts_at, s.ends_at, s.seats_left from private.coach_open_slots(p_listing, p_from, p_to) s;
end $$;
comment on function public.coach_slots(uuid, date, date) is
  'Migration 60 (design section 4): bookable starts of a listing on the coach-local dates p_from..p_to (at most 31 days), generated in SQL from the weekly rules in the coach''s time zone (wall-clock across daylight-saving changes; a skipped local time is not offered, an ambiguous one is its first occurrence), available and unavailable exceptions, the coach''s scheduled sessions with the buffer, the minimum notice and the advance limit. Group listings return their scheduled sessions with seats_left. The coach sees their own listing''s slots in any status. Errors: not_authenticated, onboarding_required, invalid_range, range_too_long, not_found (also across a block, over the viewer''s age, or an inactive listing or coach).';

-- ---------------------------------------------------------------------------
-- 6. Coach RPCs
-- ---------------------------------------------------------------------------
create or replace function public.upsert_coach_profile(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  cp       public.coach_profiles%rowtype;
  v_new    boolean;
  v_lat    double precision;
  v_lng    double precision;
  v_point  extensions.geography;
begin
  perform private.coach_raise(private.coach_member_error(uid));
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'invalid_text' using errcode = 'check_violation';
  end if;
  select * into cp from public.coach_profiles where user_id = uid for update;
  v_new := not found;
  if v_new then
    cp.user_id := uid;
    cp.timezone := (select pp.timezone from public.profile_private pp where pp.user_id = uid);
    cp.in_person := true;
    cp.online := false;
    cp.headline := '';
    cp.about := '';
    cp.area_label := '';
  end if;
  if p ? 'headline' then cp.headline := btrim(coalesce(p ->> 'headline', '')); end if;
  if p ? 'about' then cp.about := btrim(coalesce(p ->> 'about', '')); end if;
  if p ? 'area_label' then cp.area_label := btrim(coalesce(p ->> 'area_label', '')); end if;
  if p ? 'timezone' then cp.timezone := p ->> 'timezone'; end if;
  if p ? 'in_person' then cp.in_person := coalesce((p ->> 'in_person')::boolean, false); end if;
  if p ? 'online' then cp.online := coalesce((p ->> 'online')::boolean, false); end if;
  if p ? 'radius_km' then cp.service_radius_km := (p ->> 'radius_km')::smallint; end if;
  if char_length(cp.headline) > 80 or char_length(cp.about) > 2000 or char_length(cp.area_label) > 80
     or not private.coach_text_ok(cp.headline || ' ' || cp.about || ' ' || cp.area_label) then
    raise exception 'invalid_text' using errcode = 'check_violation';
  end if;
  if not coalesce(public.is_valid_timezone(cp.timezone), false) then
    raise exception 'timezone_invalid' using errcode = 'check_violation';
  end if;
  if p ? 'lat' or p ? 'lng' then
    v_lat := (p ->> 'lat')::double precision;
    v_lng := (p ->> 'lng')::double precision;
    if v_lat is null or v_lng is null or v_lat not between -90 and 90 or v_lng not between -180 and 180 then
      raise exception 'invalid_area' using errcode = 'check_violation';
    end if;
    v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography;
    cp.service_point := v_point;
  end if;
  if not (cp.in_person or cp.online) then
    raise exception 'invalid_area' using errcode = 'check_violation', hint = 'Coach in person, online, or both.';
  end if;
  if cp.in_person and (cp.service_point is null or cp.service_radius_km is null
                       or cp.service_radius_km not between 1 and 50) then
    raise exception 'invalid_area' using errcode = 'check_violation', hint = 'Pick a point and a radius of 1 to 50 km.';
  end if;
  if v_new then
    insert into public.coach_profiles (user_id, headline, about, timezone, in_person, online, service_point,
                                       service_radius_km, area_label)
    values (uid, cp.headline, cp.about, cp.timezone, cp.in_person, cp.online, cp.service_point,
            cp.service_radius_km, cp.area_label);
  else
    update public.coach_profiles
       set headline = cp.headline, about = cp.about, timezone = cp.timezone, in_person = cp.in_person,
           online = cp.online, service_point = cp.service_point, service_radius_km = cp.service_radius_km,
           area_label = cp.area_label
     where user_id = uid;
  end if;
  return jsonb_build_object('user_id', uid, 'created', v_new,
                            'status', (select c.status from public.coach_profiles c where c.user_id = uid));
end $$;
comment on function public.upsert_coach_profile(jsonb) is
  'Migration 60: creates or edits the caller''s coach profile from {headline, about, timezone, in_person, online, lat, lng, radius_km, area_label} (keys left out keep their value; the time zone defaults to profile_private.timezone). The point is rounded to 0.01 degree and never returned. Errors: section 2 rules (not_authenticated, onboarding_required, forbidden, photo_required, account_too_new, guidelines_required), invalid_text, timezone_invalid, invalid_area.';

create or replace function public.accept_coach_terms(p_version text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_version is null or p_version <> private.coach_terms_version() then
    raise exception 'unknown_version' using errcode = 'check_violation';
  end if;
  update public.coach_profiles set terms_version = p_version, terms_accepted_at = now() where user_id = uid;
  if not found then
    raise exception 'coach_profile_required' using errcode = 'P0002';
  end if;
  return jsonb_build_object('terms_version', p_version);
end $$;

create or replace function public.publish_coach_profile()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  cp  public.coach_profiles%rowtype;
begin
  perform private.coach_raise(private.coach_member_error(uid));
  select * into cp from public.coach_profiles where user_id = uid for update;
  if not found then
    raise exception 'coach_profile_required' using errcode = 'P0002';
  end if;
  if cp.status = 'suspended' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if cp.terms_version is distinct from private.coach_terms_version() then
    raise exception 'coach_terms_required' using errcode = 'check_violation';
  end if;
  if char_length(cp.headline) < 3
     or not exists (select 1 from public.coach_listings l
                     where l.coach_id = uid and l.status = 'active' and l.moderation_state is null)
     or not (exists (select 1 from public.coach_availability_rules r where r.coach_id = uid)
             or exists (select 1 from public.coach_sessions s
                         where s.coach_id = uid and s.status = 'scheduled' and s.starts_at > now())) then
    raise exception 'incomplete_profile' using errcode = 'check_violation',
      hint = 'A headline, an active listing and availability (or a group session) first.';
  end if;
  update public.coach_profiles set status = 'active', published_at = coalesce(published_at, now()) where user_id = uid;
  return jsonb_build_object('status', 'active');
end $$;

create or replace function public.pause_coach_profile()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  v_status public.coach_status;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select status into v_status from public.coach_profiles where user_id = uid for update;
  if not found then
    raise exception 'coach_profile_required' using errcode = 'P0002';
  end if;
  if v_status = 'suspended' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.coach_profiles set status = 'paused' where user_id = uid and status = 'active';
  return jsonb_build_object('status', (select status from public.coach_profiles where user_id = uid));
end $$;

create or replace function private.coach_require_profile(p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_user is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.coach_profiles where user_id = p_user) then
    raise exception 'coach_profile_required' using errcode = 'P0002';
  end if;
end $$;

create or replace function public.set_coach_credentials(p jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  x   jsonb;
  i   integer := 0;
begin
  perform private.coach_require_profile(uid);
  if p is null or jsonb_typeof(p) <> 'array' then
    raise exception 'invalid_text' using errcode = 'check_violation';
  end if;
  if jsonb_array_length(p) > 10 then
    raise exception 'too_many' using errcode = 'check_violation', hint = 'Up to 10.';
  end if;
  delete from public.coach_credentials where coach_id = uid;
  for x in select * from jsonb_array_elements(p) loop
    if char_length(btrim(coalesce(x ->> 'title', ''))) not between 2 and 80
       or char_length(coalesce(x ->> 'issuer', '')) > 80
       or not private.coach_text_ok(coalesce(x ->> 'title', '') || ' ' || coalesce(x ->> 'issuer', '')) then
      raise exception 'invalid_text' using errcode = 'check_violation';
    end if;
    if x ? 'year' and (x ->> 'year') is not null and (x ->> 'year') !~ '^\d{4}$' then
      raise exception 'invalid_text' using errcode = 'check_violation';
    end if;
    insert into public.coach_credentials (coach_id, title, issuer, year, position)
    values (uid, btrim(x ->> 'title'), btrim(coalesce(x ->> 'issuer', '')), (x ->> 'year')::smallint, i);
    i := i + 1;
  end loop;
  return i;
exception when check_violation then
  if sqlerrm in ('invalid_text', 'too_many') then raise; end if;
  raise exception 'invalid_text' using errcode = 'check_violation';
end $$;

create or replace function public.set_coach_photos(p_urls text[])
returns integer language plpgsql security definer set search_path = '' as $$
declare
  uid   uuid := (select auth.uid());
  v_url text;
  v_bucket text;
  v_path text;
  i     integer := 0;
begin
  perform private.coach_require_profile(uid);
  if coalesce(cardinality(p_urls), 0) > 6 then
    raise exception 'too_many' using errcode = 'check_violation', hint = 'Up to 6.';
  end if;
  delete from public.coach_photos where coach_id = uid;
  foreach v_url in array coalesce(p_urls, '{}') loop
    select o.bucket, o.path into v_bucket, v_path from public.storage_object_from_url(v_url) o;
    if v_bucket is distinct from 'avatars' or v_path is null or v_path not like uid::text || '/coach/%'
       or not public.is_own_storage_url(v_url, 'avatars', uid) then
      raise exception 'invalid_photo' using errcode = 'check_violation';
    end if;
    insert into public.coach_photos (coach_id, url, position) values (uid, v_url, i);
    i := i + 1;
  end loop;
  return i;
end $$;

-- A hub a coach may name: active, not moderated, not in a sensitive category.
create or replace function private.coach_hub_allowed(p_hub uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.hubs h join public.hub_categories c on c.slug = h.category_slug
                  where h.id = p_hub and h.is_active and h.moderation_state is null and not c.is_sensitive);
$$;

create or replace function public.set_coach_hubs(p_hub_ids uuid[])
returns integer language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  v   uuid;
begin
  perform private.coach_require_profile(uid);
  if coalesce(cardinality(p_hub_ids), 0) > 10 then
    raise exception 'too_many' using errcode = 'check_violation', hint = 'Up to 10.';
  end if;
  foreach v in array coalesce(p_hub_ids, '{}') loop
    if not private.coach_hub_allowed(v) then
      raise exception 'hub_not_allowed' using errcode = 'check_violation';
    end if;
  end loop;
  delete from public.coach_hubs where coach_id = uid;
  insert into public.coach_hubs (coach_id, hub_id) select distinct uid, h from unnest(coalesce(p_hub_ids, '{}')) h;
  return (select count(*)::integer from public.coach_hubs where coach_id = uid);
end $$;

create or replace function public.upsert_listing(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid   uuid := (select auth.uid());
  cp    public.coach_profiles%rowtype;
  l     public.coach_listings%rowtype;
  v_new boolean;
  v_hub_age smallint;
  v_link text;
  v_note text;
begin
  perform private.coach_raise(private.coach_member_error(uid));
  select * into cp from public.coach_profiles where user_id = uid;
  if not found then
    raise exception 'coach_profile_required' using errcode = 'P0002';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'invalid_text' using errcode = 'check_violation';
  end if;
  if p ? 'id' and p ->> 'id' is not null then
    select * into l from public.coach_listings where id = (p ->> 'id')::uuid and coach_id = uid for update;
    if not found then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
    v_new := false;
  else
    v_new := true;
    l.id := gen_random_uuid();
    l.coach_id := uid;
    l.description := '';
    l.capacity := 1;
    l.buffer_minutes := 0;
    l.min_notice_hours := 12;
    l.max_advance_days := 60;
    l.slot_step_minutes := 30;
    l.min_age := 18;
    l.status := 'active';
  end if;
  begin
    if p ? 'title' then l.title := btrim(p ->> 'title'); end if;
    if p ? 'description' then l.description := btrim(coalesce(p ->> 'description', '')); end if;
    if p ? 'delivery' then l.delivery := (p ->> 'delivery')::public.listing_delivery; end if;
    if p ? 'format' then l.format := (p ->> 'format')::public.listing_format; end if;
    if p ? 'capacity' then l.capacity := (p ->> 'capacity')::smallint; end if;
    if p ? 'duration_minutes' then l.duration_minutes := (p ->> 'duration_minutes')::smallint; end if;
    if p ? 'buffer_minutes' then l.buffer_minutes := (p ->> 'buffer_minutes')::smallint; end if;
    if p ? 'min_notice_hours' then l.min_notice_hours := (p ->> 'min_notice_hours')::smallint; end if;
    if p ? 'max_advance_days' then l.max_advance_days := (p ->> 'max_advance_days')::smallint; end if;
    if p ? 'slot_step_minutes' then l.slot_step_minutes := (p ->> 'slot_step_minutes')::smallint; end if;
    if p ? 'min_age' then l.min_age := (p ->> 'min_age')::smallint; end if;
    if p ? 'hub_id' then l.hub_id := (p ->> 'hub_id')::uuid; end if;
  exception when others then
    raise exception 'invalid_listing' using errcode = 'check_violation';
  end;
  if p ? 'price_minor' or p ? 'currency' then
    begin
      if p ? 'price_minor' then l.price_minor := (p ->> 'price_minor')::integer; end if;
      if p ? 'currency' then l.currency := lower(btrim(p ->> 'currency')); end if;
    exception when others then
      raise exception 'invalid_price' using errcode = 'check_violation';
    end;
  end if;
  if l.price_minor is null or l.price_minor not between 0 and 10000000
     or l.currency is null or l.currency !~ '^[a-z]{3}$' then
    raise exception 'invalid_price' using errcode = 'check_violation';
  end if;
  if l.title is null or char_length(l.title) not between 3 and 80 or char_length(l.description) > 2000
     or not private.coach_text_ok(l.title || ' ' || l.description) then
    raise exception 'invalid_text' using errcode = 'check_violation';
  end if;
  if l.delivery is null or l.format is null or l.duration_minutes is null then
    raise exception 'invalid_listing' using errcode = 'check_violation';
  end if;
  -- The launch shape (coach_listings_launch_shape) and the capacity rule, answered by name.
  if l.delivery = 'online' and l.format = 'group' then
    raise exception 'invalid_shape' using errcode = 'check_violation',
      hint = 'Online group sessions are not offered yet.';
  end if;
  if not p ? 'capacity' and l.format = 'one_on_one' then
    l.capacity := 1;
  end if;
  if (l.format = 'one_on_one' and l.capacity <> 1) or (l.format = 'group' and l.capacity not between 2 and 50) then
    raise exception 'invalid_shape' using errcode = 'check_violation';
  end if;
  if (l.delivery = 'in_person' and not cp.in_person) or (l.delivery = 'online' and not cp.online) then
    raise exception 'delivery_not_offered' using errcode = 'check_violation';
  end if;
  if l.hub_id is not null then
    if not private.coach_hub_allowed(l.hub_id) then
      raise exception 'hub_not_allowed' using errcode = 'check_violation';
    end if;
    select h.min_age into v_hub_age from public.hubs h where h.id = l.hub_id;
    if v_hub_age = 21 then
      l.min_age := 21;
    end if;
  end if;
  l.auto_confirm := case when p ? 'auto_confirm' then coalesce((p ->> 'auto_confirm')::boolean, false)
                         when v_new then l.format = 'group'
                         else l.auto_confirm end;
  v_note := case when p ? 'meeting_note' then btrim(coalesce(p ->> 'meeting_note', '')) end;
  v_link := case when p ? 'online_link' then nullif(btrim(coalesce(p ->> 'online_link', '')), '') end;
  if v_link is not null and v_link !~ '^https://[^\s]+$' then
    raise exception 'invalid_link' using errcode = 'check_violation';
  end if;
  if char_length(coalesce(v_note, '')) > 500 then
    raise exception 'invalid_text' using errcode = 'check_violation';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('coach_listings:' || uid::text));
  if l.status = 'active'
     and (select count(*) from public.coach_listings x where x.coach_id = uid and x.status = 'active' and x.id <> l.id) >= 20 then
    raise exception 'too_many' using errcode = 'check_violation', hint = 'Up to 20 active listings.';
  end if;
  begin
    if v_new then
      insert into public.coach_listings (id, coach_id, hub_id, title, description, delivery, format, capacity,
                                         duration_minutes, price_minor, currency, buffer_minutes, min_notice_hours,
                                         max_advance_days, slot_step_minutes, auto_confirm, min_age, status)
      values (l.id, uid, l.hub_id, l.title, l.description, l.delivery, l.format, l.capacity, l.duration_minutes,
              l.price_minor, l.currency, l.buffer_minutes, l.min_notice_hours, l.max_advance_days,
              l.slot_step_minutes, l.auto_confirm, l.min_age, l.status);
    else
      update public.coach_listings
         set hub_id = l.hub_id, title = l.title, description = l.description, delivery = l.delivery,
             format = l.format, capacity = l.capacity, duration_minutes = l.duration_minutes,
             price_minor = l.price_minor, currency = l.currency, buffer_minutes = l.buffer_minutes,
             min_notice_hours = l.min_notice_hours, max_advance_days = l.max_advance_days,
             slot_step_minutes = l.slot_step_minutes, auto_confirm = l.auto_confirm, min_age = l.min_age
       where id = l.id;
    end if;
  exception when check_violation then
    if sqlerrm like '%coach_listings_launch_shape%' or sqlerrm like '%coach_listings_capacity%' then
      raise exception 'invalid_shape' using errcode = 'check_violation';
    end if;
    raise exception 'invalid_listing' using errcode = 'check_violation';
  end;
  insert into public.coach_listing_private (listing_id, meeting_note, online_link)
  values (l.id, coalesce(v_note, ''), v_link)
  on conflict (listing_id) do update
     set meeting_note = case when p ? 'meeting_note' then excluded.meeting_note else public.coach_listing_private.meeting_note end,
         online_link  = case when p ? 'online_link' then excluded.online_link else public.coach_listing_private.online_link end;
  return jsonb_build_object('id', l.id, 'created', v_new, 'payable', private.coach_listing_payable(l.id));
end $$;
comment on function public.upsert_listing(jsonb) is
  'Migration 60: creates or edits one of the caller''s listings and its private meeting note and call link. Online + group is refused (invalid_shape, the coach_listings_launch_shape constraint). Price changes never touch existing bookings (each keeps its snapshot). A 21+ hub forces min_age 21; group listings auto-confirm by default. Errors: section 2 rules, coach_profile_required, not_found, invalid_text, invalid_listing, invalid_shape, delivery_not_offered, hub_not_allowed, invalid_price, invalid_link, too_many (20 active).';

create or replace function public.set_listing_status(p_id uuid, p_status public.listing_status)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_status is null then
    raise exception 'invalid_listing' using errcode = 'check_violation';
  end if;
  perform 1 from public.coach_listings where id = p_id and coach_id = uid for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('coach_listings:' || uid::text));
  if p_status = 'active'
     and (select count(*) from public.coach_listings x where x.coach_id = uid and x.status = 'active' and x.id <> p_id) >= 20 then
    raise exception 'too_many' using errcode = 'check_violation';
  end if;
  update public.coach_listings set status = p_status where id = p_id;
  return jsonb_build_object('id', p_id, 'status', p_status);
end $$;

create or replace function public.set_availability(p_rules jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  x   jsonb;
  n   integer := 0;
begin
  perform private.coach_require_profile(uid);
  if p_rules is null or jsonb_typeof(p_rules) <> 'array' or jsonb_array_length(p_rules) > 50 then
    raise exception 'invalid_rule' using errcode = 'check_violation', hint = 'Up to 50 weekly windows.';
  end if;
  delete from public.coach_availability_rules where coach_id = uid;
  begin
    for x in select * from jsonb_array_elements(p_rules) loop
      if x ? 'listing_id' and x ->> 'listing_id' is not null
         and not exists (select 1 from public.coach_listings l where l.id = (x ->> 'listing_id')::uuid and l.coach_id = uid) then
        raise exception 'invalid_rule' using errcode = 'check_violation';
      end if;
      insert into public.coach_availability_rules (coach_id, weekday, start_local, end_local, listing_id, valid_from, valid_until)
      values (uid, (x ->> 'weekday')::smallint, (x ->> 'start')::time, (x ->> 'end')::time,
              (x ->> 'listing_id')::uuid, (x ->> 'valid_from')::date, (x ->> 'valid_until')::date);
      n := n + 1;
    end loop;
  exception when others then
    raise exception 'invalid_rule' using errcode = 'check_violation';
  end;
  return n;
end $$;
comment on function public.set_availability(jsonb) is
  'Migration 60: replaces the caller''s weekly windows: [{weekday 1-7 (ISO, Monday 1), start "HH:MM", end "HH:MM" (same day, after start), listing_id (optional), valid_from, valid_until}], local wall-clock times in the coach''s time zone, at most 50. Errors: coach_profile_required, invalid_rule.';

create or replace function public.add_availability_exception(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  uid  uuid := (select auth.uid());
  v_id uuid;
begin
  perform private.coach_require_profile(uid);
  if (select count(*) from public.coach_availability_exceptions e where e.coach_id = uid and e.ends_at > now()) >= 100 then
    raise exception 'too_many' using errcode = 'check_violation';
  end if;
  begin
    insert into public.coach_availability_exceptions (coach_id, kind, starts_at, ends_at, note)
    values (uid, p ->> 'kind', (p ->> 'starts_at')::timestamptz, (p ->> 'ends_at')::timestamptz,
            btrim(coalesce(p ->> 'note', '')))
    returning id into v_id;
  exception when others then
    raise exception 'invalid_range' using errcode = 'check_violation';
  end;
  return v_id;
end $$;

create or replace function public.remove_availability_exception(p_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  delete from public.coach_availability_exceptions where id = p_id and coach_id = uid;
  return found;
end $$;

create or replace function public.schedule_group_session(p_listing uuid, p_starts_at timestamptz)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  uid  uuid := (select auth.uid());
  l    public.coach_listings%rowtype;
  v_id uuid;
begin
  perform private.coach_raise(private.coach_member_error(uid));
  select * into l from public.coach_listings where id = p_listing and coach_id = uid;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if l.format <> 'group' then
    raise exception 'not_group' using errcode = 'check_violation';
  end if;
  if l.status <> 'active' or l.moderation_state is not null then
    raise exception 'invalid_state' using errcode = 'check_violation';
  end if;
  if p_starts_at is null or p_starts_at <= now() or p_starts_at > now() + interval '180 days' then
    raise exception 'invalid_range' using errcode = 'check_violation';
  end if;
  begin
    insert into public.coach_sessions (coach_id, listing_id, starts_at, ends_at, busy, capacity)
    values (uid, l.id, p_starts_at, p_starts_at + make_interval(mins => l.duration_minutes::integer),
            tstzrange(p_starts_at, p_starts_at, '[]'), l.capacity)
    returning id into v_id;
  exception when exclusion_violation then
    raise exception 'slot_taken' using errcode = 'check_violation';
  end;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 7. The booking state machine (design section 3.6)
-- ---------------------------------------------------------------------------
-- A booking report for moderators. p_reporter null is an automatic one (at most one open).
create or replace function private.booking_report(p_booking uuid, p_reporter uuid, p_target uuid, p_reason text,
                                                  p_note text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  if p_reporter is null then
    select r.id into v_id from public.reports r
     where r.target_kind = 'booking' and r.target_id = p_booking and r.status = 'open' and r.reporter_id is null
       and r.reason = p_reason;
    if v_id is not null then
      return v_id;
    end if;
  end if;
  insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, note, priority, due_at)
  values (p_reporter, 'booking', p_booking, p_target, p_reason, left(coalesce(p_note, ''), 1000), 2,
          now() + interval '24 hours')
  on conflict do nothing
  returning id into v_id;
  return v_id;
end $$;

-- Cancels a requested or confirmed booking (no actor check: callers decide who may). p_refund is
-- 'policy' (a client cancellation now), 'full' or 'none'; a paid booking queues the refund job,
-- an open checkout is expired. Frees a one-on-one session. Returns false when nothing changed.
create or replace function private.booking_cancel(p_id uuid, p_by text, p_reason text, p_refund text,
                                                  p_notify boolean default true)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  b       public.bookings%rowtype;
  bp      public.booking_payments%rowtype;
  v_state public.booking_payment_state;
  v_amt   integer := 0;
  v_job   boolean := false;
begin
  select * into b from public.bookings where id = p_id for update;
  if not found or b.status not in ('requested', 'confirmed') then
    return false;
  end if;
  v_state := b.payment_state;
  if b.payment_mode = 'stripe' then
    select * into bp from public.booking_payments where booking_id = b.id for update;
    if b.payment_state = 'paid' then
      v_amt := private.booking_refund_minor(bp.amount_minor, p_refund, b.free_cancel_until, now());
      if v_amt > 0 then
        insert into public.stripe_jobs (booking_id, op, amount_minor, idempotency_key)
        values (b.id, 'refund', v_amt, 'refund:' || b.id::text || ':cancel')
        on conflict (idempotency_key) do nothing;
        update public.booking_payments set refund_requested_minor = v_amt, updated_at = now() where booking_id = b.id;
        v_state := 'refund_pending';
        v_job := true;
      end if;
    elsif b.payment_state = 'processing' then
      if bp.checkout_session_id is not null then
        insert into public.stripe_jobs (booking_id, op, idempotency_key)
        values (b.id, 'expire_checkout', 'expire:' || bp.checkout_session_id)
        on conflict (idempotency_key) do nothing;
        v_job := true;
      end if;
      v_state := 'none';
    elsif b.payment_state = 'due' then
      v_state := 'none';
    end if;
  end if;
  update public.bookings
     set status = 'cancelled', cancelled_at = now(), cancelled_by = p_by, cancel_reason = p_reason,
         payment_state = v_state
   where id = b.id;
  if b.format = 'one_on_one' and b.session_id is not null then
    update public.coach_sessions set status = 'cancelled', cancelled_at = now()
     where id = b.session_id and status = 'scheduled';
  end if;
  if p_notify then
    if p_by <> 'coach' then
      perform private.booking_notify(b.id, b.coach_id, 'booking_cancelled', jsonb_build_object('reason', p_reason));
    end if;
    if p_by <> 'client' then
      perform private.booking_notify(b.id, b.client_id, 'booking_cancelled',
                                     jsonb_build_object('reason', p_reason, 'refund_minor', v_amt));
    end if;
  end if;
  if v_job then
    perform public.stripe_dispatch();
  end if;
  return true;
end $$;

-- Declines a request (the coach, a block, a taken slot). Returns false when it was not requested.
create or replace function private.booking_decline(p_id uuid, p_reason text, p_notify boolean default true)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings%rowtype;
begin
  select * into b from public.bookings where id = p_id for update;
  if not found or b.status <> 'requested' then
    return false;
  end if;
  update public.bookings set status = 'declined', declined_at = now(), cancel_reason = p_reason where id = b.id;
  if p_notify then
    perform private.booking_notify(b.id, b.client_id, 'booking_declined',
                                   jsonb_build_object('reason', coalesce(p_reason, 'declined')));
  end if;
  return true;
end $$;

-- Confirms a request: a one-on-one booking gets its own session (the exclusion constraint refuses
-- an overlap: slot_taken) and the coach's other requests that overlap it are declined
-- (slot_taken); a group booking takes its seat. Payment due starts for in-app payments.
create or replace function private.booking_confirm(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  b       public.bookings%rowtype;
  l       public.coach_listings%rowtype;
  v_sess  uuid;
  v_pay   timestamptz;
  v_other uuid;
begin
  select * into b from public.bookings where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if b.status <> 'requested' then
    raise exception 'invalid_state' using errcode = 'check_violation';
  end if;
  if now() >= b.expires_at or now() >= b.starts_at then
    raise exception 'expired' using errcode = 'check_violation';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('booking_client:' || b.client_id::text));
  if exists (select 1 from public.bookings x
              where x.client_id = b.client_id and x.id <> b.id and x.status = 'confirmed'
                and x.starts_at < b.ends_at and x.ends_at > b.starts_at) then
    raise exception 'client_overlap' using errcode = 'check_violation';
  end if;
  select * into l from public.coach_listings where id = b.listing_id;
  if b.format = 'one_on_one' then
    if l.id is null then
      raise exception 'invalid_state' using errcode = 'check_violation';
    end if;
    begin
      insert into public.coach_sessions (coach_id, listing_id, starts_at, ends_at, busy, capacity)
      values (b.coach_id, l.id, b.starts_at, b.ends_at, tstzrange(b.starts_at, b.ends_at, '[)'), 1)
      returning id into v_sess;
    exception when exclusion_violation then
      raise exception 'slot_taken' using errcode = 'check_violation';
    end;
  else
    v_sess := b.session_id;
    if v_sess is null or not exists (select 1 from public.coach_sessions s where s.id = v_sess and s.status = 'scheduled') then
      raise exception 'invalid_state' using errcode = 'check_violation';
    end if;
    if (select count(*) from public.bookings x where x.session_id = v_sess and x.status = 'confirmed')
       >= (select s.capacity from public.coach_sessions s where s.id = v_sess) then
      raise exception 'full' using errcode = 'check_violation';
    end if;
  end if;
  if b.payment_mode = 'stripe' then
    v_pay := least(now() + interval '24 hours', b.starts_at - interval '2 hours');
    if v_pay <= now() then
      v_pay := least(now() + interval '1 hour', b.starts_at);
    end if;
  end if;
  update public.bookings
     set status = 'confirmed', confirmed_at = now(), session_id = v_sess, pay_by = v_pay,
         payment_state = case when payment_mode = 'stripe' then 'due'::public.booking_payment_state else payment_state end
   where id = b.id;
  insert into public.booking_private (booking_id, meeting_note, online_link)
  select b.id, coalesce(lp.meeting_note, ''), lp.online_link
    from (select 1) one left join public.coach_listing_private lp on lp.listing_id = b.listing_id
  on conflict (booking_id) do nothing;
  -- Requests do not hold time: the coach's other one-on-one requests that overlap are declined.
  if b.format = 'one_on_one' then
    for v_other in
      select x.id from public.bookings x
        join public.coach_sessions s on s.id = v_sess
       where x.coach_id = b.coach_id and x.id <> b.id and x.status = 'requested' and x.format = 'one_on_one'
         and tstzrange(x.starts_at, x.ends_at, '[)') && s.busy
    loop
      perform private.booking_decline(v_other, 'slot_taken', true);
    end loop;
  end if;
  perform private.booking_notify(b.id, b.client_id, 'booking_confirmed');
  if b.payment_mode = 'stripe' then
    perform private.booking_notify(b.id, b.client_id, 'booking_payment_due',
                                   jsonb_build_object('pay_by', v_pay, 'price_minor', b.price_minor,
                                                      'currency', b.currency));
  end if;
end $$;

create or replace function public.request_booking(p_listing uuid, p_starts_at timestamptz, p_note text,
                                                  p_policy_version text, p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  l         public.coach_listings%rowtype;
  b         public.bookings%rowtype;
  v_tz      text;
  v_day     date;
  v_found   boolean;
  v_end     timestamptz;
  v_session uuid;
  v_mode    text;
  v_state   public.booking_payment_state;
  v_fee     integer := 0;
  v_expires timestamptz;
  v_note    text := btrim(coalesce(p_note, ''));
  v_id      uuid;
begin
  perform private.coach_raise(private.coach_member_error(uid));
  if p_client_request_id is null or p_listing is null or p_starts_at is null then
    raise exception 'invalid_request' using errcode = 'check_violation';
  end if;
  -- Idempotent: a retry with the same client request id returns the stored booking.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('booking_req:' || uid::text || ':' || p_client_request_id::text));
  select * into b from public.bookings where client_id = uid and client_request_id = p_client_request_id;
  if found then
    return jsonb_build_object('id', b.id, 'status', b.status, 'payment_mode', b.payment_mode, 'duplicate', true);
  end if;
  if p_policy_version is null or p_policy_version <> private.refund_policy_version() then
    raise exception 'policy_ack_required' using errcode = 'check_violation';
  end if;
  select * into l from public.coach_listings where id = p_listing;
  if not found or not private.coach_listing_visible(p_listing) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if l.coach_id = uid then
    raise exception 'cannot_book_self' using errcode = 'check_violation';
  end if;
  if char_length(v_note) > 500 or not private.coach_text_ok(v_note) then
    raise exception 'invalid_text' using errcode = 'check_violation';
  end if;

  -- The message-request limits (a request opens a DM): 10 a day, 5 open, one open per listing.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('booking_requests:' || uid::text));
  if (select count(*) from public.bookings x where x.client_id = uid and x.requested_at > now() - interval '1 day') >= 10 then
    raise exception 'rate_limited' using errcode = 'check_violation', hint = '86400';
  end if;
  if (select count(*) from public.bookings x where x.client_id = uid and x.status = 'requested') >= 5
     or exists (select 1 from public.bookings x where x.client_id = uid and x.listing_id = l.id and x.status = 'requested') then
    raise exception 'too_many_open' using errcode = 'check_violation';
  end if;

  -- The same function the client was shown (design section 4).
  select cp.timezone into v_tz from public.coach_profiles cp where cp.user_id = l.coach_id;
  v_day := (p_starts_at at time zone v_tz)::date;
  select true, s.ends_at, s.session_id into v_found, v_end, v_session
    from private.coach_open_slots(l.id, v_day, v_day) s
   where s.starts_at = p_starts_at
   limit 1;
  if not coalesce(v_found, false) then
    if l.format = 'group' and exists (select 1 from public.coach_sessions s
                                       where s.listing_id = l.id and s.status = 'scheduled' and s.starts_at = p_starts_at
                                         and s.starts_at > now()
                                         and s.capacity <= private.coach_session_seats(s.id)) then
      raise exception 'full' using errcode = 'check_violation';
    end if;
    raise exception 'slot_unavailable' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.bookings x
              where x.client_id = uid and x.status = 'confirmed'
                and x.starts_at < v_end and x.ends_at > p_starts_at) then
    raise exception 'client_overlap' using errcode = 'check_violation';
  end if;

  if l.price_minor = 0 then
    v_mode := 'none'; v_state := 'none';
  elsif private.coach_listing_payable(l.id) then
    v_mode := 'stripe'; v_state := 'none'; v_fee := private.coach_fee(l.price_minor, l.currency);
  else
    v_mode := 'off_platform'; v_state := 'off_platform';
  end if;
  v_expires := least(now() + interval '48 hours', p_starts_at - interval '2 hours');
  if v_expires <= now() then
    v_expires := p_starts_at;
  end if;

  begin
    insert into public.bookings (listing_id, session_id, coach_id, client_id, starts_at, ends_at, title, delivery,
                                 format, price_minor, currency, fee_minor, payment_mode, payment_state,
                                 policy_version, free_cancel_until, client_note, client_request_id, expires_at)
    values (l.id, v_session, l.coach_id, uid, p_starts_at, v_end, l.title, l.delivery, l.format, l.price_minor,
            l.currency, v_fee, v_mode, v_state, p_policy_version, p_starts_at - interval '24 hours', v_note,
            p_client_request_id, v_expires)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'client_overlap' using errcode = 'check_violation';
  end;
  perform private.booking_notify(v_id, l.coach_id, 'booking_requested');
  if l.auto_confirm then
    perform private.booking_confirm(v_id);
  end if;
  select * into b from public.bookings where id = v_id;
  return jsonb_build_object('id', b.id, 'status', b.status, 'payment_mode', b.payment_mode, 'duplicate', false);
end $$;
comment on function public.request_booking(uuid, timestamptz, text, text, uuid) is
  'Migration 60: the caller asks for p_starts_at on a listing. The start must be one coach_slots offers now (slot_unavailable; a group session with no seat left is full). Stores the snapshot (title, delivery, format, price, currency), the payment mode (none for free, stripe when payments are on and the listing is payable, else off_platform), the Refund Policy version acknowledged, free_cancel_until (start - 24 h) and expires_at (least(now + 48 h, start - 2 h), or the start when that is past). Idempotent on (caller, p_client_request_id). With auto_confirm it confirms at once. Message-request limits apply: 10 requests a day (rate_limited), 5 open and one open per listing (too_many_open). Errors: section 2 rules, invalid_request, policy_ack_required, not_found (also a block or over the viewer''s age), cannot_book_self, invalid_text, rate_limited, too_many_open, slot_unavailable, full, client_overlap.';

create or replace function private.booking_for_party(p_id uuid, p_role text)
returns public.bookings language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  b   public.bookings%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into b from public.bookings where id = p_id for update;
  if not found
     or (p_role = 'coach' and b.coach_id <> uid)
     or (p_role = 'client' and b.client_id <> uid)
     or (p_role = 'either' and uid not in (b.coach_id, b.client_id)) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  return b;
end $$;

create or replace function public.confirm_booking(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings%rowtype;
begin
  b := private.booking_for_party(p_id, 'coach');
  if public.users_blocked(b.coach_id, b.client_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.coach_profiles cp where cp.user_id = b.coach_id and cp.status = 'suspended')
     or exists (select 1 from public.profiles p where p.id = b.coach_id and p.status <> 'active') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform private.booking_confirm(p_id);
  return jsonb_build_object('id', p_id, 'status', 'confirmed');
end $$;

create or replace function public.decline_booking(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings%rowtype;
begin
  b := private.booking_for_party(p_id, 'coach');
  if not private.booking_decline(p_id, null, true) then
    raise exception 'invalid_state' using errcode = 'check_violation';
  end if;
  return jsonb_build_object('id', p_id, 'status', 'declined');
end $$;

create or replace function public.cancel_booking(p_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid   uuid := (select auth.uid());
  b     public.bookings%rowtype;
  v_by  text;
  v_amt integer;
begin
  b := private.booking_for_party(p_id, 'either');
  if b.status not in ('requested', 'confirmed') then
    raise exception 'invalid_state' using errcode = 'check_violation';
  end if;
  if now() >= b.starts_at then
    raise exception 'too_late' using errcode = 'check_violation';
  end if;
  v_by := case when uid = b.client_id then 'client' else 'coach' end;
  -- A coach answers a request by declining it.
  if v_by = 'coach' and b.status = 'requested' then
    perform private.booking_decline(b.id, null, true);
    return jsonb_build_object('id', b.id, 'status', 'declined', 'refund_minor', 0, 'currency', b.currency);
  end if;
  v_amt := private.booking_refund_minor(b.price_minor, case when v_by = 'client' then 'policy' else 'full' end,
                                        b.free_cancel_until, now());
  perform private.booking_cancel(b.id, v_by, v_by, case when v_by = 'client' then 'policy' else 'full' end, true);
  -- Three coach cancellations inside 24 hours of the start within 30 days open a report.
  if v_by = 'coach' and b.starts_at < now() + interval '24 hours'
     and (select count(*) from public.bookings x
           where x.coach_id = b.coach_id and x.status = 'cancelled' and x.cancelled_by = 'coach'
             and x.cancelled_at > now() - interval '30 days'
             and x.starts_at < x.cancelled_at + interval '24 hours') >= 3 then
    perform private.booking_report(b.id, null, b.coach_id, 'other', 'Three late cancellations by the coach in 30 days.');
  end if;
  return jsonb_build_object('id', b.id, 'status', 'cancelled',
                            'refund_minor', case when b.status = 'confirmed' then v_amt else 0 end,
                            'currency', b.currency);
end $$;
comment on function public.cancel_booking(uuid, text) is
  'Migration 60: the client or the coach cancels before the start (a coach''s cancel of a request declines it). Refund Policy 2026-12: a client cancellation at least 24 hours before the start refunds in full, later half; a coach cancellation refunds in full. A paid booking queues the refund (stripe_jobs); refund_minor is the policy amount (the expectation for off-platform bookings). Three coach cancellations inside 24 hours of the start within 30 days open a booking report. Errors: not_authenticated, not_found, invalid_state, too_late.';

create or replace function public.set_booking_meeting(p_id uuid, p_note text, p_link text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b      public.bookings%rowtype;
  v_link text := nullif(btrim(coalesce(p_link, '')), '');
  v_note text := btrim(coalesce(p_note, ''));
begin
  b := private.booking_for_party(p_id, 'coach');
  if b.status <> 'confirmed' then
    raise exception 'invalid_state' using errcode = 'check_violation';
  end if;
  if v_link is not null and v_link !~ '^https://[^\s]+$' then
    raise exception 'invalid_link' using errcode = 'check_violation';
  end if;
  if char_length(v_note) > 500 or not private.coach_text_ok(v_note) then
    raise exception 'invalid_text' using errcode = 'check_violation';
  end if;
  insert into public.booking_private (booking_id, meeting_note, online_link) values (b.id, v_note, v_link)
  on conflict (booking_id) do update set meeting_note = excluded.meeting_note, online_link = excluded.online_link;
  return jsonb_build_object('id', b.id);
end $$;

create or replace function public.complete_booking(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings%rowtype;
begin
  b := private.booking_for_party(p_id, 'coach');
  if b.status <> 'confirmed' then
    raise exception 'invalid_state' using errcode = 'check_violation';
  end if;
  if now() < b.ends_at then
    raise exception 'too_early' using errcode = 'check_violation';
  end if;
  update public.bookings set status = 'completed', completed_at = now() where id = b.id;
  if b.format = 'one_on_one' then
    update public.coach_sessions set status = 'done' where id = b.session_id and status = 'scheduled';
  end if;
  return jsonb_build_object('id', b.id, 'status', 'completed');
end $$;

-- A no-show: party 'client' (the coach marks it) or 'coach' (the client reports it), from 15
-- minutes after the start to 48 hours after the end.
create or replace function private.booking_no_show(p_id uuid, p_party text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings%rowtype;
begin
  b := private.booking_for_party(p_id, case when p_party = 'client' then 'coach' else 'client' end);
  if b.status <> 'confirmed' then
    raise exception 'invalid_state' using errcode = 'check_violation';
  end if;
  if now() < b.starts_at + interval '15 minutes' then
    raise exception 'too_early' using errcode = 'check_violation';
  end if;
  if now() > b.ends_at + interval '48 hours' then
    raise exception 'too_late' using errcode = 'check_violation';
  end if;
  update public.bookings set status = 'no_show', no_show_at = now(), no_show_party = p_party where id = b.id;
  perform private.booking_notify(b.id, case when p_party = 'client' then b.client_id else b.coach_id end,
                                 'booking_no_show', jsonb_build_object('party', p_party));
  return jsonb_build_object('id', b.id, 'status', 'no_show', 'party', p_party);
end $$;

create or replace function public.mark_no_show(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return private.booking_no_show(p_id, 'client');
end $$;

create or replace function public.report_coach_no_show(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return private.booking_no_show(p_id, 'coach');
end $$;

create or replace function public.contest_no_show(p_id uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid  uuid := (select auth.uid());
  b    public.bookings%rowtype;
  v_id uuid;
begin
  b := private.booking_for_party(p_id, 'either');
  if b.status <> 'no_show' or b.no_show_contested_at is not null or b.no_show_settled_at is not null
     or (b.no_show_party = 'client' and uid <> b.client_id) or (b.no_show_party = 'coach' and uid <> b.coach_id) then
    raise exception 'invalid_state' using errcode = 'check_violation';
  end if;
  if now() > b.no_show_at + interval '48 hours' then
    raise exception 'too_late' using errcode = 'check_violation';
  end if;
  update public.bookings set no_show_contested_at = now() where id = b.id;
  v_id := private.booking_report(b.id, uid, case when uid = b.client_id then b.coach_id else b.client_id end,
                                 'no_show', left(btrim(coalesce(p_note, '')), 1000));
  return jsonb_build_object('id', b.id, 'report_id', v_id);
end $$;

create or replace function public.cancel_group_session(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  s   public.coach_sessions%rowtype;
  v_b uuid;
  n   integer := 0;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into s from public.coach_sessions where id = p_id and coach_id = uid for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.coach_listings l where l.id = s.listing_id and l.format = 'group') then
    raise exception 'not_group' using errcode = 'check_violation';
  end if;
  if s.status <> 'scheduled' or s.starts_at <= now() then
    raise exception 'invalid_state' using errcode = 'check_violation';
  end if;
  for v_b in select b.id from public.bookings b where b.session_id = s.id and b.status in ('requested', 'confirmed') loop
    if private.booking_cancel(v_b, 'coach', 'coach', 'full', true) then
      n := n + 1;
    end if;
  end loop;
  update public.coach_sessions set status = 'cancelled', cancelled_at = now() where id = s.id;
  return jsonb_build_object('id', s.id, 'bookings_cancelled', n);
end $$;

-- ---------------------------------------------------------------------------
-- 8. Reviews (design section 3.8)
-- ---------------------------------------------------------------------------
create or replace function private.review_text_ok(p_text text)
returns boolean language sql stable security definer set search_path = '' as $$
  select not private.chat_has_link(coalesce(p_text, '')) and not private.chat_link_shortened(coalesce(p_text, ''))
     and private.coach_text_ok(p_text);
$$;

create or replace function public.write_review(p_booking uuid, p_rating integer, p_body text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b      public.bookings%rowtype;
  r      public.coach_reviews%rowtype;
  v_body text := btrim(coalesce(p_body, ''));
begin
  b := private.booking_for_party(p_booking, 'client');
  if public.users_blocked(b.coach_id, b.client_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if b.status <> 'completed' then
    raise exception 'not_completed' using errcode = 'check_violation';
  end if;
  if now() > b.completed_at + interval '30 days' then
    raise exception 'review_window_closed' using errcode = 'check_violation';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception 'invalid_rating' using errcode = 'check_violation';
  end if;
  if char_length(v_body) > 1000 or not private.review_text_ok(v_body) then
    raise exception 'review_filtered' using errcode = 'check_violation', hint = 'No links, and nothing from the blocked-words list.';
  end if;
  select * into r from public.coach_reviews where booking_id = b.id for update;
  if found then
    if r.created_at < now() - interval '7 days' then
      raise exception 'already_reviewed' using errcode = 'check_violation';
    end if;
    update public.coach_reviews set rating = p_rating, body = v_body, edited_at = now() where booking_id = b.id;
    return jsonb_build_object('booking_id', b.id, 'edited', true);
  end if;
  insert into public.coach_reviews (booking_id, coach_id, client_id, rating, body)
  values (b.id, b.coach_id, b.client_id, p_rating, v_body);
  perform private.booking_notify(b.id, b.coach_id, 'review_received', jsonb_build_object('rating', p_rating));
  return jsonb_build_object('booking_id', b.id, 'edited', false);
end $$;
comment on function public.write_review(uuid, integer, text) is
  'Migration 60: the client of a completed booking reviews it, from completed_at to 30 days later; one review per booking, editable for 7 days (a second call edits). No links, slur list refused. Errors: not_authenticated, not_found (also a block), not_completed (no-shows, cancellations and open bookings cannot be reviewed), review_window_closed, invalid_rating, review_filtered, already_reviewed.';

create or replace function public.reply_to_review(p_booking uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  r      public.coach_reviews%rowtype;
  v_text text := btrim(coalesce(p_text, ''));
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into r from public.coach_reviews where booking_id = p_booking and coach_id = uid for update;
  if not found or public.users_blocked(r.coach_id, r.client_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if char_length(v_text) not between 1 and 1000 or not private.review_text_ok(v_text) then
    raise exception 'review_filtered' using errcode = 'check_violation';
  end if;
  if r.reply is not null and r.replied_at < now() - interval '7 days' then
    raise exception 'reply_locked' using errcode = 'check_violation';
  end if;
  update public.coach_reviews set reply = v_text, replied_at = coalesce(replied_at, now()) where booking_id = r.booking_id;
  if r.reply is null then
    perform private.booking_notify(r.booking_id, r.client_id, 'review_reply');
  end if;
  return jsonb_build_object('booking_id', r.booking_id, 'edited', r.reply is not null);
end $$;

-- ---------------------------------------------------------------------------
-- 9. Reading
-- ---------------------------------------------------------------------------
create or replace function public.coaching_config()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'payments_enabled', private.coach_payments_on(),
    'policy_version', private.refund_policy_version(),
    'coach_terms_version', private.coach_terms_version(),
    'fee_percent', 12,
    'fee_minimums', coalesce((select jsonb_object_agg(m.currency, m.min_fee_minor) from public.coach_fee_minimums m),
                             '{}'::jsonb));
$$;

-- A review as the viewer may see it: the reply only when unmoderated (the two parties see their
-- own hidden rows, labelled).
create or replace function private.coach_review_json(p_booking uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
           'booking_id', r.booking_id, 'rating', r.rating, 'body', r.body, 'created_at', r.created_at,
           'edited_at', r.edited_at,
           'author', jsonb_build_object('user_id', a.id, 'handle', a.handle, 'first_name', a.first_name,
                                        'avatar_url', a.avatar_url),
           'reply', case when r.reply_moderation_state is null or (select auth.uid()) in (r.coach_id, r.client_id)
                         then r.reply end,
           'replied_at', r.replied_at,
           'moderation_state', case when (select auth.uid()) in (r.coach_id, r.client_id) then r.moderation_state end,
           'reply_moderation_state', case when (select auth.uid()) in (r.coach_id, r.client_id) then r.reply_moderation_state end,
           'mine', r.client_id = (select auth.uid()))
    from public.coach_reviews r
    join public.profiles a on a.id = r.client_id
   where r.booking_id = p_booking;
$$;

create or replace function public.coach_reviews_page(p_coach uuid, p_before jsonb default null, p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 50));
  v_at    timestamptz;
  v_id    uuid;
  v_items jsonb;
  v_last  record;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not private.coach_visible(p_coach) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  begin
    v_at := (p_before ->> 'created_at')::timestamptz;
    v_id := (p_before ->> 'booking_id')::uuid;
  exception when others then
    raise exception 'invalid_cursor' using errcode = 'check_violation';
  end;
  with page as (
    select r.booking_id, r.created_at from public.coach_reviews r
     where r.coach_id = p_coach
       and (r.moderation_state is null or uid in (r.coach_id, r.client_id))
       and (r.client_id = uid or not private.is_blocked_with(r.client_id))
       and (v_at is null or (r.created_at, r.booking_id) < (v_at, v_id))
     order by r.created_at desc, r.booking_id desc
     limit v_limit
  )
  select coalesce(jsonb_agg(private.coach_review_json(pg.booking_id) order by pg.created_at desc, pg.booking_id desc), '[]'::jsonb)
    into v_items from page pg;
  select x.created_at, x.booking_id into v_last from (
    select r.created_at, r.booking_id from public.coach_reviews r
     where r.booking_id in (select (e ->> 'booking_id')::uuid from jsonb_array_elements(v_items) e)
     order by r.created_at asc, r.booking_id asc limit 1) x;
  return jsonb_build_object('items', v_items,
                            'next', case when jsonb_array_length(v_items) = v_limit
                                         then jsonb_build_object('created_at', v_last.created_at, 'booking_id', v_last.booking_id) end);
end $$;

create or replace function public.get_coach(p_handle text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid  uuid := (select auth.uid());
  p    public.profiles%rowtype;
  cp   public.coach_profiles%rowtype;
  v_own boolean;
  v_age integer := (select public.viewer_age());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into p from public.profiles x where lower(x.handle) = lower(btrim(coalesce(p_handle, '')));
  if not found or not private.coach_visible(p.id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  select * into cp from public.coach_profiles where user_id = p.id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  v_own := p.id = uid;
  return jsonb_build_object(
    'user_id', p.id, 'handle', p.handle, 'first_name', p.first_name, 'avatar_url', p.avatar_url,
    'status', cp.status, 'own', v_own,
    'headline', cp.headline, 'about', cp.about, 'timezone', cp.timezone, 'area_label', cp.area_label,
    'in_person', cp.in_person, 'online', cp.online, 'service_radius_km', cp.service_radius_km,
    'rating_avg', cp.rating_avg, 'rating_count', cp.rating_count, 'completed_count', cp.completed_count,
    'published_at', cp.published_at,
    'terms_current', case when v_own then cp.terms_version is not distinct from private.coach_terms_version() end,
    'credentials', coalesce((select jsonb_agg(jsonb_build_object('title', c.title, 'issuer', c.issuer, 'year', c.year,
                                                                 'self_reported', true) order by c.position)
                               from public.coach_credentials c where c.coach_id = p.id), '[]'::jsonb),
    'photos', coalesce((select jsonb_agg(ph.url order by ph.position) from public.coach_photos ph where ph.coach_id = p.id),
                       '[]'::jsonb),
    'hubs', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'slug', h.slug, 'name', h.name, 'emoji', h.emoji)
                                       order by h.name)
                        from public.coach_hubs ch join public.hubs h on h.id = ch.hub_id
                       where ch.coach_id = p.id and h.is_active), '[]'::jsonb),
    'listings', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', l.id, 'title', l.title, 'description', l.description, 'delivery', l.delivery,
                  'format', l.format, 'capacity', l.capacity, 'duration_minutes', l.duration_minutes,
                  'price_minor', l.price_minor, 'currency', l.currency, 'min_age', l.min_age,
                  'hub_id', l.hub_id, 'auto_confirm', l.auto_confirm, 'status', l.status,
                  'min_notice_hours', l.min_notice_hours, 'max_advance_days', l.max_advance_days,
                  'moderation_state', case when v_own then l.moderation_state end,
                  'payable', private.coach_listing_payable(l.id)) order by l.price_minor, l.created_at)
                    from public.coach_listings l
                   where l.coach_id = p.id
                     and ((v_own and l.status <> 'archived')
                          or (l.status = 'active' and l.moderation_state is null and coalesce(v_age >= l.min_age, false)))),
                  '[]'::jsonb),
    'from_prices', coalesce((select jsonb_agg(jsonb_build_object('currency', x.currency, 'price_minor', x.price_minor)
                                              order by x.currency)
                               from (select l.currency, min(l.price_minor) as price_minor from public.coach_listings l
                                      where l.coach_id = p.id and l.status = 'active' and l.moderation_state is null
                                        and coalesce(v_age >= l.min_age, false)
                                      group by l.currency) x), '[]'::jsonb),
    'reviews', public.coach_reviews_page(p.id, null, 10),
    'payments_enabled', private.coach_payments_on());
end $$;
comment on function public.get_coach(text) is
  'Migration 60: a coach''s public page for an adult viewer (the coach also sees their own draft or paused profile): profile (never the service point), credentials each with self_reported true, photos, hubs, active listings within the viewer''s age with payable per listing, the lowest price per currency, ratings and the first page of reviews. Errors: not_authenticated, not_found (also across a block).';

-- Search and browse (design section 5): the feed's origin chain and distance bands, never a
-- distance or a coordinate.
create or replace function public.search_coaches(
  p_lat double precision default null, p_lng double precision default null, p_radius_km integer default null,
  p_hub_id uuid default null, p_delivery public.listing_delivery default null, p_query text default null,
  p_max_price_minor integer default null, p_currency text default null, p_before jsonb default null,
  p_limit integer default 20)
returns table (user_id uuid, handle text, first_name text, avatar_url text, headline text, area_label text,
               distance_band text, in_person boolean, online boolean, rating_avg numeric, rating_count integer,
               completed_count integer, from_price_minor integer, from_currency text, hub_ids uuid[], page_key jsonb)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid        uuid := (select auth.uid());
  v_origin   extensions.geography;
  v_radius_m double precision;
  v_limit    integer := greatest(1, least(coalesce(p_limit, 20), 50));
  v_q        text := nullif(lower(btrim(coalesce(p_query, ''))), '');
  v_cur      text := nullif(lower(btrim(coalesce(p_currency, ''))), '');
  v_age      integer := (select public.viewer_age());
  c1 integer; c2 integer; c3 integer; c4 numeric; c5 numeric; c6 uuid;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.viewer_is_adult() then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if (p_lat is null) <> (p_lng is null)
     or (p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180)) then
    raise exception 'invalid_coordinates' using errcode = 'check_violation';
  end if;
  if p_before is not null then
    begin
      c1 := (p_before ->> 'k1')::integer; c2 := (p_before ->> 'k2')::integer; c3 := (p_before ->> 'k3')::integer;
      c4 := (p_before ->> 'k4')::numeric; c5 := (p_before ->> 'k5')::numeric; c6 := (p_before ->> 'id')::uuid;
    exception when others then
      raise exception 'invalid_cursor' using errcode = 'check_violation';
    end;
  end if;
  v_origin := coalesce(
    case when p_lat is not null then
      extensions.ST_SetSRID(extensions.ST_MakePoint(round(p_lng::numeric, 2)::double precision,
                                                    round(p_lat::numeric, 2)::double precision), 4326)::extensions.geography
    end,
    (select pp.home_point from public.profile_private pp where pp.user_id = uid),
    (select a.center from public.profile_private pp join public.areas a on a.id = pp.home_area_id where pp.user_id = uid),
    (select a.center from public.areas a where a.slug = 'atlanta'));
  v_radius_m := 1000.0 * greatest(1, least(50, coalesce(
    p_radius_km,
    (select pp.feed_radius_km::integer from public.profile_private pp where pp.user_id = uid),
    (select a.default_radius_km::integer from public.profile_private pp join public.areas a on a.id = pp.home_area_id where pp.user_id = uid),
    (select a.default_radius_km::integer from public.areas a where a.slug = 'atlanta'),
    10)));

  return query
  with ls as (
    select l.coach_id, l.delivery, l.price_minor, l.currency::text as currency, l.hub_id, l.title
      from public.coach_listings l
     where l.status = 'active' and l.moderation_state is null and l.min_age <= coalesce(v_age, 0)
  ), c as (
    select cp.user_id as uid_, p.handle as h, p.first_name as fn, p.avatar_url as av, cp.headline as hl,
           cp.area_label as al, cp.in_person as ip, cp.online as ol, cp.rating_avg as ra, cp.rating_count as rc,
           cp.completed_count as cc, coalesce(cp.published_at, cp.created_at) as pub,
           case when cp.in_person and cp.service_point is not null and v_origin is not null
                then extensions.ST_Distance(cp.service_point, v_origin) end as dist,
           cp.service_radius_km as srk,
           exists (select 1 from ls where ls.coach_id = cp.user_id and ls.delivery = 'in_person') as has_ip,
           exists (select 1 from ls where ls.coach_id = cp.user_id and ls.delivery = 'online') as has_ol
      from public.coach_profiles cp
      join public.profiles p on p.id = cp.user_id
     where cp.status = 'active'
       and private.chat_user_ok(cp.user_id)
       and not private.is_blocked_with(cp.user_id)
  ), m as (
    select c.*,
           (c.has_ip and c.ip and c.dist is not null and c.dist <= c.srk * 1000.0 and c.dist <= v_radius_m
            and coalesce(p_delivery::text, 'in_person') = 'in_person') as ip_ok,
           (c.has_ol and c.ol and coalesce(p_delivery::text, 'online') = 'online') as ol_ok,
           (p_hub_id is not null and (exists (select 1 from public.coach_hubs ch where ch.coach_id = c.uid_ and ch.hub_id = p_hub_id)
                                      or exists (select 1 from ls where ls.coach_id = c.uid_ and ls.hub_id = p_hub_id))) as hub_match
      from c
  ), f as (
    select m.*,
           case when not m.ip_ok then 'online'
                when m.dist < 1609.344 then '<1 mi'
                when m.dist < 8046.72 then '1-5 mi'
                when m.dist < 16093.44 then '5-10 mi'
                when m.dist < 40233.6 then '10-25 mi'
                else '25+ mi' end as band
      from m
     where (m.ip_ok or m.ol_ok)
       and (p_hub_id is null or m.hub_match)
       and (v_q is null
            or lower(m.hl) like '%' || v_q || '%'
            or extensions.word_similarity(v_q, lower(m.hl)) >= 0.4
            or exists (select 1 from ls where ls.coach_id = m.uid_
                         and (lower(ls.title) like '%' || v_q || '%' or extensions.word_similarity(v_q, lower(ls.title)) >= 0.4))
            or exists (select 1 from public.coach_hubs ch join public.hubs h on h.id = ch.hub_id
                        where ch.coach_id = m.uid_ and (h.search_text like '%' || v_q || '%'
                                                         or extensions.word_similarity(v_q, h.search_text) >= 0.4)))
       and (p_max_price_minor is null
            or exists (select 1 from ls where ls.coach_id = m.uid_ and ls.price_minor <= p_max_price_minor
                         and (v_cur is null or ls.currency = v_cur)))
  ), k as (
    select f.*,
           case when f.hub_match then 0 else 1 end as k1,
           case f.band when '<1 mi' then 1 when '1-5 mi' then 2 when '5-10 mi' then 3 when '10-25 mi' then 4
                       when '25+ mi' then 5 else 6 end as k2,
           case when f.rc >= 3 then 0 else 1 end as k3,
           (-coalesce(f.ra, 0))::numeric as k4,
           (-extract(epoch from f.pub))::numeric as k5
      from f
  )
  select k.uid_, k.h, k.fn, k.av, k.hl, k.al, k.band, k.ip, k.ol, k.ra, k.rc, k.cc,
         fp.price_minor, fp.currency,
         array(select x.hub_id from (select ch.hub_id from public.coach_hubs ch where ch.coach_id = k.uid_
                                     union select ls.hub_id from ls where ls.coach_id = k.uid_ and ls.hub_id is not null) x
                order by x.hub_id limit 3),
         jsonb_build_object('k1', k.k1, 'k2', k.k2, 'k3', k.k3, 'k4', k.k4, 'k5', k.k5, 'id', k.uid_)
    from k
    left join lateral (select ls.price_minor, ls.currency from ls where ls.coach_id = k.uid_
                        order by (ls.currency = coalesce(v_cur, ls.currency)) desc, ls.price_minor, ls.currency
                        limit 1) fp on true
   where p_before is null or (k.k1, k.k2, k.k3, k.k4, k.k5, k.uid_) > (c1, c2, c3, c4, c5, c6)
   order by k.k1, k.k2, k.k3, k.k4, k.k5, k.uid_
   limit v_limit;
end $$;
comment on function public.search_coaches(double precision, double precision, integer, uuid, public.listing_delivery, text, integer, text, jsonb, integer) is
  'Migration 60 (design section 5): active coaches with an active, unmoderated listing within the viewer''s age, no block either way. Origin as the feed (device point rounded to 0.01 degree, else home point, else home area, else Atlanta), radius p_radius_km (else the saved feed radius, else the area default; capped at 50 km). In person: the origin is inside the coach''s own radius and the coach inside the viewer''s; band <1 mi, 1-5 mi, 5-10 mi, 10-25 mi, 25+ mi. Online: from anywhere, band online. p_hub_id keeps coaches with that hub or an active listing in it; p_query matches headline, listing titles and hub names; p_max_price_minor (in p_currency when given). Order: hub match, band, rating_count >= 3 first, rating, published; page_key is the keyset for p_before. Never returns a distance or a coordinate. Errors: not_authenticated, onboarding_required, invalid_coordinates, invalid_cursor.';

-- The booking as one of its parties sees it.
create or replace function private.booking_json(p_id uuid, p_full boolean)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid   uuid := (select auth.uid());
  b     public.bookings%rowtype;
  o     public.profiles%rowtype;
  bp    public.booking_payments%rowtype;
  pr    public.booking_private%rowtype;
  v_role text;
  v_out jsonb;
  v_rev boolean;
  v_rev_at timestamptz;
begin
  select * into b from public.bookings where id = p_id;
  if not found or uid not in (b.coach_id, b.client_id) then
    return null;
  end if;
  v_role := case when uid = b.coach_id then 'coach' else 'client' end;
  select * into o from public.profiles where id = case when v_role = 'coach' then b.client_id else b.coach_id end;
  v_out := jsonb_build_object(
    'id', b.id, 'role', v_role, 'listing_id', b.listing_id, 'status', b.status,
    'title', b.title, 'delivery', b.delivery, 'format', b.format, 'starts_at', b.starts_at, 'ends_at', b.ends_at,
    'price_minor', b.price_minor, 'currency', b.currency, 'payment_mode', b.payment_mode,
    'payment_state', b.payment_state, 'pay_by', b.pay_by,
    'other', jsonb_build_object('user_id', o.id, 'handle', o.handle, 'first_name', o.first_name,
                                'avatar_url', case when public.users_blocked(b.coach_id, b.client_id) then null else o.avatar_url end),
    'coach_timezone', (select cp.timezone from public.coach_profiles cp where cp.user_id = b.coach_id),
    'requested_at', b.requested_at, 'expires_at', b.expires_at, 'confirmed_at', b.confirmed_at,
    'declined_at', b.declined_at, 'expired_at', b.expired_at, 'paid_at', b.paid_at,
    'cancelled_at', b.cancelled_at, 'cancelled_by', b.cancelled_by, 'cancel_reason', b.cancel_reason,
    'completed_at', b.completed_at, 'no_show_at', b.no_show_at, 'no_show_party', b.no_show_party,
    'no_show_contested_at', b.no_show_contested_at, 'free_cancel_until', b.free_cancel_until,
    'policy_version', b.policy_version);
  if not p_full then
    return v_out;
  end if;
  select * into bp from public.booking_payments where booking_id = b.id;
  select * into pr from public.booking_private where booking_id = b.id;
  select true, r.created_at into v_rev, v_rev_at from public.coach_reviews r where r.booking_id = b.id;
  return v_out || jsonb_build_object(
    'client_note', b.client_note,
    'fee_minor', case when b.payment_mode = 'stripe' then b.fee_minor end,
    'refunded_minor', coalesce(bp.refunded_minor, 0),
    'refund_if_cancelled_now', case when b.status = 'confirmed' and now() < b.starts_at then
                                 private.booking_refund_minor(b.price_minor,
                                   case when v_role = 'client' then 'policy' else 'full' end, b.free_cancel_until, now()) end,
    'meeting_note', case when b.status = 'confirmed' then pr.meeting_note end,
    'online_link', case when b.status = 'confirmed' then pr.online_link end,
    'review', private.coach_review_json(b.id),
    'can_confirm', v_role = 'coach' and b.status = 'requested' and now() < b.expires_at and now() < b.starts_at,
    'can_decline', v_role = 'coach' and b.status = 'requested',
    'can_cancel', b.status in ('requested', 'confirmed') and now() < b.starts_at,
    'can_complete', v_role = 'coach' and b.status = 'confirmed' and now() >= b.ends_at,
    'can_mark_no_show', v_role = 'coach' and b.status = 'confirmed'
                        and now() between b.starts_at + interval '15 minutes' and b.ends_at + interval '48 hours',
    'can_report_no_show', v_role = 'client' and b.status = 'confirmed'
                          and now() between b.starts_at + interval '15 minutes' and b.ends_at + interval '48 hours',
    'can_contest', b.status = 'no_show' and b.no_show_contested_at is null and b.no_show_settled_at is null
                   and b.no_show_party = v_role and now() <= b.no_show_at + interval '48 hours',
    'can_review', v_role = 'client' and b.status = 'completed' and now() <= b.completed_at + interval '30 days'
                  and (v_rev is null or v_rev_at >= now() - interval '7 days')
                  and not public.users_blocked(b.coach_id, b.client_id),
    'can_set_meeting', v_role = 'coach' and b.status = 'confirmed',
    'can_pay', v_role = 'client' and b.payment_mode = 'stripe' and b.status = 'confirmed'
               and b.payment_state = 'due' and now() < b.pay_by and private.coach_payments_on(),
    'can_message', not public.users_blocked(b.coach_id, b.client_id));
end $$;

create or replace function public.get_booking(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v jsonb;
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  v := private.booking_json(p_id, true);
  if v is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  return v;
end $$;
comment on function public.get_booking(uuid) is
  'Migration 60: a booking for either party: the other person, times and every state timestamp, price, payment_mode and payment_state, the refund so far and the refund a cancellation now would give, the meeting note and call link (confirmed only), the review, and can_* flags. Errors: not_authenticated, not_found.';

create or replace function public.my_bookings(p_role text, p_scope text, p_before jsonb default null,
                                              p_limit integer default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_limit integer := greatest(1, least(coalesce(p_limit, 30), 100));
  v_at    timestamptz;
  v_id    uuid;
  v_items jsonb;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_role is null or p_role not in ('client', 'coach') or p_scope is null or p_scope not in ('upcoming', 'requests', 'past') then
    raise exception 'invalid_scope' using errcode = 'check_violation';
  end if;
  begin
    v_at := (p_before ->> 'starts_at')::timestamptz;
    v_id := (p_before ->> 'id')::uuid;
  exception when others then
    raise exception 'invalid_cursor' using errcode = 'check_violation';
  end;
  with base as (
    select b.id, b.starts_at from public.bookings b
     where ((p_role = 'client' and b.client_id = uid) or (p_role = 'coach' and b.coach_id = uid))
       and case p_scope
             when 'requests' then b.status = 'requested'
             when 'upcoming' then b.status = 'confirmed' and b.ends_at >= now()
             else b.status not in ('requested') and not (b.status = 'confirmed' and b.ends_at >= now()) end
  ), page as (
    select * from base
     where v_at is null
        or (p_scope <> 'past' and (base.starts_at, base.id) > (v_at, v_id))
        or (p_scope = 'past' and (base.starts_at, base.id) < (v_at, v_id))
     order by case when p_scope = 'past' then null else base.starts_at end asc,
              case when p_scope = 'past' then base.starts_at end desc,
              case when p_scope = 'past' then null else base.id end asc,
              case when p_scope = 'past' then base.id end desc
     limit v_limit
  )
  select coalesce(jsonb_agg(private.booking_json(pg.id, false)
                            order by case when p_scope = 'past' then null else pg.starts_at end asc,
                                     case when p_scope = 'past' then pg.starts_at end desc,
                                     case when p_scope = 'past' then null else pg.id end asc,
                                     case when p_scope = 'past' then pg.id end desc), '[]'::jsonb)
    into v_items from page pg;
  return jsonb_build_object('items', v_items,
                            'next', case when jsonb_array_length(v_items) = v_limit then
                                      jsonb_build_object('starts_at', v_items -> -1 ->> 'starts_at',
                                                         'id', v_items -> -1 ->> 'id') end);
end $$;

create or replace function public.my_bookings_with(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid  uuid := (select auth.uid());
  v_id uuid;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_user is null or public.users_blocked(uid, p_user) then
    return null;
  end if;
  select b.id into v_id from public.bookings b
   where ((b.coach_id = uid and b.client_id = p_user) or (b.client_id = uid and b.coach_id = p_user))
     and b.status in ('requested', 'confirmed') and b.ends_at > now()
   order by b.starts_at, b.id
   limit 1;
  return case when v_id is not null then private.booking_json(v_id, false) end;
end $$;

create or replace function public.coach_payout_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  a   public.coach_stripe_accounts%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into a from public.coach_stripe_accounts where coach_id = uid;
  return jsonb_build_object(
    'payments_enabled', private.coach_payments_on(),
    'state', case when a.coach_id is null then 'none'
                  when a.charges_enabled and a.payouts_enabled then 'active'
                  when a.details_submitted then 'restricted'
                  else 'onboarding' end,
    'requirements_due', coalesce(cardinality(a.requirements_due), 0),
    'default_currency', a.default_currency,
    'country', a.country);
end $$;

-- ---------------------------------------------------------------------------
-- 10. Payments: service role only (design section 9). No Stripe call is made from SQL; the
--     database queues stripe_jobs and asks stripe-checkout to run them through pg_net.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('vault.secrets') is null then
    raise notice 'supabase_vault is not installed; stripe_dispatch_secret not created';
  elsif not exists (select 1 from vault.secrets where name = 'stripe_dispatch_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'stripe_dispatch_secret',
                                'Shared secret between the database and the stripe-checkout Edge Function (migration 60)');
  end if;
end $$;

create or replace function public.stripe_dispatch_verify_secret(p_secret text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_secret text;
begin
  if p_secret is null or char_length(p_secret) < 32 or to_regclass('vault.decrypted_secrets') is null then
    return false;
  end if;
  select ds.decrypted_secret into v_secret
    from vault.decrypted_secrets ds where ds.name = 'stripe_dispatch_secret' limit 1;
  return v_secret is not null and v_secret = p_secret;
end $$;
comment on function public.stripe_dispatch_verify_secret(text) is
  'Migration 60: true when p_secret is the vault secret stripe_dispatch_secret (generated in the database). Service role only; used by the stripe-checkout Edge Function for {op: job}.';

-- Asks stripe-checkout to run due jobs (after the transaction commits; never on rollback). Only
-- while payments are on and something is due. Returns the pg_net request id or null.
create or replace function public.stripe_dispatch()
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_base   text := public.project_url();
  v_secret text;
begin
  if not private.coach_payments_on()
     or not exists (select 1 from public.stripe_jobs j where j.status = 'pending' and j.next_at <= now() + interval '1 minute') then
    return null;
  end if;
  if v_base is null then
    return null;
  end if;
  if to_regclass('vault.decrypted_secrets') is not null then
    select ds.decrypted_secret into v_secret
      from vault.decrypted_secrets ds where ds.name = 'stripe_dispatch_secret' limit 1;
  end if;
  if v_secret is null or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    return null;
  end if;
  return net.http_post(
    url := v_base || '/functions/v1/stripe-checkout',
    body := jsonb_build_object('op', 'job'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-stripe-dispatch-secret', v_secret),
    timeout_milliseconds := 60000);
end $$;

-- What stripe-connect needs about the caller.
create or replace function public.stripe_connect_context(p_user uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'payments_enabled', private.coach_payments_on(),
    'is_coach', exists (select 1 from public.coach_profiles cp where cp.user_id = p_user and cp.status <> 'suspended'),
    'terms_ok', exists (select 1 from public.coach_profiles cp where cp.user_id = p_user
                                                                and cp.terms_version = private.coach_terms_version()),
    'account_ok', private.chat_user_ok(p_user),
    'email', (select pp.email from public.profile_private pp where pp.user_id = p_user),
    'account', (select jsonb_build_object('stripe_account_id', a.stripe_account_id, 'country', a.country,
                                          'charges_enabled', a.charges_enabled, 'payouts_enabled', a.payouts_enabled,
                                          'details_submitted', a.details_submitted)
                  from public.coach_stripe_accounts a where a.coach_id = p_user));
$$;

create or replace function private.stripe_account_apply(p_coach uuid, p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_due text[];
  v_old text[];
begin
  v_due := coalesce(array(select jsonb_array_elements_text(coalesce(p -> 'requirements_due', '[]'::jsonb))), '{}');
  select a.requirements_due into v_old from public.coach_stripe_accounts a where a.coach_id = p_coach;
  update public.coach_stripe_accounts a
     set country           = coalesce(upper(p ->> 'country'), a.country),
         default_currency  = coalesce(lower(p ->> 'default_currency'), a.default_currency),
         charges_enabled   = coalesce((p ->> 'charges_enabled')::boolean, a.charges_enabled),
         payouts_enabled   = coalesce((p ->> 'payouts_enabled')::boolean, a.payouts_enabled),
         details_submitted = coalesce((p ->> 'details_submitted')::boolean, a.details_submitted),
         requirements_due  = case when p ? 'requirements_due' then v_due else a.requirements_due end,
         disabled_reason   = case when p ? 'disabled_reason' then p ->> 'disabled_reason' else a.disabled_reason end,
         updated_at        = now()
   where a.coach_id = p_coach;
  -- Stripe needs something new from the coach: one notice a day.
  if p ? 'requirements_due' and cardinality(v_due) > 0 and not (v_due <@ coalesce(v_old, '{}')) then
    perform public.enqueue_notification(p_coach, 'coach_payout_action'::public.notification_kind,
                                        'coach_payout_action:' || p_coach::text || ':' || current_date::text,
                                        null, null, null, null,
                                        jsonb_build_object('requirements_due', cardinality(v_due)));
  end if;
end $$;

create or replace function public.stripe_account_upsert(p_coach uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if p_coach is null or p is null or coalesce(p ->> 'stripe_account_id', '') !~ '^acct_[A-Za-z0-9]+$' then
    raise exception 'invalid_account' using errcode = 'check_violation';
  end if;
  insert into public.coach_stripe_accounts (coach_id, stripe_account_id, country)
  values (p_coach, p ->> 'stripe_account_id', upper(coalesce(p ->> 'country', 'US')))
  on conflict (coach_id) do nothing;
  if (select a.stripe_account_id from public.coach_stripe_accounts a where a.coach_id = p_coach) <> p ->> 'stripe_account_id' then
    raise exception 'account_mismatch' using errcode = 'check_violation';
  end if;
  perform private.stripe_account_apply(p_coach, p);
  return jsonb_build_object('coach_id', p_coach, 'stripe_account_id', p ->> 'stripe_account_id');
end $$;

-- From the webhook: the account by its Stripe id. False when unknown.
create or replace function public.stripe_account_sync(p_account text, p jsonb)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_coach uuid;
begin
  select a.coach_id into v_coach from public.coach_stripe_accounts a where a.stripe_account_id = p_account;
  if v_coach is null then
    return false;
  end if;
  perform private.stripe_account_apply(v_coach, coalesce(p, '{}'::jsonb));
  return true;
end $$;

create or replace function public.stripe_account_closed(p_account text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v boolean;
begin
  delete from public.coach_stripe_accounts where stripe_account_id = p_account;
  v := found;
  update public.stripe_jobs set status = 'done', updated_at = now()
   where op = 'close_account' and stripe_account_id = p_account and status <> 'done';
  return v;
end $$;

create or replace function public.booking_checkout_params(p_booking uuid, p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  b public.bookings%rowtype;
  a public.coach_stripe_accounts%rowtype;
  n integer;
begin
  select * into b from public.bookings where id = p_booking;
  if not found or b.client_id is distinct from p_user or b.status <> 'confirmed' or b.payment_mode <> 'stripe'
     or b.payment_state not in ('due') or b.pay_by is null or now() >= b.pay_by
     or not private.coach_payments_on() then
    raise exception 'not_payable' using errcode = 'check_violation';
  end if;
  select * into a from public.coach_stripe_accounts where coach_id = b.coach_id;
  if not found or not a.charges_enabled then
    raise exception 'not_payable' using errcode = 'check_violation';
  end if;
  select coalesce(bp.checkout_attempts, 0) + 1 into n from (select 1) one
    left join public.booking_payments bp on bp.booking_id = b.id;
  return jsonb_build_object('booking_id', b.id, 'amount_minor', b.price_minor, 'fee_minor', b.fee_minor,
                            'currency', b.currency, 'stripe_account_id', a.stripe_account_id, 'title', b.title,
                            'pay_by', b.pay_by, 'attempt', n);
end $$;
comment on function public.booking_checkout_params(uuid, uuid) is
  'Migration 60, service role (stripe-checkout): what a Checkout Session for the booking needs, when p_user is its client, it is confirmed, its payment is due, pay_by has not passed, payments are on and the coach''s account takes charges. Errors: not_payable.';

create or replace function public.booking_checkout_opened(p_booking uuid, p_session_id text, p_amount integer,
                                                          p_fee integer, p_currency text, p_account text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings%rowtype;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found or b.payment_mode <> 'stripe' then
    raise exception 'not_payable' using errcode = 'check_violation';
  end if;
  insert into public.booking_payments (booking_id, checkout_session_id, amount_minor, fee_minor, currency,
                                       stripe_account_id, checkout_attempts)
  values (b.id, p_session_id, p_amount, p_fee, lower(p_currency), p_account, 1)
  on conflict (booking_id) do update
     set checkout_session_id = excluded.checkout_session_id, amount_minor = excluded.amount_minor,
         fee_minor = excluded.fee_minor, currency = excluded.currency, stripe_account_id = excluded.stripe_account_id,
         checkout_attempts = public.booking_payments.checkout_attempts + 1, updated_at = now();
  update public.bookings set payment_state = 'processing'
   where id = b.id and status = 'confirmed' and payment_state = 'due';
  return jsonb_build_object('booking_id', b.id, 'payment_state',
                            (select x.payment_state from public.bookings x where x.id = b.id));
end $$;

-- checkout.session.completed (paid). Idempotent. A booking that is no longer confirmed (cancelled
-- while the client was paying) gets a full refund queued at once.
create or replace function public.booking_mark_paid(p_booking uuid, p_session_id text, p_payment_intent text,
                                                    p_amount integer)
returns text language plpgsql security definer set search_path = '' as $$
declare
  b  public.bookings%rowtype;
  bp public.booking_payments%rowtype;
begin
  select * into bp from public.booking_payments
   where checkout_session_id = p_session_id or (p_booking is not null and booking_id = p_booking)
   order by (checkout_session_id = p_session_id) desc limit 1 for update;
  if not found then
    return 'unknown';
  end if;
  select * into b from public.bookings where id = bp.booking_id for update;
  if bp.payment_intent_id is not null and b.paid_at is not null then
    return 'already';
  end if;
  update public.booking_payments
     set payment_intent_id = p_payment_intent, checkout_session_id = coalesce(p_session_id, checkout_session_id),
         amount_minor = coalesce(p_amount, amount_minor), updated_at = now(),
         last_error = case when p_amount is not null and p_amount <> bp.amount_minor then 'amount_mismatch' else last_error end
   where booking_id = bp.booking_id;
  if b.status in ('confirmed', 'completed', 'no_show') and b.payment_mode = 'stripe' then
    update public.bookings set payment_state = 'paid', paid_at = now() where id = b.id;
    return 'paid';
  end if;
  update public.bookings set payment_state = 'refund_pending', paid_at = now() where id = b.id;
  insert into public.stripe_jobs (booking_id, op, amount_minor, idempotency_key)
  values (b.id, 'refund', coalesce(p_amount, bp.amount_minor), 'refund:' || b.id::text || ':late_payment')
  on conflict (idempotency_key) do nothing;
  update public.booking_payments set refund_requested_minor = coalesce(p_amount, bp.amount_minor) where booking_id = b.id;
  perform public.stripe_dispatch();
  return 'refund_queued';
end $$;

-- checkout.session.expired: back to due while pay_by has not passed (coaching_tick settles the rest).
create or replace function public.booking_payment_expired(p_session_id text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  select bp.booking_id into v_id from public.booking_payments bp where bp.checkout_session_id = p_session_id;
  if v_id is null then
    return 'unknown';
  end if;
  update public.bookings set payment_state = 'due'
   where id = v_id and status = 'confirmed' and payment_state = 'processing' and now() < pay_by;
  return case when found then 'due' else 'unchanged' end;
end $$;

-- charge.refunded: the total refunded so far (idempotent: never goes down).
create or replace function public.booking_refund_recorded(p_payment_intent text, p_refunded_minor integer)
returns text language plpgsql security definer set search_path = '' as $$
declare
  bp public.booking_payments%rowtype;
  v  integer;
begin
  select * into bp from public.booking_payments where payment_intent_id = p_payment_intent for update;
  if not found then
    return 'unknown';
  end if;
  v := greatest(bp.refunded_minor, coalesce(p_refunded_minor, 0));
  update public.booking_payments set refunded_minor = v, updated_at = now() where booking_id = bp.booking_id;
  update public.bookings
     set payment_state = case when v >= bp.amount_minor then 'refunded'::public.booking_payment_state
                              when v > 0 then 'partially_refunded'::public.booking_payment_state
                              else payment_state end
   where id = bp.booking_id and payment_state <> 'disputed';
  return case when v >= bp.amount_minor then 'refunded' when v > 0 then 'partially_refunded' else 'unchanged' end;
end $$;

-- charge.dispute.created / closed: disputed, an automatic booking report, the coach told.
create or replace function public.booking_dispute_update(p_payment_intent text, p_status text, p_closed boolean)
returns text language plpgsql security definer set search_path = '' as $$
declare
  bp public.booking_payments%rowtype;
  b  public.bookings%rowtype;
begin
  select * into bp from public.booking_payments where payment_intent_id = p_payment_intent for update;
  if not found then
    return 'unknown';
  end if;
  select * into b from public.bookings where id = bp.booking_id for update;
  update public.booking_payments
     set disputed_at = coalesce(disputed_at, now()), dispute_status = left(p_status, 40), updated_at = now()
   where booking_id = bp.booking_id;
  if coalesce(p_closed, false) then
    update public.bookings
       set payment_state = case when p_status = 'won' then 'paid'::public.booking_payment_state else payment_state end
     where id = b.id and payment_state = 'disputed';
    return 'closed';
  end if;
  update public.bookings set payment_state = 'disputed' where id = b.id;
  perform private.booking_report(b.id, null, b.coach_id, 'payment', 'Card dispute opened.');
  perform public.enqueue_notification(b.coach_id, 'coach_payout_action'::public.notification_kind,
                                      'coach_payout_action:dispute:' || b.id::text, null, null, null, null,
                                      jsonb_build_object('booking_id', b.id, 'reason', 'dispute', 'title', b.title));
  return 'disputed';
end $$;

-- Webhook ledger: 'new' (first delivery), 'retry' (seen, not finished) or 'done' (answer 200 now).
create or replace function public.stripe_event_begin(p_id text, p_type text, p_account text, p_object text,
                                                     p_livemode boolean)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_done timestamptz;
begin
  insert into public.stripe_events (id, type, account, object_id, livemode)
  values (p_id, left(p_type, 100), left(p_account, 100), left(p_object, 100), coalesce(p_livemode, false))
  on conflict (id) do nothing;
  if found then
    return 'new';
  end if;
  select e.processed_at into v_done from public.stripe_events e where e.id = p_id;
  return case when v_done is not null then 'done' else 'retry' end;
end $$;

create or replace function public.stripe_event_finish(p_id text, p_error text default null)
returns void language sql security definer set search_path = '' as $$
  update public.stripe_events
     set processed_at = case when p_error is null then now() else processed_at end,
         error = left(p_error, 300)
   where id = p_id;
$$;

-- Due jobs, leased: sent for 10 minutes, then retried with backoff; 8 failures is failed.
create or replace function public.stripe_jobs_claim(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_out jsonb;
begin
  update public.stripe_jobs j set status = 'pending', updated_at = now()
   where j.status = 'sent' and j.updated_at < now() - interval '10 minutes';
  with picked as (
    select j.id from public.stripe_jobs j
     where j.status = 'pending' and j.next_at <= now()
     order by j.next_at, j.id
     limit greatest(1, least(coalesce(p_limit, 20), 50))
     for update skip locked
  ), u as (
    update public.stripe_jobs j
       set status = 'sent', attempts = j.attempts + 1, updated_at = now()
      from picked
     where j.id = picked.id
    returning j.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'op', u.op, 'booking_id', u.booking_id, 'amount_minor', u.amount_minor,
           'idempotency_key', u.idempotency_key,
           'payment_intent_id', bp.payment_intent_id, 'checkout_session_id', bp.checkout_session_id,
           'stripe_account_id', coalesce(u.stripe_account_id, bp.stripe_account_id)) order by u.id), '[]'::jsonb)
    into v_out
    from u left join public.booking_payments bp on bp.booking_id = u.booking_id;
  return v_out;
end $$;

create or replace function public.stripe_job_done(p_id bigint, p_ok boolean, p_error text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare
  j public.stripe_jobs%rowtype;
begin
  select * into j from public.stripe_jobs where id = p_id for update;
  if not found then
    return 'unknown';
  end if;
  if coalesce(p_ok, false) then
    update public.stripe_jobs set status = 'done', last_error = null, updated_at = now() where id = p_id;
    return 'done';
  end if;
  update public.stripe_jobs
     set status = case when j.attempts >= 8 then 'failed' else 'pending' end,
         next_at = now() + make_interval(mins => (5 * power(2, least(j.attempts, 8)))::integer),
         last_error = left(p_error, 300), updated_at = now()
   where id = p_id;
  if j.attempts >= 8 and j.booking_id is not null then
    update public.booking_payments set last_error = left(p_error, 300), updated_at = now() where booking_id = j.booking_id;
  end if;
  return case when j.attempts >= 8 then 'failed' else 'pending' end;
end $$;

-- stripe-checkout calls this whenever it runs with its keys, so coaching_tick knows a checkout
-- could open (design section 9.1).
create or replace function public.stripe_checkout_heartbeat()
returns void language sql security definer set search_path = '' as $$
  insert into public.meta (key, value) values ('stripe_checkout_seen_at', now()::text)
  on conflict (key) do update set value = excluded.value, updated_at = now();
$$;

-- ---------------------------------------------------------------------------
-- 11. Moderators (design section 12)
-- ---------------------------------------------------------------------------
create or replace function public.mod_set_coach_status(p_user uuid, p_status text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  cp     public.coach_profiles%rowtype;
  v_b    uuid;
  n      integer := 0;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_status is null or p_status not in ('suspended', 'active') then
    raise exception 'invalid_action' using errcode = 'check_violation';
  end if;
  if p_user is null or public.moderation_is_own('profile', p_user, p_user) then
    raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews this one.';
  end if;
  select * into cp from public.coach_profiles where user_id = p_user for update;
  if not found then
    raise exception 'target_not_found' using errcode = 'P0002';
  end if;
  if p_status = 'suspended' then
    update public.coach_profiles set status = 'suspended', suspended_at = now() where user_id = p_user;
    update public.coach_listings set status = 'paused' where coach_id = p_user and status = 'active';
    for v_b in select b.id from public.bookings b
                where b.coach_id = p_user and b.status in ('requested', 'confirmed') and b.starts_at > now() loop
      if private.booking_cancel(v_b, 'moderator', 'moderator', 'full', true) then
        n := n + 1;
      end if;
    end loop;
  elsif cp.status = 'suspended' then
    update public.coach_profiles
       set status = case when published_at is not null then 'active'::public.coach_status else 'draft'::public.coach_status end,
           suspended_at = null
     where user_id = p_user;
  end if;
  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
  values (uid, case when p_status = 'suspended' then 'coach_suspend' else 'coach_restore' end, 'profile', p_user,
          p_user, v_note);
  return jsonb_build_object('user_id', p_user, 'status', (select c.status from public.coach_profiles c where c.user_id = p_user),
                            'bookings_cancelled', n);
end $$;
comment on function public.mod_set_coach_status(uuid, text, text) is
  'Migration 60, moderators: suspended pauses the coach''s listings and cancels their future bookings with full refunds; active lifts a suspension (listings stay paused for the coach to turn back on). Logged (coach_suspend, coach_restore). Errors: not_authenticated, forbidden, invalid_action, own_item, target_not_found.';

create or replace function public.mod_booking(p_id uuid, p_action text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  b      public.bookings%rowtype;
  bp     public.booking_payments%rowtype;
  v_open integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_action is null or p_action not in ('cancel_refund', 'uphold_no_show', 'reject_no_show', 'complete') then
    raise exception 'invalid_action' using errcode = 'check_violation';
  end if;
  select * into b from public.bookings where id = p_id for update;
  if not found then
    raise exception 'target_not_found' using errcode = 'P0002';
  end if;
  if uid in (b.coach_id, b.client_id) or public.moderation_is_own('booking', p_id, null) then
    raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews this one.';
  end if;
  select * into bp from public.booking_payments where booking_id = b.id;
  if p_action = 'cancel_refund' then
    if b.status in ('requested', 'confirmed') then
      perform private.booking_cancel(b.id, 'moderator', 'moderator', 'full', true);
    elsif b.status in ('no_show', 'completed') then
      update public.bookings
         set status = 'cancelled', cancelled_at = now(), cancelled_by = 'moderator', cancel_reason = 'moderator',
             no_show_settled_at = coalesce(no_show_settled_at, case when b.status = 'no_show' then now() end),
             payment_state = case when payment_state = 'paid' then 'refund_pending'::public.booking_payment_state
                                  else payment_state end
       where id = b.id;
      if b.payment_state = 'paid' then
        insert into public.stripe_jobs (booking_id, op, amount_minor, idempotency_key)
        values (b.id, 'refund', bp.amount_minor - bp.refunded_minor, 'refund:' || b.id::text || ':moderator')
        on conflict (idempotency_key) do nothing;
        perform public.stripe_dispatch();
      end if;
      perform private.booking_notify(b.id, b.client_id, 'booking_cancelled', jsonb_build_object('reason', 'moderator'));
      perform private.booking_notify(b.id, b.coach_id, 'booking_cancelled', jsonb_build_object('reason', 'moderator'));
    else
      raise exception 'invalid_state' using errcode = 'check_violation';
    end if;
  elsif p_action = 'uphold_no_show' then
    if b.status <> 'no_show' then
      raise exception 'invalid_state' using errcode = 'check_violation';
    end if;
    update public.bookings set no_show_settled_at = now() where id = b.id;
    if b.no_show_party = 'coach' and b.payment_state = 'paid' then
      update public.bookings set payment_state = 'refund_pending' where id = b.id;
      insert into public.stripe_jobs (booking_id, op, amount_minor, idempotency_key)
      values (b.id, 'refund', bp.amount_minor, 'refund:' || b.id::text || ':no_show_coach')
      on conflict (idempotency_key) do nothing;
      perform public.stripe_dispatch();
    end if;
  else
    if not (b.status = 'confirmed' or (b.status = 'no_show' and p_action in ('reject_no_show', 'complete'))) then
      raise exception 'invalid_state' using errcode = 'check_violation';
    end if;
    update public.bookings
       set status = 'completed', completed_at = now(),
           no_show_settled_at = case when b.status = 'no_show' then now() else no_show_settled_at end
     where id = b.id;
  end if;
  update public.reports set status = 'actioned', resolved_by = uid, resolved_at = now()
   where target_kind = 'booking' and target_id = b.id and status = 'open';
  get diagnostics v_open = row_count;
  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, report_count, note)
  values (uid, p_action, 'booking', b.id, b.coach_id, v_open, v_note);
  return jsonb_build_object('id', b.id, 'action', p_action,
                            'status', (select x.status from public.bookings x where x.id = b.id), 'reports_closed', v_open);
end $$;
comment on function public.mod_booking(uuid, text, text) is
  'Migration 60, moderators: decides a booking report (a contested no-show, a dispute about the session). cancel_refund cancels with a full refund; uphold_no_show settles the no-show (a coach no-show refunds in full); reject_no_show and complete mark the session completed. Closes the booking''s open reports; logged. Never shows the card or the private meeting note. Errors: not_authenticated, forbidden, invalid_action, target_not_found, own_item, invalid_state.';

create or replace function public.mod_coaching_numbers()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'coaches_active', (select count(*) from public.coach_profiles where status = 'active'),
    'bookings_week', (select count(*) from public.bookings where requested_at > now() - interval '7 days'),
    'completed_week', (select count(*) from public.bookings where completed_at > now() - interval '7 days'),
    'gmv_week', coalesce((select jsonb_object_agg(x.currency, x.amount) from (
                   select bp.currency, sum(bp.amount_minor) as amount from public.booking_payments bp
                     join public.bookings b on b.id = bp.booking_id
                    where b.paid_at > now() - interval '7 days' group by bp.currency) x), '{}'::jsonb),
    'refunds_week', coalesce((select jsonb_object_agg(x.currency, x.amount) from (
                   select bp.currency, sum(bp.refunded_minor) as amount from public.booking_payments bp
                    where bp.refunded_minor > 0 and bp.updated_at > now() - interval '7 days' group by bp.currency) x), '{}'::jsonb),
    'disputes_open', (select count(*) from public.bookings where payment_state = 'disputed'),
    'stripe_jobs_failed', (select count(*) from public.stripe_jobs where status = 'failed'),
    'booking_reports_open', (select count(*) from public.reports where target_kind = 'booking' and status = 'open'));
end $$;

-- ---------------------------------------------------------------------------
-- 12. Jobs (design section 14)
-- ---------------------------------------------------------------------------
create or replace function public.coaching_tick()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b          public.bookings%rowtype;
  n_expired  integer := 0;
  n_unpaid   integer := 0;
  n_fallback integer := 0;
  n_remind   integer := 0;
  n_complete integer := 0;
  n_settled  integer := 0;
  n_prompts  integer := 0;
begin
  -- Requests nobody answered.
  for b in select * from public.bookings x where x.status = 'requested' and x.expires_at <= now() for update skip locked loop
    update public.bookings set status = 'expired', expired_at = now() where id = b.id;
    perform private.booking_notify(b.id, b.client_id, 'booking_declined', jsonb_build_object('reason', 'expired'));
    n_expired := n_expired + 1;
  end loop;

  -- Unpaid in-app payments: cancelled once pay_by passes. When no checkout could ever open (the
  -- flag is on but stripe-checkout has never run with its keys, meta.stripe_checkout_seen_at),
  -- the booking falls back to off-platform payment with a notice to both sides instead.
  for b in select * from public.bookings x
            where x.status = 'confirmed' and x.payment_mode = 'stripe' and x.payment_state in ('due', 'processing')
              and x.pay_by <= now() - case when x.payment_state = 'processing' then interval '15 minutes' else interval '0' end
            for update skip locked loop
    if not exists (select 1 from public.booking_payments bp where bp.booking_id = b.id)
       and coalesce((select m.value from public.meta m where m.key = 'stripe_checkout_seen_at'), '') = '' then
      update public.bookings set payment_mode = 'off_platform', payment_state = 'off_platform', fee_minor = 0, pay_by = null
       where id = b.id;
      perform private.booking_notify(b.id, b.client_id, 'booking_payment_due',
                                     jsonb_build_object('fallback', 'off_platform', 'key', 'fallback'));
      perform private.booking_notify(b.id, b.coach_id, 'booking_payment_due',
                                     jsonb_build_object('fallback', 'off_platform', 'key', 'fallback'));
      n_fallback := n_fallback + 1;
    elsif private.booking_cancel(b.id, 'system', 'unpaid', 'none', true) then
      n_unpaid := n_unpaid + 1;
    end if;
  end loop;

  -- Reminders, a day and 2 hours before, to both sides (idempotent by dedupe key).
  for b in select * from public.bookings x
            where x.status = 'confirmed' and x.starts_at > now() and x.starts_at <= now() + interval '24 hours' loop
    if b.starts_at > now() + interval '2 hours' then
      perform private.booking_notify(b.id, b.client_id, 'booking_reminder_day');
      perform private.booking_notify(b.id, b.coach_id, 'booking_reminder_day');
    else
      perform private.booking_notify(b.id, b.client_id, 'booking_reminder_2h');
      perform private.booking_notify(b.id, b.coach_id, 'booking_reminder_2h');
    end if;
    n_remind := n_remind + 1;
  end loop;

  -- Completed automatically 48 hours after the end when nobody reported a no-show.
  for b in select * from public.bookings x
            where x.status = 'confirmed' and x.ends_at + interval '48 hours' <= now() for update skip locked loop
    update public.bookings set status = 'completed', completed_at = now() where id = b.id;
    if b.format = 'one_on_one' then
      update public.coach_sessions set status = 'done' where id = b.session_id and status = 'scheduled';
    end if;
    n_complete := n_complete + 1;
  end loop;

  -- Uncontested no-shows settle after 48 hours; a coach no-show refunds in full.
  for b in select * from public.bookings x
            where x.status = 'no_show' and x.no_show_contested_at is null and x.no_show_settled_at is null
              and x.no_show_at + interval '48 hours' <= now() for update skip locked loop
    update public.bookings set no_show_settled_at = now(),
           payment_state = case when b.no_show_party = 'coach' and payment_state = 'paid'
                                then 'refund_pending'::public.booking_payment_state else payment_state end
     where id = b.id;
    if b.no_show_party = 'coach' and b.payment_state = 'paid' then
      insert into public.stripe_jobs (booking_id, op, amount_minor, idempotency_key)
      select b.id, 'refund', bp.amount_minor, 'refund:' || b.id::text || ':no_show_coach'
        from public.booking_payments bp where bp.booking_id = b.id
      on conflict (idempotency_key) do nothing;
    end if;
    n_settled := n_settled + 1;
  end loop;

  -- Review prompts, 2 hours after completion.
  for b in select * from public.bookings x
            where x.status = 'completed' and x.completed_at <= now() - interval '2 hours'
              and x.completed_at > now() - interval '7 days'
              and not exists (select 1 from public.coach_reviews r where r.booking_id = x.id)
              and not exists (select 1 from public.notifications n
                               where n.dedupe_key = 'booking_review_prompt:' || x.id::text || ':' || x.client_id::text) loop
    perform private.booking_notify(b.id, b.client_id, 'booking_review_prompt');
    n_prompts := n_prompts + 1;
  end loop;

  perform public.stripe_dispatch();
  return jsonb_build_object('expired', n_expired, 'unpaid_cancelled', n_unpaid, 'fell_back', n_fallback,
                            'reminders', n_remind, 'completed', n_complete, 'no_shows_settled', n_settled,
                            'review_prompts', n_prompts);
end $$;
comment on function public.coaching_tick() is
  'Migration 60, service role (pg_cron coaching-tick every 5 minutes): expires unanswered requests, cancels unpaid in-app bookings past pay_by (or turns them off-platform when no checkout ever opened), sends day and 2-hour reminders, completes confirmed bookings 48 hours after the end, settles uncontested no-shows after 48 hours (a coach no-show queues a full refund), sends review prompts 2 hours after completion, and dispatches due stripe_jobs. Returns counts.';

create or replace function public.purge_coaching()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  n_events integer;
  n_jobs   integer;
  n_exc    integer;
begin
  delete from public.stripe_events where received_at < now() - interval '90 days';
  get diagnostics n_events = row_count;
  delete from public.stripe_jobs where status = 'done' and updated_at < now() - interval '90 days';
  get diagnostics n_jobs = row_count;
  delete from public.coach_availability_exceptions where ends_at < now() - interval '30 days';
  get diagnostics n_exc = row_count;
  return jsonb_build_object('stripe_events', n_events, 'stripe_jobs', n_jobs, 'exceptions', n_exc);
end $$;

-- ---------------------------------------------------------------------------
-- 13. Rebuilt functions (latest bodies; changes marked "Migration 60")
-- ---------------------------------------------------------------------------

-- private.chat_shared_context (migration 58 body)
create or replace function private.chat_shared_context(p_a uuid, p_b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_a is not null and p_b is not null and p_a <> p_b and (
    exists (
      select 1
        from (select r.event_id from public.rsvps r
               where r.user_id = p_a and r.status in ('going', 'waitlisted') and r.removed_at is null
              union select e.id from public.events e where e.host_id = p_a) xa
        join (select r.event_id from public.rsvps r
               where r.user_id = p_b and r.status in ('going', 'waitlisted') and r.removed_at is null
              union select e.id from public.events e where e.host_id = p_b) xb on xb.event_id = xa.event_id
        join public.events e on e.id = xa.event_id
       where e.kind <> 'imported' and e.ends_at > now() - interval '180 days')
    or exists (
      select 1 from public.hub_members ha
        join public.hub_members hb on hb.hub_id = ha.hub_id and hb.user_id = p_b
        join public.hubs h on h.id = ha.hub_id
        join public.hub_categories c on c.slug = h.category_slug
       where ha.user_id = p_a and h.is_active and not c.is_sensitive
         and ha.joined_at <= now() - interval '24 hours' and hb.joined_at <= now() - interval '24 hours')
    or exists (
      select 1 from public.chapter_members ca
        join public.chapter_members cb on cb.chapter_id = ca.chapter_id and cb.user_id = p_b
        join public.hub_chapters ch on ch.id = ca.chapter_id
       where ca.user_id = p_a and ch.is_active)
    or exists (
      select 1 from public.event_meets m1
        join public.event_meets m2 on m2.event_id = m1.event_id and m2.user_id = p_b and m2.met_user_id = p_a
       where m1.user_id = p_a and m1.met_user_id = p_b)
    or exists (
      select 1 from public.conversations c
       where c.kind = 'dm' and c.dm_key = private.chat_dm_key(p_a, p_b)
         and not exists (select 1 from public.message_requests r
                          where r.conversation_id = c.id and r.status <> 'accepted'))
    -- Migration 60: a booking between them (open, or ended in the last 180 days).
    or exists (
      select 1 from public.bookings b
       where ((b.coach_id = p_a and b.client_id = p_b) or (b.coach_id = p_b and b.client_id = p_a))
         and (b.status in ('requested', 'confirmed')
              or (b.status in ('completed', 'no_show') and b.ends_at > now() - interval '180 days')))
  );
$$;



-- enqueue_notification (migration 58 body)
create or replace function public.enqueue_notification(
  p_user_id    uuid,
  p_kind       public.notification_kind,
  p_dedupe_key text,
  p_event_id   uuid default null,
  p_hub_id     uuid default null,
  p_chapter_id uuid default null,
  p_actor_id   uuid default null,
  p_payload    jsonb default '{}'::jsonb,
  p_batch      boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  np           public.notification_prefs%rowtype;
  v_topic      boolean;
  v_email      public.notification_channel_status;
  v_push       public.notification_channel_status;
  v_push_after timestamptz;
  v_tz         text;
  v_now_local  timestamp;
  v_local      time;
  v_quiet      boolean;
  v_id         uuid;
  v_joiner     text;
begin
  if p_user_id is null or p_kind is null or nullif(btrim(coalesce(p_dedupe_key, '')), '') is null then
    return null;
  end if;
  if not exists (select 1 from public.profiles
                  where id = p_user_id and status = 'active' and deleted_at is null) then
    return null;
  end if;
  -- Migration 51: across a block, social notices are dropped and every other
  -- notice loses its actor; a mute drops the social notices.
  if p_actor_id is not null and p_actor_id <> p_user_id then
    if public.users_blocked(p_user_id, p_actor_id) then
      -- Migration 58: message and message_request are social too.
      if p_kind in ('attendee_joined', 'hub_new_event', 'message', 'message_request') then
        return null;
      end if;
      p_actor_id := null;
    elsif p_kind in ('attendee_joined', 'hub_new_event', 'message', 'message_request')
          and exists (select 1 from public.mutes m where m.muter_id = p_user_id and m.muted_id = p_actor_id) then
      return null;
    end if;
  end if;

  select * into np from public.notification_prefs where user_id = p_user_id;
  -- Topic switches; confirmations of the person's own actions and claim
  -- reviews are transactional and follow only the channel switches.
  v_topic := case
    when p_kind in ('event_reminder_day', 'event_reminder_2h') then coalesce(np.event_reminders, true)
    when p_kind in ('event_cancelled', 'event_updated', 'broadcast') then coalesce(np.event_updates, true)
    when p_kind in ('attendee_joined', 'hub_new_event') then coalesce(np.hub_activity, true)
    when p_kind = 'checkin_prompt' then coalesce(np.checkin_prompts, true)
    when p_kind in ('message', 'message_request') then coalesce(np.messages, true)   -- Migration 58
    -- Migration 60: booking reminders, review prompts and review notices follow bookings;
    -- confirmations, declines, cancellations and payment due are transactional.
    when p_kind in ('booking_reminder_day', 'booking_reminder_2h', 'booking_review_prompt', 'review_received', 'review_reply') then coalesce(np.bookings, true)
    else true
  end;
  v_email := case when np.unsubscribed_all_at is not null or not coalesce(np.email_enabled, true) or not v_topic
                       -- Migration 58: chat notices never go by email (the daily cap is for plans).
                       or p_kind in ('message', 'message_request')
                       -- Migration 60: of the booking kinds only requested, confirmed, cancelled and
                       -- payment due are emailed (logistics).
                       or p_kind in ('booking_declined', 'booking_reminder_day', 'booking_reminder_2h', 'booking_review_prompt',
                                      'booking_no_show', 'review_received', 'review_reply', 'coach_payout_action')
                  then 'skipped' else 'pending' end;
  v_push  := case when np.unsubscribed_all_at is not null or not coalesce(np.push_enabled, true) or not v_topic
                  then 'skipped' else 'pending' end;

  if v_push = 'pending' and np.quiet_start is not null and np.quiet_end is not null
     and np.quiet_start <> np.quiet_end then
    v_tz := case when public.is_valid_timezone(np.timezone) then np.timezone else 'America/New_York' end;
    v_now_local := now() at time zone v_tz;
    v_local := v_now_local::time;
    v_quiet := case when np.quiet_start < np.quiet_end
                    then v_local >= np.quiet_start and v_local < np.quiet_end
                    else v_local >= np.quiet_start or v_local < np.quiet_end end;
    if v_quiet then
      v_push_after := ((v_now_local::date + np.quiet_end)
                       + case when np.quiet_end <= v_local then interval '1 day' else interval '0' end)
                      at time zone v_tz;
    end if;
  end if;

  if p_batch and p_kind = 'message' then
    -- Migration 58: a burst of messages is one row; count is the number of
    -- messages, seq the newest, actor the latest sender. Seen again on news.
    insert into public.notifications as n
      (user_id, kind, event_id, hub_id, chapter_id, actor_id, payload, dedupe_key, email_status, push_status, push_after)
    values (p_user_id, p_kind, p_event_id, p_hub_id, p_chapter_id, p_actor_id,
            coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('count', 1),
            p_dedupe_key, v_email, v_push, v_push_after)
    on conflict (dedupe_key) do update
       set payload  = n.payload || jsonb_build_object(
                        'count', coalesce((n.payload ->> 'count')::integer, 1) + 1,
                        'seq', coalesce(p_payload -> 'seq', n.payload -> 'seq')),
           actor_id = excluded.actor_id,
           read_at  = null,
           seen_at  = null
    returning n.id into v_id;
  elsif p_batch then
    -- joiners: md5(dedupe_key || ':' || actor) per distinct actor, so the set
    -- never stores a user id (account deletion needs no payload scrub).
    v_joiner := md5(p_dedupe_key || ':' || coalesce(p_actor_id::text, ''));
    insert into public.notifications as n
      (user_id, kind, event_id, hub_id, chapter_id, actor_id, payload, dedupe_key, email_status, push_status, push_after)
    values (p_user_id, p_kind, p_event_id, p_hub_id, p_chapter_id, p_actor_id,
            coalesce(p_payload, '{}'::jsonb)
              || jsonb_build_object('count', 1, 'joiners', jsonb_build_array(v_joiner)),
            p_dedupe_key, v_email, v_push, v_push_after)
    on conflict (dedupe_key) do update
       set payload  = n.payload || jsonb_build_object(
                        'joiners', coalesce(n.payload -> 'joiners',
                                            jsonb_build_array(md5(n.dedupe_key || ':' || coalesce(n.actor_id::text, ''))))
                                   || to_jsonb(v_joiner),
                        'count', jsonb_array_length(coalesce(n.payload -> 'joiners',
                                            jsonb_build_array(md5(n.dedupe_key || ':' || coalesce(n.actor_id::text, ''))))) + 1),
           actor_id = excluded.actor_id,
           read_at  = null,
           seen_at  = null
     where p_actor_id is not null
       and not (coalesce(n.payload -> 'joiners',
                         jsonb_build_array(md5(n.dedupe_key || ':' || coalesce(n.actor_id::text, '')))) ? v_joiner)
    returning n.id into v_id;
  else
    insert into public.notifications
      (user_id, kind, event_id, hub_id, chapter_id, actor_id, payload, dedupe_key, email_status, push_status, push_after)
    values (p_user_id, p_kind, p_event_id, p_hub_id, p_chapter_id, p_actor_id, coalesce(p_payload, '{}'::jsonb),
            p_dedupe_key, v_email, v_push, v_push_after)
    on conflict (dedupe_key) do nothing
    returning id into v_id;
  end if;
  return v_id;
end $$;

comment on function public.enqueue_notification(uuid, public.notification_kind, text, uuid, uuid, uuid, uuid, jsonb, boolean) is
  'Internal. Records one notification honoring notification_prefs (channels, topics, unsubscribed_all_at, quiet hours via push_after). Idempotent by dedupe_key; p_batch keeps a hash per distinct actor in payload.joiners and their number in payload.count. Migration 51: across a block attendee_joined and hub_new_event are dropped and other kinds lose the actor; a mute drops attendee_joined and hub_new_event. Migration 58: message and message_request are social the same way, follow notification_prefs.messages and never email; a batched message counts messages in payload.count and keeps the newest payload.seq. Migration 60: booking kinds are transactional (a mute does not drop them); reminders, review prompts and review notices follow notification_prefs.bookings; only booking_requested, booking_confirmed, booking_cancelled and booking_payment_due are emailed. Returns the id, or null when nothing was written.';

-- claim_pending_notifications (migration 58 body)
create or replace function public.claim_pending_notifications(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_limit     integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_cap       integer;
  v_day       date := (now() at time zone 'UTC')::date;
  v_reserved  integer;
  n           public.notifications%rowtype;
  np          public.notification_prefs%rowtype;
  e           public.events%rowtype;
  v_email     boolean;
  v_push      boolean;
  v_email_st  public.notification_channel_status;
  v_push_st   public.notification_channel_status;
  v_push_aft  timestamptz;
  v_err       text;
  v_topic     boolean;
  v_social    boolean;
  v_blocked   boolean;
  v_actor     text;
  v_quiet     timestamptz;
  v_to        text;
  v_devices   jsonb;
  v_out       jsonb := '[]'::jsonb;
  v_conv      uuid;   -- Migration 58
  v_bk        uuid;   -- Migration 60
begin
  -- Expire what is too old to be useful (in-app keeps it).
  update public.notifications
     set email_status = case when email_status = 'pending' then 'skipped'::public.notification_channel_status else email_status end,
         push_status  = case when push_status  = 'pending' then 'skipped'::public.notification_channel_status else push_status end,
         last_error   = 'expired',
         claimed_at   = null
   where (email_status = 'pending' or push_status = 'pending')
     and created_at < now() - interval '2 days';

  v_cap := coalesce((select case when value ~ '^\d{1,5}$' then value::integer end
                       from public.meta where key = 'notify_email_daily_cap'), 90);
  insert into public.notification_email_days (day) values (v_day) on conflict (day) do nothing;
  select reserved into v_reserved from public.notification_email_days where day = v_day for update;

  for n in
    select * from public.notifications x
     where (x.email_status = 'pending'
            or (x.push_status = 'pending' and (x.push_after is null or x.push_after <= now())))
       and (x.claimed_at is null or x.claimed_at < now() - interval '10 minutes')
     order by x.created_at
     limit v_limit
     for update skip locked
  loop
    v_email_st := n.email_status;
    v_push_st  := n.push_status;
    v_push_aft := n.push_after;
    v_err := null;
    v_email := n.email_status = 'pending';
    v_push := n.push_status = 'pending' and (n.push_after is null or n.push_after <= now());

    -- Five tries per channel, then failed.
    if n.attempts >= 5 then
      if v_email then v_email_st := 'failed'; end if;
      if v_push then v_push_st := 'failed'; end if;
      v_email := false; v_push := false; v_err := 'too_many_attempts';
    end if;

    -- Seen in the app already: nothing to send.
    if (v_email or v_push) and n.read_at is not null then
      if v_email then v_email_st := 'skipped'; end if;
      if v_push then v_push_st := 'skipped'; end if;
      v_email := false; v_push := false; v_err := 'read_in_app';
    end if;

    -- The recipient, and their prefs as they are now.
    if (v_email or v_push) and not exists (
         select 1 from public.profiles p
          where p.id = n.user_id and p.status = 'active' and p.deleted_at is null) then
      if v_email then v_email_st := 'skipped'; end if;
      if v_push then v_push_st := 'skipped'; end if;
      v_email := false; v_push := false; v_err := 'inactive_recipient';
    end if;

    if v_email or v_push then
      select * into np from public.notification_prefs where user_id = n.user_id;
      v_topic := case
        when n.kind in ('event_reminder_day', 'event_reminder_2h') then coalesce(np.event_reminders, true)
        when n.kind in ('event_cancelled', 'event_updated', 'broadcast') then coalesce(np.event_updates, true)
        when n.kind in ('attendee_joined', 'hub_new_event') then coalesce(np.hub_activity, true)
        when n.kind = 'checkin_prompt' then coalesce(np.checkin_prompts, true)
        when n.kind in ('message', 'message_request') then coalesce(np.messages, true)   -- Migration 58
        when n.kind in ('booking_reminder_day', 'booking_reminder_2h', 'booking_review_prompt', 'review_received', 'review_reply') then coalesce(np.bookings, true)   -- Migration 60
        else true
      end;
      if v_email and (np.unsubscribed_all_at is not null or not coalesce(np.email_enabled, true) or not v_topic) then
        v_email_st := 'skipped'; v_email := false; v_err := 'prefs';
      end if;
      if v_push and (np.unsubscribed_all_at is not null or not coalesce(np.push_enabled, true) or not v_topic) then
        v_push_st := 'skipped'; v_push := false; v_err := 'prefs';
      end if;
    end if;

    -- Never across a block (or to a muter, for the social notices).
    -- Migration 56: the same rule as enqueue_notification (migration 51). Only
    -- attendee_joined and hub_new_event are social; every other notice,
    -- broadcast included (it may carry plan logistics), still goes across a
    -- block or a mute but never names the actor.
    v_actor := null;
    if (v_email or v_push) and n.actor_id is not null and n.actor_id <> n.user_id then
      v_social := n.kind in ('attendee_joined', 'hub_new_event', 'message', 'message_request');   -- Migration 58
      v_blocked := public.users_blocked(n.user_id, n.actor_id);
      if v_social and (v_blocked or exists (select 1 from public.mutes m
                                             where m.muter_id = n.user_id and m.muted_id = n.actor_id)) then
        if v_email then v_email_st := 'skipped'; end if;
        if v_push then v_push_st := 'skipped'; end if;
        v_email := false; v_push := false; v_err := 'blocked';
      elsif not v_blocked then
        select p.first_name into v_actor from public.profiles p
         where p.id = n.actor_id and p.status = 'active' and p.deleted_at is null and p.moderation_state is null;
      end if;
    end if;

    -- Stale plan notices. Migration 56: every notice about a plan (all but
    -- event_cancelled, which is the news itself) is skipped once the plan is
    -- gone, moderated or cancelled, so a removed title never goes out; the
    -- already-started check stays for reminders only.
    if (v_email or v_push) and n.event_id is not null and n.kind <> 'event_cancelled' then
      select * into e from public.events where id = n.event_id;
      if not found or e.moderation_state is not null
         or e.status = 'cancelled'
         or (n.kind in ('event_reminder_day', 'event_reminder_2h') and e.starts_at <= now()) then
        if v_email then v_email_st := 'skipped'; end if;
        if v_push then v_push_st := 'skipped'; end if;
        v_email := false; v_push := false; v_err := 'stale';
      end if;
    end if;

    -- Migration 58: chat notices. Never email; nothing once the conversation
    -- is gone, closed or muted now, or the member has read up to its seq.
    if (v_email or v_push) and n.kind in ('message', 'message_request') then
      if v_email then
        v_email_st := 'skipped'; v_email := false; v_err := 'prefs';
      end if;
      v_conv := case when n.payload ->> 'conversation_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                     then (n.payload ->> 'conversation_id')::uuid end;
      if v_push and (
           not exists (select 1 from public.conversations c where c.id = v_conv and c.closed_at is null)
           or exists (select 1 from public.conversation_members cm
                       where cm.conversation_id = v_conv and cm.user_id = n.user_id
                         and (cm.muted_until > now() or cm.removed_at is not null or cm.left_at is not null
                              or (n.kind = 'message' and n.payload ->> 'seq' ~ '^\d{1,18}$'
                                  and cm.last_read_seq >= (n.payload ->> 'seq')::bigint)))) then
        v_push_st := 'skipped'; v_push := false; v_err := 'stale';
      end if;
    end if;

    -- Migration 60: booking notices. Email only for requested, confirmed, cancelled and payment
    -- due; reminders, payment due and review prompts are skipped once the booking moved on.
    if v_email and n.kind in ('booking_declined', 'booking_reminder_day', 'booking_reminder_2h', 'booking_review_prompt',
                                      'booking_no_show', 'review_received', 'review_reply', 'coach_payout_action') then
      v_email_st := 'skipped'; v_email := false; v_err := 'prefs';
    end if;
    if (v_email or v_push) and n.kind in ('booking_reminder_day', 'booking_reminder_2h', 'booking_payment_due',
                                          'booking_review_prompt') then
      v_bk := case when n.payload ->> 'booking_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                   then (n.payload ->> 'booking_id')::uuid end;
      if not exists (
           select 1 from public.bookings b
            where b.id = v_bk
              and ((n.kind in ('booking_reminder_day', 'booking_reminder_2h') and b.status = 'confirmed' and b.starts_at > now())
                   or (n.kind = 'booking_payment_due'
                       and (n.payload ? 'fallback' or (b.status = 'confirmed' and b.payment_state in ('due', 'processing'))))
                   or (n.kind = 'booking_review_prompt' and b.status = 'completed'
                       and not exists (select 1 from public.coach_reviews r where r.booking_id = b.id)))) then
        if v_email then v_email_st := 'skipped'; end if;
        if v_push then v_push_st := 'skipped'; end if;
        v_email := false; v_push := false; v_err := 'stale';
      end if;
    end if;

    -- Quiet hours, as set now (push waits, never dropped).
    if v_push then
      v_quiet := public.notification_quiet_until(n.user_id);
      if v_quiet is not null then
        v_push_aft := v_quiet; v_push := false;
      end if;
    end if;

    -- Email: a confirmed address and room under the daily cap.
    v_to := null;
    if v_email then
      select u.email into v_to from auth.users u
       where u.id = n.user_id and u.email_confirmed_at is not null and u.email is not null and u.email <> '';
      if v_to is null then
        v_email_st := 'skipped'; v_email := false; v_err := 'no_confirmed_email';
      elsif v_reserved >= v_cap then
        v_email_st := 'skipped'; v_email := false; v_err := 'daily_cap';
      else
        v_reserved := v_reserved + 1;
      end if;
    end if;

    -- Push: live web devices on an allowed service.
    v_devices := null;
    if v_push then
      select coalesce(jsonb_agg(jsonb_build_object(
               'device_id', d.id,
               'endpoint', d.subscription ->> 'endpoint',
               'p256dh', d.subscription #>> '{keys,p256dh}',
               'auth', d.subscription #>> '{keys,auth}') order by d.last_seen_at desc), '[]'::jsonb)
        into v_devices
        from (select * from public.push_devices pd
               where pd.user_id = n.user_id and pd.revoked_at is null and pd.platform = 'web'
                 and public.push_endpoint_allowed(pd.subscription ->> 'endpoint')
                 and pd.subscription #>> '{keys,p256dh}' is not null
                 and pd.subscription #>> '{keys,auth}' is not null
               order by pd.last_seen_at desc limit 10) d;
      if jsonb_array_length(v_devices) = 0 then
        v_push_st := 'skipped'; v_push := false; v_devices := null;
        v_err := coalesce(v_err, 'no_device');
      end if;
    end if;

    update public.notifications
       set email_status = v_email_st,
           push_status  = v_push_st,
           push_after   = v_push_aft,
           claimed_at   = case when v_email or v_push then now() else null end,
           attempts     = attempts + case when v_email or v_push then 1 else 0 end,
           last_error   = coalesce(v_err, last_error)
     where id = n.id;

    if v_email or v_push then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', n.id,
        'kind', n.kind,
        'created_at', n.created_at,
        'event_id', n.event_id,
        'payload', n.payload - 'joiners',
        'actor_name', v_actor,
        'hub', (select jsonb_build_object('slug', h.slug, 'name', h.name) from public.hubs h where h.id = n.hub_id),
        'chapter', (select jsonb_build_object('slug', c.slug, 'name', c.name) from public.hub_chapters c where c.id = n.chapter_id),
        'email', case when v_email then jsonb_build_object(
                   'to', v_to, 'unsubscribe_token', public.notification_unsubscribe_token(n.user_id)) end,
        'push', case when v_push then v_devices end));
    end if;
  end loop;

  update public.notification_email_days set reserved = v_reserved where day = v_day;
  return v_out;
end $$;

comment on function public.claim_pending_notifications(integer) is
  'Migrations 55, 56, 58 and 60, service role (send-notifications): claims up to p_limit (max 100) due rows with for update skip locked, re-checks prefs, quiet hours, blocks and mutes, staleness, the confirmed address and the daily email cap, writes skipped or deferred channels, and returns what to send now as jsonb. Leased for 10 minutes; 5 attempts. Migration 56: a moderated, cancelled or missing plan stops every notice about it but event_cancelled; blocks and mutes stop only attendee_joined and hub_new_event (others go without the actor''s name), as at queueing. Migration 58: message and message_request are social too, follow notification_prefs.messages, never email, and are skipped when the conversation is gone, closed or muted, or the member read up to payload.seq. Migration 60: booking kinds follow notification_prefs.bookings for reminders and review notices, email only requested, confirmed, cancelled and payment due, and reminders, payment due and review prompts are skipped once the booking moved on.';

-- moderation_set_state (migration 58 body)
create or replace function public.moderation_set_state(p_kind text, p_id uuid, p_state text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_old text;
begin
  if p_kind = 'profile' then
    select moderation_state into v_old from public.profiles where id = p_id for update;
    update public.profiles set moderation_state = p_state, moderated_at = now() where id = p_id;
  elsif p_kind = 'event' then
    select moderation_state into v_old from public.events where id = p_id for update;
    update public.events set moderation_state = p_state, moderated_at = now() where id = p_id;
  elsif p_kind = 'chapter' then
    select moderation_state into v_old from public.hub_chapters where id = p_id for update;
    update public.hub_chapters
       set moderation_state = p_state, moderated_at = now(),
           is_active = case when p_state is not null then false when v_old is not null then true else is_active end
     where id = p_id;
  elsif p_kind = 'message' then
    -- Migration 58
    select moderation_state into v_old from public.messages where id = p_id for update;
    update public.messages set moderation_state = p_state, moderated_at = now() where id = p_id;
  elsif p_kind = 'coach_listing' then
    -- Migration 60
    select moderation_state into v_old from public.coach_listings where id = p_id for update;
    update public.coach_listings set moderation_state = p_state, moderated_at = now() where id = p_id;
  elsif p_kind = 'coach_review' then
    select moderation_state into v_old from public.coach_reviews where booking_id = p_id for update;
    update public.coach_reviews set moderation_state = p_state, moderated_at = now() where booking_id = p_id;
  elsif p_kind = 'coach_review_reply' then
    select reply_moderation_state into v_old from public.coach_reviews where booking_id = p_id for update;
    update public.coach_reviews set reply_moderation_state = p_state, moderated_at = now() where booking_id = p_id;
  elsif p_kind = 'hub' then
    select moderation_state into v_old from public.hubs where id = p_id for update;
    update public.hubs
       set moderation_state = p_state, moderated_at = now(),
           is_active = case when p_state is not null then false when v_old is not null then true else is_active end
     where id = p_id;
  else
    raise exception 'invalid_kind' using errcode = 'check_violation';
  end if;
  return v_old;
end $$;

comment on function public.moderation_set_state(text, uuid, text) is
  'Migration 51 (58, 60), internal: sets moderation_state on a profile, event, chapter, hub, message, coach listing, coach review or review reply (a hub or chapter also goes inactive, and active again when a state is cleared). Returns the previous state.';

-- moderation_is_own (migration 58 body)
create or replace function public.moderation_is_own(p_kind text, p_id uuid, p_target_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and (
    p_target_user = (select auth.uid())
    or exists (select 1 from public.reports r
                where r.target_kind = p_kind and r.target_id = p_id and r.status = 'open'
                  and r.reporter_id = (select auth.uid()))
    or (p_kind = 'chapter' and exists (select 1 from public.chapter_members cm
                                        where cm.chapter_id = p_id and cm.user_id = (select auth.uid())
                                          and cm.role in ('captain', 'organizer')))
    -- Migration 54: a plan in a chapter the caller runs.
    or (p_kind = 'event' and exists (select 1 from public.events e
                                      where e.id = p_id and public.is_chapter_captain(e.chapter_id)))
    -- Migration 58: a message in a dm or group the caller is in.
    or (p_kind = 'message' and exists (select 1 from public.messages m
                                         join public.conversations c on c.id = m.conversation_id
                                         join public.conversation_members cm
                                           on cm.conversation_id = m.conversation_id and cm.user_id = (select auth.uid())
                                        where m.id = p_id and c.kind in ('dm', 'group')))
    -- Migration 60: the caller's listing, a review by or about the caller, a booking the caller is in.
    or (p_kind = 'coach_listing' and exists (select 1 from public.coach_listings l
                                              where l.id = p_id and l.coach_id = (select auth.uid())))
    or (p_kind in ('coach_review', 'coach_review_reply')
        and exists (select 1 from public.coach_reviews r
                     where r.booking_id = p_id and (select auth.uid()) in (r.coach_id, r.client_id)))
    or (p_kind = 'booking' and exists (select 1 from public.bookings b
                                        where b.id = p_id and (select auth.uid()) in (b.coach_id, b.client_id)))
  );
$$;

comment on function public.moderation_is_own(text, uuid, uuid) is
  'Migration 51 (54, 58, 60), internal: the second-moderator rule. True when the target is the caller, the caller''s plan or a plan in a chapter the caller runs, a chapter the caller runs, a message in a dm or group the caller is in, the caller''s coach listing, a review by or about the caller, a booking the caller is in, or the caller filed an open report on it.';

-- report_content (migration 58 body)
create or replace function public.report_content(p_kind text, p_id uuid, p_reason text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid           uuid := (select auth.uid());
  v_note        text := left(btrim(coalesce(p_note, '')), 1000);
  v_target_user uuid;
  v_state       text;
  v_id          uuid;
  v_n           integer;
  v_priority    smallint;
  v_due         interval;
  v_hidden      boolean := false;
  v_conv        uuid;          -- Migration 58
  v_deleted_at  timestamptz;
  v_deleted_by  text;
  v_coach       uuid;          -- Migration 60
  v_client      uuid;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  -- Places keep their own reasons, rules and queue (migration 34).
  if p_kind = 'place' then
    return public.report_place(p_id, p_reason, p_note);
  end if;
  if p_kind is null or p_id is null
     or p_kind not in ('profile', 'event', 'chapter', 'hub', 'message',                   -- Migration 58
                       'coach_listing', 'coach_review', 'coach_review_reply', 'booking') then   -- Migration 60
    raise exception 'invalid_kind' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and deleted_at is null
                    and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_reason is null or p_reason not in ('harassment', 'hate', 'sexual_content', 'violence', 'spam', 'scam',
                                          'impersonation', 'underage', 'unsafe', 'ncii', 'child_safety', 'other',
                                          'no_show', 'payment')   -- Migration 60: booking reports only
     or (p_reason in ('no_show', 'payment') and p_kind <> 'booking') then
    raise exception 'invalid_reason' using errcode = 'check_violation';
  end if;

  if p_kind = 'profile' then
    select p.id, p.moderation_state into v_target_user, v_state
      from public.profiles p where p.id = p_id and p.deleted_at is null;
    if not found then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
  elsif p_kind = 'event' then
    select e.host_id, e.moderation_state into v_target_user, v_state from public.events e where e.id = p_id;
    -- Migration 54: a hidden or removed plan the caller cannot read is not found.
    if not found or not public.can_read_event(p_id) then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
  elsif p_kind = 'message' then
    -- Migration 58: a message the reporter can read (an author-deleted one
    -- within 30 days, while its text is still kept).
    select m.author_id, m.moderation_state, m.conversation_id, m.deleted_at, m.deleted_by
      into v_target_user, v_state, v_conv, v_deleted_at, v_deleted_by
      from public.messages m where m.id = p_id;
    if not found or not private.chat_can_read(v_conv) or not private.chat_visible_author(v_target_user, uid)
       or (v_deleted_at is not null and (v_deleted_by <> 'author' or v_deleted_at < now() - interval '30 days')) then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
  elsif p_kind = 'coach_listing' then
    -- Migration 60: a listing the reporter can see (the coach is the target).
    select l.coach_id, l.moderation_state into v_target_user, v_state from public.coach_listings l where l.id = p_id;
    if not found or not private.coach_listing_visible(p_id) then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
  elsif p_kind in ('coach_review', 'coach_review_reply') then
    -- Migration 60: a review (target: its author) or a reply (target: the coach) the reporter can see.
    select r.coach_id, r.client_id,
           case when p_kind = 'coach_review' then r.moderation_state else r.reply_moderation_state end
      into v_coach, v_client, v_state
      from public.coach_reviews r
     where r.booking_id = p_id and (p_kind = 'coach_review' or r.reply is not null);
    if not found or not private.coach_visible(v_coach)
       or (v_state is not null and uid not in (v_coach, v_client))
       or (uid <> v_client and private.is_blocked_with(v_client)) then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
    v_target_user := case when p_kind = 'coach_review' then v_client else v_coach end;
  elsif p_kind = 'booking' then
    -- Migration 60: only a party reports a booking; the target is the other party.
    select b.coach_id, b.client_id into v_coach, v_client from public.bookings b
     where b.id = p_id and uid in (b.coach_id, b.client_id);
    if not found then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
    v_target_user := case when uid = v_coach then v_client else v_coach end;
  elsif p_kind = 'chapter' then
    -- Migration 54: an inactive (hidden or removed) chapter is not found, except for moderators.
    select c.moderation_state into v_state from public.hub_chapters c
     where c.id = p_id and (c.is_active or (c.moderation_state is not null and public.is_moderator()));
    if not found then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
    if exists (select 1 from public.chapter_members cm
                where cm.chapter_id = p_id and cm.user_id = uid and cm.role in ('captain', 'organizer')) then
      raise exception 'own_item' using errcode = 'check_violation';
    end if;
  else
    -- Migration 54: likewise for hubs.
    select h.moderation_state into v_state from public.hubs h
     where h.id = p_id and (h.is_active or (h.moderation_state is not null and public.is_moderator()));
    if not found then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
  end if;
  if v_target_user = uid then
    raise exception 'own_item' using errcode = 'check_violation';
  end if;

  select r.id into v_id from public.reports r
   where r.target_kind = p_kind and r.target_id = p_id and r.reporter_id = uid and r.status = 'open';
  if v_id is not null then
    -- Migration 54: hidden says only whether this report hid it, never the target's state.
    return jsonb_build_object('id', v_id, 'already', true, 'hidden', false);
  end if;

  -- Twenty reports a day across kinds (places count their own).
  if not public.is_moderator() then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('reports:' || uid::text));
    if (select count(*) from public.reports r
         where r.reporter_id = uid and r.created_at > now() - interval '1 day') >= 20 then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = 'Up to twenty reports a day.';
    end if;
  end if;

  v_priority := case when p_reason = 'child_safety' then 0 when p_reason in ('ncii', 'underage') then 1 else 2 end;
  v_due := case when p_reason = 'child_safety' then interval '4 hours' else interval '24 hours' end;
  insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, note, priority, due_at)
  values (uid, p_kind, p_id, v_target_user, p_reason, v_note, v_priority, now() + v_due)
  returning id into v_id;

  -- Migration 58: the evidence copy of a reported message, with up to 10
  -- earlier and 5 later messages the reporter could see.
  if p_kind = 'message' then
    insert into public.message_report_evidence (report_id, message_id, conversation_id, conversation_kind,
                                                author_id, body, context)
    select v_id, m.id, m.conversation_id, c.kind, m.author_id,
           case when m.deleted_at is not null then coalesce(m.deleted_body, '') else m.body end,
           coalesce((
             select jsonb_agg(jsonb_build_object('id', x.id, 'seq', x.seq, 'author_id', x.author_id, 'kind', x.kind,
                                                 'body', x.body, 'created_at', x.created_at) order by x.seq)
               from ((select o.* from public.messages o
                       where o.conversation_id = m.conversation_id and o.seq < m.seq
                         and o.deleted_at is null and o.moderation_state is null
                         and private.chat_visible_author(o.author_id, uid)
                         and (o.author_id = uid or o.kind <> 'image' or o.image_state = 'visible')
                       order by o.seq desc limit 10)
                     union all
                     (select o.* from public.messages o
                       where o.conversation_id = m.conversation_id and o.seq > m.seq
                         and o.deleted_at is null and o.moderation_state is null
                         and private.chat_visible_author(o.author_id, uid)
                         and (o.author_id = uid or o.kind <> 'image' or o.image_state = 'visible')
                       order by o.seq asc limit 5)) x), '[]'::jsonb)
      from public.messages m
      join public.conversations c on c.id = m.conversation_id
     where m.id = p_id
    on conflict (report_id) do nothing;
  end if;

  -- Auto-hide at three (see the header): different active accounts older
  -- than a day, never the target; hubs are never auto-hidden.
  -- Migration 54: after a moderator dismissed or restored it in the last 30
  -- days, only a moderator hides it again; and nobody the target (for a
  -- chapter, one of its captains or organizers) blocked counts. The report
  -- itself is still filed.
  if p_kind not in ('hub', 'booking') and v_state is null   -- Migration 60: bookings are decided by mod_booking
     and not exists (select 1 from public.moderation_actions ma
                      where ma.target_kind = p_kind and ma.target_id = p_id
                        and ma.action in ('dismiss', 'restore') and ma.created_at > now() - interval '30 days') then
    select count(distinct r.reporter_id) into v_n
      from public.reports r
      join public.profiles rp on rp.id = r.reporter_id
     where r.target_kind = p_kind and r.target_id = p_id and r.status = 'open'
       and rp.status = 'active' and rp.deleted_at is null
       and rp.created_at <= now() - interval '1 day'
       and r.reporter_id is distinct from v_target_user
       and not exists (select 1 from public.blocks b
                        where b.blocked_id = r.reporter_id
                          and (b.blocker_id = v_target_user
                               or (p_kind = 'chapter' and b.blocker_id in (
                                     select cm.user_id from public.chapter_members cm
                                      where cm.chapter_id = p_id and cm.role in ('captain', 'organizer')))));
    if v_n >= 3 then
      perform public.moderation_set_state(p_kind, p_id, 'hidden');
      insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, report_count)
      values (null, 'auto_hide', p_kind, p_id, v_target_user, v_n);
      v_hidden := true;
    end if;
  end if;

  return jsonb_build_object('id', v_id, 'already', false, 'hidden', v_hidden);   -- Migration 54
end $$;

comment on function public.report_content(text, uuid, text, text) is
  'Migration 51 (54, 58, 60): report a profile, event, chapter, hub, message, coach listing, coach review, review reply or booking (kind place hands over to report_place). Reasons: harassment, hate, sexual_content, violence, spam, scam, impersonation, underage, unsafe, ncii, child_safety, other; booking reports also no_show and payment. One open report per person per target (a repeat returns already true). Hides a profile, plan, chapter, message, listing, review or reply pending review at three reports from different active accounts older than a day, not counting anyone the target (or a captain of the chapter) blocked, and never within 30 days of a moderator dismissing or restoring it; hubs and bookings are never auto-hidden. A message report needs a message the caller can read (an author-deleted one within 30 days) and copies it with its context into message_report_evidence. A listing, review or reply must be one the caller can see; only a party reports a booking (target: the other party). Returns {id, already, hidden}; hidden is true only when this report hid it. Errors: not_authenticated, invalid_kind, onboarding_required, invalid_reason, target_not_found, own_item, rate_limited (20 a day).';

-- mod_moderate (migration 58 body)
create or replace function public.mod_moderate(p_kind text, p_id uuid, p_action text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid           uuid := (select auth.uid());
  v_note        text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  v_target_user uuid;
  v_state       text;
  v_new         text;
  v_open        integer;
  v_snapshot    jsonb;
  e             public.events%rowtype;
  p             public.profiles%rowtype;
  v_b           uuid;   -- Migration 60
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_kind is null or p_id is null
     or p_kind not in ('profile', 'event', 'chapter', 'hub', 'message',                   -- Migration 58
                       'coach_listing', 'coach_review', 'coach_review_reply', 'booking') then   -- Migration 60
    raise exception 'invalid_kind' using errcode = 'check_violation';
  end if;
  if p_action is null or p_action not in ('dismiss', 'hide', 'remove', 'restore') then
    raise exception 'invalid_action' using errcode = 'check_violation';
  end if;
  -- Migration 60: a booking is decided by mod_booking; here its reports can only be dismissed.
  if p_kind = 'booking' and p_action <> 'dismiss' then
    raise exception 'invalid_action' using errcode = 'check_violation', hint = 'Use mod_booking.';
  end if;

  if p_kind = 'profile' then
    select * into p from public.profiles where id = p_id for update;
    if not found or p.deleted_at is not null then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
    v_target_user := p.id;
    v_state := p.moderation_state;
  elsif p_kind = 'event' then
    select * into e from public.events where id = p_id for update;
    if not found then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
    v_target_user := e.host_id;
    v_state := e.moderation_state;
  elsif p_kind = 'message' then
    -- Migration 58: a chat message (soft delete only; nothing is hard-deleted).
    select m.author_id, m.moderation_state into v_target_user, v_state from public.messages m
     where m.id = p_id for update;
    if not found then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
  elsif p_kind = 'coach_listing' then
    -- Migration 60
    select l.coach_id, l.moderation_state into v_target_user, v_state from public.coach_listings l
     where l.id = p_id for update;
    if not found then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
  elsif p_kind in ('coach_review', 'coach_review_reply') then
    select case when p_kind = 'coach_review' then r.client_id else r.coach_id end,
           case when p_kind = 'coach_review' then r.moderation_state else r.reply_moderation_state end
      into v_target_user, v_state
      from public.coach_reviews r where r.booking_id = p_id for update;
    if not found then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
  elsif p_kind = 'booking' then
    select b.coach_id into v_target_user from public.bookings b where b.id = p_id for update;
    if not found then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
  elsif p_kind = 'chapter' then
    select c.moderation_state into v_state from public.hub_chapters c where c.id = p_id for update;
    if not found then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
  else
    select h.moderation_state into v_state from public.hubs h where h.id = p_id for update;
    if not found then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
  end if;
  if public.moderation_is_own(p_kind, p_id, v_target_user) then
    raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews this one.';
  end if;

  select count(*)::integer into v_open from public.reports r
   where r.target_kind = p_kind and r.target_id = p_id and r.status = 'open';
  if p_action = 'dismiss' and v_open = 0 then
    raise exception 'item_not_pending' using errcode = 'check_violation';
  end if;

  if p_action in ('dismiss', 'restore') then
    -- Reports were wrong, or a moderator undoes a hide or removal: back to normal.
    v_new := null;
    if v_state is not null then
      perform public.moderation_set_state(p_kind, p_id, null);
    end if;
  elsif p_action = 'hide' then
    v_new := 'hidden';
    perform public.moderation_set_state(p_kind, p_id, 'hidden');
  else
    -- Soft delete.
    if p_kind = 'profile' then
      v_new := null;
      v_snapshot := jsonb_build_object('avatar_url', p.avatar_url, 'bio', p.bio);
      update public.profiles
         set avatar_url = null, bio = '', moderation_state = null, moderated_at = now()
       where id = p.id;
    else
      v_new := 'removed';
      perform public.moderation_set_state(p_kind, p_id, 'removed');
      -- Migration 60: a removed listing's open bookings end with full refunds.
      if p_kind = 'coach_listing' then
        for v_b in select b.id from public.bookings b
                    where b.listing_id = p_id and (b.status = 'requested' or (b.status = 'confirmed' and b.starts_at > now())) loop
          perform private.booking_cancel(v_b, 'moderator', 'listing_removed', 'full', true);
        end loop;
      end if;
      if p_kind = 'event' and e.status = 'published' and e.starts_at > now() then
        update public.events
           set status = 'cancelled', cancelled_at = now(), cancel_reason = 'moderator_removed'
         where id = e.id;
        perform public.notify_event_audience(
          e.id, 'event_cancelled', array['going', 'waitlisted', 'interested']::public.rsvp_status[],
          e.id::text, null, jsonb_build_object('reason', 'moderator_removed'));
      end if;
    end if;
  end if;

  update public.reports
     set status = case when p_action in ('dismiss', 'restore') then 'dismissed' else 'actioned' end,
         resolved_by = uid, resolved_at = now()
   where target_kind = p_kind and target_id = p_id and status = 'open';

  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id,
                                         report_count, note, snapshot)
  values (uid, p_action, p_kind, p_id, v_target_user, v_open, v_note, v_snapshot);

  return jsonb_build_object('kind', p_kind, 'id', p_id, 'action', p_action, 'state', v_new,
                            'reports_closed', v_open);
end $$;

comment on function public.mod_moderate(text, uuid, text, text) is
  'Migration 51 (58, 60), moderators: act on a profile, event, chapter, hub, message, coach listing, coach review, review reply or booking. dismiss (needs open reports) and restore clear a hide or removal and dismiss the open reports; hide holds it for review; remove is the soft delete (a profile loses its photo and bio, kept in the log; an upcoming plan is cancelled and its audience told; a hub or chapter goes inactive; a message reads "Removed by moderators"; a removed listing''s open bookings are cancelled with full refunds). Booking reports can only be dismissed here (mod_booking decides them). hide and remove action the open reports. Logged in moderation_actions. Errors: not_authenticated, forbidden, invalid_kind, invalid_action, target_not_found, own_item (second-moderator rule), item_not_pending.';

-- mod_queue (migration 58 body)
create or replace function public.mod_queue(p_limit integer default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 500);
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return coalesce((
    with q as (
      -- Reports on people, plans, chapters and hubs, one item per target.
      select 'report'::text as source,
             g.target_kind || ':' || g.target_id::text as id,
             coalesce(case g.target_kind
                        when 'profile' then (select p.first_name from public.profiles p where p.id = g.target_id)
                        when 'event'   then (select e.title from public.events e where e.id = g.target_id)
                        when 'chapter' then (select c.name from public.hub_chapters c where c.id = g.target_id)
                        when 'message' then 'Message'   -- Migration 58
                        -- Migration 60
                        when 'coach_listing' then (select l.title from public.coach_listings l where l.id = g.target_id)
                        when 'coach_review' then 'Review'
                        when 'coach_review_reply' then 'Review reply'
                        when 'booking' then (select b.title from public.bookings b where b.id = g.target_id)
                        else (select h.name from public.hubs h where h.id = g.target_id) end, '') as title,
             g.target_kind as detail,
             g.priority::integer as priority, g.first_at as received_at, g.due_at, g.n as count,
             not public.moderation_is_own(g.target_kind, g.target_id, g.target_user_id) as can_act,
             jsonb_build_object('kind', g.target_kind, 'target_id', g.target_id,
                                'reasons', (select coalesce(jsonb_agg(distinct r2.reason), '[]'::jsonb)
                                              from public.reports r2
                                             where r2.target_kind = g.target_kind and r2.target_id = g.target_id
                                               and r2.status = 'open')) as ref
        from (select r.target_kind, r.target_id, min(r.priority) as priority, min(r.due_at) as due_at,
                     min(r.created_at) as first_at, count(*)::integer as n,
                     (array_agg(r.target_user_id) filter (where r.target_user_id is not null))[1] as target_user_id
                from public.reports r
               where r.status = 'open'
               group by r.target_kind, r.target_id) g
      union all
      -- NCII takedown requests.
      select 'takedown', t.id::text, t.reference,
             case when t.status = 'waiting' then 'waiting' else 'ncii' end,
             t.priority::integer, t.created_at, t.due_at, 1,
             t.target_user_id is distinct from uid,
             jsonb_build_object('request_id', t.id, 'involves_minor', t.involves_minor, 'status', t.status)
        from public.takedown_requests t
       where t.status in ('open', 'waiting')
      union all
      -- Places with open reports.
      select 'place_report', pr.place_id::text, coalesce(pl.name, ''), 'place',
             case when bool_or(pr.reason in ('private_residence', 'unsafe')) then 1 else 2 end,
             min(pr.created_at), min(pr.created_at) + make_interval(hours => public.mod_sla_hours('place_report')),
             count(*)::integer,
             not coalesce(bool_or(pr.reporter_id = uid), false),   -- Migration 54: any report the moderator filed
             jsonb_build_object('place_id', pr.place_id)
        from public.place_reports pr
        join public.places pl on pl.id = pr.place_id
       where pr.status = 'open'
       group by pr.place_id, pl.name
      union all
      -- Pending public member places.
      select 'place', pl.id::text, pl.name, 'place', 2,
             pl.created_at, pl.created_at + make_interval(hours => public.mod_sla_hours('place')), 1,
             pl.created_by is distinct from uid,
             jsonb_build_object('place_id', pl.id)
        from public.places pl
       where pl.source = 'user' and pl.is_public and pl.status = 'pending'
      union all
      -- Pending corrections on places that still exist.
      select 'place_edit', pe.id::text, pl.name, 'place', 2,
             pe.created_at, pe.created_at + make_interval(hours => public.mod_sla_hours('place_edit')), 1,
             pe.proposed_by is distinct from uid,
             jsonb_build_object('place_id', pe.place_id, 'edit_id', pe.id)
        from public.place_edits pe
        join public.places pl on pl.id = pe.place_id
       where pe.status = 'pending' and pl.status <> 'removed'
      union all
      -- Pending chapter claims.
      select 'claim', cc.id::text, cc.proposed_name, cc.kind, 2,
             cc.created_at, cc.created_at + make_interval(hours => public.mod_sla_hours('claim')), 1,
             cc.user_id <> uid,
             jsonb_build_object('claim_id', cc.id)
        from public.chapter_claims cc
       where cc.status = 'pending'
      union all
      -- Member calendar suggestions.
      select 'calendar', sc.id::text, sc.host, 'calendar', 2,
             sc.created_at, sc.created_at + make_interval(hours => public.mod_sla_hours('calendar')),
             greatest(sc.suggest_count, 1),
             true,
             jsonb_build_object('candidate_id', sc.id)
        from public.source_candidates sc
       where sc.review_status = 'pending'
    ), picked as (
      select * from q order by q.priority, q.due_at, q.received_at, q.source, q.id limit v_limit
    )
    select jsonb_agg(jsonb_build_object(
             'source', x.source,
             'id', x.id,
             'title', x.title,
             'detail', x.detail,
             'priority', x.priority,
             'received_at', x.received_at,
             'due_at', x.due_at,
             'overdue', x.due_at < now(),
             'minutes_left', floor(extract(epoch from (x.due_at - now())) / 60)::integer,
             'count', x.count,
             'can_act', x.can_act,
             'ref', x.ref
           ) order by x.priority, x.due_at, x.received_at, x.source, x.id)
      from picked x), '[]'::jsonb);
end $$;



-- block_user (migration 58 body)
create or replace function public.block_user(p_user uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  v_already boolean;
  v_shared  integer;
  v_b       record;    -- Migration 60
  v_bk      integer := 0;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_user is null or p_user = uid then
    raise exception 'cannot_block_self' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.profiles where id = uid and status = 'active' and deleted_at is null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.profiles where id = p_user and deleted_at is null) then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;
  v_already := exists (select 1 from public.blocks where blocker_id = uid and blocked_id = p_user);
  if not v_already then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('blocks:' || uid::text));
    if (select count(*) from public.blocks where blocker_id = uid) >= 1000 then
      raise exception 'too_many_blocks' using errcode = 'check_violation', hint = 'Up to 1000 blocks.';
    end if;
    insert into public.blocks (blocker_id, blocked_id) values (uid, p_user) on conflict do nothing;
  end if;
  -- A block replaces a mute, and neither person keeps a "met" pick of the other.
  delete from public.mutes where muter_id = uid and muted_id = p_user;
  delete from public.event_meets
   where (user_id = uid and met_user_id = p_user) or (user_id = p_user and met_user_id = uid);
  -- Migration 58: a DM between them closes and a pending request is declined.
  update public.message_requests set status = 'declined', decided_at = now()
   where status = 'pending'
     and conversation_id in (select c.id from public.conversations c
                              where c.kind = 'dm' and c.dm_key = private.chat_dm_key(uid, p_user));
  update public.conversations set closed_at = coalesce(closed_at, now())
   where kind = 'dm' and dm_key = private.chat_dm_key(uid, p_user);
  -- Migration 60: their open bookings end, silently (design section 3.7). Requests are declined;
  -- a confirmed booking is cancelled: a block by the coach refunds in full, a block by the client
  -- is a client cancellation at this moment.
  for v_b in select b.id, b.status, (b.coach_id = uid) as by_coach from public.bookings b
              where ((b.coach_id = uid and b.client_id = p_user) or (b.coach_id = p_user and b.client_id = uid))
                and (b.status = 'requested' or (b.status = 'confirmed' and b.starts_at > now())) loop
    if v_b.status = 'requested' then
      perform private.booking_decline(v_b.id, 'blocked', false);
    else
      perform private.booking_cancel(v_b.id, 'system', 'blocked', case when v_b.by_coach then 'full' else 'policy' end, false);
    end if;
    v_bk := v_bk + 1;
  end loop;
  -- Upcoming plans both are on (host or live RSVP), for the "you'll both be there" warning.
  select count(*)::integer into v_shared
    from public.events e
   where e.status = 'published' and e.ends_at > now()
     and (e.host_id = uid or exists (select 1 from public.rsvps r
                                      where r.event_id = e.id and r.user_id = uid and r.status <> 'cancelled'))
     and (e.host_id = p_user or exists (select 1 from public.rsvps r
                                         where r.event_id = e.id and r.user_id = p_user and r.status <> 'cancelled'));
  return jsonb_build_object('blocked', true, 'already', v_already, 'shared_upcoming', v_shared,
                            'bookings_ended', v_bk);   -- Migration 60
end $$;

comment on function public.block_user(uuid) is
  'Migration 51 (58, 60): blocks p_user for the caller (symmetric in every read path). Removes the caller''s mute of them and both people''s "met" picks of each other; closes a DM between them and declines a pending request (migration 58); declines their open booking requests and cancels their upcoming confirmed bookings without a notice (migration 60: full refund when the coach blocks, the client-cancellation refund when the client blocks). Returns {blocked, already, shared_upcoming, bookings_ended}: shared_upcoming counts upcoming plans both are on, for a warning. Errors: not_authenticated, cannot_block_self, onboarding_required, user_not_found, too_many_blocks (1000).';

-- image_clear_references (migration 58 body)
create or replace function public.image_clear_references(p_bucket text, p_path text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_url text;
  v_n   integer := 0;
  v_c   integer;
begin
  -- Migration 58: chat images are referenced by path, not by URL.
  if p_bucket = 'chat-images' and p_path is not null then
    update public.messages set image_state = 'blocked'
     where image_path = p_path and image_state is distinct from 'blocked';
    get diagnostics v_c = row_count; v_n := v_n + v_c;
    return v_n;
  end if;
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
  -- Migration 60: coach photos that use it go.
  delete from public.coach_photos where url = v_url;
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  return v_n;
end $$;

comment on function public.image_clear_references(text, text) is
  'Migration 52 (58, 60), internal: nulls profiles.avatar_url and the cover_url of events, event_series, hubs and hub_chapters that point at the object and deletes coach_photos rows that use it; for the chat-images bucket, sets image_state blocked on the messages that use it. Returns the rows changed.';

-- mod_ban_user (migration 54 body, 20261218000100_safety_review_fixes.sql)
create or replace function public.mod_ban_user(p_user uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_note  text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  p       public.profiles%rowtype;
  v_ids   uuid[];
  v_event uuid;
  v_open  integer;
  v_rsvps integer := 0;
  v_chapters uuid[];
  v_orphans  uuid[];
  v_b        record;   -- Migration 60
  v_bk       integer := 0;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_user is null or p_user = uid then
    raise exception 'own_item' using errcode = '42501';
  end if;
  select * into p from public.profiles where id = p_user for update;
  if not found or p.deleted_at is not null or p.status = 'deleted' then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;
  if p.status = 'banned' then
    return jsonb_build_object('banned', true, 'already', true);
  end if;
  if exists (select 1 from public.user_roles where user_id = p_user and role = 'admin') then
    raise exception 'cannot_ban_admin' using errcode = '42501';
  end if;
  if exists (select 1 from public.user_roles where user_id = p_user)
     and not public.has_role('admin'::public.app_role) then
    raise exception 'forbidden' using errcode = '42501', hint = 'Only an admin bans a moderator.';
  end if;
  if public.moderation_is_own('profile', p_user, p_user) then
    raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews this one.';
  end if;

  update public.profiles set status = 'banned', moderated_at = now() where id = p_user;
  update auth.users set banned_until = now() + interval '100 years' where id = p_user;
  delete from public.user_roles where user_id = p_user;
  -- Migration 54: every session ends now (refresh tokens go with them).
  delete from auth.sessions where user_id = p_user;

  -- Migration 54: chapter roles drop to member. A chapter left without an
  -- organizer gets an open report (no reporter) so a moderator hands it over.
  select coalesce(array_agg(cm.chapter_id), '{}') into v_orphans
    from public.chapter_members cm where cm.user_id = p_user and cm.role = 'organizer';
  with d as (
    update public.chapter_members set role = 'member'
     where user_id = p_user and role in ('captain', 'organizer')
    returning chapter_id
  )
  select coalesce(array_agg(distinct chapter_id), '{}') into v_chapters from d;
  select coalesce(array_agg(c.id), '{}') into v_orphans
    from public.hub_chapters c
   where c.id = any (v_orphans)
     and not exists (select 1 from public.chapter_members cm where cm.chapter_id = c.id and cm.role = 'organizer')
     and not exists (select 1 from public.reports r
                      where r.target_kind = 'chapter' and r.target_id = c.id and r.status = 'open'
                        and r.reporter_id is null);
  insert into public.reports (reporter_id, target_kind, target_id, reason, note, priority, due_at)
  select null, 'chapter', c, 'other', 'Its organizer was banned; it needs a new organizer.', 2, now() + interval '24 hours'
    from unnest(v_orphans) c;

  -- Hosted upcoming plans and series end, and their audience hears why
  -- (the same steps as account deletion, migration 36). Migration 54: plans
  -- already under way end too.
  update public.event_series
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'moderator_removed'
   where host_id = p_user and status = 'published';
  with u as (
    update public.events
       set status = 'cancelled', cancelled_at = now(), cancel_reason = 'moderator_removed'
     where host_id = p_user and status = 'published' and ends_at > now()   -- Migration 54
    returning id
  )
  select coalesce(array_agg(id), '{}') into v_ids from u;
  foreach v_event in array v_ids loop
    perform public.notify_event_audience(
      v_event, 'event_cancelled', array['going', 'waitlisted', 'interested']::public.rsvp_status[],
      v_event::text, null, jsonb_build_object('reason', 'moderator_removed'));
  end loop;

  -- Live RSVPs on other upcoming plans go; seats pass to the waitlist.
  for v_event in
    select r.event_id from public.rsvps r
      join public.events e on e.id = r.event_id
     where r.user_id = p_user and r.status <> 'cancelled' and e.status = 'published' and e.ends_at > now()
  loop
    update public.rsvps
       set status = 'cancelled', waitlist_position = null, approved_by_host = false,
           removed_by = uid, removed_at = now(), removed_reason = 'banned'
     where event_id = v_event and user_id = p_user;
    perform public.rsvp_promote_waitlist(v_event);
    v_rsvps := v_rsvps + 1;
  end loop;

  -- Migration 60: coaching. A banned coach's profile is suspended and their listings paused, and
  -- their upcoming bookings are cancelled with full refunds; a banned client's upcoming bookings
  -- are cancelled with the client-cancellation refund. The other side is told.
  update public.coach_profiles set status = 'suspended', suspended_at = now()
   where user_id = p_user and status <> 'suspended';
  update public.coach_listings set status = 'paused' where coach_id = p_user and status = 'active';
  for v_b in select b.id, b.coach_id from public.bookings b
              where (b.coach_id = p_user or b.client_id = p_user)
                and b.status in ('requested', 'confirmed') and b.starts_at > now() loop
    if private.booking_cancel(v_b.id, 'system', 'banned', case when v_b.coach_id = p_user then 'full' else 'policy' end, true) then
      v_bk := v_bk + 1;
    end if;
  end loop;

  update public.reports
     set status = 'actioned', resolved_by = uid, resolved_at = now()
   where target_kind = 'profile' and target_id = p_user and status = 'open';
  get diagnostics v_open = row_count;

  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, report_count, note)
  values (uid, 'ban', 'profile', p_user, p_user, v_open, v_note);

  return jsonb_build_object('banned', true, 'already', false, 'events_cancelled', cardinality(v_ids),
                            'rsvps_removed', v_rsvps, 'reports_closed', v_open,
                            'chapter_roles_removed', cardinality(v_chapters),             -- Migration 54
                            'chapters_need_organizer', cardinality(v_orphans),
                            'bookings_cancelled', v_bk);                                  -- Migration 60
end $$;

comment on function public.mod_ban_user(uuid, text) is
  'Migration 51 (54, 60), moderators: bans an account. Profile status banned (reads and RSVPs close at once), sign-in blocked for 100 years and every session ended, roles removed, chapter roles dropped to member (a chapter left without an organizer gets an open report for a moderator), hosted plans that have not ended and series cancelled with the audience told, live RSVPs on upcoming plans removed (waitlist promoted), a coach profile suspended with its listings paused and upcoming bookings cancelled (full refunds for the coach''s clients, the client-cancellation refund for a banned client), open reports on the profile actioned, logged. Only an admin bans a moderator; nobody bans an admin. Returns {banned, already, events_cancelled, rsvps_removed, reports_closed, chapter_roles_removed, chapters_need_organizer, bookings_cancelled}. Errors: not_authenticated, forbidden, own_item, user_not_found, cannot_ban_admin.';

-- request_account_deletion (migration 58 body)
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

comment on function public.request_account_deletion(text) is
  'Deletes the caller''s account immediately (migrations 36, 51, 52, 53, 58 and 60): ledger row (a year for a banned account), tombstone profile, private data, memberships, claims, notifications, attendance, blocks, mutes, place and content reports unattributed, moderator stamps and admin lookups by the caller unattributed, image hashes (blocked ones kept), hosted series and future events cancelled (attendees notified), RSVPs removed (waitlists promoted), messaging (pending requests sent removed with their message, DMs closed, owned groups handed over, member rows removed, empty conversations deleted, received messages kept under "Deleted user" without device keys, kept deleted text or images), coaching (open bookings cancelled with refunds and the other side told, coach profile, listings, availability, sessions and reviews by or about the caller deleted, client notes and meeting details cleared; past bookings and payment records kept under "Deleted user"), auth user banned. The delete-account Edge Function finishes (avatars, chat images, the Stripe connected account). Idempotent.';

-- ---------------------------------------------------------------------------
-- 14. RLS policies (design section 8). Clients never write these tables.
-- ---------------------------------------------------------------------------
drop policy if exists "coach_profiles_select" on public.coach_profiles;
create policy "coach_profiles_select" on public.coach_profiles for select to authenticated
  using (private.coach_visible(user_id));
drop policy if exists "coach_credentials_select" on public.coach_credentials;
create policy "coach_credentials_select" on public.coach_credentials for select to authenticated
  using (private.coach_visible(coach_id));
drop policy if exists "coach_photos_select" on public.coach_photos;
create policy "coach_photos_select" on public.coach_photos for select to authenticated
  using (private.coach_visible(coach_id));
drop policy if exists "coach_hubs_select" on public.coach_hubs;
create policy "coach_hubs_select" on public.coach_hubs for select to authenticated
  using (private.coach_visible(coach_id));
drop policy if exists "coach_listings_select" on public.coach_listings;
create policy "coach_listings_select" on public.coach_listings for select to authenticated
  using (private.coach_listing_visible(id));
drop policy if exists "coach_listing_private_select_own" on public.coach_listing_private;
create policy "coach_listing_private_select_own" on public.coach_listing_private for select to authenticated
  using (exists (select 1 from public.coach_listings l where l.id = listing_id and l.coach_id = (select auth.uid())));
drop policy if exists "coach_availability_rules_select_own" on public.coach_availability_rules;
create policy "coach_availability_rules_select_own" on public.coach_availability_rules for select to authenticated
  using (coach_id = (select auth.uid()));
drop policy if exists "coach_availability_exceptions_select_own" on public.coach_availability_exceptions;
create policy "coach_availability_exceptions_select_own" on public.coach_availability_exceptions for select to authenticated
  using (coach_id = (select auth.uid()));
drop policy if exists "bookings_select_party" on public.bookings;
create policy "bookings_select_party" on public.bookings for select to authenticated
  using ((select auth.uid()) in (coach_id, client_id));
drop policy if exists "coach_reviews_select" on public.coach_reviews;
create policy "coach_reviews_select" on public.coach_reviews for select to authenticated
  using (private.coach_visible(coach_id)
         and (moderation_state is null or (select auth.uid()) in (coach_id, client_id))
         and (client_id = (select auth.uid()) or not private.is_blocked_with(client_id)));
-- coach_sessions, booking_private, coach_stripe_accounts, booking_payments, stripe_events,
-- coach_fee_minimums and stripe_jobs: RLS on, no policy and no grant for clients.

-- ---------------------------------------------------------------------------
-- 15. pg_cron
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; coaching-tick and purge-coaching not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'coaching-tick') then
    perform cron.unschedule('coaching-tick');
  end if;
  perform cron.schedule('coaching-tick', '*/5 * * * *', 'select public.coaching_tick()');
  if exists (select 1 from cron.job where jobname = 'purge-coaching') then
    perform cron.unschedule('purge-coaching');
  end if;
  perform cron.schedule('purge-coaching', '41 4 * * *', 'select public.purge_coaching()');
end $$;

-- ---------------------------------------------------------------------------
-- 16. Privileges (explicit)
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  -- Private helpers and trigger functions: service role only (two are called by RLS policies).
  foreach f in array array[
    'private.coach_meta(text,text)', 'private.coach_payments_on()', 'private.coach_terms_version()',
    'private.refund_policy_version()', 'private.coach_fee(integer,text)',
    'private.booking_refund_minor(integer,text,timestamptz,timestamptz)', 'private.coach_member_error(uuid)',
    'private.coach_raise(text)', 'private.coach_visible(uuid)', 'private.coach_listing_visible(uuid)',
    'private.coach_listing_payable(uuid)', 'private.coach_text_ok(text)',
    'private.booking_notify(uuid,uuid,text,jsonb)', 'private.coach_profiles_before()',
    'private.coach_sessions_busy()', 'private.coach_refresh_counts(uuid)', 'private.coach_reviews_counts()',
    'private.bookings_counts()', 'private.coach_slot_candidates(uuid,date,date)', 'private.coach_session_seats(uuid)',
    'private.coach_open_slots(uuid,date,date)', 'private.coach_require_profile(uuid)', 'private.coach_hub_allowed(uuid)',
    'private.booking_report(uuid,uuid,uuid,text,text)', 'private.booking_cancel(uuid,text,text,text,boolean)',
    'private.booking_decline(uuid,text,boolean)', 'private.booking_confirm(uuid)', 'private.booking_for_party(uuid,text)',
    'private.booking_no_show(uuid,text)', 'private.review_text_ok(text)', 'private.coach_review_json(uuid)',
    'private.booking_json(uuid,boolean)', 'private.stripe_account_apply(uuid,jsonb)',
    'private.chat_shared_context(uuid,uuid)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array['private.coach_visible(uuid)', 'private.coach_listing_visible(uuid)'] loop
    execute format('grant execute on function %s to authenticated', f);
  end loop;

  -- Signed-in RPCs.
  foreach f in array array[
    'public.upsert_coach_profile(jsonb)', 'public.accept_coach_terms(text)', 'public.publish_coach_profile()',
    'public.pause_coach_profile()', 'public.set_coach_credentials(jsonb)', 'public.set_coach_photos(text[])',
    'public.set_coach_hubs(uuid[])', 'public.upsert_listing(jsonb)',
    'public.set_listing_status(uuid,public.listing_status)', 'public.set_availability(jsonb)',
    'public.add_availability_exception(jsonb)', 'public.remove_availability_exception(uuid)',
    'public.schedule_group_session(uuid,timestamptz)', 'public.cancel_group_session(uuid)',
    'public.confirm_booking(uuid)', 'public.decline_booking(uuid)', 'public.cancel_booking(uuid,text)',
    'public.set_booking_meeting(uuid,text,text)', 'public.complete_booking(uuid)', 'public.mark_no_show(uuid)',
    'public.report_coach_no_show(uuid)', 'public.contest_no_show(uuid,text)',
    'public.request_booking(uuid,timestamptz,text,text,uuid)', 'public.write_review(uuid,integer,text)',
    'public.reply_to_review(uuid,text)', 'public.coaching_config()', 'public.coach_slots(uuid,date,date)',
    'public.coach_reviews_page(uuid,jsonb,integer)', 'public.get_coach(text)',
    'public.search_coaches(double precision,double precision,integer,uuid,public.listing_delivery,text,integer,text,jsonb,integer)',
    'public.get_booking(uuid)', 'public.my_bookings(text,text,jsonb,integer)', 'public.my_bookings_with(uuid)',
    'public.coach_payout_status()', 'public.mod_set_coach_status(uuid,text,text)', 'public.mod_booking(uuid,text,text)',
    'public.mod_coaching_numbers()']
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;

  -- Service role only (the Edge Functions and pg_cron).
  foreach f in array array[
    'public.stripe_dispatch_verify_secret(text)', 'public.stripe_dispatch()', 'public.stripe_connect_context(uuid)',
    'public.stripe_account_upsert(uuid,jsonb)', 'public.stripe_account_sync(text,jsonb)',
    'public.stripe_account_closed(text)', 'public.booking_checkout_params(uuid,uuid)',
    'public.booking_checkout_opened(uuid,text,integer,integer,text,text)',
    'public.booking_mark_paid(uuid,text,text,integer)', 'public.booking_payment_expired(text)',
    'public.booking_refund_recorded(text,integer)', 'public.booking_dispute_update(text,text,boolean)',
    'public.stripe_event_begin(text,text,text,text,boolean)', 'public.stripe_event_finish(text,text)',
    'public.stripe_jobs_claim(integer)', 'public.stripe_job_done(bigint,boolean,text)',
    'public.stripe_checkout_heartbeat()', 'public.coaching_tick()', 'public.purge_coaching()']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- Rebuilt functions keep their grants (create or replace does not change them); restated here.
revoke all on function public.enqueue_notification(uuid, public.notification_kind, text, uuid, uuid, uuid, uuid, jsonb, boolean)
  from public, anon, authenticated;
revoke all on function public.claim_pending_notifications(integer) from public, anon, authenticated;
grant execute on function public.claim_pending_notifications(integer) to service_role;
revoke all on function public.report_content(text, uuid, text, text) from public, anon;
grant execute on function public.report_content(text, uuid, text, text) to authenticated;
revoke all on function public.moderation_is_own(text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.moderation_is_own(text, uuid, uuid) to service_role;
revoke all on function public.moderation_set_state(text, uuid, text) from public, anon, authenticated;
grant execute on function public.moderation_set_state(text, uuid, text) to service_role;
revoke all on function public.mod_queue(integer) from public, anon;
grant execute on function public.mod_queue(integer) to authenticated;
revoke all on function public.mod_moderate(text, uuid, text, text) from public, anon;
grant execute on function public.mod_moderate(text, uuid, text, text) to authenticated;
revoke all on function public.block_user(uuid) from public, anon;
grant execute on function public.block_user(uuid) to authenticated;
revoke all on function public.mod_ban_user(uuid, text) from public, anon;
grant execute on function public.mod_ban_user(uuid, text) to authenticated;
revoke all on function public.image_clear_references(text, text) from public, anon, authenticated;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 17. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.56')
  on conflict (key) do update set value = excluded.value, updated_at = now();
