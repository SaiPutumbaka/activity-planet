# Coaching: design (release B, recorded as D-044)

Date: 2026-11-05. Status: recorded as D-044 (`docs/DECISIONS.md`). Spec: PLAN.md 4.7 (the **A** and **B** items; packages, subscriptions, group-clinic ticketing and coach analytics are **P**, post-launch), ROADMAP weeks 9 and 10, TRUST-SAFETY-LEGAL.md sections 1 (App Store 3.1.3), 2 (Play payments), 5 (Stripe Connect), 6 (Coach Terms, Refund Policy) and 11 (account deletion), D-026 (12% with a $3 minimum), FINANCIAL-PLAN section 5. Builds on the schema as it stands after migration 59 (`20261223000100_messaging_review_fixes.sql`, `meta.schema_version` 2.55): profiles and `profile_private` (home point, time zone), hubs and hub categories, the feed's origin chain and distance bands (migration 57), blocks and mutes and the unified reports and moderation (migrations 51, 54, 58), image-guard's reference trigger on the public `avatars` bucket (migration 52), the notification queue and delivery worker (migrations 18, 55, 56, as rebuilt in 58) and the messaging model (migrations 58 and 59, `docs/design/messaging/MESSAGING_DESIGN.md`).

Everyone, anywhere (D-040): coaches and clients are adults anywhere. Nothing is limited to students or to Atlanta, and no copy says so. In-app card payments are available where Stripe Connect supports the coach's country and currency; everywhere else the same listing works in requests-only mode.

**Short version.** A coach is a member with a `coach_profiles` row (headline, about, self-reported credentials labelled so, photos in the existing `avatars` bucket, hubs, an in-person service area and/or online, an IANA time zone). Coaches publish **listings**: any service, any price and currency, any duration, a delivery (`in_person` / `online`) and a format (`one_on_one` / `group`); a check constraint refuses `online` + `group` at launch. **Availability** is weekly recurring windows in the coach's time zone plus dated exceptions; **slots are generated in SQL** (`coach_slots`), never by the client. A client sends a **booking request**; the coach confirms or declines; the booking then ends `completed`, `cancelled` or `no_show`, each with its timestamp. A confirmed session lives in `coach_sessions`, whose **exclusion constraint** makes double booking impossible. **Reviews** exist only for completed bookings, one per booking, with one coach reply, reported and moderated through the existing `report_content` / `mod_moderate`. Coaches are found **near you** (the feed's origin chain and distance bands) and **by hub**. Client and coach talk in an ordinary **DM**: a booking is new "shared context" for `private.chat_shared_context`, so no message request is needed. **Payments** are Stripe Connect Express (onboarding link, account webhook, Checkout Session after confirmation, application fee max(12%, $3), refunds by policy, idempotent `stripe_events`, Edge Functions `stripe-connect`, `stripe-checkout`, `stripe-webhook`) but **key-gated**: without `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` the product runs in **requests only** mode: the price is shown, payment is arranged off-platform with a clear note, and every payment entry point is hidden. Coach Terms and the Refund Policy are DRAFT pages in `apps/web`, linked wherever a coach or client commits. Two build slices: database and Edge Functions, then the client.

---

## 1. Principles

1. **The database decides.** Who may coach, book, see a slot, confirm, cancel, review, message or be refunded is computed in SQL from the rows the rest of the app trusts. Slots, fees and refund amounts are computed server-side; the client renders them.
2. **Requests first, payments when keys exist.** Every flow works with no Stripe account at all. Payment is a layer on top of a confirmed booking, never a precondition for the booking model. With no keys, no payment UI, no Stripe call and no payment row exists.
3. **No double booking, by construction.** A scheduled session holds a time range for its coach under an exclusion constraint; two confirmations that overlap cannot both commit, whatever the race.
4. **Never touch card data.** Stripe Checkout (hosted) collects cards, Apple Pay and Google Pay. Activity Planet stores Stripe ids, amounts and states, never a card number, a bank account or an identity document.
5. **Blocks are symmetric and silent.** A blocked pair never sees each other's coach profile, listings, slots or reviews, cannot book each other, and their open bookings are cancelled (section 12).
6. **Free only.** Supabase Free (Postgres with `btree_gist`, pg_cron, pg_net, Storage), the existing image-guard, Resend and push. Stripe charges only per transaction and per active connected account, paid out of bookings (FINANCIAL-PLAN section 5); with no key it is not used at all.
7. **Honest labels.** Credentials say "Self-reported". A coach is never called "verified" unless they hold the existing Captain-style verification; coaching itself adds no badge.

## 2. Who can coach and who can book

| Rule                                                                                            | Coach                                      | Client                                  | Error                                       |
| ----------------------------------------------------------------------------------------------- | ------------------------------------------ | --------------------------------------- | ------------------------------------------- |
| Signed in, active, onboarded, 18+ (`viewer_is_adult()`)                                         | yes                                        | yes                                     | `not_authenticated` / `onboarding_required` |
| Profile photo set and its `image_hashes` row not `blocked` or `unreadable`                      | yes                                        | yes (the coach must know who is coming) | `photo_required`                            |
| Account at least 24 hours old                                                                   | yes                                        | yes                                     | `account_too_new`                           |
| Community Guidelines accepted (`profiles.guidelines_accepted_at`, the first-RSVP gate)          | yes                                        | yes, asked at the first booking request | `guidelines_required`                       |
| Coach Terms accepted, current version (`coach_profiles.terms_version`, `terms_accepted_at`)     | yes, at publish and again on a new version | no                                      | `coach_terms_required`                      |
| Refund / Cancellation Policy shown and acknowledged (version stored on the booking)             | no                                         | yes, on every request                   | `policy_ack_required`                       |
| Not banned, not suspended, coach profile not `suspended` by a moderator                         | yes                                        | yes                                     | `forbidden`                                 |
| Not blocked with the other person                                                               | n/a                                        | n/a                                     | `not_found` (the block is never revealed)   |
| Listing `min_age` (18 or 21; a 21+ hub forces 21) at or below the viewer's age (`viewer_age()`) | n/a                                        | yes                                     | `not_found`                                 |

Coach Terms state (TRUST-SAFETY-LEGAL 5, amended by D-044 for D-040): 18+; the coach is an independent service provider and Activity Planet the facilitator; the coach is legally allowed to do paid work where they coach (in the US that means work authorization; visa holders such as F-1 students generally may not take paid off-campus work); venue permission is the coach's responsibility; credentials are self-reported; taxes are the coach's responsibility; the Stripe Connected Account Agreement is incorporated when in-app payments are used. This wording applies to everyone and names no school or city.

## 3. Tables (migration 60, `20261224000100_coaching.sql`)

All new tables have RLS on, `revoke all ... from public, anon`, and explicit grants. Clients never write these tables directly: every write is a `security definer set search_path = ''` RPC that checks `auth.uid()` (section 7). `create extension if not exists btree_gist with schema extensions` is added for the exclusion constraint (free, in Supabase's extension list).

### 3.1 Enums

```sql
do $$ begin create type public.coach_status    as enum ('draft', 'active', 'paused', 'suspended'); exception when duplicate_object then null; end $$;
do $$ begin create type public.listing_delivery as enum ('in_person', 'online'); exception when duplicate_object then null; end $$;
do $$ begin create type public.listing_format   as enum ('one_on_one', 'group'); exception when duplicate_object then null; end $$;
do $$ begin create type public.listing_status   as enum ('active', 'paused', 'archived'); exception when duplicate_object then null; end $$;
do $$ begin create type public.booking_status   as enum ('requested', 'confirmed', 'declined', 'expired', 'cancelled', 'completed', 'no_show'); exception when duplicate_object then null; end $$;
do $$ begin create type public.booking_payment_state as enum
  ('none', 'off_platform', 'due', 'processing', 'paid', 'refund_pending', 'partially_refunded', 'refunded', 'disputed', 'failed');
exception when duplicate_object then null; end $$;
do $$ begin create type public.coach_session_status as enum ('scheduled', 'cancelled', 'done'); exception when duplicate_object then null; end $$;
```

### 3.2 Coach profile

```sql
create table if not exists public.coach_profiles (
  user_id            uuid primary key references public.profiles (id) on delete cascade,
  status             public.coach_status not null default 'draft',
  headline           text not null default '',        -- 3 to 80 characters to publish
  about              text not null default '',        -- at most 2,000
  timezone           text not null,                   -- IANA, validated like profile_private.timezone (migration 26 trigger)
  in_person          boolean not null default true,
  online             boolean not null default false,
  service_point      extensions.geography(Point, 4326), -- rounded to 0.01 degree by trigger; never granted to clients
  service_radius_km  smallint,                        -- 1 to 50; required with in_person
  area_label         text not null default '',        -- public, at most 80 ("Midtown, Atlanta", "Kreuzberg, Berlin")
  rating_avg         numeric(3,2),                    -- maintained by the review trigger; null with no reviews
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

create table if not exists public.coach_credentials (   -- always shown as "Self-reported"
  id        uuid primary key default gen_random_uuid(),
  coach_id  uuid not null references public.coach_profiles (user_id) on delete cascade,
  title     text not null check (char_length(title) between 2 and 80),   -- "USPTA Professional"
  issuer    text not null default '' check (char_length(issuer) <= 80),
  year      smallint check (year between 1950 and 2100),
  position  smallint not null default 0
);                                                       -- at most 10 per coach (RPC)

create table if not exists public.coach_photos (
  id        uuid primary key default gen_random_uuid(),
  coach_id  uuid not null references public.coach_profiles (user_id) on delete cascade,
  url       text not null,     -- public avatars URL under <uid>/coach/<uuid>.jpg (the existing owner-folder policies)
  position  smallint not null default 0,
  created_at timestamptz not null default now()
);                                                       -- at most 6 per coach (RPC)
-- trigger: image_guard_on_reference('url') (migration 52), like profiles.avatar_url

create table if not exists public.coach_hubs (
  coach_id  uuid not null references public.coach_profiles (user_id) on delete cascade,
  hub_id    uuid not null references public.hubs (id) on delete cascade,
  primary key (coach_id, hub_id)
);                                                       -- at most 10; hubs in sensitive categories refused
```

- **Photos** reuse the `avatars` bucket and its existing storage policies (public read, owner writes only under `<uid>/`), the client's 512 px resize path (a 1200 px long side for coach photos), image-guard's pHash check through the reference trigger, and the delete-account function's removal of the whole `avatars/<uid>/` folder. No new bucket, no new storage policy. When chat images' classifier is enabled (D-043), coach photos go through the same `classify` op before they are shown; until then they get the same treatment as profile photos.
- **Rates** are the listings' prices; the profile shows "From $40" as the lowest active listing price per currency (computed in `get_coach`).
- **Service area:** the coach picks a point (device or typed, geocoded like `set_home_location`) and a radius. The point is rounded to 0.01 degree on every write and is never selected by clients (column grants omit it); search returns only the feed's distance band. In-person session addresses are never public (section 3.5).
- **Sensitive hubs** (`hub_categories.is_sensitive`) cannot be coach hubs: a coach's hubs are public, and membership in those categories is hidden by design.

### 3.3 Listings

```sql
create table if not exists public.coach_listings (
  id               uuid primary key default gen_random_uuid(),
  coach_id         uuid not null references public.coach_profiles (user_id) on delete cascade,
  hub_id           uuid references public.hubs (id) on delete set null,
  title            text not null check (char_length(title) between 3 and 80),
  description      text not null default '' check (char_length(description) <= 2000),
  delivery         public.listing_delivery not null,
  format           public.listing_format not null,
  capacity         smallint not null default 1,
  duration_minutes smallint not null check (duration_minutes between 15 and 480),
  price_minor      integer not null check (price_minor between 0 and 10000000),  -- in the currency's minor unit; 0 = free
  currency         char(3) not null check (currency ~ '^[a-z]{3}$'),            -- ISO 4217, lower case like Stripe
  buffer_minutes   smallint not null default 0 check (buffer_minutes between 0 and 120),
  min_notice_hours smallint not null default 12 check (min_notice_hours between 1 and 336),
  max_advance_days smallint not null default 60 check (max_advance_days between 1 and 180),
  slot_step_minutes smallint not null default 30 check (slot_step_minutes in (15, 30, 60)),
  auto_confirm     boolean not null default false,   -- default true for group listings (RPC)
  min_age          smallint not null default 18 check (min_age in (18, 21)),
  status           public.listing_status not null default 'active',
  moderation_state text,                             -- null | hidden | removed (mod_moderate)
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  -- Launch listing shapes (PLAN 4.7 B, TRUST-SAFETY-LEGAL 1 and 2): online group sessions are an
  -- in-app-purchase product under App Store 3.1.3(d) and wait for P.
  constraint coach_listings_launch_shape check (not (delivery = 'online' and format = 'group')),
  constraint coach_listings_capacity check (
    (format = 'one_on_one' and capacity = 1) or (format = 'group' and capacity between 2 and 50))
);  -- upsert_listing also requires a delivery the coach offers (coach_profiles.in_person / online)
create index if not exists coach_listings_coach_idx on public.coach_listings (coach_id) where status = 'active';
create index if not exists coach_listings_hub_idx on public.coach_listings (hub_id) where status = 'active';

create table if not exists public.coach_listing_private (  -- the coach and confirmed clients only
  listing_id       uuid primary key references public.coach_listings (id) on delete cascade,
  meeting_note     text not null default '' check (char_length(meeting_note) <= 500),  -- "North gate of the courts"
  online_link      text check (online_link is null or online_link ~ '^https://')       -- default call link
);
```

- `coach_listings_launch_shape` is the database constraint PLAN 4.7 asks for. The same sentence appears in Coach Terms and in the App Review notes (TRUST-SAFETY-LEGAL 1). Removing it is a P decision with web checkout in the system browser.
- **Currency:** any ISO 4217 code is allowed for display and requests-only bookings. A listing is **payable in-app** only when payments are on (section 9), the coach's Stripe account has `charges_enabled`, the listing currency equals the account's `default_currency`, the currency has a row in `coach_fee_minimums` (seeded `usd` 300; more added as markets open), and `price_minor` is at least twice the minimum fee. Otherwise it is a requests-only listing, with the same booking flow.
- At most 20 active listings per coach.

### 3.4 Availability

```sql
create table if not exists public.coach_availability_rules (
  id          uuid primary key default gen_random_uuid(),
  coach_id    uuid not null references public.coach_profiles (user_id) on delete cascade,
  weekday     smallint not null check (weekday between 1 and 7),   -- ISO: 1 = Monday, in the coach's time zone
  start_local time not null,
  end_local   time not null,                                       -- end > start; a window does not cross midnight
  listing_id  uuid references public.coach_listings (id) on delete cascade,  -- null = every listing
  valid_from  date,
  valid_until date,
  constraint coach_availability_rules_order check (end_local > start_local),
  constraint coach_availability_rules_dates check (valid_until is null or valid_from is null or valid_until >= valid_from)
);                                                                  -- at most 50 rules per coach

create table if not exists public.coach_availability_exceptions (
  id         uuid primary key default gen_random_uuid(),
  coach_id   uuid not null references public.coach_profiles (user_id) on delete cascade,
  kind       text not null check (kind in ('unavailable', 'available')),
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  note       text not null default '' check (char_length(note) <= 120),   -- coach-only
  constraint coach_availability_exceptions_order check (ends_at > starts_at and ends_at <= starts_at + interval '31 days')
);
```

Rules are stored as local wall-clock times in `coach_profiles.timezone`, so "Tuesdays 6 to 9 pm" stays 6 to 9 pm across daylight-saving changes. Exceptions are absolute instants (a holiday, an extra Saturday morning). Changing the coach's time zone keeps the wall-clock rules and shows a warning that future slots move.

### 3.5 Sessions and bookings

```sql
create table if not exists public.coach_sessions (
  id          uuid primary key default gen_random_uuid(),
  coach_id    uuid not null references public.coach_profiles (user_id) on delete cascade,
  listing_id  uuid not null references public.coach_listings (id) on delete cascade,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  busy        tstzrange not null,              -- [starts_at, ends_at + listing buffer), set by a before trigger (tstzrange is pg_catalog's)
  capacity    smallint not null,
  status      public.coach_session_status not null default 'scheduled',
  created_at  timestamptz not null default now(),
  cancelled_at timestamptz,
  constraint coach_sessions_order check (ends_at > starts_at),
  constraint coach_sessions_no_overlap exclude using gist (coach_id with =, busy with &&) where (status = 'scheduled')
);

create table if not exists public.bookings (
  id                 uuid primary key default gen_random_uuid(),
  listing_id         uuid references public.coach_listings (id) on delete set null,  -- the snapshot below survives the listing
  session_id         uuid references public.coach_sessions (id) on delete set null,  -- set at confirmation (group: at request)
  coach_id           uuid not null references public.profiles (id),   -- tombstone stays after deletion (no cascade)
  client_id          uuid not null references public.profiles (id),
  starts_at          timestamptz not null,
  ends_at            timestamptz not null,
  status             public.booking_status not null default 'requested',
  -- snapshot at request time: what the client agreed to
  title              text not null,
  delivery           public.listing_delivery not null,
  format             public.listing_format not null,
  price_minor        integer not null,
  currency           char(3) not null,
  fee_minor          integer not null default 0,     -- application fee (in-app payments only)
  payment_mode       text not null check (payment_mode in ('none', 'off_platform', 'stripe')),
  payment_state      public.booking_payment_state not null,
  policy_version     text not null,                  -- Refund Policy version acknowledged
  free_cancel_until  timestamptz not null,           -- starts_at - 24 hours
  client_note        text not null default '' check (char_length(client_note) <= 500),
  client_request_id  uuid not null,                  -- idempotency for request_booking
  -- lifecycle timestamps
  requested_at       timestamptz not null default now(),
  expires_at         timestamptz not null,           -- least(requested_at + 48 h, starts_at - 2 h)
  confirmed_at       timestamptz,
  declined_at        timestamptz,
  expired_at         timestamptz,
  pay_by             timestamptz,                    -- stripe only: least(confirmed_at + 24 h, starts_at - 2 h)
  paid_at            timestamptz,
  cancelled_at       timestamptz,
  cancelled_by       text check (cancelled_by in ('client', 'coach', 'system', 'moderator')),
  cancel_reason      text check (cancel_reason in ('client', 'coach', 'unpaid', 'slot_taken', 'blocked',
                                                   'banned', 'account_deleted', 'listing_removed', 'moderator')),
  completed_at       timestamptz,
  no_show_at         timestamptz,
  no_show_party      text check (no_show_party in ('client', 'coach')),
  no_show_contested_at timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
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
-- one live seat per client per session
create unique index if not exists bookings_seat_uq on public.bookings (session_id, client_id) where status in ('requested', 'confirmed');

create table if not exists public.booking_private (     -- the two parties only, through get_booking
  booking_id    uuid primary key references public.bookings (id) on delete cascade,
  meeting_note  text not null default '' check (char_length(meeting_note) <= 500),
  online_link   text check (online_link is null or online_link ~ '^https://')
);
```

- **Why sessions.** A one-on-one booking creates its own session at confirmation; a group listing's session is created by the coach (`schedule_group_session`) and clients book seats in it. Either way the coach's time is held by exactly one `scheduled` session row, and the exclusion constraint (`btree_gist` for `coach_id with =`) refuses any second session whose busy range overlaps, so two confirmations racing for the same hour cannot both commit. `busy` is maintained by a trigger because `timestamptz + interval` is not immutable and cannot be a generated column.
- **Requests do not hold time.** Several requests may ask for the same hour; the coach picks one. Confirming it inserts the session; the other overlapping requests are declined by the system in the same transaction with `cancel_reason = 'slot_taken'` (shown as "That time was just taken"). A client may also not hold two confirmed bookings that overlap (checked in the RPC, error `client_overlap`).
- **The meeting place and the call link** are copied from `coach_listing_private` into `booking_private` at confirmation, editable by the coach, and readable only by the two parties of a confirmed booking (in-person: from confirmation; online: from confirmation, and the link is also in the reminder). The public listing shows only `area_label` and the distance band. The booking page carries "Meet in public places" and the Safety Center link (TRUST-SAFETY-LEGAL 6).

### 3.6 States and timestamps

```
                 coach confirms (or auto_confirm)            after ends_at
 requested ─────────────────────────────────────► confirmed ───────────────► completed
   │  │  │                                          │   │                       (coach marks, or
   │  │  └─ coach declines ──► declined            │   │                        automatic at ends_at + 48 h)
   │  └──── expires_at passes ─► expired           │   └─ from starts_at + 15 min ─► no_show
   └─────── client withdraws ─► cancelled          │        (party client: coach marks;
                                                   │         party coach: client reports)
                                                   └─ client, coach, system or moderator ─► cancelled
```

| Transition        | Who                                  | When allowed                                                        | Stamps                                           |
| ----------------- | ------------------------------------ | ------------------------------------------------------------------- | ------------------------------------------------ |
| request           | client                               | a slot `coach_slots` returns, now                                   | `requested_at`, `expires_at`                     |
| confirm           | coach (or automatically)             | `requested`, before `expires_at` and `starts_at`                    | `confirmed_at`, `pay_by` (stripe)                |
| decline           | coach; system (`slot_taken`, block)  | `requested`                                                         | `declined_at`                                    |
| expire            | `coaching_tick`                      | `requested` past `expires_at`                                       | `expired_at`                                     |
| cancel            | client, coach, system, moderator     | `requested` or `confirmed`, before `starts_at` (moderator any time) | `cancelled_at`, `cancelled_by`, `cancel_reason`  |
| unpaid            | `coaching_tick`                      | stripe, `payment_state = 'due'` past `pay_by`                       | cancelled, `cancel_reason = 'unpaid'`            |
| complete          | coach; `coaching_tick` at end + 48 h | `confirmed`, after `ends_at`, no open no-show                       | `completed_at`                                   |
| no-show (client)  | coach                                | `confirmed`, `starts_at + 15 min` to `ends_at + 48 h`               | `no_show_at`, `no_show_party = 'client'`         |
| no-show (coach)   | client                               | `confirmed`, `starts_at + 15 min` to `ends_at + 48 h`               | `no_show_at`, `no_show_party = 'coach'`          |
| contest a no-show | the other party                      | within 48 h of `no_show_at`                                         | `no_show_contested_at`, opens a `booking` report |

Every transition is a definer RPC that locks the booking row (`for update`), re-checks the state, writes the stamps, and enqueues the notifications (section 11) in the same transaction. Late transitions answer `invalid_state`.

### 3.7 Cancellation windows (the Refund Policy, launch version `2026-12`)

| Event                                                            | In-app payment                                            | Requests only                                        |
| ---------------------------------------------------------------- | --------------------------------------------------------- | ---------------------------------------------------- |
| Coach declines, request expires, slot taken                      | nothing was charged                                       | nothing to settle                                    |
| Client cancels at least 24 hours before the start                | full refund, fee included                                 | the policy is shown as the expectation               |
| Client cancels less than 24 hours before                         | 50% refund; the fee is refunded proportionally            | as above                                             |
| Client no-show (not contested, or upheld)                        | no refund                                                 | as above                                             |
| Coach cancels (any time), coach no-show, coach banned or deleted | full refund, fee included                                 | as above                                             |
| Block by the coach                                               | full refund                                               | booking cancelled                                    |
| Block by the client                                              | treated as a client cancellation at that moment           | booking cancelled                                    |
| Contested no-show or a dispute about the session                 | the refund waits for a moderator's decision (24 h target) | moderators can cancel or mark, money is off-platform |

The window is stored on each booking (`free_cancel_until`, `policy_version`), so a later policy change never alters an existing booking. Coaches cannot set their own window at launch (one policy is simpler to state and to defend in a dispute); per-coach presets are a P item. Three coach cancellations inside 24 hours of the start within 30 days open an automatic `booking` report for moderators.

### 3.8 Reviews

```sql
create table if not exists public.coach_reviews (
  booking_id       uuid primary key references public.bookings (id) on delete cascade,  -- one per booking
  coach_id         uuid not null references public.profiles (id) on delete cascade,
  client_id        uuid not null references public.profiles (id) on delete cascade,
  rating           smallint not null check (rating between 1 and 5),
  body             text not null default '' check (char_length(body) <= 1000),
  created_at       timestamptz not null default now(),
  edited_at        timestamptz,
  reply            text check (reply is null or char_length(reply) between 1 and 1000),
  replied_at       timestamptz,
  moderation_state text,                    -- null | hidden | removed
  reply_moderation_state text
);
create index if not exists coach_reviews_coach_idx on public.coach_reviews (coach_id, created_at desc);
```

- Only the client of a **completed** booking may review it, from `completed_at` to 30 days later (`review_window_closed`); one review per booking (the primary key); editable for 7 days. A no-show or a cancellation cannot be reviewed.
- The coach may post **one reply** per review, editable for 7 days.
- `rating_avg`, `rating_count` and `completed_count` on `coach_profiles` are maintained by triggers and count only reviews with `moderation_state is null`.
- Reviews and replies are reported through `report_content('coach_review', booking_id, reason, note)` (target user: the client for the review; `'coach_review_reply'` targets the coach for the reply) and moderated through `mod_moderate`. Auto-hide at three different reporters applies as for other content. Text runs through the messaging link filter (no links) and the slur list (`message_filtered` becomes `review_filtered`).
- Blocks: a viewer never sees reviews written by someone they block or who blocks them; aggregates still count them, so blocking cannot game a coach's rating.

### 3.9 Payments tables (service role writes only)

```sql
create table if not exists public.coach_stripe_accounts (
  coach_id          uuid primary key references public.profiles (id) on delete cascade,
  stripe_account_id text not null unique check (stripe_account_id ~ '^acct_[A-Za-z0-9]+$'),
  country           char(2) not null,
  default_currency  char(3),
  charges_enabled   boolean not null default false,
  payouts_enabled   boolean not null default false,
  details_submitted boolean not null default false,
  requirements_due  text[] not null default '{}',   -- Stripe requirement keys only, no values
  disabled_reason   text,
  updated_at        timestamptz not null default now()
);

create table if not exists public.booking_payments (
  booking_id          uuid primary key references public.bookings (id) on delete restrict,
  checkout_session_id text unique,
  payment_intent_id   text unique,
  amount_minor        integer not null,
  fee_minor           integer not null,
  currency            char(3) not null,
  stripe_account_id   text not null,
  refunded_minor      integer not null default 0,
  refund_requested_minor integer not null default 0,
  disputed_at         timestamptz,
  dispute_status      text,
  last_error          text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table if not exists public.stripe_events (     -- idempotent webhook ledger
  id           text primary key check (id ~ '^evt_[A-Za-z0-9]+$'),
  type         text not null,
  account      text,                                  -- connected account for Connect events
  object_id    text,                                  -- cs_, pi_, ch_, re_, dp_ or acct_ id
  livemode     boolean not null,
  received_at  timestamptz not null default now(),
  processed_at timestamptz,
  error        text
);                                                    -- no payload is stored; purged after 90 days

create table if not exists public.coach_fee_minimums (
  currency      char(3) primary key,
  min_fee_minor integer not null check (min_fee_minor > 0)
);                                                    -- seeded ('usd', 300)

create table if not exists public.stripe_jobs (       -- outbound work the database asks for (refund, expire, close)
  id          bigserial primary key,
  booking_id  uuid references public.bookings (id) on delete restrict,   -- null only for close_account
  stripe_account_id text,                             -- close_account
  op          text not null check (op in ('refund', 'expire_checkout', 'close_account')),
  amount_minor integer,
  idempotency_key text not null unique,               -- 'refund:<booking>:<reason>'
  status      text not null default 'pending' check (status in ('pending', 'sent', 'done', 'failed')),
  attempts    smallint not null default 0,
  next_at     timestamptz not null default now(),
  last_error  text,
  created_at  timestamptz not null default now()
);
```

None of these are granted to `authenticated`; the parties read payment state through `get_booking` and the coach reads their own account state through `coach_payout_status()`. `booking_payments` rows are kept for 7 years (tax records, TRUST-SAFETY-LEGAL 11 "Payment records") and hold no card or bank data.

## 4. Slot generation (server-side)

`public.coach_slots(p_listing uuid, p_from date, p_to date) returns table (starts_at timestamptz, ends_at timestamptz, seats_left smallint)`, `security definer`, stable, at most 31 days per call, adults only, `not_found` across a block or for an inactive listing or coach.

1. Dates `d` from `greatest(p_from, today in the coach's zone)` to `least(p_to, today + max_advance_days)`.
2. For each rule matching `isodow(d)` (and the listing, and `valid_from`/`valid_until`), the window is `[(d + start_local) at time zone tz, (d + end_local) at time zone tz)`. A local time that does not exist on a spring-forward day is skipped (the round trip `(ts at time zone tz)::time` must equal the rule's time); an ambiguous fall-back time takes the first occurrence.
3. Add `available` exceptions; subtract `unavailable` exceptions.
4. One-on-one: candidate starts every `slot_step_minutes` from each window's start while `start + duration <= window end`; drop any whose `[start, end + buffer)` overlaps a `scheduled` session of the coach (any listing); drop starts before `now() + min_notice_hours`.
5. Group: the listing's `scheduled` sessions in the range with `capacity - live seats > 0`, returned with `seats_left`.

`request_booking` re-runs the same function for the requested start inside its transaction (`slot_unavailable` otherwise), so a client cannot book a time the server would not offer. The client shows slots in the viewer's time zone and labels the coach's zone when they differ ("6:00 pm your time, 3:00 pm for Sam").

## 5. Search and browse

`public.search_coaches(p_lat double precision default null, p_lng double precision default null, p_radius_km integer default null, p_hub_id uuid default null, p_delivery public.listing_delivery default null, p_query text default null, p_max_price_minor integer default null, p_currency text default null, p_before jsonb default null, p_limit integer default 20)`.

- **Origin:** the feed's chain (migration 57): the device point sent (rounded to 0.01 degree, never stored), else `profile_private.home_point`, else the home area centre, else Atlanta. Radius: the 10, 25, 50 km ladder, capped at 50.
- **In person:** a coach matches when the origin is within the coach's own `service_radius_km` of `service_point` **and** the coach is within the viewer's radius. Returns `distance_band` exactly as the feed does (`'<1 mi'`, `'1-5 mi'`, `'5-10 mi'`, `'10-25 mi'`, `'25+ mi'`; kilometres when the client's locale uses them), never a distance or a coordinate.
- **Online:** coaches with an active online listing match from anywhere, `distance_band = 'online'`.
- **By hub:** `p_hub_id` keeps coaches with that hub in `coach_hubs` or an active listing in it. Hub pages show "Coaches in this hub" through the same function.
- **Query:** trigram match on headline, listing titles and hub names (`pg_trgm`, already installed).
- **Excluded:** non-active coach profiles, coaches with no active unmoderated listing, banned, suspended or deleted accounts, listings over the viewer's age, and anyone blocked with the viewer in either direction.
- **Order:** hub match first when a hub is given, then distance band, then `rating_count >= 3` before fewer, then `rating_avg`, then `published_at desc`; keyset cursor on those keys and `user_id`.
- Returns per coach: `user_id, handle, first_name, avatar_url, headline, area_label, distance_band, in_person, online, rating_avg, rating_count, completed_count, from_price_minor, from_currency, hub_ids` (at most 3). Recommendations (ROADMAP week 11) later rank the same rows.

## 6. Messaging between client and coach

A booking reuses the `dm` conversation kind; there is no new conversation kind. `private.chat_shared_context(p_a, p_b)` is rebuilt from its migration 58 body (the latest) with one more arm, marked "Migration 60":

```sql
or exists (
  select 1 from public.bookings b
   where ((b.coach_id = p_a and b.client_id = p_b) or (b.coach_id = p_b and b.client_id = p_a))
     and (b.status in ('requested', 'confirmed')
          or (b.status in ('completed', 'no_show') and b.ends_at > now() - interval '180 days')))
```

So once a client sends a booking request, either side can open the DM with `start_dm` and it is `open`, not a request. Asking a coach a question before booking goes through the ordinary message request (D-043). The messaging rules otherwise stand: a profile photo to send, the rate limits, the link and slur filter, blocks closing the DM. Since a booking request now opens a DM, `request_booking` carries the same anti-spam limits as message requests (24-hour account, photo, at most 10 requests a day, 5 open requests at once, one open request per listing). The booking page has **Message** (`start_dm(other)` then `/chats/<id>`); the DM header shows the next booking with the other person ("Tennis, one hour · Sat 10:00"), read from `my_bookings_with(user)`.

## 7. RPCs (all `security definer set search_path = ''`, check `auth.uid()`, `revoke all from public, anon`, `grant execute to authenticated` unless marked)

Coach side:

| RPC                                                                                                     | Does                                                                                                                                         | Errors                                                                                |
| ------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `upsert_coach_profile(p jsonb)`                                                                         | creates or edits the caller's coach profile (headline, about, timezone, in_person, online, point, radius, area_label); the point is rounded  | rules in section 2, `timezone_invalid`, `invalid_area`, `invalid_text`                |
| `accept_coach_terms(p_version text)`                                                                    | stamps `terms_version`, `terms_accepted_at`                                                                                                  | `unknown_version`                                                                     |
| `publish_coach_profile()` / `pause_coach_profile()`                                                     | `draft`/`paused` to `active` (needs terms, photo, headline, at least one active listing and one availability rule or group session) and back | `coach_terms_required`, `incomplete_profile`, `forbidden` (suspended)                 |
| `set_coach_credentials(p jsonb)`, `set_coach_photos(p_urls text[])`, `set_coach_hubs(p_hub_ids uuid[])` | replace the lists (photo URLs must be the caller's `avatars/<uid>/coach/` objects; image-guard trigger refuses blocked images)               | `too_many`, `invalid_photo`, `image_blocked`, `hub_not_allowed`                       |
| `upsert_listing(p jsonb)` / `set_listing_status(p_id, p_status)`                                        | create or edit a listing and its private meeting note or link; price changes never touch existing bookings                                   | `invalid_shape` (the constraint), `delivery_not_offered`, `too_many`, `invalid_price` |
| `set_availability(p_rules jsonb)`                                                                       | replaces the weekly rules (validated, at most 50)                                                                                            | `invalid_rule`                                                                        |
| `add_availability_exception(p jsonb)` / `remove_availability_exception(p_id)`                           |                                                                                                                                              | `invalid_range`                                                                       |
| `schedule_group_session(p_listing, p_starts_at)` / `cancel_group_session(p_id)`                         | group listings only; cancelling cancels every seat (coach cancellation: full refunds)                                                        | `slot_taken` (exclusion), `not_group`                                                 |
| `confirm_booking(p_id)` / `decline_booking(p_id)`                                                       | section 3.6; confirm inserts the session (one-on-one) and declines overlapping requests                                                      | `invalid_state`, `slot_taken`, `expired`                                              |
| `set_booking_meeting(p_id, p_note, p_link)`                                                             | edits `booking_private` for a confirmed booking                                                                                              | `invalid_link`                                                                        |
| `complete_booking(p_id)` / `mark_no_show(p_id)`                                                         | coach marks done, or the client absent                                                                                                       | `too_early`, `invalid_state`                                                          |
| `reply_to_review(p_booking, p_text)`                                                                    | one reply, editable 7 days                                                                                                                   | `review_filtered`, `reply_locked`                                                     |
| `coach_payout_status()`                                                                                 | the caller's Stripe state (`none`, `onboarding`, `restricted`, `active`), requirement count, and whether payments are on                     |                                                                                       |

Client side and shared:

| RPC                                                                                      | Does                                                                                                                                                                                              | Errors                                                                                                          |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `coaching_config()`                                                                      | `{payments_enabled, policy_version, coach_terms_version, fee_percent: 12, fee_minimums}`; `payments_enabled` is `meta.coach_payments = 'on'` (section 9)                                          |                                                                                                                 |
| `search_coaches(...)`                                                                    | section 5                                                                                                                                                                                         | `invalid_coordinates`                                                                                           |
| `get_coach(p_handle)`                                                                    | profile, credentials (each with `self_reported: true`), photos, hubs, active listings with `payable` per listing, rating, the first page of reviews                                               | `not_found`                                                                                                     |
| `coach_reviews_page(p_coach, p_before)`                                                  | reviews newest first, keyset                                                                                                                                                                      | `not_found`                                                                                                     |
| `coach_slots(p_listing, p_from, p_to)`                                                   | section 4                                                                                                                                                                                         | `not_found`, `range_too_long`                                                                                   |
| `request_booking(p_listing, p_starts_at, p_note, p_policy_version, p_client_request_id)` | creates the booking with its snapshot, payment mode and windows; idempotent on `(client, client_request_id)`; with `auto_confirm` it confirms at once                                             | section 2, `slot_unavailable`, `client_overlap`, `rate_limited`, `too_many_open`, `policy_ack_required`, `full` |
| `cancel_booking(p_id, p_reason text default null)`                                       | client or coach; computes the refund (section 3.7) and queues it                                                                                                                                  | `invalid_state`, `too_late` (after the start)                                                                   |
| `report_coach_no_show(p_id)` / `contest_no_show(p_id, p_note)`                           | section 3.6; a contest opens a `booking` report                                                                                                                                                   | `too_early`, `too_late`, `invalid_state`                                                                        |
| `get_booking(p_id)`                                                                      | the booking for either party: other person, times, state, price, `payment_state`, refund amount, meeting note and link (confirmed only), `can_*` flags                                            | `not_found`                                                                                                     |
| `my_bookings(p_role text, p_scope text, p_before jsonb)`                                 | `client` or `coach`; `upcoming`, `requests`, `past`; keyset                                                                                                                                       |                                                                                                                 |
| `my_bookings_with(p_user)`                                                               | the next open booking with that person, for the DM header                                                                                                                                         |                                                                                                                 |
| `write_review(p_booking, p_rating, p_body)`                                              | section 3.8                                                                                                                                                                                       | `not_completed`, `review_window_closed`, `review_filtered`, `already_reviewed` (then it edits within 7 days)    |
| `booking_checkout_params(p_id)` (**service_role only**)                                  | for `stripe-checkout`: verifies the caller passed in is the client, the booking is `confirmed`, `payment_state = 'due'`, before `pay_by`; returns amount, fee, currency, account, title, `pay_by` | `not_payable`                                                                                                   |

Service role only (Edge Functions): `stripe_account_upsert`, `booking_checkout_opened`, `booking_mark_paid`, `booking_payment_expired`, `booking_refund_recorded`, `booking_dispute_update`, `stripe_event_begin` / `stripe_event_finish`, `stripe_jobs_claim` / `stripe_job_done`, `stripe_dispatch_verify_secret`.

Moderators (`is_moderator()` inside): `mod_set_coach_status(p_user, 'suspended' | 'active', p_note)` (suspension pauses listings and cancels future bookings with full refunds), `mod_booking(p_id, 'cancel_refund' | 'uphold_no_show' | 'reject_no_show' | 'complete', p_note)` for contested no-shows and disputes, and `mod_coaching_numbers()` (bookings this week, completed, GMV per currency, refunds, disputes) for the admin overview (PLAN 4.12).

### 7.1 Rebuilt from their latest bodies (each change marked "Migration 60")

| Function                                                                 | Latest body                          | Change                                                                                                                                                         |
| ------------------------------------------------------------------------ | ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `private.chat_shared_context`                                            | migration 58                         | the booking arm (section 6)                                                                                                                                    |
| `report_content`                                                         | migration 58                         | kinds `coach_listing` (target: the coach), `coach_review` (the client), `coach_review_reply` (the coach), `booking` (the other party; only a party may report) |
| `mod_moderate`, `moderation_set_state`, `moderation_is_own`, `mod_queue` | migration 58                         | the same kinds; `hide`/`remove`/`restore` set `moderation_state` on listings, reviews and replies; `booking` reports open `mod_booking`                        |
| `reports_target_kind`, `moderation_actions_kind` check constraints       | migration 58                         | dropped and re-added with the four kinds                                                                                                                       |
| `block_user`                                                             | migration 58                         | cancels the pair's `requested` and `confirmed` bookings (section 3.7's block rows)                                                                             |
| `mod_ban_user`                                                           | migration 54 (`safety_review_fixes`) | a banned coach: profile `suspended`, future bookings cancelled with full refunds; a banned client: future bookings cancelled with the policy's refund          |
| `enqueue_notification`, `claim_pending_notifications`                    | migration 58                         | the booking kinds (section 11): transactional, follow `notification_prefs.bookings`                                                                            |
| `image_clear_references`                                                 | migration 58                         | also deletes `coach_photos` rows pointing at a removed image                                                                                                   |
| `request_account_deletion`                                               | migration 58                         | section 13                                                                                                                                                     |

## 8. RLS and grants

- `coach_profiles`, `coach_credentials`, `coach_photos`, `coach_hubs`, `coach_listings`: `select` for `authenticated` where `viewer_is_adult()`, the coach is `active` (or it is the caller's own row), the owner is not banned or deleted, the listing is unmoderated and within the viewer's age, and `not private.is_blocked_with(coach)`. Column grants on `coach_profiles` omit `service_point`, `terms_*` and `suspended_at`. No `insert`, `update` or `delete` grants.
- `coach_listing_private`, `coach_availability_rules`, `coach_availability_exceptions`: owner `select` only.
- `coach_sessions`: no client grant (slots come from `coach_slots`).
- `bookings`: `select` for either party on a column list without `client_request_id`; `booking_private` through `get_booking` only.
- `coach_reviews`: `select` for adults when unmoderated (the author and the coach also see their own hidden rows with the label), minus blocked pairs.
- Payments tables, `stripe_events`, `stripe_jobs`, `coach_fee_minimums`: no grant to `authenticated`; service role only.
- `notification_prefs.bookings boolean not null default true` is added and granted for update like the other topic switches.

## 9. Payments: Stripe Connect Express, key-gated

### 9.1 Modes

| Mode              | When                                                                                                                                          | What people see                                                                                                                                                                                                                                                                                                                                                                |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Requests only** | default; `meta.coach_payments = 'off'`, or the function secrets are missing                                                                   | Prices on listings and bookings. Under every price on a booking screen: "Payment is arranged directly with Sam. Activity Planet doesn't process payments for this booking. Agree on the amount and how you'll pay before you meet." No Pay button, no payout settings, no fee line, no Stripe link anywhere. `payment_mode = 'off_platform'` (or `'none'` for a free listing). |
| **Payments on**   | an operator sets `meta.coach_payments = 'on'` only after `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` exist on that project (FOUNDER-TODO) | Coaches see "Get paid in the app" (Stripe onboarding). Payable listings take card, Apple Pay and Google Pay through Stripe Checkout after the coach confirms; the rest stay requests only with the note above.                                                                                                                                                                 |

Two gates, both needed: the database flag (what the app shows, read through `coaching_config()`) and the secrets (what the functions can do). If the flag is on but a function has no key, it answers `503 {error: "payments_off"}`; `request_booking` then still works, and the booking falls back to off-platform once `pay_by` passes (`coaching_tick` turns an unpaid booking whose checkout could never open into `off_platform` with a notice to both sides instead of cancelling it). "Could never open" is decided by `meta.stripe_checkout_seen_at`, which `stripe-checkout` stamps (`stripe_checkout_heartbeat`) whenever it runs with its key: with no stamp and no `booking_payments` row the booking falls back; otherwise an unpaid booking is cancelled (`unpaid`). No Stripe call is made from SQL; the database only queues `stripe_jobs` and dispatches to `stripe-checkout` through pg_net with a vault secret, like image-guard.

### 9.2 Onboarding (`stripe-connect`, `verify_jwt = true`)

- `POST {op: "onboard", country}`: the caller must be a coach who accepted Coach Terms. If no `coach_stripe_accounts` row exists, creates an Express account (`POST /v1/accounts`, `type=express`, `country`, `email` from `profile_private`, `capabilities[card_payments][requested]=true`, `capabilities[transfers][requested]=true`, `business_type=individual`, `business_profile[product_description]`, `settings[payouts][schedule][delay_days]=7`, `metadata[coach_id]`, idempotency key `acct:<coach id>`), stores it through `stripe_account_upsert`, then returns an Account Link (`POST /v1/account_links`, `type=account_onboarding`, `refresh_url` and `return_url` on the app's `/coach/payouts`). The country list is Stripe's supported Connect countries; the app asks for the country the coach works in.
- `POST {op: "dashboard"}`: a login link to the Express dashboard (`POST /v1/accounts/{id}/login_links`).
- `POST {op: "refresh"}`: retrieves the account and syncs `charges_enabled`, `payouts_enabled`, `details_submitted`, `requirements.currently_due` (keys only), `disabled_reason`, `default_currency`; the return page calls it, so the state is right even before the webhook arrives.

### 9.3 Checkout (`stripe-checkout`)

- `POST {op: "create", booking_id}` (user JWT): `booking_checkout_params` as the service role with the caller's id; creates a Checkout Session (`mode=payment`, one `line_items[0][price_data]` with `currency`, `unit_amount = price_minor`, `product_data[name] = title`; `payment_intent_data[application_fee_amount] = fee_minor`, `payment_intent_data[transfer_data][destination] = acct`, `payment_intent_data[metadata][booking_id]`; `client_reference_id = booking id`; `expires_at = max(now + 30 min, pay_by)` capped at 24 h; `success_url` and `cancel_url` back to `/bookings/<id>`; idempotency key `checkout:<booking>:<n>`), records it (`booking_checkout_opened`, `payment_state = 'processing'`) and returns the URL. In the bundled app the URL opens in the system browser or in-app browser, never a WebView that reads card input.
- Allowed shapes: in-person one-on-one, in-person group, online one-on-one (App Store 3.1.3(d) and (e); Play treats physical and one-to-one services alike). The launch-shape constraint makes the fourth impossible.
- **Destination charges.** The platform is the merchant of record and pays Stripe's processing out of its fee (D-026's proposal: the platform absorbs processing, so a $40 session pays the coach $35.20). `application_fee_amount = max(round(price * 0.12), min_fee)`, never more than half the price (listings under twice the minimum are not payable). The same function lives in SQL (`private.coach_fee(price, currency)`) and TypeScript (`fees.ts`), tested on the same fixtures.
- `POST {op: "job"}` (the database only, through pg_net; header `x-stripe-dispatch-secret` checked by `stripe_dispatch_verify_secret`; the function runs with `verify_jwt = false` and checks the user JWT itself for `create`, section 15): claims `stripe_jobs` and runs them. `refund`: `POST /v1/refunds` with `payment_intent`, `amount`, `refund_application_fee=true` (the fee comes back in proportion), `reverse_transfer=true` (the coach's share comes back from the connected account), idempotency key from the job. `expire_checkout`: `POST /v1/checkout/sessions/{id}/expire` when a booking is cancelled while its checkout is open. A pg_cron tick re-dispatches pending jobs every 5 minutes with backoff; a job failing 8 times is `failed` and appears in the admin health panel.

### 9.4 Webhook (`stripe-webhook`, `verify_jwt = false`)

- Verifies `Stripe-Signature` (HMAC-SHA256 over `t.payload` with Web Crypto, 300-second tolerance, constant-time compare) against `STRIPE_WEBHOOK_SECRET` and, for Connect events from connected accounts, `STRIPE_CONNECT_WEBHOOK_SECRET` (Stripe gives a Connect endpoint its own secret; if that one is absent, account state is synced by `stripe-connect` `refresh`). No Stripe SDK: plain `fetch` and Web Crypto, so the functions run under Deno with no dependency and are unit-testable.
- **Idempotent.** `stripe_event_begin(id, type, account, object_id, livemode)` inserts into `stripe_events` `on conflict do nothing` and returns whether this delivery is new or a retry of one that did not finish; an already processed event answers `200` at once. After handling, `stripe_event_finish(id, error)`. Every handler is itself idempotent (state checks, unique ids), so a replay is harmless.
- Handled: `account.updated` (sync), `account.application.deauthorized` (charges off, payable listings fall back to requests only), `checkout.session.completed` with `payment_status = 'paid'` (`booking_mark_paid`: `paid`, `paid_at`, the payment intent id; if the booking was cancelled meanwhile, a full refund job is queued at once), `checkout.session.expired` (back to `due` if still before `pay_by`), `charge.refunded` and `refund.updated` (`refunded_minor`, `partially_refunded` or `refunded`), `charge.dispute.created` and `charge.dispute.closed` (`disputed`, an automatic `booking` report with no reporter, the coach notified; a lost dispute counts toward the coach's record). Everything else answers `200` and is recorded.
- `livemode` must match the key's mode (`sk_live_` or `sk_test_`); a mismatch is recorded and ignored. Staging uses test keys only.
- Logs carry event ids and types only, never emails, names or amounts tied to a person (the Actions logs and the repo are public).

### 9.5 Liability notes (TRUST-SAFETY-LEGAL 5)

Express makes the platform liable for negative balances and disputes. The design limits exposure: payment after confirmation (no refunds for declines), a 7-day payout delay so a no-show refund can be reversed from the coach's balance, refunds always with `reverse_transfer`, the fee refunded in proportion (Stripe does not do this by default), disputes routed to moderators, and coaches with repeated disputes suspended. FINANCIAL-PLAN's note stands: until the LLC exists, keep volume small.

## 10. Coach Terms and Refund Policy pages

`apps/web/src/app/coach-terms/page.tsx` and `apps/web/src/app/refund-policy/page.tsx`, static, with a banner "DRAFT: pending review by an attorney. Not yet in effect." and the version string (`coach-terms 2026-12`, `refund-policy 2026-12`) that `coaching_config()` returns. Linked from: the site footer; the coach setup screen (the accept checkbox opens Coach Terms); the booking request sheet (the Refund Policy link next to the acknowledgment); the booking page (cancel sheet shows the refund the policy gives now); the payouts screen (payments on only, together with the Stripe Connected Account Agreement link).

Coach Terms contents (TRUST-SAFETY-LEGAL 5): eligibility (18+, lawful to do paid work where you coach, US work authorization when in the US); independent provider, facilitator; listing accuracy and self-reported credentials; venue permission and public meeting places; safety and conduct (Community Guidelines apply off-platform at sessions); the launch listing shapes and why online group sessions are not offered; the cancellation windows; no-shows and how disputes are decided (moderators, with appeal to support); the platform fee (12%, minimum $3 in USD, refunded in proportion with refunds) and that processing is absorbed by the platform; payouts by Stripe and the Stripe Connected Account Agreement; chargebacks (reversed from the coach's balance, repeated disputes lead to suspension); taxes are the coach's; requests-only bookings are arranged directly between coach and client and Activity Planet is not a party to that payment; reviews; termination; governing law as in the Terms of Service.

Refund Policy contents: section 3.7's table in plain words; when a refund appears (5 to 10 business days, by Stripe); requests-only bookings (the policy is the expectation, settled between the two people, and moderators can act on conduct, not money); how to raise a problem (report the booking, 24-hour target); the support address.

## 11. Notifications

New `notification_kind` values (`alter type ... add value if not exists`): `booking_requested` (to the coach), `booking_confirmed`, `booking_declined` (also expiry and slot taken), `booking_cancelled`, `booking_payment_due` (stripe), `booking_reminder_day`, `booking_reminder_2h`, `booking_review_prompt` (2 hours after completion), `booking_no_show` (to the other party), `review_received`, `review_reply`, `coach_payout_action` (Stripe needs information).

- **Transactional, not social.** These are not dropped by a person mute (a mute does not cancel a session). A block cancels the bookings, so there is nothing left to notify.
- **Channels.** In-app and push for all; **email** for `booking_requested`, `booking_confirmed`, `booking_cancelled` and `booking_payment_due` (logistics, the same class as RSVP confirmations; Resend's free cap is kept for these and plan logistics). Payloads carry ids, the title, the time and the other person's first name; never the client's note.
- **Prefs.** `notification_prefs.bookings` switches off reminders, review prompts and review notices; confirmations, declines, cancellations and payment due always arrive in-app. Quiet hours hold pushes through `push_after` as for every kind.
- **Calendar.** The send-notifications worker attaches no `.ics` to any email today (RSVP confirmations included; `packages/core/src/calendar` serves the site's `.ics` route). The `booking_confirmed` email links to the booking; an `.ics` attachment for both is a later item.
- Producers are the RPCs in section 7 (same transaction) and `coaching_tick` for reminders, prompts and expiries. The send-notifications worker's `pathFor` maps booking kinds to `/bookings/<id>` and review kinds to `/coaches/<handle>`.

## 12. Blocks, bans and moderation

- **Block:** `block_user` cancels the pair's open bookings (refunds per section 3.7) and declines open requests; search, profile, slots and reviews hide each from the other; the DM closes as in D-043. `request_booking` across a block answers `not_found`.
- **Ban or suspension:** section 7.1 (`mod_ban_user`, `mod_set_coach_status`).
- **Reports:** `report_content` gains `coach_listing`, `coach_review`, `coach_review_reply` and `booking` (a booking report is how a client or coach raises a safety problem, a contested no-show or a payment problem; reasons: the existing list plus `no_show` and `payment`). Coach profiles are reported as profiles. Moderators see a booking report with the booking's state and timestamps, never the payment card or the private meeting note unless the reporter quoted it.
- **Moderator actions** are `moderation_actions` rows as today; nothing is hard-deleted by moderators.

## 13. Account deletion

`request_account_deletion` is rebuilt from its migration 58 body, adding in the same transaction:

- **As a coach:** every `requested` and future `confirmed` booking is cancelled (`cancelled_by = 'system'`, `cancel_reason = 'account_deleted'`, full refund jobs queued) and the clients notified; `coach_profiles` and with it credentials, photos rows, hubs, listings' private notes, availability rules and exceptions, and scheduled future sessions are deleted; past bookings lose their `listing_id` and `session_id` (set null) and keep their own snapshot (title, delivery, format, price, times). Photo files go with the `avatars/<uid>/` folder, which the `delete-account` function already removes.
- **As a client:** future bookings are cancelled as a client cancellation at that moment (the policy's refund).
- **Past bookings** stay, pointing at the tombstone profile ("Deleted user"), because they are payment and tax records and the other party's history; `client_note` and `booking_private` are cleared for both sides' bookings with the deleted person.
- **Reviews** the person wrote are deleted (ratings recomputed); replies they wrote as a coach go with the coach's reviews. Reported reviews keep their report rows and the captured text in the report note, per TRUST-SAFETY-LEGAL 3.
- **Stripe:** `coach_stripe_accounts` is kept until the account is closed. The `delete-account` Edge Function, when `STRIPE_SECRET_KEY` is set and an account exists, asks Stripe to delete the connected account (`DELETE /v1/accounts/{id}`, allowed when its balance is zero); if Stripe refuses because funds are pending, a `stripe_jobs` row (`op = 'close_account'`) retries after the payout delay. The row is deleted when Stripe confirms. Stripe keeps its own records as an independent processor (Privacy Policy). `booking_payments` keeps ids and amounts only, for 7 years.
- TRUST-SAFETY-LEGAL section 11's "Payment records" row changes from "none exist yet" to: booking and payment records (times, amounts, Stripe ids, no card data) kept 7 years under "Deleted user"; coach profile, listings, availability, photos and reviews deleted at once.

## 14. Jobs

`coaching_tick()` (pg_cron every 5 minutes, unscheduled by name first, service role only): expire requests; cancel or fall back unpaid bookings (section 9.1); reminders a day and 2 hours before; auto-complete at `ends_at + 48 h` without an open no-show; settle uncontested no-shows after 48 hours (a coach no-show queues the full refund); review prompts; dispatch due `stripe_jobs`. `purge_coaching()` daily: `stripe_events` older than 90 days, done `stripe_jobs` older than 90 days, past exceptions older than 30 days.

## 15. Build slices

Exactly two.

### Slice 1: database and Edge Functions

Migration 60, `supabase/migrations/20261224000100_coaching.sql` (sorts after `20261223000100_messaging_review_fixes.sql`), idempotent, `meta.schema_version` **2.55 to 2.56**, `meta.coach_payments = 'off'` (`on conflict do nothing`):

1. `btree_gist`; enums; the tables in section 3 with indexes, constraints (including `coach_listings_launch_shape` and `coach_sessions_no_overlap`), RLS, explicit grants and revokes; the `busy` and point-rounding and time-zone triggers; the image-guard reference trigger on `coach_photos.url`; the rating triggers; `coach_fee_minimums` seed; `notification_prefs.bookings`.
2. `private.coach_fee`, `private.coach_slots_raw` and the other helpers; the RPCs in section 7; `stripe_dispatch` with the vault secret `stripe_dispatch_secret` generated in the database (as migration 52 does for image-guard).
3. The functions in 7.1, rebuilt from their latest bodies, each change marked "Migration 60"; the new notification kinds; the report kind constraints.
4. pg_cron `coaching-tick` and `purge-coaching`.
5. Edge Functions, each with its logic in pure modules and a thin `index.ts`:
   - `supabase/functions/stripe-connect/` (`index.ts`, `connect.ts`, `connect_test.ts`), `verify_jwt = true`.
   - `supabase/functions/stripe-checkout/` (`index.ts`, `checkout.ts`, `fees.ts`, `checkout_test.ts`, `fees_test.ts`), `verify_jwt = false` with its own checks: user calls carry the user JWT, verified against the project's JWKS exactly as `delete-account` does; database calls carry `x-stripe-dispatch-secret`.
   - `supabase/functions/stripe-webhook/` (`index.ts`, `signature.ts`, `events.ts`, `signature_test.ts`, `events_test.ts`), `verify_jwt = false`.
   - `supabase/functions/_shared/stripe.ts`: a 30-line form-encoded `fetch` client (`Authorization: Bearer`, `Idempotency-Key`, `Stripe-Version` pinned), injected so tests pass a mock.
   - **Key gate:** each `index.ts` reads `STRIPE_SECRET_KEY` (and the webhook secrets) first and answers `503 {error: "payments_off"}` without them, before parsing anything (`keyGate` in `supabase/functions/_shared/stripe.ts`; `stripe-connect` also answers it while `meta.coach_payments` is off). Tests cover the gate, signature success, bad signature, stale timestamp, duplicate event, the fee fixtures, refund amounts per policy row, and every Stripe request's form body against a mocked `fetch`; no network.
   - `delete-account`: the Stripe account deletion step, skipped without the key.
   - `supabase/config.toml` entries; `.github/workflows/ci.yml` runs `deno test` and `deno check` for the three functions.

Tests (implemented as three files: `coaching.sql`, `coaching_rules.sql` for slots, daylight saving, exceptions, group sessions and client limits, and `coaching_payments.sql`): `supabase/tests/coaching.sql` (profile and listing rules, the online + group refusal, slots across a DST change in a non-US zone, exceptions, min notice, request idempotency, confirm declining overlaps, the exclusion constraint refusing an overlapping session, client overlap, state transitions and stamps, expiry and auto-complete through `coaching_tick`, reviews only after completion and once, coach reply once, search near / online / by hub with bands and no coordinates, 18+ and 21+, blocks in search, slots, booking and reviews, the booking arm of shared context opening a DM without a request) and `supabase/tests/coaching_payments.sql` (requests-only default: `payment_mode = 'off_platform'`, no `stripe_jobs`; with the flag on and a fake connected account row: payable shapes, fee min and percent, `pay_by`, cancellation refund amounts per window, block and ban refunds, `stripe_event_begin` idempotency, webhook handlers' state changes, report kinds, account deletion coverage of every new table). Both one transaction, `set local role authenticated` and `request.jwt.claims` per actor, pass/fail only, `ROLLBACK`; added to `supabase/tests/regression.txt`. Then regenerate `packages/core/src/types/database.ts` from the staging run's "Staging, print generated Database types" section and deploy the three functions to staging with `staging_functions` (they answer `payments_off` there until test keys are added).

### Slice 2: client

Built on branch main-r1pc3k: `packages/core/src/coaching`, `apps/app/src/lib/coaching.ts`, the routes below, the DRAFT pages in `apps/web`, `apps/app/e2e/08-coaching.mjs` (with `supabase/staging/qa_coaching_past.sql` between its phases). Not built: analytics (the app has no analytics module yet) and cancelling a group session from the app (`coach_sessions` has no client read, so the listing page shows scheduled sessions from `coach_slots` without their ids).

- `packages/core/src/coaching/`: Zod schemas for every RPC result; `fees.ts` mirroring `private.coach_fee` (same fixtures); refund preview by policy row; slot grouping by day in the viewer's zone with the coach-zone label; state and payment-state labels; the error-code to copy map; the requests-only note. Unit tests.
- `apps/app/src/lib/coaching.ts`: Supabase calls and TanStack Query options, following `lib/notifications.ts` and `lib/messaging.ts`.
- `apps/app` routes (`src/routes/_app/`):

| File                                  | Path                             | What                                                                                                                                                          |
| ------------------------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `coaches.tsx`                         | `/coaches`                       | browse: Near you (radius ladder like the feed), Online, hub filter, search, price filter                                                                      |
| `coaches_.$handle.tsx`                | `/coaches/$handle`               | profile: photos, headline, "Self-reported" credentials, area and band, hubs, listings with prices, reviews, Message, Report                                   |
| `coaches_.$handle_.book.$listing.tsx` | `/coaches/$handle/book/$listing` | slot picker (`coach_slots`), note, Refund Policy acknowledgment, request; requests-only note or "Pay after the coach confirms"                                |
| `bookings.tsx`                        | `/bookings`                      | tabs As client / As coach (coaches only); Upcoming, Requests, Past                                                                                            |
| `bookings_.$id.tsx`                   | `/bookings/$id`                  | state timeline with timestamps, meeting note or link, Pay (payments on, due), Cancel with the refund preview, Message, no-show, Review, Report, Safety Center |
| `coach.tsx`                           | `/coach`                         | coach home: setup checklist, requests to answer, upcoming sessions                                                                                            |
| `coach_.profile.tsx`                  | `/coach/profile`                 | profile, credentials, photos, hubs, service area or online, time zone, Coach Terms acceptance, publish/pause                                                  |
| `coach_.listings.$id.tsx`             | `/coach/listings/$id`            | create/edit (online + group not offered in the form; the server refuses it anyway), group sessions                                                            |
| `coach_.availability.tsx`             | `/coach/availability`            | weekly windows in the coach's zone, exceptions, a preview of the next two weeks' slots                                                                        |
| `coach_.payouts.tsx`                  | `/coach/payouts`                 | payments on only (route redirects to `/coach` otherwise): onboarding, status, dashboard link                                                                  |

- Entry points: "Coaches in this hub" on hub pages; "Coaching" on the You tab (Become a coach / Coach home; My bookings); the DM header's next booking; booking notifications. Every payment control is behind `coaching_config().payments_enabled` and the listing's `payable` flag; with payments off none renders.
- `apps/web`: `coach-terms/page.tsx` and `refund-policy/page.tsx` (DRAFT banner, version), footer links, sitemap entries.
- Analytics: `booking` (PLAN 4.12) with the delivery, format and payment mode only, never price or note.
- Copy is neutral and for everyone (D-040). Done when `pnpm typecheck`, `lint`, `test` and `build` pass and the slice 1 test files pass on staging.

### Review fixes: migration 61

`supabase/migrations/20261225000100_coaching_review_fixes.sql`, `meta.schema_version` **2.56 to 2.57**, checks in `supabase/tests/coaching_review_fixes.sql`:

- Group seats are counted under the session's row lock (`request_booking`, `booking_confirm`), so two requests for the last seat cannot both get it.
- A deleted coach's Stripe account stays open while money can still move back through it (`coach_stripe_close_blocked`: a pending or sent refund or expiry job, a confirmed paid or processing booking, an unsettled paid no-show, a dispute). `delete-account` queues the `close_account` job instead of deleting, and `stripe_jobs_claim` holds that job an hour at a time, without an attempt.
- Payments off: `stripe_dispatch` no longer depends on `meta.coach_payments`, so refunds already owed still run; `coaching_tick` turns a booking still due into an off-platform one at `pay_by` instead of cancelling it.
- No review prompt and no `write_review` for a coach whose account was deleted.
- `booking_confirm` refuses a hidden, removed, paused or archived listing (`listing_unavailable`).
- The app reads the Edge Functions' JSON error code (`edgeFunctionError` in `packages/core/src/coaching/errors.ts`), so `payments_off`, `not_payable` and the Connect errors show their copy.

## 16. Open items for Sai

- Create the Stripe account and the Connect platform profile (FOUNDER-TODO 17), then add **test** keys to staging (`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, optional `STRIPE_CONNECT_WEBHOOK_SECRET`) and set `meta.coach_payments = 'on'` there; production keys and the flag only after the attorney read of Coach Terms and the Refund Policy, and the LLC trigger in FINANCIAL-PLAN section 4.
- Confirm the launch Refund Policy windows (free 24 hours or more, 50% inside 24 hours, no-show forfeits, coach cancellation full refund) and that the platform absorbs Stripe processing (D-026's proposal).
- The Privacy Policy gains bookings and payment records (Stripe as processor already listed) and the 7-year retention line; the Play Data safety form the same.
