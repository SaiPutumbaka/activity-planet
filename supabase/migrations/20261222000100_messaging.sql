-- ============================================================================
-- Activity Planet schema v2 — migration 58: messaging, slice 1 (database)
--   (D-043, docs/design/messaging/MESSAGING_DESIGN.md; PLAN.md 4.6;
--   TRUST-SAFETY-LEGAL.md sections 1, 7, 8 and 11; ROADMAP week 8).
--   Rebuilt functions start from their latest bodies and each change is
--   marked "Migration 58": enqueue_notification, block_user,
--   moderation_set_state, mod_moderate (migration 51); report_content,
--   moderation_is_own, mod_queue (migration 54); image_clear_references
--   (migration 52); request_account_deletion (migration 53);
--   claim_pending_notifications (migration 56); unread_notification_count,
--   mark_notifications_read (migration 18). Checks: messaging.sql and
--   messaging_safety.sql in supabase/tests.
--
--   What this file does
--     1. Enums conversation_kind (dm, group, event, hub, chapter) and
--        conversation_role (owner, admin, member); notification_kind gains
--        message and message_request; the reports and moderation_actions
--        kind checks accept message.
--     2. Tables: conversations, conversation_members, message_requests,
--        messages, message_report_evidence, chat_filter_strikes (refusals by
--        the filter, for the cooldown); private.chat_link_denylist and
--        private.chat_filter_terms (the lists, kept here and grown by
--        migration). RLS on all of them; clients never write any of them.
--     3. Private helpers (not in the API): chat_role, chat_can_read,
--        chat_can_post, chat_shared_context, chat_topic_conversation and the
--        link and filter checks.
--     4. RPCs: start_dm, create_group, add_group_members,
--        remove_conversation_member, set_conversation_role, rename_group,
--        leave_conversation, open_event_chat, open_hub_chat,
--        open_chapter_chat, respond_message_request, chat_list,
--        chat_unread_total, get_messages, conversation_info, people_you_met,
--        send_message, delete_message, mark_conversation_read,
--        mute_conversation, set_conversation_notify; service role
--        chat_image_classified and purge_messaging; moderators
--        mod_message_evidence.
--     5. Triggers: messages_broadcast (realtime.send to conv:<id> and, for
--        dm and group, user:<id>:chats; ids only, never a body), the
--        image-guard reference trigger on messages.image_path and the
--        image_hashes hashed-to-classify trigger.
--     6. Realtime Broadcast authorization: policies on realtime.messages so
--        only people who can read a conversation join conv:<id>, only the
--        owner joins user:<id>:chats, and only people who can post send
--        (typing) on conv:<id>.
--     7. Storage: private buckets chat-images (2 MiB, JPEG) and
--        chat-evidence (service role only). meta.chat_images = 'off': chat
--        images are refused until a classifier key exists (section 10 of the
--        design).
--     8. pg_cron purge-messaging daily.
--     * meta.schema_version 2.54.
--
--   Not here (later work, see the design's open items): the image-guard
--   classify, evidence_copy and evidence_url operations (chat images stay
--   off until they exist and the classifier secrets are set), the client.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Enums and kind checks
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.conversation_kind as enum ('dm', 'group', 'event', 'hub', 'chapter');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.conversation_role as enum ('owner', 'admin', 'member');
exception when duplicate_object then null; end $$;
alter type public.notification_kind add value if not exists 'message';
alter type public.notification_kind add value if not exists 'message_request';

alter table public.reports drop constraint if exists reports_target_kind;
alter table public.reports add constraint reports_target_kind
  check (target_kind in ('profile', 'event', 'chapter', 'hub', 'message'));
alter table public.moderation_actions drop constraint if exists moderation_actions_kind;
alter table public.moderation_actions add constraint moderation_actions_kind
  check (target_kind in ('profile', 'event', 'chapter', 'hub', 'takedown', 'image', 'message'));

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.conversations (
  id              uuid primary key default gen_random_uuid(),
  kind            public.conversation_kind not null,
  event_id        uuid references public.events (id) on delete cascade,
  hub_id          uuid references public.hubs (id) on delete cascade,
  chapter_id      uuid references public.hub_chapters (id) on delete cascade,
  dm_key          text,
  title           text,
  created_by      uuid references public.profiles (id) on delete set null,
  last_seq        bigint not null default 0,
  last_message_at timestamptz,
  closed_at       timestamptz,
  created_at      timestamptz not null default now(),
  constraint conversations_scope check (
    (kind = 'event'   and event_id is not null and hub_id is null and chapter_id is null) or
    (kind = 'hub'     and hub_id is not null and event_id is null and chapter_id is null) or
    (kind = 'chapter' and chapter_id is not null and event_id is null and hub_id is null) or
    (kind in ('dm', 'group') and event_id is null and hub_id is null and chapter_id is null)),
  constraint conversations_dm_key check ((kind = 'dm') = (dm_key is not null)),
  constraint conversations_title check (title is null or (kind = 'group' and char_length(title) between 1 and 60))
);
create unique index if not exists conversations_event_uq   on public.conversations (event_id)   where kind = 'event';
create unique index if not exists conversations_hub_uq     on public.conversations (hub_id)     where kind = 'hub';
create unique index if not exists conversations_chapter_uq on public.conversations (chapter_id) where kind = 'chapter';
create unique index if not exists conversations_dm_uq      on public.conversations (dm_key)     where kind = 'dm';
create index if not exists conversations_created_by_idx on public.conversations (created_by, created_at)
  where created_by is not null;
comment on table public.conversations is
  'Migration 58 (D-043): one row per chat. dm and group keep their members in conversation_members; event, hub and chapter chats derive membership live (private.chat_role). dm_key is least(a,b):greatest(a,b) of the two user ids. last_seq is the per-conversation message counter. closed_at: read-only (a DM after a block or an account deletion). Read through RLS (private.chat_can_read) by column list; written only by the messaging RPCs.';

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  user_id         uuid not null references public.profiles (id) on delete cascade,
  role            public.conversation_role not null default 'member',
  joined_at       timestamptz not null default now(),
  left_at         timestamptz,
  removed_at      timestamptz,
  removed_by      uuid references public.profiles (id) on delete set null,
  last_read_seq   bigint not null default 0,
  last_read_at    timestamptz,
  muted_until     timestamptz,
  notify          boolean,
  primary key (conversation_id, user_id)
);
create index if not exists conversation_members_user_idx on public.conversation_members (user_id) where left_at is null;
create index if not exists conversation_members_removed_by_idx on public.conversation_members (removed_by)
  where removed_by is not null;
comment on table public.conversation_members is
  'Migration 58: dm and group members (left_at, removed_at, role) and, for every kind, per-person read and mute state. For event, hub and chapter chats a row grants nothing by itself; removed_at bars the person from that room. muted_until ''infinity'' = muted until unmuted; notify null = the kind''s default (dm, group, event on; hub, chapter off).';

create table if not exists public.message_requests (
  conversation_id uuid primary key references public.conversations (id) on delete cascade,
  from_user       uuid not null references public.profiles (id) on delete cascade,
  to_user         uuid not null references public.profiles (id) on delete cascade,
  status          text not null default 'pending',
  created_at      timestamptz not null default now(),
  decided_at      timestamptz,
  constraint message_requests_status check (status in ('pending', 'accepted', 'declined')),
  constraint message_requests_not_self check (from_user <> to_user)
);
create index if not exists message_requests_to_idx   on public.message_requests (to_user, created_at desc) where status = 'pending';
create index if not exists message_requests_from_idx on public.message_requests (from_user, created_at);
comment on table public.message_requests is
  'Migration 58: a first DM with no shared context (one text message, no links or images, account 24 hours old). Members read the conversation, both user ids and created_at; status and decided_at are not granted, so a decline stays silent to the requester (the recipient reads them through chat_list).';

create table if not exists public.messages (
  id               uuid primary key default gen_random_uuid(),
  conversation_id  uuid not null references public.conversations (id) on delete cascade,
  seq              bigint not null,
  author_id        uuid references public.profiles (id) on delete set null,
  client_id        uuid,
  kind             text not null default 'text',
  body             text not null default '',
  image_path       text,
  image_state      text,
  has_link         boolean not null default false,
  deleted_at       timestamptz,
  deleted_by       text,
  deleted_body     text,
  moderation_state text,
  moderated_at     timestamptz,
  created_at       timestamptz not null default now(),
  constraint messages_seq_uq unique (conversation_id, seq),
  constraint messages_kind check (kind in ('text', 'image', 'system')),
  constraint messages_body_length check (char_length(body) <= 2000),
  constraint messages_image check ((kind = 'image') = (image_path is not null)),
  constraint messages_image_state check (image_state is null or image_state in
    ('pending', 'classifying', 'visible', 'queued', 'blocked', 'removed')),
  constraint messages_deleted_by check (deleted_by is null or deleted_by in ('author', 'room_admin', 'moderator')),
  constraint messages_moderation_state check (moderation_state is null or moderation_state in ('hidden', 'removed'))
);
create unique index if not exists messages_client_uq on public.messages (author_id, client_id) where client_id is not null;
create index if not exists messages_author_idx on public.messages (author_id, created_at);
create index if not exists messages_image_idx  on public.messages (image_path) where image_path is not null;
create index if not exists messages_deleted_idx on public.messages (deleted_at) where deleted_body is not null;
comment on table public.messages is
  'Migration 58: chat messages. No client grants: read through get_messages and chat_list, which apply blocks, bans, moderation and image state at read time; written only by send_message, delete_message and the moderation RPCs. A deleted message keeps its row (empty body; deleted_body kept 30 days for evidence). Messages of a deleted account stay under its tombstone profile.';

create table if not exists public.message_report_evidence (
  report_id           uuid primary key references public.reports (id) on delete cascade,
  message_id          uuid,
  conversation_id     uuid,
  conversation_kind   public.conversation_kind not null,
  author_id           uuid references public.profiles (id) on delete set null,
  body                text not null,
  image_evidence_path text,
  context             jsonb not null,
  retain_until        timestamptz,
  created_at          timestamptz not null default now()
);
create index if not exists message_report_evidence_retain_idx on public.message_report_evidence (retain_until)
  where retain_until is not null;
create index if not exists message_report_evidence_author_idx on public.message_report_evidence (author_id)
  where author_id is not null;
comment on table public.message_report_evidence is
  'Migration 58: what a reported message said, copied when the report is filed, with up to 10 earlier and 5 later messages the reporter could see. Outlives the message, the room and both accounts until retain_until (set when the report closes: a year for child_safety, ncii and underage, 90 days otherwise). Moderators read it through mod_message_evidence only.';

create table if not exists public.chat_filter_strikes (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists chat_filter_strikes_user_idx on public.chat_filter_strikes (user_id, created_at);
comment on table public.chat_filter_strikes is
  'Migration 58: one row per message refused by the filter (message_filtered). Three in an hour start a one-hour send cooldown and an automatic report. Kept a day; deleted with the account. Service role only.';

create table if not exists private.chat_link_denylist (
  domain text primary key,
  constraint chat_link_denylist_domain check (domain ~ '^[a-z0-9.-]+\.[a-z]{2,}$')
);
create table if not exists private.chat_filter_terms (
  term       text primary key,
  applies_to text not null default 'all',
  constraint chat_filter_terms_applies check (applies_to in ('all', 'requests'))
);
comment on table private.chat_link_denylist is
  'Migration 58: link shorteners refused in every message because they hide the destination.';
comment on table private.chat_filter_terms is
  'Migration 58: normalized terms refused by send_message (message_filtered). applies_to requests: only in message requests. High-confidence slurs and solicitation only; ordinary profanity is allowed.';

insert into private.chat_link_denylist (domain) values
  ('bit.ly'), ('tinyurl.com'), ('t.co'), ('goo.gl'), ('is.gd'), ('cutt.ly'), ('rb.gy'), ('ow.ly'), ('buff.ly'),
  ('tiny.cc'), ('shorturl.at'), ('t.ly'), ('v.gd'), ('rebrand.ly'), ('bl.ink'), ('s.id'), ('lnkd.in'),
  ('qrco.de'), ('shorte.st'), ('adf.ly'), ('linktr.ee')
on conflict do nothing;

insert into private.chat_filter_terms (term, applies_to) values
  ('nigger', 'all'), ('niggers', 'all'), ('faggot', 'all'), ('faggots', 'all'), ('kike', 'all'), ('kikes', 'all'),
  ('tranny', 'all'), ('trannies', 'all'), ('wetback', 'all'), ('wetbacks', 'all'),
  ('send nudes', 'all'), ('send me nudes', 'all'), ('selling nudes', 'all'), ('nudes for sale', 'all'),
  ('onlyfans', 'requests'), ('cashapp', 'requests'), ('cash app', 'requests'), ('venmo me', 'requests'),
  ('sugar daddy', 'requests'), ('sugar baby', 'requests'), ('send pics', 'requests'), ('telegram me', 'requests'),
  ('whatsapp me', 'requests'), ('crypto investment', 'requests')
on conflict do nothing;

alter table public.conversations           enable row level security;
alter table public.conversation_members    enable row level security;
alter table public.message_requests        enable row level security;
alter table public.messages                enable row level security;
alter table public.message_report_evidence enable row level security;
alter table public.chat_filter_strikes     enable row level security;
alter table private.chat_link_denylist     enable row level security;
alter table private.chat_filter_terms      enable row level security;
revoke all on public.conversations, public.conversation_members, public.message_requests, public.messages,
              public.message_report_evidence, public.chat_filter_strikes
  from public, anon, authenticated;
revoke all on private.chat_link_denylist, private.chat_filter_terms from public, anon, authenticated;
grant all on public.conversations, public.conversation_members, public.message_requests, public.messages,
             public.message_report_evidence, public.chat_filter_strikes to service_role;
grant all on private.chat_link_denylist, private.chat_filter_terms to service_role;
grant select (id, kind, event_id, hub_id, chapter_id, title, last_seq, last_message_at, closed_at, created_at)
  on public.conversations to authenticated;
grant select on public.conversation_members to authenticated;
grant select (conversation_id, from_user, to_user, created_at) on public.message_requests to authenticated;

insert into public.meta (key, value) values ('chat_images', 'off') on conflict (key) do nothing;
insert into public.meta (key, value) values ('chat_classifier_monthly_cap', '1800') on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 3. Private helpers
-- ---------------------------------------------------------------------------
create or replace function private.chat_dm_key(p_a uuid, p_b uuid)
returns text language sql immutable set search_path = '' as $$
  select least(p_a::text, p_b::text) || ':' || greatest(p_a::text, p_b::text);
$$;

-- The other person of a dm_key.
create or replace function private.chat_dm_other(p_key text, p_user uuid)
returns uuid language sql immutable set search_path = '' as $$
  select case when split_part(p_key, ':', 1) = p_user::text then split_part(p_key, ':', 2)::uuid
              else split_part(p_key, ':', 1)::uuid end;
$$;

create or replace function private.chat_uuid(p_text text)
returns uuid language sql immutable set search_path = '' as $$
  select case when p_text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then p_text::uuid end;
$$;

-- 'conv:<uuid>' -> uuid; anything else -> null (never a cast error).
create or replace function private.chat_topic_conversation(p_topic text)
returns uuid language sql immutable set search_path = '' as $$
  select case when left(coalesce(p_topic, ''), 5) = 'conv:' then private.chat_uuid(substr(p_topic, 6)) end;
$$;

create or replace function private.chat_images_enabled()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select m.value from public.meta m where m.key = 'chat_images'), 'off') = 'on';
$$;

-- An account that can take part in chats: active, onboarded, adult, not held by moderators.
create or replace function private.chat_user_ok(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_user is not null and exists (
    select 1 from public.profiles p
      join public.profile_private pp on pp.user_id = p.id
     where p.id = p_user and p.status = 'active' and p.deleted_at is null and p.moderation_state is null
       and p.onboarding_completed_at is not null
       and pp.birth_date is not null and pp.birth_date <= (current_date - interval '18 years')::date);
$$;

-- A profile photo that image-guard has not refused (PLAN 4.6: sending needs a photo).
create or replace function private.chat_has_photo(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
     where p.id = p_user and p.avatar_url is not null
       and not exists (select 1 from public.storage_object_from_url(p.avatar_url) o
                         join public.image_hashes h on h.bucket = o.bucket and h.path = o.path
                        where h.status in ('blocked', 'unreadable')));
$$;

-- Who may read an event, hub or chapter chat, from the rows the app already
-- trusts. 'admin' | 'member' | null.
create or replace function private.chat_derived_role(p_kind public.conversation_kind, p_event uuid, p_hub uuid,
                                                     p_chapter uuid, p_user uuid)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  e public.events%rowtype;
begin
  if p_user is null then
    return null;
  end if;
  if p_kind = 'event' then
    select * into e from public.events where id = p_event;
    if not found or e.kind = 'imported' or e.moderation_state is not null
       or not exists (select 1 from public.hubs h where h.id = e.hub_id and h.is_active) then
      return null;
    end if;
    if e.host_id = p_user then
      return 'admin';
    end if;
    if e.chapter_id is not null and exists (
         select 1 from public.chapter_members cm
          where cm.chapter_id = e.chapter_id and cm.user_id = p_user and cm.role in ('captain', 'organizer')) then
      return 'admin';
    end if;
    if exists (select 1 from public.rsvps r
                where r.event_id = e.id and r.user_id = p_user
                  and r.status in ('going', 'waitlisted') and r.removed_at is null) then
      return 'member';
    end if;
    return null;
  elsif p_kind = 'hub' then
    if not exists (select 1 from public.hubs h
                     join public.hub_categories c on c.slug = h.category_slug
                    where h.id = p_hub and h.is_active and h.moderation_state is null and not c.is_sensitive) then
      return null;
    end if;
    if exists (select 1 from public.hub_members hm where hm.hub_id = p_hub and hm.user_id = p_user) then
      return 'member';
    end if;
    return null;
  elsif p_kind = 'chapter' then
    if not exists (select 1 from public.hub_chapters ch
                     join public.hubs h on h.id = ch.hub_id
                     join public.hub_categories c on c.slug = h.category_slug
                    where ch.id = p_chapter and ch.is_active and ch.moderation_state is null
                      and h.is_active and not c.is_sensitive) then
      return null;
    end if;
    return (select case when cm.role in ('captain', 'organizer') then 'admin' else 'member' end
              from public.chapter_members cm where cm.chapter_id = p_chapter and cm.user_id = p_user);
  end if;
  return null;
end $$;

-- The design's section 2.1 table, evaluated live: 'owner' | 'admin' | 'member' | null.
create or replace function private.chat_role(p_conversation uuid, p_user uuid)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  c public.conversations%rowtype;
  m public.conversation_members%rowtype;
begin
  if p_conversation is null or p_user is null then
    return null;
  end if;
  if not exists (select 1 from public.profiles p where p.id = p_user and p.status = 'active' and p.deleted_at is null) then
    return null;
  end if;
  select * into c from public.conversations where id = p_conversation;
  if not found then
    return null;
  end if;
  select * into m from public.conversation_members where conversation_id = p_conversation and user_id = p_user;
  if m.user_id is not null and m.removed_at is not null then
    return null;
  end if;
  if c.kind in ('dm', 'group') then
    if m.user_id is null or m.left_at is not null then
      return null;
    end if;
    return m.role::text;
  end if;
  return private.chat_derived_role(c.kind, c.event_id, c.hub_id, c.chapter_id, p_user);
end $$;

-- The signed-in caller may read the conversation (and join conv:<id>).
create or replace function private.chat_can_read(p_conversation uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_conversation is not null and (select auth.uid()) is not null and public.viewer_is_adult()
     and private.chat_role(p_conversation, (select auth.uid())) is not null;
$$;

-- conversation_members rows other people may see: dm and group rows of a
-- conversation the caller can read.
create or replace function private.chat_member_rows_visible(p_conversation uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.conversations c where c.id = p_conversation and c.kind in ('dm', 'group'))
     and private.chat_can_read(p_conversation);
$$;

-- The caller may post: null, or the error code (design section 4).
create or replace function private.chat_can_post(p_conversation uuid)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  c       public.conversations%rowtype;
  r       public.message_requests%rowtype;
  e       public.events%rowtype;
  v_other uuid;
begin
  if uid is null then
    return 'not_authenticated';
  end if;
  if not public.viewer_is_adult() then
    return 'onboarding_required';
  end if;
  select * into c from public.conversations where id = p_conversation;
  if not found then
    return 'not_found';
  end if;
  if private.chat_role(c.id, uid) is null then
    return 'forbidden';
  end if;
  if not private.chat_has_photo(uid) then
    return 'photo_required';
  end if;
  if c.kind = 'dm' then
    -- A block reads exactly like a deleted account.
    v_other := private.chat_dm_other(c.dm_key, uid);
    if c.closed_at is not null or public.users_blocked(uid, v_other)
       or not exists (select 1 from public.profiles p
                       where p.id = v_other and p.status = 'active' and p.deleted_at is null) then
      return 'conversation_closed';
    end if;
    select * into r from public.message_requests where conversation_id = c.id;
    if r.conversation_id is not null and r.status <> 'accepted' and r.from_user = uid
       and (r.status = 'declined'
            or exists (select 1 from public.messages m
                        where m.conversation_id = c.id and m.author_id = uid and m.created_at >= r.created_at)) then
      return 'request_pending';
    end if;
    return null;
  end if;
  if c.closed_at is not null then
    return 'read_only';
  end if;
  if c.kind = 'event' then
    select * into e from public.events where id = c.event_id;
    if e.status = 'cancelled' or e.ends_at < now() - interval '7 days' then
      return 'read_only';
    end if;
  elsif c.kind = 'hub' then
    if (select p.created_at from public.profiles p where p.id = uid) > now() - interval '24 hours'
       or exists (select 1 from public.hub_members hm
                   where hm.hub_id = c.hub_id and hm.user_id = uid and hm.joined_at > now() - interval '24 hours') then
      return 'account_too_new';
    end if;
  end if;
  return null;
end $$;

-- Shared context (no message request needed), design section 2.3.
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
  );
$$;

-- Text for matching: NFKC, lower case, no zero-width characters, single spaces.
create or replace function private.chat_match_text(p_text text)
returns text language sql immutable set search_path = '' as $$
  select regexp_replace(
           regexp_replace(lower(normalize(coalesce(p_text, ''), NFKC)), '[​-‍⁠﻿­]', '', 'g'),
           '\s+', ' ', 'g');
$$;

-- Folded for the term list: look-alikes and leetspeak, runs of a letter cut to two.
create or replace function private.chat_fold(p_text text)
returns text language sql immutable set search_path = '' as $$
  select regexp_replace(translate(private.chat_match_text(p_text), '01345@$аеорсхі', 'oieasasaeopcxi'),
                        '(.)\1{2,}', '\1\1', 'g');
$$;

-- A link: a scheme, www., or a bare label.tld. Email addresses and phone numbers are not links.
create or replace function private.chat_has_link(p_text text)
returns boolean language sql immutable set search_path = '' as $$
  select private.chat_match_text(p_text) ~
    '(https?://|(^|[^a-z0-9@._-])www\.|(^|[^a-z0-9@._-])([a-z0-9-]+\.)+(com|net|org|app|xyz|info|biz|link|site|online|[a-z]{2})([^a-z0-9-]|$))';
$$;

create or replace function private.chat_link_shortened(p_text text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from private.chat_link_denylist d
     where private.chat_match_text(p_text) ~ ('(^|[^a-z0-9.-])' || replace(d.domain, '.', '\.') || '([^a-z0-9.-]|$)'));
$$;

create or replace function private.chat_filtered(p_text text, p_request boolean)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from private.chat_filter_terms t
     where (t.applies_to = 'all' or (p_request and t.applies_to = 'requests'))
       and private.chat_fold(p_text) ~ ('(^|[^a-z])' || t.term || '([^a-z]|$)'));
$$;

-- Messages by this author are shown to this viewer (no block, not banned).
create or replace function private.chat_visible_author(p_author uuid, p_viewer uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_author is null or p_author = p_viewer or (
    not public.users_blocked(p_author, p_viewer)
    and not exists (select 1 from public.profiles p where p.id = p_author and p.status = 'banned'));
$$;

-- Storage helpers for the chat-images policies.
create or replace function private.chat_image_readable(p_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.messages m
     where m.image_path = p_path and m.image_state = 'visible' and m.deleted_at is null and m.moderation_state is null
       and private.chat_can_read(m.conversation_id)
       and private.chat_visible_author(m.author_id, (select auth.uid())));
$$;

create or replace function private.chat_image_sent(p_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.messages m where m.image_path = p_path);
$$;

-- A first request: account at least a day old, at most 10 a day.
create or replace function private.chat_request_checks(p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if (select p.created_at from public.profiles p where p.id = p_user) > now() - interval '24 hours' then
    raise exception 'account_too_new' using errcode = 'check_violation',
      hint = 'New accounts can message people they share a plan, hub or chapter with.';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('chat_requests:' || p_user::text));
  if (select count(*) from public.message_requests r
       where r.from_user = p_user and r.created_at > now() - interval '1 day') >= 10 then
    raise exception 'rate_limited' using errcode = 'check_violation', hint = '86400';
  end if;
end $$;

-- Whether p_adder may put p_user in a group (shared context, no block with
-- anyone already in it).
create or replace function private.chat_can_add(p_adder uuid, p_user uuid, p_conversation uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_user is not null and p_user <> p_adder
     and private.chat_user_ok(p_user)
     and not public.users_blocked(p_adder, p_user)
     and private.chat_shared_context(p_adder, p_user)
     and not exists (select 1 from public.conversation_members cm
                      where cm.conversation_id = p_conversation and cm.left_at is null and cm.removed_at is null
                        and public.users_blocked(cm.user_id, p_user));
$$;

-- ---------------------------------------------------------------------------
-- 4. RPCs: conversations and requests
-- ---------------------------------------------------------------------------
create or replace function public.start_dm(p_user uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid   uuid := (select auth.uid());
  v_key text;
  v_ctx boolean;
  c     public.conversations%rowtype;
  r     public.message_requests%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.viewer_is_adult() then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_user = uid then
    raise exception 'cannot_message_self' using errcode = 'check_violation';
  end if;
  -- A blocked pair, a banned, hidden or deleted profile: all the same answer.
  if not private.chat_user_ok(p_user) or public.users_blocked(uid, p_user) then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;
  if not private.chat_has_photo(uid) then
    raise exception 'photo_required' using errcode = 'check_violation', hint = 'Add a profile photo to send messages.';
  end if;

  v_key := private.chat_dm_key(uid, p_user);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('chat_dm:' || v_key));
  v_ctx := private.chat_shared_context(uid, p_user);
  select * into c from public.conversations where kind = 'dm' and dm_key = v_key;

  if c.id is not null then
    select * into r from public.message_requests where conversation_id = c.id for update;
    if r.conversation_id is not null and r.status <> 'accepted' then
      if v_ctx or r.to_user = uid then
        -- Shared context appeared, or the recipient writes back: accepted.
        update public.message_requests set status = 'accepted', decided_at = now() where conversation_id = c.id;
      elsif r.status = 'pending' then
        return jsonb_build_object('conversation_id', c.id, 'state', 'request_pending');
      else
        -- Declined: the requester may ask again after 30 days, under the first-request rules.
        if r.decided_at > now() - interval '30 days' then
          raise exception 'request_cooldown' using errcode = 'check_violation';
        end if;
        perform private.chat_request_checks(uid);
        update public.message_requests
           set status = 'pending', created_at = now(), decided_at = null
         where conversation_id = c.id;
        update public.conversations set closed_at = null where id = c.id;
        update public.conversation_members set left_at = null
         where conversation_id = c.id and user_id = uid;
        return jsonb_build_object('conversation_id', c.id, 'state', 'request');
      end if;
    end if;
    -- Reopened after both unblocked, or after one of them left.
    update public.conversations set closed_at = null where id = c.id and closed_at is not null;
    insert into public.conversation_members (conversation_id, user_id) values (c.id, uid)
    on conflict (conversation_id, user_id) do update set left_at = null;
    insert into public.conversation_members (conversation_id, user_id) values (c.id, p_user)
    on conflict (conversation_id, user_id) do nothing;
    return jsonb_build_object('conversation_id', c.id, 'state', 'open');
  end if;

  if not v_ctx then
    perform private.chat_request_checks(uid);
  end if;
  insert into public.conversations (kind, dm_key, created_by) values ('dm', v_key, uid) returning * into c;
  insert into public.conversation_members (conversation_id, user_id) values (c.id, uid), (c.id, p_user);
  if not v_ctx then
    insert into public.message_requests (conversation_id, from_user, to_user) values (c.id, uid, p_user);
  end if;
  return jsonb_build_object('conversation_id', c.id, 'state', case when v_ctx then 'open' else 'request' end);
end $$;
comment on function public.start_dm(uuid) is
  'Migration 58: opens (or finds) the DM with p_user. With shared context (private.chat_shared_context) state open; without, a message request (state request; request_pending while one is waiting). Errors: not_authenticated, onboarding_required, cannot_message_self, user_not_found (also a blocked pair, a banned or hidden profile), photo_required, account_too_new (requests need 24 hours), rate_limited (10 requests a day), request_cooldown (30 days after a decline).';

create or replace function public.create_group(p_title text, p_users uuid[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_title  text := btrim(coalesce(p_title, ''));
  v_users  uuid[];
  v_user   uuid;
  v_added  integer := 0;
  v_new    boolean;
  c        public.conversations%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.viewer_is_adult() then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if not private.chat_has_photo(uid) then
    raise exception 'photo_required' using errcode = 'check_violation';
  end if;
  if char_length(v_title) not between 1 and 60 then
    raise exception 'invalid_title' using errcode = 'check_violation', hint = '1 to 60 characters.';
  end if;
  select coalesce(array_agg(distinct u), '{}') into v_users from unnest(coalesce(p_users, '{}')) u
   where u is not null and u <> uid;
  if cardinality(v_users) > 49 then
    raise exception 'too_many_members' using errcode = 'check_violation', hint = 'Up to 50 people.';
  end if;
  v_new := (select p.created_at from public.profiles p where p.id = uid) > now() - interval '24 hours';
  if not public.is_moderator() then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('chat_groups:' || uid::text));
    if (select count(*) from public.conversations g
         where g.kind = 'group' and g.created_by = uid and g.created_at > now() - interval '1 day')
       >= (case when v_new then 1 else 5 end) then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = '86400';
    end if;
  end if;

  insert into public.conversations (kind, title, created_by) values ('group', v_title, uid) returning * into c;
  insert into public.conversation_members (conversation_id, user_id, role) values (c.id, uid, 'owner');
  foreach v_user in array v_users loop
    if private.chat_can_add(uid, v_user, c.id) then
      insert into public.conversation_members (conversation_id, user_id) values (c.id, v_user);
      v_added := v_added + 1;
    end if;
  end loop;
  if v_added < 2 then
    raise exception 'too_few_members' using errcode = 'check_violation',
      hint = 'A group needs at least two other people you share a plan, hub or chapter with.';
  end if;
  return jsonb_build_object('conversation_id', c.id, 'added', v_added, 'skipped', cardinality(v_users) - v_added);
end $$;
comment on function public.create_group(text, uuid[]) is
  'Migration 58: a group of 3 to 50 people with the caller as owner. People without shared context with the caller, or blocked with someone already added, are skipped (counted, never named). Returns {conversation_id, added, skipped}. Errors: not_authenticated, onboarding_required, photo_required, invalid_title, too_many_members, too_few_members, rate_limited (5 groups a day, 1 for accounts under a day).';

create or replace function public.add_group_members(p_conversation uuid, p_users uuid[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  c       public.conversations%rowtype;
  v_users uuid[];
  v_user  uuid;
  v_n     integer;
  v_added integer := 0;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into c from public.conversations where id = p_conversation for update;
  if not found or c.kind <> 'group' or not private.chat_can_read(c.id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if private.chat_role(c.id, uid) not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select coalesce(array_agg(distinct u), '{}') into v_users from unnest(coalesce(p_users, '{}')) u
   where u is not null and u <> uid
     and not exists (select 1 from public.conversation_members cm
                      where cm.conversation_id = c.id and cm.user_id = u and cm.left_at is null and cm.removed_at is null);
  select count(*)::integer into v_n from public.conversation_members cm
   where cm.conversation_id = c.id and cm.left_at is null and cm.removed_at is null;
  if v_n + cardinality(v_users) > 50 then
    raise exception 'too_many_members' using errcode = 'check_violation', hint = 'Up to 50 people.';
  end if;
  foreach v_user in array v_users loop
    if private.chat_can_add(uid, v_user, c.id) then
      insert into public.conversation_members (conversation_id, user_id) values (c.id, v_user)
      on conflict (conversation_id, user_id) do update
         set left_at = null, removed_at = null, removed_by = null, role = 'member', joined_at = now();
      v_added := v_added + 1;
    end if;
  end loop;
  return jsonb_build_object('added', v_added, 'skipped', cardinality(v_users) - v_added);
end $$;
comment on function public.add_group_members(uuid, uuid[]) is
  'Migration 58: the group''s owner or an admin adds people (same skip rules as create_group). Returns {added, skipped}. Errors: not_authenticated, not_found, forbidden, too_many_members.';

create or replace function public.remove_conversation_member(p_conversation uuid, p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  c        public.conversations%rowtype;
  v_mine   text;
  v_theirs text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into c from public.conversations where id = p_conversation;
  if not found or not private.chat_can_read(c.id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if p_user is null or p_user = uid or c.kind in ('dm', 'hub') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_mine := private.chat_role(c.id, uid);
  v_theirs := private.chat_role(c.id, p_user);
  if v_theirs is null then
    return;
  end if;
  if c.kind = 'group' then
    if v_mine not in ('owner', 'admin') or v_theirs = 'owner' or (v_theirs = 'admin' and v_mine <> 'owner') then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  elsif v_mine <> 'admin' or v_theirs = 'admin' then
    -- event and chapter rooms: hosts, captains and organizers remove members, not each other.
    raise exception 'forbidden' using errcode = '42501';
  end if;
  insert into public.conversation_members (conversation_id, user_id, removed_at, removed_by)
  values (c.id, p_user, now(), uid)
  on conflict (conversation_id, user_id) do update set removed_at = now(), removed_by = uid;
end $$;
comment on function public.remove_conversation_member(uuid, uuid) is
  'Migration 58: a group owner or admin (admins cannot remove the owner or other admins), or an event or chapter room admin (host, captain, organizer; not another admin), removes someone from the room (removed_at). Errors: not_authenticated, not_found, forbidden.';

create or replace function public.set_conversation_role(p_conversation uuid, p_user uuid,
                                                        p_role public.conversation_role)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  c   public.conversations%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into c from public.conversations where id = p_conversation for update;
  if not found or c.kind <> 'group' or not private.chat_can_read(c.id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if private.chat_role(c.id, uid) <> 'owner' or p_user is null or p_user = uid or p_role is null
     or private.chat_role(c.id, p_user) is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_role = 'owner' then
    -- Handing over: the caller stays as an admin.
    update public.conversation_members set role = 'admin' where conversation_id = c.id and user_id = uid;
  end if;
  update public.conversation_members set role = p_role where conversation_id = c.id and user_id = p_user;
end $$;
comment on function public.set_conversation_role(uuid, uuid, public.conversation_role) is
  'Migration 58: the group owner makes a member an admin or a member again, or hands ownership over (the caller becomes an admin). Errors: not_authenticated, not_found, forbidden.';

create or replace function public.rename_group(p_conversation uuid, p_title text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_title text := btrim(coalesce(p_title, ''));
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.conversations c where c.id = p_conversation and c.kind = 'group')
     or not private.chat_can_read(p_conversation) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if private.chat_role(p_conversation, uid) not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if char_length(v_title) not between 1 and 60 then
    raise exception 'invalid_title' using errcode = 'check_violation', hint = '1 to 60 characters.';
  end if;
  update public.conversations set title = v_title where id = p_conversation;
end $$;
comment on function public.rename_group(uuid, text) is
  'Migration 58: the group owner or an admin renames it (1 to 60 characters). Errors: not_authenticated, not_found, forbidden, invalid_title.';

create or replace function public.leave_conversation(p_conversation uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  c      public.conversations%rowtype;
  v_role text;
  v_next uuid;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into c from public.conversations where id = p_conversation for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if c.kind not in ('dm', 'group') then
    raise exception 'forbidden' using errcode = '42501',
      hint = 'Leave the plan, hub or chapter to leave its chat, or mute it.';
  end if;
  v_role := private.chat_role(c.id, uid);
  if v_role is null then
    return;
  end if;
  update public.conversation_members set left_at = now(), role = 'member'
   where conversation_id = c.id and user_id = uid;
  if v_role = 'owner' then
    select cm.user_id into v_next from public.conversation_members cm
     where cm.conversation_id = c.id and cm.user_id <> uid and cm.left_at is null and cm.removed_at is null
     order by (cm.role = 'admin') desc, cm.joined_at, cm.user_id
     limit 1;
    if v_next is not null then
      update public.conversation_members set role = 'owner' where conversation_id = c.id and user_id = v_next;
    end if;
  end if;
  -- Nobody left: the conversation goes (reported messages live on in their evidence).
  if not exists (select 1 from public.conversation_members cm
                  where cm.conversation_id = c.id and cm.left_at is null and cm.removed_at is null) then
    delete from public.conversations where id = c.id;
  end if;
end $$;
comment on function public.leave_conversation(uuid) is
  'Migration 58: leave a dm or group. An owner leaving hands ownership to the oldest admin, else the oldest member; a conversation nobody is left in is deleted. Event, hub and chapter chats are left by leaving the plan, hub or chapter (forbidden here). Errors: not_authenticated, not_found, forbidden.';

-- Internal: the room for a derived kind, created on first open.
create or replace function private.chat_open_room(p_kind public.conversation_kind, p_event uuid, p_hub uuid,
                                                  p_chapter uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid  uuid := (select auth.uid());
  v_id uuid;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.viewer_is_adult() then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if private.chat_derived_role(p_kind, p_event, p_hub, p_chapter, uid) is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  insert into public.conversations (kind, event_id, hub_id, chapter_id, created_by)
  values (p_kind, p_event, p_hub, p_chapter, uid)
  on conflict do nothing;
  select c.id into v_id from public.conversations c
   where c.kind = p_kind
     and c.event_id is not distinct from p_event and c.hub_id is not distinct from p_hub
     and c.chapter_id is not distinct from p_chapter;
  if exists (select 1 from public.conversation_members cm
              where cm.conversation_id = v_id and cm.user_id = uid and cm.removed_at is not null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  insert into public.conversation_members (conversation_id, user_id) values (v_id, uid)
  on conflict (conversation_id, user_id) do nothing;
  return jsonb_build_object('conversation_id', v_id);
end $$;

create or replace function public.open_event_chat(p_event uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.events e
                   join public.hubs h on h.id = e.hub_id
                  where e.id = p_event and e.kind <> 'imported' and e.moderation_state is null and h.is_active) then
    raise exception 'chat_unavailable' using errcode = 'check_violation';
  end if;
  return private.chat_open_room('event', p_event, null, null);
end $$;
comment on function public.open_event_chat(uuid) is
  'Migration 58: the plan''s chat (host, going and waitlisted people, captains and organizers of its chapter), created on first open. Returns {conversation_id}. Errors: not_authenticated, onboarding_required, chat_unavailable (imported, moderated or in an inactive hub), forbidden.';

create or replace function public.open_hub_chat(p_hub uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.hubs h
                   join public.hub_categories c on c.slug = h.category_slug
                  where h.id = p_hub and h.is_active and h.moderation_state is null and not c.is_sensitive) then
    raise exception 'chat_unavailable' using errcode = 'check_violation';
  end if;
  return private.chat_open_room('hub', null, p_hub, null);
end $$;
comment on function public.open_hub_chat(uuid) is
  'Migration 58: the hub''s chat (its members), created on first open. Hubs in a sensitive category have none. Returns {conversation_id}. Errors: not_authenticated, onboarding_required, chat_unavailable, forbidden.';

create or replace function public.open_chapter_chat(p_chapter uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.hub_chapters ch
                   join public.hubs h on h.id = ch.hub_id
                   join public.hub_categories c on c.slug = h.category_slug
                  where ch.id = p_chapter and ch.is_active and ch.moderation_state is null
                    and h.is_active and not c.is_sensitive) then
    raise exception 'chat_unavailable' using errcode = 'check_violation';
  end if;
  return private.chat_open_room('chapter', null, null, p_chapter);
end $$;
comment on function public.open_chapter_chat(uuid) is
  'Migration 58: the chapter''s chat (its members; captains and organizers are admins), created on first open. Returns {conversation_id}. Errors: not_authenticated, onboarding_required, chat_unavailable (inactive, moderated or in a sensitive hub), forbidden.';

create or replace function public.respond_message_request(p_conversation uuid, p_action text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_action is null or p_action not in ('accept', 'decline') then
    raise exception 'invalid_action' using errcode = 'check_violation';
  end if;
  update public.message_requests
     set status = case when p_action = 'accept' then 'accepted' else 'declined' end, decided_at = now()
   where conversation_id = p_conversation and to_user = uid and status = 'pending';
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
end $$;
comment on function public.respond_message_request(uuid, text) is
  'Migration 58: the recipient accepts or declines a pending request. A decline is silent (the requester still sees it as sent) and bars a new request for 30 days. Errors: not_authenticated, invalid_action, not_found.';

-- ---------------------------------------------------------------------------
-- 5. RPCs: reading
-- ---------------------------------------------------------------------------
create or replace function public.chat_list(p_tab text default 'chats', p_before timestamptz default null,
                                            p_limit integer default 30)
returns table (conversation_id uuid, kind public.conversation_kind, title text, other jsonb, context jsonb,
               last_message jsonb, unread integer, muted boolean, closed boolean, request text,
               activity_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid     uuid := (select auth.uid());
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 100);
  v_req   boolean := coalesce(p_tab, 'chats') = 'requests';
begin
  if uid is null or not public.viewer_is_adult() then
    return;
  end if;
  return query
  with cand as (
    select c.* from public.conversations c
      join public.conversation_members cm
        on cm.conversation_id = c.id and cm.user_id = uid and cm.left_at is null and cm.removed_at is null
     where c.kind in ('dm', 'group')
    union all
    select c.* from public.conversations c
     where not v_req and c.kind = 'event'
       and c.event_id in (select r.event_id from public.rsvps r
                           where r.user_id = uid and r.status in ('going', 'waitlisted') and r.removed_at is null
                          union select e.id from public.events e where e.host_id = uid
                          union select e.id from public.events e
                                  join public.chapter_members cm on cm.chapter_id = e.chapter_id
                                 where cm.user_id = uid and cm.role in ('captain', 'organizer'))
       and exists (select 1 from public.events e where e.id = c.event_id and e.ends_at > now() - interval '30 days')
    union all
    select c.* from public.conversations c
     where not v_req and c.kind = 'hub' and c.hub_id in (select hm.hub_id from public.hub_members hm where hm.user_id = uid)
    union all
    select c.* from public.conversations c
     where not v_req and c.kind = 'chapter'
       and c.chapter_id in (select cm.chapter_id from public.chapter_members cm where cm.user_id = uid)
  ), lst as (
    select c.*, r.status as req_status, r.from_user, r.created_at as req_at,
           case when c.kind = 'dm' then private.chat_dm_other(c.dm_key, uid) end as other_id,
           coalesce(c.last_message_at, c.created_at) as act
      from cand c
      left join public.message_requests r on r.conversation_id = c.id
     where private.chat_role(c.id, uid) is not null
       and (c.kind <> 'dm' or not public.users_blocked(uid, private.chat_dm_other(c.dm_key, uid)))
       and case
             when v_req then coalesce(c.kind = 'dm' and r.status = 'pending' and r.to_user = uid, false)
                             and exists (select 1 from public.messages m
                                          where m.conversation_id = c.id and m.author_id = r.from_user)
             else not coalesce(c.kind = 'dm' and r.status in ('pending', 'declined') and r.to_user = uid, false)
           end
       and (p_before is null or coalesce(c.last_message_at, c.created_at) < p_before)
     order by coalesce(c.last_message_at, c.created_at) desc, c.id
     limit v_limit
  )
  select x.id, x.kind,
         case x.kind
           when 'group'   then x.title
           when 'event'   then (select e.title from public.events e where e.id = x.event_id)
           when 'hub'     then (select h.name from public.hubs h where h.id = x.hub_id)
           when 'chapter' then (select ch.name from public.hub_chapters ch where ch.id = x.chapter_id)
         end,
         case when x.kind = 'dm' then (
           select jsonb_build_object('id', p.id, 'first_name', p.first_name, 'handle', p.handle,
                                     'avatar_url', case when p.status = 'active' and p.moderation_state is null
                                                        then p.avatar_url end)
             from public.profiles p where p.id = x.other_id) end,
         case x.kind
           when 'event' then (select jsonb_build_object('event_id', e.id, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
                                                        'status', e.status)
                                from public.events e where e.id = x.event_id)
           when 'hub' then (select jsonb_build_object('hub_id', h.id, 'slug', h.slug, 'emoji', h.emoji)
                              from public.hubs h where h.id = x.hub_id)
           when 'chapter' then (select jsonb_build_object('chapter_id', ch.id, 'slug', ch.slug)
                                  from public.hub_chapters ch where ch.id = x.chapter_id)
         end,
         (select jsonb_build_object(
                   'preview', case when lm.deleted_at is not null then 'Message deleted'
                                   when lm.moderation_state is not null then 'Message hidden'
                                   when lm.kind = 'image' then 'Photo'
                                   else left(lm.body, 120) end,
                   'at', lm.created_at, 'mine', lm.author_id = uid, 'kind', lm.kind)
            from public.messages lm
           where lm.conversation_id = x.id and private.chat_visible_author(lm.author_id, uid)
             and (lm.author_id = uid or lm.kind <> 'image' or lm.image_state = 'visible' or lm.deleted_at is not null)
           order by lm.seq desc limit 1),
         (select count(*)::integer from (
            select 1 from public.messages um
             where um.conversation_id = x.id
               and um.seq > coalesce((select me.last_read_seq from public.conversation_members me
                                       where me.conversation_id = x.id and me.user_id = uid), 0)
               and um.author_id is distinct from uid and um.deleted_at is null and um.moderation_state is null
               and private.chat_visible_author(um.author_id, uid)
               and (um.kind <> 'image' or um.image_state = 'visible')
             limit 99) u),
         coalesce((select me.muted_until > now() from public.conversation_members me
                    where me.conversation_id = x.id and me.user_id = uid), false),
         coalesce(private.chat_can_post(x.id) in ('conversation_closed', 'read_only'), false),
         case when x.kind = 'dm' and x.req_status in ('pending', 'declined') then
                case when x.from_user = uid then 'sent' else 'received' end end,
         x.act
    from lst x
   order by x.act desc, x.id;
end $$;
comment on function public.chat_list(text, timestamptz, integer) is
  'Migration 58: the caller''s chats, newest activity first (p_before is the activity_at cursor; p_limit up to 100). Tab chats: dms (not pending or declined requests to the caller), groups, event chats until 30 days after the plan, hub and chapter chats that exist. Tab requests: pending requests to the caller that carry their message. Each row: conversation_id, kind, title, other (dm), context, last_message {preview, at, mine, kind}, unread (capped at 99), muted, closed, request (sent | received | null), activity_at. Never a blocked person''s dm or message; hidden or deleted messages preview as a neutral line.';

create or replace function public.chat_unread_total()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'chats', (select count(*)::integer from public.chat_list('chats', null, 100) l
               where l.unread > 0 and not l.muted
                 and (l.kind in ('dm', 'group')
                      or (l.kind = 'event' and (l.context ->> 'ends_at')::timestamptz > now() - interval '7 days'))),
    'requests', (select count(*)::integer from public.chat_list('requests', null, 100)));
$$;
comment on function public.chat_unread_total() is
  'Migration 58: {chats, requests} for the Chats badge: dms, groups and event chats of upcoming or recent plans with unread messages and not muted; pending requests to the caller.';

create or replace function public.get_messages(p_conversation uuid, p_before_seq bigint default null,
                                               p_after_seq bigint default null, p_limit integer default 50)
returns table (id uuid, seq bigint, author jsonb, kind text, body text, image jsonb, created_at timestamptz,
               deleted text, hidden boolean, mine boolean, client_id uuid)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid     uuid := (select auth.uid());
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_asc   boolean := p_after_seq is not null and p_before_seq is null;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not private.chat_can_read(p_conversation) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  return query
  with picked as (
    select m.* from public.messages m
     where m.conversation_id = p_conversation
       and (p_before_seq is null or m.seq < p_before_seq)
       and (p_after_seq is null or m.seq > p_after_seq)
       and private.chat_visible_author(m.author_id, uid)
       and (m.author_id = uid or m.kind <> 'image' or m.image_state = 'visible'
            or m.deleted_at is not null or m.moderation_state is not null)
     order by case when v_asc then m.seq end asc, m.seq desc
     limit v_limit
  )
  select x.id, x.seq,
         case when x.author_id is not null then jsonb_build_object(
           'id', p.id, 'first_name', p.first_name,
           'avatar_url', case when p.status = 'active' and p.moderation_state is null then p.avatar_url end) end,
         x.kind,
         case when x.deleted_at is not null or x.moderation_state is not null then '' else x.body end,
         case when x.kind = 'image' and x.deleted_at is null and x.moderation_state is null then jsonb_build_object(
           'state', x.image_state,
           'path', case when x.author_id = uid or x.image_state = 'visible' then x.image_path end) end,
         x.created_at,
         case when x.deleted_at is not null then x.deleted_by when x.moderation_state = 'removed' then 'moderator' end,
         coalesce(x.moderation_state = 'hidden', false),
         coalesce(x.author_id = uid, false),
         case when x.author_id = uid then x.client_id end
    from picked x
    left join public.profiles p on p.id = x.author_id
   order by x.seq desc;
end $$;
comment on function public.get_messages(uuid, bigint, bigint, integer) is
  'Migration 58: a page of a conversation the caller can read, newest first (p_limit up to 100). p_before_seq pages back; p_after_seq returns the next messages after it (the oldest first, then listed newest first). Leaves out messages by people blocked with the caller or banned, and other people''s images that are not visible yet; a deleted or moderated message keeps its row with an empty body (deleted: author | room_admin | moderator; hidden). client_id only on the caller''s own. Errors: not_authenticated, not_found.';

create or replace function public.conversation_info(p_conversation uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  c         public.conversations%rowtype;
  me        public.conversation_members%rowtype;
  r         public.message_requests%rowtype;
  e         public.events%rowtype;
  v_members jsonb;
  v_admins  jsonb := '[]'::jsonb;
  v_count   integer;
  v_other   jsonb;
  v_title   text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not private.chat_can_read(p_conversation) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  select * into c from public.conversations where id = p_conversation;
  select * into me from public.conversation_members where conversation_id = c.id and user_id = uid;
  select * into r from public.message_requests where conversation_id = c.id;

  if c.kind in ('dm', 'group') then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', p.id, 'first_name', p.first_name, 'handle', p.handle,
             'avatar_url', case when p.status = 'active' and p.moderation_state is null then p.avatar_url end,
             'role', cm.role) order by cm.joined_at, p.id), '[]'::jsonb), count(*)::integer
      into v_members, v_count
      from public.conversation_members cm
      join public.profiles p on p.id = cm.user_id
     where cm.conversation_id = c.id and cm.left_at is null and cm.removed_at is null
       and (cm.user_id = uid or not private.is_blocked_with(cm.user_id));
    v_title := c.title;
    if c.kind = 'dm' then
      select jsonb_build_object('id', p.id, 'first_name', p.first_name, 'handle', p.handle,
                                'avatar_url', case when p.status = 'active' and p.moderation_state is null
                                                   then p.avatar_url end)
        into v_other
        from public.profiles p
       where p.id = private.chat_dm_other(c.dm_key, uid) and not private.is_blocked_with(p.id);
    end if;
  elsif c.kind = 'event' then
    select * into e from public.events where id = c.event_id;
    v_title := e.title;
    select count(*)::integer + 1 into v_count from public.rsvps rr
     where rr.event_id = e.id and rr.status in ('going', 'waitlisted') and rr.removed_at is null
       and rr.user_id is distinct from e.host_id;
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'first_name', p.first_name, 'handle', p.handle)
                              order by p.first_name, p.id), '[]'::jsonb)
      into v_admins
      from public.profiles p
     where p.status = 'active' and not private.is_blocked_with(p.id)
       and (p.id = e.host_id or p.id in (select cm.user_id from public.chapter_members cm
                                          where cm.chapter_id = e.chapter_id and cm.role in ('captain', 'organizer')));
  elsif c.kind = 'hub' then
    select h.name into v_title from public.hubs h where h.id = c.hub_id;
    select count(*)::integer into v_count from public.hub_members hm where hm.hub_id = c.hub_id;
  else
    select ch.name into v_title from public.hub_chapters ch where ch.id = c.chapter_id;
    select count(*)::integer into v_count from public.chapter_members cm where cm.chapter_id = c.chapter_id;
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'first_name', p.first_name, 'handle', p.handle)
                              order by p.first_name, p.id), '[]'::jsonb)
      into v_admins
      from public.chapter_members cm
      join public.profiles p on p.id = cm.user_id
     where cm.chapter_id = c.chapter_id and cm.role in ('captain', 'organizer') and p.status = 'active'
       and not private.is_blocked_with(p.id);
  end if;

  return jsonb_build_object(
    'conversation_id', c.id,
    'kind', c.kind,
    'title', v_title,
    'role', private.chat_role(c.id, uid),
    'members', v_members,
    'member_count', v_count,
    'admins', v_admins,
    'other', v_other,
    'event_id', c.event_id,
    'hub_id', c.hub_id,
    'chapter_id', c.chapter_id,
    'muted_until', me.muted_until,
    'notify', coalesce(me.notify, c.kind in ('dm', 'group', 'event')),
    'last_read_seq', coalesce(me.last_read_seq, 0),
    'last_seq', c.last_seq,
    'can_post', private.chat_can_post(c.id),
    'images_enabled', private.chat_images_enabled(),
    'request', case when r.conversation_id is not null and r.status <> 'accepted' then
                 case when r.from_user = uid then 'sent' else 'received' end end);
end $$;
comment on function public.conversation_info(uuid) is
  'Migration 58: one conversation for its info page: kind, title, the caller''s role, members (dm and group, never someone blocked with the caller), member_count, admins (event and chapter), other (dm), muted_until, notify (null default: on for dm, group, event), last_read_seq, last_seq, can_post (null or the error code), images_enabled, request (sent | received | null). Errors: not_authenticated, not_found.';

create or replace function public.people_you_met(p_before timestamptz default null, p_limit integer default 30)
returns table (user_id uuid, handle text, first_name text, avatar_url text, last_plan jsonb, can_message boolean)
language sql stable security definer set search_path = '' as $$
  with me as (
    select (select auth.uid()) as uid where public.viewer_is_adult()
  ), pairs as (
    select m1.met_user_id as other, m1.event_id
      from me join public.event_meets m1 on m1.user_id = me.uid
      join public.event_meets m2 on m2.event_id = m1.event_id and m2.user_id = m1.met_user_id and m2.met_user_id = me.uid
    union
    select r2.user_id, r1.event_id
      from me join public.rsvps r1 on r1.user_id = me.uid and r1.checked_in_at is not null
      join public.rsvps r2 on r2.event_id = r1.event_id and r2.user_id <> me.uid and r2.checked_in_at is not null
  ), latest as (
    select distinct on (pr.other) pr.other, e.id as event_id, e.title, e.starts_at
      from pairs pr
      join public.events e on e.id = pr.event_id
     where e.starts_at > now() - interval '365 days' and e.moderation_state is null
     order by pr.other, e.starts_at desc, e.id
  )
  select p.id, p.handle, p.first_name, p.avatar_url,
         jsonb_build_object('id', l.event_id, 'title', l.title, 'starts_at', l.starts_at),
         private.chat_user_ok(p.id)
    from latest l
    join public.profiles p on p.id = l.other
    cross join me
   where p.status = 'active' and p.deleted_at is null and p.moderation_state is null
     and not public.users_blocked(me.uid, p.id)
     and (p_before is null or l.starts_at < p_before)
   order by l.starts_at desc, p.id
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;
comment on function public.people_you_met(timestamptz, integer) is
  'Migration 58: people the caller met (mutual "who did you meet" picks, or both checked in at the same plan) in the last 365 days, newest shared plan first (p_before is the starts_at cursor): user_id, handle, first_name, avatar_url, last_plan {id, title, starts_at}, can_message. Never across a block, never banned, hidden or deleted profiles; one-sided picks stay private.';

-- ---------------------------------------------------------------------------
-- 6. RPCs: writing
-- ---------------------------------------------------------------------------
create or replace function public.send_message(p_conversation uuid, p_client_id uuid, p_body text,
                                               p_image_path text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  c         public.conversations%rowtype;
  r         public.message_requests%rowtype;
  e         public.events%rowtype;
  v_body    text;
  v_err     text;
  v_mod     boolean;
  v_new     boolean;
  v_request boolean;
  v_link    boolean := false;
  v_seq     bigint;
  v_id      uuid;
  v_at      timestamptz;
  v_n       integer;
  v_last    timestamptz;
  v_user    uuid;
  v_title   text;
  v_payload jsonb;
  v_bucket  bigint;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_client_id is null then
    raise exception 'client_id_required' using errcode = 'check_violation';
  end if;
  -- A retry of a send that already went through: the same row, free.
  select m.id, m.seq, m.created_at into v_id, v_seq, v_at
    from public.messages m where m.author_id = uid and m.client_id = p_client_id;
  if v_id is not null then
    return jsonb_build_object('id', v_id, 'seq', v_seq, 'created_at', v_at, 'duplicate', true);
  end if;

  select * into c from public.conversations where id = p_conversation;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  -- Requests: shared context that appeared since, or the recipient writing back, accepts.
  if c.kind = 'dm' then
    select * into r from public.message_requests where conversation_id = c.id for update;
    if r.conversation_id is not null and r.status <> 'accepted'
       and (r.to_user = uid or private.chat_shared_context(r.from_user, r.to_user)) then
      update public.message_requests set status = 'accepted', decided_at = now() where conversation_id = c.id;
      r.status := 'accepted';
    end if;
  end if;

  v_err := private.chat_can_post(c.id);
  if v_err is not null then
    raise exception '%', v_err using
      errcode = case when v_err in ('not_authenticated', 'forbidden') then '42501'
                     when v_err = 'not_found' then 'P0002' else '23514' end;
  end if;
  v_request := c.kind = 'dm' and r.conversation_id is not null and r.status = 'pending' and r.from_user = uid;

  -- stripControlChars (packages/core) and trim.
  v_body := regexp_replace(regexp_replace(coalesce(p_body, ''), '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]', '', 'g'),
                           '^\s+|\s+$', '', 'g');
  if char_length(v_body) > 2000 or (p_image_path is null and char_length(v_body) = 0) then
    raise exception 'body_length' using errcode = 'check_violation', hint = '1 to 2000 characters.';
  end if;
  v_mod := public.is_moderator();
  v_new := (select p.created_at from public.profiles p where p.id = uid) > now() - interval '24 hours';

  if p_image_path is not null then
    if not private.chat_images_enabled() then
      raise exception 'images_disabled' using errcode = 'check_violation';
    end if;
    if v_request then
      raise exception 'request_text_only' using errcode = 'check_violation';
    end if;
    if v_new then
      raise exception 'account_too_new' using errcode = 'check_violation';
    end if;
    if p_image_path !~ ('^' || uid::text || '/' || c.id::text
                        || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$')
       or not exists (select 1 from storage.objects o where o.bucket_id = 'chat-images' and o.name = p_image_path)
       or exists (select 1 from public.messages m where m.image_path = p_image_path) then
      raise exception 'image_invalid' using errcode = 'check_violation';
    end if;
    if exists (select 1 from public.image_hashes h
                where h.bucket = 'chat-images' and h.path = p_image_path and h.status in ('blocked', 'unreadable')) then
      raise exception 'image_blocked' using errcode = 'check_violation';
    end if;
  end if;

  if char_length(v_body) > 0 and (private.chat_has_link(v_body) or private.chat_link_shortened(v_body)) then
    v_link := true;
    if v_request or v_new or private.chat_link_shortened(v_body) then
      raise exception 'link_not_allowed' using errcode = 'check_violation';
    end if;
  end if;

  if not v_mod then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('chat:' || uid::text));
    -- Three filter refusals in an hour: one hour without sending.
    select min(s.created_at), count(*)::integer into v_last, v_n
      from (select fs.created_at from public.chat_filter_strikes fs
             where fs.user_id = uid and fs.created_at > now() - interval '1 hour'
             order by fs.created_at desc limit 3) s;
    if v_n >= 3 then
      raise exception 'rate_limited' using errcode = 'check_violation',
        hint = greatest(1, ceil(extract(epoch from (v_last + interval '1 hour' - now()))))::text;
    end if;
    if (select count(*) from public.messages m
         where m.author_id = uid and m.created_at > now() - interval '1 minute')
       >= (case when v_new then 10 else 30 end) then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = '60';
    end if;
    if (select count(*) from public.messages m
         where m.author_id = uid and m.created_at > now() - interval '1 day')
       >= (case when v_new then 100 else 1000 end) then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = '3600';
    end if;
    select max(m.created_at) into v_last from public.messages m
     where m.author_id = uid and m.conversation_id = c.id;
    if c.kind = 'hub' and v_last > now() - interval '10 seconds' then
      raise exception 'slow_mode' using errcode = 'check_violation',
        hint = greatest(1, ceil(extract(epoch from (v_last + interval '10 seconds' - now()))))::text;
    end if;
    if v_last > now() - (case when v_new then interval '5 seconds' else interval '1 second' end) then
      raise exception 'rate_limited' using errcode = 'check_violation',
        hint = case when v_new then '5' else '1' end;
    end if;
    if p_image_path is not null and (select count(*) from public.messages m
                                      where m.author_id = uid and m.kind = 'image'
                                        and m.created_at > now() - interval '1 day') >= 30 then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = '86400';
    end if;
  end if;

  -- The filter: refused without raising, so the strike is kept.
  if char_length(v_body) > 0 and private.chat_filtered(v_body, v_request) then
    insert into public.chat_filter_strikes (user_id) values (uid);
    if (select count(*) from public.chat_filter_strikes fs
         where fs.user_id = uid and fs.created_at > now() - interval '1 hour') >= 3
       and not exists (select 1 from public.reports rp
                        where rp.target_kind = 'profile' and rp.target_id = uid and rp.reporter_id is null
                          and rp.status = 'open') then
      insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, note)
      values (null, 'profile', uid, uid, 'harassment', 'Automatic: three messages refused by the chat filter within an hour.');
    end if;
    return jsonb_build_object('error', 'message_filtered');
  end if;

  update public.conversations set last_seq = last_seq + 1, last_message_at = now()
   where id = c.id returning last_seq into v_seq;
  insert into public.messages (conversation_id, seq, author_id, client_id, kind, body, image_path, image_state, has_link)
  values (c.id, v_seq, uid, p_client_id, case when p_image_path is null then 'text' else 'image' end, v_body,
          p_image_path, case when p_image_path is not null then 'pending' end, v_link)
  returning id, created_at into v_id, v_at;

  -- The sender has read their own message; a dm the other person left comes back to them.
  insert into public.conversation_members (conversation_id, user_id, last_read_seq, last_read_at)
  values (c.id, uid, v_seq, now())
  on conflict (conversation_id, user_id) do update
     set last_read_seq = greatest(public.conversation_members.last_read_seq, excluded.last_read_seq),
         last_read_at = now();
  if c.kind = 'dm' then
    update public.conversation_members set left_at = null
     where conversation_id = c.id and left_at is not null;
  end if;

  -- Notifications (design section 11): ids and counts only, never the text.
  v_title := case c.kind
               when 'group' then c.title
               when 'event' then (select ev.title from public.events ev where ev.id = c.event_id)
               when 'hub' then (select h.name from public.hubs h where h.id = c.hub_id)
               when 'chapter' then (select ch.name from public.hub_chapters ch where ch.id = c.chapter_id)
             end;
  v_payload := jsonb_build_object('conversation_id', c.id, 'kind', c.kind, 'title', v_title, 'seq', v_seq);
  if v_request then
    v_user := private.chat_dm_other(c.dm_key, uid);
    perform public.enqueue_notification(v_user, 'message_request', 'message_request:' || c.id || ':' || v_user,
                                        null, null, null, uid, v_payload);
  elsif c.kind in ('dm', 'group') then
    v_bucket := floor(extract(epoch from now()) / 600)::bigint;
    for v_user in
      select cm.user_id from public.conversation_members cm
       where cm.conversation_id = c.id and cm.user_id <> uid and cm.left_at is null and cm.removed_at is null
         and (cm.muted_until is null or cm.muted_until <= now()) and coalesce(cm.notify, true)
    loop
      perform public.enqueue_notification(v_user, 'message', 'message:' || c.id || ':' || v_user || ':' || v_bucket,
                                          null, null, null, uid, v_payload, true);
    end loop;
  elsif c.kind = 'event' then
    select * into e from public.events where id = c.event_id;
    if e.ends_at > now() then
      v_bucket := floor(extract(epoch from now()) / 1800)::bigint;
      for v_user in
        select x.user_id
          from (select rr.user_id from public.rsvps rr
                 where rr.event_id = e.id and rr.status in ('going', 'waitlisted') and rr.removed_at is null
                union select e.host_id) x
          left join public.conversation_members cm on cm.conversation_id = c.id and cm.user_id = x.user_id
         where x.user_id is not null and x.user_id <> uid and cm.removed_at is null
           and (cm.muted_until is null or cm.muted_until <= now()) and coalesce(cm.notify, true)
      loop
        perform public.enqueue_notification(v_user, 'message', 'message:' || c.id || ':' || v_user || ':' || v_bucket,
                                            null, null, null, uid, v_payload, true);
      end loop;
    end if;
  else
    -- Hub and chapter chats notify only people who turned it on for the room.
    v_bucket := floor(extract(epoch from now()) / 1800)::bigint;
    for v_user in
      select cm.user_id from public.conversation_members cm
       where cm.conversation_id = c.id and cm.user_id <> uid and cm.notify is true and cm.removed_at is null
         and (cm.muted_until is null or cm.muted_until <= now())
         and private.chat_role(c.id, cm.user_id) is not null
    loop
      perform public.enqueue_notification(v_user, 'message', 'message:' || c.id || ':' || v_user || ':' || v_bucket,
                                          null, null, null, uid, v_payload, true);
    end loop;
  end if;

  return jsonb_build_object('id', v_id, 'seq', v_seq, 'created_at', v_at, 'duplicate', false);
end $$;
comment on function public.send_message(uuid, uuid, text, text) is
  'Migration 58: posts a message. p_client_id makes it idempotent (a retry returns the same row with duplicate true, free of limits). Returns {id, seq, created_at, duplicate}, or {error: message_filtered} when the filter refuses it (not raised, so the refusal counts toward the cooldown). Errors: not_authenticated, client_id_required, not_found, forbidden, onboarding_required, photo_required, conversation_closed, read_only, request_pending, account_too_new, body_length (1 to 2000), images_disabled, request_text_only, image_invalid, image_blocked, link_not_allowed (requests, accounts under a day, shorteners), rate_limited and slow_mode (hint: seconds to wait).';

create or replace function public.delete_message(p_message uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  m      public.messages%rowtype;
  v_kind public.conversation_kind;
  v_by   text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into m from public.messages where id = p_message for update;
  if not found or not private.chat_can_read(m.conversation_id)
     or not private.chat_visible_author(m.author_id, uid) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if m.deleted_at is not null then
    return;
  end if;
  select c.kind into v_kind from public.conversations c where c.id = m.conversation_id;
  if m.author_id = uid then
    v_by := 'author';
  elsif v_kind in ('group', 'event', 'chapter')
        and private.chat_role(m.conversation_id, uid) in ('owner', 'admin') then
    v_by := 'room_admin';
  else
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.messages
     set deleted_at = now(), deleted_by = v_by, deleted_body = body, body = '',
         image_state = case when kind = 'image' then 'removed' else image_state end
   where id = m.id;
  if v_by = 'room_admin' then
    insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
    values (uid, 'remove', 'message', m.id, m.author_id, 'room_admin');
  end if;
end $$;
comment on function public.delete_message(uuid) is
  'Migration 58: the author deletes their message, or a room admin (group owner or admin, event host, chapter captain or organizer) deletes someone else''s in a group, event or chapter chat (logged in moderation_actions). The row stays with an empty body; the text is kept 30 days as deleted_body for evidence; an image goes to removed. Moderators use mod_moderate. Errors: not_authenticated, not_found, forbidden.';

create or replace function public.mark_conversation_read(p_conversation uuid, p_seq bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid   uuid := (select auth.uid());
  v_seq bigint;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not private.chat_can_read(p_conversation) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  select least(greatest(coalesce(p_seq, 0), 0), c.last_seq) into v_seq
    from public.conversations c where c.id = p_conversation;
  insert into public.conversation_members (conversation_id, user_id, last_read_seq, last_read_at)
  values (p_conversation, uid, v_seq, now())
  on conflict (conversation_id, user_id) do update
     set last_read_seq = greatest(public.conversation_members.last_read_seq, excluded.last_read_seq),
         last_read_at = now();
  -- What was seen in the chat is not pushed.
  update public.notifications n
     set read_at = now()
   where n.user_id = uid and n.read_at is null and n.kind in ('message', 'message_request')
     and n.payload ->> 'conversation_id' = p_conversation::text
     and coalesce((n.payload ->> 'seq')::bigint, 0) <= v_seq;
end $$;
comment on function public.mark_conversation_read(uuid, bigint) is
  'Migration 58: raises the caller''s last_read_seq (never lowers it, never past the last message), stamps last_read_at and marks the caller''s message notifications up to that seq read, so the worker does not push what was already seen. Errors: not_authenticated, not_found.';

create or replace function public.mute_conversation(p_conversation uuid, p_until timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not private.chat_can_read(p_conversation) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  insert into public.conversation_members (conversation_id, user_id, muted_until)
  values (p_conversation, uid, case when p_until > now() then p_until end)
  on conflict (conversation_id, user_id) do update set muted_until = excluded.muted_until;
end $$;
comment on function public.mute_conversation(uuid, timestamptz) is
  'Migration 58: mutes the conversation for the caller until p_until (''infinity'' = until unmuted; null or a past time unmutes). Muted chats send no notifications and are left out of the badge. Errors: not_authenticated, not_found.';

create or replace function public.set_conversation_notify(p_conversation uuid, p_notify boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not private.chat_can_read(p_conversation) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  insert into public.conversation_members (conversation_id, user_id, notify)
  values (p_conversation, uid, p_notify)
  on conflict (conversation_id, user_id) do update set notify = excluded.notify;
end $$;
comment on function public.set_conversation_notify(uuid, boolean) is
  'Migration 58: the caller''s notification switch for one conversation (null = the kind''s default: on for dm, group and event chats, off for hub and chapter chats). Errors: not_authenticated, not_found.';

-- ---------------------------------------------------------------------------
-- 7. Service role and moderators
-- ---------------------------------------------------------------------------
create or replace function public.chat_image_classified(p_bucket text, p_path text, p_verdict text,
                                                        p_scores jsonb default '{}'::jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_n integer;
  v_m record;
begin
  if p_bucket is distinct from 'chat-images' or p_path is null then
    raise exception 'invalid_object' using errcode = '22023';
  end if;
  if p_verdict is null or p_verdict not in ('visible', 'queued', 'blocked') then
    raise exception 'invalid_verdict' using errcode = '22023';
  end if;
  update public.messages set image_state = p_verdict
   where image_path = p_path and image_state in ('pending', 'classifying');
  get diagnostics v_n = row_count;
  if p_verdict = 'queued' then
    for v_m in select m.id, m.author_id from public.messages m where m.image_path = p_path loop
      insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, note)
      values (null, 'message', v_m.id, v_m.author_id,
              case when coalesce(p_scores ->> 'category', '') = 'violence' then 'violence' else 'sexual_content' end,
              'Automatic: the image classifier was unsure.');
    end loop;
  elsif p_verdict = 'blocked' then
    update public.image_hashes set status = 'blocked', blocked_at = coalesce(blocked_at, now())
     where bucket = p_bucket and path = p_path and status <> 'blocked';
  end if;
  return v_n;
end $$;
comment on function public.chat_image_classified(text, text, text, jsonb) is
  'Migration 58, service role (image-guard): records the classifier verdict for a chat image: visible (shown), queued (hidden, an open report with no reporter for a moderator) or blocked (never shown; the object is queued for deletion). Only the verdict is stored. Returns the messages changed.';

create or replace function public.purge_messaging()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_req integer;
  v_del integer;
  v_ev  integer;
  v_evi integer;
begin
  update public.message_requests set status = 'declined', decided_at = now()
   where status = 'pending' and created_at < now() - interval '30 days';
  get diagnostics v_req = row_count;
  update public.messages set deleted_body = null
   where deleted_body is not null and deleted_at < now() - interval '30 days';
  get diagnostics v_del = row_count;
  delete from public.conversations c using public.events e
   where c.kind = 'event' and e.id = c.event_id and e.ends_at < now() - interval '90 days';
  get diagnostics v_ev = row_count;
  update public.message_report_evidence ev
     set retain_until = coalesce(rp.resolved_at, now())
                        + case when rp.reason in ('child_safety', 'ncii', 'underage') then interval '365 days'
                               else interval '90 days' end
    from public.reports rp
   where rp.id = ev.report_id and ev.retain_until is null and rp.status <> 'open';
  delete from public.message_report_evidence where retain_until < now();
  get diagnostics v_evi = row_count;
  delete from public.chat_filter_strikes where created_at < now() - interval '1 day';
  return jsonb_build_object('requests_expired', v_req, 'deleted_bodies_cleared', v_del,
                            'event_chats_purged', v_ev, 'evidence_purged', v_evi);
end $$;
comment on function public.purge_messaging() is
  'Migration 58, pg_cron purge-messaging daily: pending requests older than 30 days are declined, deleted message bodies older than 30 days are cleared, event chats go 90 days after the plan ended, evidence gets its retain_until when the report closes (a year for child_safety, ncii and underage, 90 days otherwise) and goes after it, filter strikes go after a day. Returns counts.';

create or replace function public.mod_message_evidence(p_report uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  ev  public.message_report_evidence%rowtype;
  rp  public.reports%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into ev from public.message_report_evidence where report_id = p_report;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  select * into rp from public.reports where id = p_report;
  if public.moderation_is_own('message', ev.message_id, ev.author_id) then
    raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews this one.';
  end if;
  insert into public.admin_lookups (moderator_id, via, target_user_id, result_count)
  values (uid, 'open', ev.author_id, 1);
  return jsonb_build_object(
    'report_id', ev.report_id,
    'message_id', ev.message_id,
    'conversation_kind', ev.conversation_kind,
    'author', (select jsonb_build_object('id', p.id, 'handle', p.handle, 'first_name', p.first_name, 'status', p.status)
                 from public.profiles p where p.id = ev.author_id),
    'body', ev.body,
    'context', ev.context,
    'image_evidence_path', ev.image_evidence_path,
    'reason', rp.reason,
    'status', rp.status,
    'reported_at', ev.created_at,
    'retain_until', ev.retain_until,
    'state', (select m.moderation_state from public.messages m where m.id = ev.message_id));
end $$;
comment on function public.mod_message_evidence(uuid) is
  'Migration 58, moderators: the captured evidence of one message report (body, author, conversation kind, up to 10 earlier and 5 later messages the reporter could see, reason, status). Logged in admin_lookups (via open). The only way a moderator reads chat content. Errors: not_authenticated, forbidden, not_found, own_item (second-moderator rule).';

-- ---------------------------------------------------------------------------
-- 8. Rebuilt functions (latest bodies; changes marked "Migration 58")
-- ---------------------------------------------------------------------------
-- enqueue_notification (migration 51): message and message_request are
-- social (dropped across a block or a mute), follow notification_prefs.messages,
-- never email, and a message burst batches into one row with a count.
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
    else true
  end;
  v_email := case when np.unsubscribed_all_at is not null or not coalesce(np.email_enabled, true) or not v_topic
                       -- Migration 58: chat notices never go by email (the daily cap is for plans).
                       or p_kind in ('message', 'message_request')
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
  'Internal. Records one notification honoring notification_prefs (channels, topics, unsubscribed_all_at, quiet hours via push_after). Idempotent by dedupe_key; p_batch keeps a hash per distinct actor in payload.joiners and their number in payload.count. Migration 51: across a block attendee_joined and hub_new_event are dropped and other kinds lose the actor; a mute drops attendee_joined and hub_new_event. Migration 58: message and message_request are social the same way, follow notification_prefs.messages and never email; a batched message counts messages in payload.count and keeps the newest payload.seq. Returns the id, or null when nothing was written.';

-- claim_pending_notifications (migration 56).
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
  'Migrations 55, 56 and 58, service role (send-notifications): claims up to p_limit (max 100) due rows with for update skip locked, re-checks prefs, quiet hours, blocks and mutes, staleness, the confirmed address and the daily email cap, writes skipped or deferred channels, and returns what to send now as jsonb. Leased for 10 minutes; 5 attempts. Migration 56: a moderated, cancelled or missing plan stops every notice about it but event_cancelled; blocks and mutes stop only attendee_joined and hub_new_event (others go without the actor''s name), as at queueing. Migration 58: message and message_request are social too, follow notification_prefs.messages, never email, and are skipped when the conversation is gone, closed or muted, or the member read up to payload.seq.';

-- unread_notification_count (migration 18).
create or replace function public.unread_notification_count()
returns integer language sql stable security definer set search_path = '' as $$
  select count(*)::integer from public.notifications
   where user_id = (select auth.uid()) and read_at is null
     -- Migration 58: chat notices have their own badge (chat_unread_total).
     and kind::text not in ('message', 'message_request');
$$;

comment on function public.unread_notification_count() is
  'Number of the caller''s unread notifications (0 when signed out). Migration 58: message and message_request are left out (the Chats badge uses chat_unread_total).';

-- mark_notifications_read (migration 18).
create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  n   integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  update public.notifications
     set read_at = now(), seen_at = coalesce(seen_at, now())
   where user_id = uid and read_at is null
     and (p_ids is null or id = any (p_ids))
     -- Migration 58: "mark all read" in the inbox leaves chat notices alone
     -- (the chat marks them read when they are seen there).
     and (p_ids is not null or kind::text not in ('message', 'message_request'));
  get diagnostics n = row_count;
  return n;
end $$;

comment on function public.mark_notifications_read(uuid[]) is
  'Marks the caller''s notifications read (every unread one when p_ids is null, except message and message_request since migration 58). Returns the count. Errors: not_authenticated.';

-- moderation_set_state (migration 51).
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
  'Migration 51 (58), internal: sets moderation_state on a profile, event, chapter, hub or message (a hub or chapter also goes inactive, and active again when a state is cleared). Returns the previous state.';

-- moderation_is_own (migration 54).
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
  );
$$;

comment on function public.moderation_is_own(text, uuid, uuid) is
  'Migration 51 (54, 58), internal: the second-moderator rule. True when the target is the caller, the caller''s plan or a plan in a chapter the caller runs, a chapter the caller runs, a message in a dm or group the caller is in, or the caller filed an open report on it.';

-- report_content (migration 54).
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
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  -- Places keep their own reasons, rules and queue (migration 34).
  if p_kind = 'place' then
    return public.report_place(p_id, p_reason, p_note);
  end if;
  if p_kind is null or p_kind not in ('profile', 'event', 'chapter', 'hub', 'message') or p_id is null then   -- Migration 58
    raise exception 'invalid_kind' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and deleted_at is null
                    and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_reason is null or p_reason not in ('harassment', 'hate', 'sexual_content', 'violence', 'spam', 'scam',
                                          'impersonation', 'underage', 'unsafe', 'ncii', 'child_safety', 'other') then
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
  if p_kind <> 'hub' and v_state is null
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
  'Migration 51 (54, 58): report a profile, event, chapter, hub or message (kind place hands over to report_place). Reasons: harassment, hate, sexual_content, violence, spam, scam, impersonation, underage, unsafe, ncii, child_safety, other. One open report per person per target (a repeat returns already true). Hides a profile, plan, chapter or message pending review at three reports from different active accounts older than a day, not counting anyone the target (or a captain of the chapter) blocked, and never within 30 days of a moderator dismissing or restoring it. A message report needs a message the caller can read (an author-deleted one within 30 days) and copies it with its context into message_report_evidence. Returns {id, already, hidden}; hidden is true only when this report hid it. A plan the caller cannot read, and an inactive chapter or hub, is target_not_found. Errors: not_authenticated, invalid_kind, onboarding_required, invalid_reason, target_not_found, own_item, rate_limited (20 a day).';

-- mod_moderate (migration 51).
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
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_kind is null or p_kind not in ('profile', 'event', 'chapter', 'hub', 'message') or p_id is null then   -- Migration 58
    raise exception 'invalid_kind' using errcode = 'check_violation';
  end if;
  if p_action is null or p_action not in ('dismiss', 'hide', 'remove', 'restore') then
    raise exception 'invalid_action' using errcode = 'check_violation';
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
  'Migration 51 (58), moderators: act on a profile, event, chapter, hub or message. dismiss (needs open reports) and restore clear a hide or removal and dismiss the open reports; hide holds it for review; remove is the soft delete (a profile loses its photo and bio, kept in the log; an upcoming plan is cancelled and its audience told; a hub or chapter goes inactive; a message reads "Removed by moderators"). hide and remove action the open reports. Logged in moderation_actions. Errors: not_authenticated, forbidden, invalid_kind, invalid_action, target_not_found, own_item (second-moderator rule), item_not_pending.';

-- mod_queue (migration 54).
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


-- block_user (migration 51).
create or replace function public.block_user(p_user uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  v_already boolean;
  v_shared  integer;
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
  -- Upcoming plans both are on (host or live RSVP), for the "you'll both be there" warning.
  select count(*)::integer into v_shared
    from public.events e
   where e.status = 'published' and e.ends_at > now()
     and (e.host_id = uid or exists (select 1 from public.rsvps r
                                      where r.event_id = e.id and r.user_id = uid and r.status <> 'cancelled'))
     and (e.host_id = p_user or exists (select 1 from public.rsvps r
                                         where r.event_id = e.id and r.user_id = p_user and r.status <> 'cancelled'));
  return jsonb_build_object('blocked', true, 'already', v_already, 'shared_upcoming', v_shared);
end $$;

comment on function public.block_user(uuid) is
  'Migration 51 (58): blocks p_user for the caller (symmetric in every read path). Removes the caller''s mute of them and both people''s "met" picks of each other; closes a DM between them and declines a pending request (migration 58). Returns {blocked, already, shared_upcoming}: shared_upcoming counts upcoming plans both are on, for a warning. Errors: not_authenticated, cannot_block_self, onboarding_required, user_not_found, too_many_blocks (1000).';

-- image_clear_references (migration 52).
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
  return v_n;
end $$;

comment on function public.image_clear_references(text, text) is
  'Migration 52 (58), internal: nulls profiles.avatar_url and the cover_url of events, event_series, hubs and hub_chapters that point at the object; for the chat-images bucket, sets image_state blocked on the messages that use it. Returns the rows changed.';

-- request_account_deletion (migration 53).
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
  'Deletes the caller''s account immediately (migrations 36, 51, 52, 53 and 58): ledger row (a year for a banned account), tombstone profile, private data, memberships, claims, notifications, attendance, blocks, mutes, place and content reports unattributed, moderator stamps and admin lookups by the caller unattributed, image hashes (blocked ones kept), hosted series and future events cancelled (attendees notified), RSVPs removed (waitlists promoted), messaging (pending requests sent removed with their message, DMs closed, owned groups handed over, member rows removed, empty conversations deleted, received messages kept under "Deleted user" without device keys, kept deleted text or images), auth user banned. The delete-account Edge Function finishes. Idempotent.';

-- ---------------------------------------------------------------------------
-- 9. Triggers
-- ---------------------------------------------------------------------------
-- Thin Broadcast signals (design section 5.2): ids only. The client then
-- reads through get_messages, which applies every rule at read time.
create or replace function private.messages_broadcast()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  c      public.conversations%rowtype;
  v_user uuid;
  v_req  uuid;
begin
  if tg_op = 'UPDATE' and new.deleted_at is not distinct from old.deleted_at
     and new.moderation_state is not distinct from old.moderation_state
     and new.image_state is not distinct from old.image_state then
    return null;
  end if;
  if to_regprocedure('realtime.send(jsonb,text,text,boolean)') is null then
    return null;
  end if;
  begin
    perform realtime.send(
      jsonb_build_object('conversation_id', new.conversation_id, 'message_id', new.id,
                         'seq', new.seq, 'op', lower(tg_op)),
      case when tg_op = 'INSERT' then 'msg' else 'msg_update' end,
      'conv:' || new.conversation_id::text,
      true);
    select * into c from public.conversations where id = new.conversation_id;
    if c.kind in ('dm', 'group') then
      select r.to_user into v_req from public.message_requests r
       where r.conversation_id = c.id and r.status = 'pending';
      -- One personal signal per member (at most 50): not the author, not
      -- people who left, never across a block.
      for v_user in
        select cm.user_id from public.conversation_members cm
         where cm.conversation_id = c.id and cm.left_at is null and cm.removed_at is null
           and cm.user_id is distinct from new.author_id
           and not public.users_blocked(cm.user_id, new.author_id)
         limit 50
      loop
        perform realtime.send(
          jsonb_build_object('conversation_id', c.id, 'seq', new.seq),
          case when v_user = v_req then 'request' else 'chat_activity' end,
          'user:' || v_user::text || ':chats',
          true);
      end loop;
    end if;
  exception when others then
    raise warning 'messages_broadcast: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists messages_broadcast on public.messages;
create trigger messages_broadcast after insert or update of deleted_at, moderation_state, image_state
  on public.messages for each row execute function private.messages_broadcast();

-- The upload path for chat images (migration 52's check, by path): a new
-- object is hashed first; an object already hashed goes to the classifier.
create or replace function private.messages_image_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_status text;
begin
  if new.image_path is null then
    return null;
  end if;
  select h.status into v_status from public.image_hashes h where h.bucket = 'chat-images' and h.path = new.image_path;
  if v_status in ('blocked', 'unreadable') then
    update public.messages set image_state = 'blocked' where id = new.id;
  elsif v_status = 'hashed' then
    update public.messages set image_state = 'classifying' where id = new.id and image_state = 'pending';
    perform public.image_guard_dispatch(jsonb_build_object('op', 'classify', 'bucket', 'chat-images',
                                                           'path', new.image_path));
  else
    insert into public.image_hashes (bucket, path, owner_id, status, attempts, dispatched_at)
    values ('chat-images', new.image_path, public.image_owner_from_path(new.image_path), 'pending', 1, now())
    on conflict (bucket, path) do update set status = 'pending', attempts = 1, dispatched_at = now()
     where public.image_hashes.status = 'missing';
    perform public.image_guard_dispatch(jsonb_build_object('op', 'check', 'bucket', 'chat-images',
                                                           'path', new.image_path));
  end if;
  return null;
end $$;
drop trigger if exists messages_image_guard on public.messages;
create trigger messages_image_guard after insert on public.messages
  for each row when (new.image_path is not null) execute function private.messages_image_guard();

-- Hashed and allowed: on to the classifier. (Blocked and unreadable objects
-- are cleared by image_clear_references.)
create or replace function private.image_hashes_chat_classify()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.bucket = 'chat-images' and new.status = 'hashed' and old.status is distinct from 'hashed' then
    update public.messages set image_state = 'classifying'
     where image_path = new.path and image_state = 'pending';
    if found then
      perform public.image_guard_dispatch(jsonb_build_object('op', 'classify', 'bucket', new.bucket,
                                                             'path', new.path));
    end if;
  end if;
  return null;
end $$;
drop trigger if exists image_hashes_chat_classify on public.image_hashes;
create trigger image_hashes_chat_classify after update of status on public.image_hashes
  for each row when (new.bucket = 'chat-images') execute function private.image_hashes_chat_classify();

-- ---------------------------------------------------------------------------
-- 10. Realtime Broadcast authorization (design section 5.3)
-- ---------------------------------------------------------------------------
-- realtime.messages belongs to the Realtime service; it is missing on a
-- local stack started without Realtime (the CLI rehearsal), so the policies
-- are created only where the table exists.
do $$
begin
  if to_regclass('realtime.messages') is null then
    raise notice 'realtime.messages is missing; chat Broadcast policies not created';
    return;
  end if;
  execute 'drop policy if exists "chat_topics_read" on realtime.messages';
  execute $p$
    create policy "chat_topics_read" on realtime.messages for select to authenticated
      using (
        realtime.messages.extension = 'broadcast' and (
          (select realtime.topic()) = 'user:' || (select auth.uid())::text || ':chats'
          or private.chat_can_read(private.chat_topic_conversation((select realtime.topic())))
        ))
  $p$;
  execute 'drop policy if exists "chat_topics_typing" on realtime.messages';
  execute $p$
    create policy "chat_topics_typing" on realtime.messages for insert to authenticated
      with check (
        realtime.messages.extension = 'broadcast'
        and private.chat_can_post(private.chat_topic_conversation((select realtime.topic()))) is null)
  $p$;
end $$;

-- ---------------------------------------------------------------------------
-- 11. Storage: chat-images (private, JPEG, 2 MiB) and chat-evidence
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage is missing; chat buckets not created';
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('chat-images', 'chat-images', false, 2097152, array['image/jpeg'])
  on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
                                 allowed_mime_types = excluded.allowed_mime_types;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('chat-evidence', 'chat-evidence', false, 5242880, array['image/jpeg', 'image/png'])
  on conflict (id) do update set public = false;

  execute 'drop policy if exists "chat_images_insert" on storage.objects';
  execute $p$
    create policy "chat_images_insert" on storage.objects for insert to authenticated
      with check (
        bucket_id = 'chat-images'
        and private.chat_images_enabled()
        and (storage.foldername(name))[1] = (select auth.uid())::text
        and private.chat_can_post(private.chat_uuid((storage.foldername(name))[2])) is null)
  $p$;
  execute 'drop policy if exists "chat_images_select" on storage.objects';
  execute $p$
    create policy "chat_images_select" on storage.objects for select to authenticated
      using (
        bucket_id = 'chat-images'
        and ((storage.foldername(name))[1] = (select auth.uid())::text or private.chat_image_readable(name)))
  $p$;
  execute 'drop policy if exists "chat_images_delete_unsent" on storage.objects';
  execute $p$
    create policy "chat_images_delete_unsent" on storage.objects for delete to authenticated
      using (
        bucket_id = 'chat-images'
        and (storage.foldername(name))[1] = (select auth.uid())::text
        and not private.chat_image_sent(name))
  $p$;
end $$;

-- ---------------------------------------------------------------------------
-- 12. RLS policies on the message tables
-- ---------------------------------------------------------------------------
drop policy if exists "conversations_select" on public.conversations;
create policy "conversations_select" on public.conversations for select to authenticated
  using (private.chat_can_read(id) or (select public.is_moderator()));

drop policy if exists "conversation_members_select" on public.conversation_members;
create policy "conversation_members_select" on public.conversation_members for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.is_moderator())
    or (not private.is_blocked_with(user_id) and private.chat_member_rows_visible(conversation_id))
  );

drop policy if exists "message_requests_select" on public.message_requests;
create policy "message_requests_select" on public.message_requests for select to authenticated
  using (from_user = (select auth.uid()) or to_user = (select auth.uid()));
-- messages, message_report_evidence, chat_filter_strikes and the private
-- lists have no policy and no client grant: definer RPCs only.

-- ---------------------------------------------------------------------------
-- 13. pg_cron
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; purge-messaging not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'purge-messaging') then
    perform cron.unschedule('purge-messaging');
  end if;
  perform cron.schedule('purge-messaging', '23 4 * * *', 'select public.purge_messaging()');
end $$;

-- ---------------------------------------------------------------------------
-- 14. Privileges (explicit)
-- ---------------------------------------------------------------------------
-- Private helpers: all revoked from the API roles; the ones RLS policies
-- (tables, realtime.messages, storage.objects) call are granted to the
-- signed-in role.
do $$
declare
  f text;
begin
  foreach f in array array[
    'private.chat_dm_key(uuid,uuid)', 'private.chat_dm_other(text,uuid)', 'private.chat_uuid(text)',
    'private.chat_topic_conversation(text)', 'private.chat_images_enabled()', 'private.chat_user_ok(uuid)',
    'private.chat_has_photo(uuid)',
    'private.chat_derived_role(public.conversation_kind,uuid,uuid,uuid,uuid)', 'private.chat_role(uuid,uuid)',
    'private.chat_can_read(uuid)', 'private.chat_member_rows_visible(uuid)', 'private.chat_can_post(uuid)',
    'private.chat_shared_context(uuid,uuid)', 'private.chat_match_text(text)', 'private.chat_fold(text)',
    'private.chat_has_link(text)', 'private.chat_link_shortened(text)', 'private.chat_filtered(text,boolean)',
    'private.chat_visible_author(uuid,uuid)', 'private.chat_image_readable(text)', 'private.chat_image_sent(text)',
    'private.chat_request_checks(uuid)', 'private.chat_can_add(uuid,uuid,uuid)',
    'private.chat_open_room(public.conversation_kind,uuid,uuid,uuid)',
    'private.messages_broadcast()', 'private.messages_image_guard()', 'private.image_hashes_chat_classify()']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array[
    'private.chat_uuid(text)', 'private.chat_topic_conversation(text)', 'private.chat_images_enabled()',
    'private.chat_can_read(uuid)', 'private.chat_member_rows_visible(uuid)', 'private.chat_can_post(uuid)',
    'private.chat_image_readable(text)', 'private.chat_image_sent(text)']
  loop
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- Signed-in RPCs.
do $$
declare
  f text;
begin
  foreach f in array array[
    'public.start_dm(uuid)', 'public.create_group(text,uuid[])', 'public.add_group_members(uuid,uuid[])',
    'public.remove_conversation_member(uuid,uuid)',
    'public.set_conversation_role(uuid,uuid,public.conversation_role)', 'public.rename_group(uuid,text)',
    'public.leave_conversation(uuid)', 'public.open_event_chat(uuid)', 'public.open_hub_chat(uuid)',
    'public.open_chapter_chat(uuid)', 'public.respond_message_request(uuid,text)',
    'public.chat_list(text,timestamptz,integer)', 'public.chat_unread_total()',
    'public.get_messages(uuid,bigint,bigint,integer)', 'public.conversation_info(uuid)',
    'public.people_you_met(timestamptz,integer)', 'public.send_message(uuid,uuid,text,text)',
    'public.delete_message(uuid)', 'public.mark_conversation_read(uuid,bigint)',
    'public.mute_conversation(uuid,timestamptz)', 'public.set_conversation_notify(uuid,boolean)',
    'public.mod_message_evidence(uuid)']
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- Service role only.
revoke all on function public.chat_image_classified(text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.chat_image_classified(text, text, text, jsonb) to service_role;
revoke all on function public.purge_messaging() from public, anon, authenticated;
grant execute on function public.purge_messaging() to service_role;

-- Rebuilt functions keep their grants (create or replace does not change
-- them); restated here.
revoke all on function public.enqueue_notification(uuid, public.notification_kind, text, uuid, uuid, uuid, uuid, jsonb, boolean)
  from public, anon, authenticated;
revoke all on function public.claim_pending_notifications(integer) from public, anon, authenticated;
grant execute on function public.claim_pending_notifications(integer) to service_role;
revoke all on function public.mark_notifications_read(uuid[]) from public, anon;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;
revoke all on function public.unread_notification_count() from public, anon;
grant execute on function public.unread_notification_count() to authenticated;
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
revoke all on function public.image_clear_references(text, text) from public, anon, authenticated;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 15. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.54')
  on conflict (key) do update set value = excluded.value, updated_at = now();
