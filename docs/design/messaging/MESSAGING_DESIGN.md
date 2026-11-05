# Messaging: design (release B, recorded as D-043)

Date: 2026-11-05. Status: recorded as D-043 (`docs/DECISIONS.md`). Spec: PLAN.md 4.6 (the **A** items only; reactions, read receipts, voice notes and link previews are **P**, post-launch), ROADMAP week 8, TRUST-SAFETY-LEGAL.md sections 1, 7, 8 and 11. Builds on the schema as it stands after migration 57 (`20261221000100_feed_distance.sql`, `meta.schema_version` 2.53): blocks, mutes, unified reports, auto-hide and ban (migrations 51 and 54, `private.is_blocked_with`, `public.users_blocked`), the admin queue (`mod_queue`, migration 53 rebuilt in 54), image-guard pHash checks (migration 52), the notification queue (migrations 18 and 19, `enqueue_notification` as rebuilt in 51) and the delivery worker (migrations 55 and 56, `claim_pending_notifications`). The `delete-account` Edge Function's `TODO(messages)` is closed by this design.

Everyone, anywhere (D-040): nothing here is limited to students or to Atlanta, and no copy says so.

**Short version.** One `conversations` table with five kinds: `dm`, `group`, `event`, `hub`, `chapter`. DMs and groups keep their members in `conversation_members`; event, hub and chapter chats derive membership live from RSVPs, hub membership and chapter membership, and use `conversation_members` only for per-person state (`last_read_at`, `muted_until`). First contact with someone you share no plan, hub, chapter or mutual meet with is a **message request**: one text message, no images or links, from accounts at least 24 hours old. Sending anything needs a profile photo. Every write goes through `security definer` RPCs; clients never insert into the message tables. A trigger on `messages` sends a thin Broadcast signal (`realtime.send`, private channel) to `conv:<conversation id>`; the client then fetches the message through an RLS-checked RPC, so a block or a removal takes effect on the next fetch rather than when the socket's cached authorization expires. Chat images are **off** until an image classifier key exists; with a key, an image is visible only after the pHash check and the classifier both pass. Two build slices: database, then client.

---

## 1. Principles

1. **The database decides.** Who may read, send, request, upload or be notified is computed in SQL from the same rows the rest of the app trusts (RSVPs, memberships, blocks, mutes, profile status). The client only renders.
2. **Signals, not content, on the socket.** Realtime authorization is evaluated when a client joins a channel and cached until the next JWT (Supabase docs, "Realtime Authorization: Updating RLS policies"). Broadcast payloads therefore carry ids only; the message body is read through `get_messages`, which applies every rule at read time.
3. **Blocks are symmetric and silent.** A block closes a DM in both directions and hides each person's messages from the other in shared rooms. Nobody can ask whether they were blocked (`private.is_blocked_with` stays out of the API).
4. **Evidence survives.** Reporting a message copies it and its context into moderator-only evidence; author deletion, account deletion and room expiry do not destroy it before its retention date.
5. **Free only.** Supabase Free (Realtime Broadcast, Storage, pg_cron), the existing image-guard function. The optional classifier (Sightengine's free plan, already listed as a processor) runs only when its key is set; without it chat images are disabled, not unchecked.

## 2. Conversations model

### 2.1 Kinds and membership

| Kind      | Created by                                        | Who is a member                                                                                                                | Roles                                            | Who can post                                                                  | Lifetime                                                                               |
| --------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------ | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `dm`      | `start_dm(user)`                                  | exactly the two people (`conversation_members`)                                                                                | none                                             | both, once accepted (section 3)                                               | until both leave; read-only when the other account is deleted, banned or blocked       |
| `group`   | `create_group(title, users[])`                    | rows in `conversation_members` with `left_at is null`; 3 to 50 people                                                          | `owner`, `admin`, `member`                       | every member                                                                  | until the last member leaves                                                           |
| `event`   | lazily by `open_event_chat(event)` (first opener) | the host; `rsvps` with status `going` or `waitlisted` and `removed_at is null`; captains and organizers of the event's chapter | host and chapter captains/organizers are `admin` | members; read-only from 7 days after `ends_at` and when the plan is cancelled | listed until 30 days after the end; messages purged 90 days after the end (section 12) |
| `hub`     | lazily by `open_hub_chat(hub)`                    | `hub_members` rows                                                                                                             | moderators only act as admins                    | members whose hub membership is at least 24 hours old (slow mode, section 9)  | as long as the hub is active                                                           |
| `chapter` | lazily by `open_chapter_chat(chapter)`            | `chapter_members` rows (any role)                                                                                              | `captain` and `organizer` are `admin`            | members                                                                       | as long as the chapter is active                                                       |

Rules that apply to every kind:

- The caller must pass `viewer_is_adult()` (active, onboarded, 18+, not deleted). A banned, suspended or deleted account reads and sends nothing.
- Imported plans (`events.kind = 'imported'`) have no chat (no host to answer for it). Plans that are hidden or removed by moderators (`moderation_state is not null`) have their chat closed to everyone but moderators acting on a report.
- Hubs in a sensitive category (`hub_categories.is_sensitive`, whose membership is hidden from other members) have **no hub chat**: a member list or a message author would reveal membership.
- A hidden or inactive hub or chapter closes its chat.
- Leaving an event chat means leaving the plan; a person who wants quiet mutes the chat instead. Leaving a hub or chapter chat means leaving the hub or chapter. Groups and DMs have `leave_conversation`.
- Derived membership is never copied into `conversation_members`. A row there for a derived kind exists only to hold read and mute state, is created on first open, and grants nothing on its own. A `removed_at` on that row (set by a room admin, section 10) bars the person from that room even while the derived rule still holds.

### 2.2 Table sketch (migration 58)

```sql
do $$ begin
  create type public.conversation_kind as enum ('dm', 'group', 'event', 'hub', 'chapter');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.conversation_role as enum ('owner', 'admin', 'member');
exception when duplicate_object then null; end $$;

create table if not exists public.conversations (
  id          uuid primary key default gen_random_uuid(),
  kind        public.conversation_kind not null,
  event_id    uuid references public.events (id) on delete cascade,
  hub_id      uuid references public.hubs (id) on delete cascade,
  chapter_id  uuid references public.hub_chapters (id) on delete cascade,
  dm_key      text,                      -- least(a,b)||':'||greatest(a,b) for dm, else null
  title       text,                      -- groups only, 1 to 60 characters
  created_by  uuid references public.profiles (id) on delete set null,
  last_seq    bigint not null default 0, -- per-conversation message counter
  last_message_at timestamptz,
  closed_at   timestamptz,               -- read-only (dm after block/deletion, cancelled plan)
  created_at  timestamptz not null default now(),
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

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  user_id         uuid not null references public.profiles (id) on delete cascade,
  role            public.conversation_role not null default 'member',
  joined_at       timestamptz not null default now(),
  left_at         timestamptz,           -- dm/group: left; the row stays for history
  removed_at      timestamptz,           -- removed by a room admin (any kind)
  removed_by      uuid references public.profiles (id) on delete set null,
  last_read_seq   bigint not null default 0,
  last_read_at    timestamptz,
  muted_until     timestamptz,           -- 'infinity' = muted until unmuted
  notify          boolean,               -- null = the kind's default (section 11)
  primary key (conversation_id, user_id)
);
create index if not exists conversation_members_user_idx on public.conversation_members (user_id) where left_at is null;

create table if not exists public.message_requests (
  conversation_id uuid primary key references public.conversations (id) on delete cascade,
  from_user       uuid not null references public.profiles (id) on delete cascade,
  to_user         uuid not null references public.profiles (id) on delete cascade,
  status          text not null default 'pending',  -- pending | accepted | declined
  created_at      timestamptz not null default now(),
  decided_at      timestamptz,
  constraint message_requests_status check (status in ('pending', 'accepted', 'declined')),
  constraint message_requests_not_self check (from_user <> to_user)
);
create index if not exists message_requests_to_idx   on public.message_requests (to_user, created_at desc) where status = 'pending';
create index if not exists message_requests_from_idx on public.message_requests (from_user, created_at);

create table if not exists public.messages (
  id               uuid primary key default gen_random_uuid(),
  conversation_id  uuid not null references public.conversations (id) on delete cascade,
  seq              bigint not null,
  author_id        uuid references public.profiles (id) on delete set null,  -- stays the tombstone after deletion
  client_id        uuid,                  -- idempotency key from the sender's device
  kind             text not null default 'text',  -- text | image | system
  body             text not null default '',
  image_path       text,                  -- chat-images/<uid>/<conversation>/<uuid>.jpg
  image_state      text,                  -- pending | classifying | visible | queued | blocked | removed
  has_link         boolean not null default false,
  deleted_at       timestamptz,
  deleted_by       text,                  -- author | room_admin | moderator
  deleted_body     text,                  -- kept 30 days after a delete for evidence, then nulled
  moderation_state text,                  -- hidden | removed | null (migration 51 meaning)
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

create table if not exists public.message_report_evidence (
  report_id       uuid primary key references public.reports (id) on delete cascade,
  message_id      uuid,                  -- no FK: outlives the message
  conversation_id uuid,
  conversation_kind public.conversation_kind not null,
  author_id       uuid references public.profiles (id) on delete set null,
  body            text not null,
  image_evidence_path text,              -- chat-evidence/<report id>.jpg
  context         jsonb not null,        -- up to 10 earlier and 5 later messages the reporter could see
  retain_until    timestamptz,           -- set when the report closes (section 13)
  created_at      timestamptz not null default now()
);
```

Every new table: `enable row level security`, `revoke all ... from public, anon, authenticated`, `grant all ... to service_role`, then only the grants in section 6. Message tables are written only by the RPCs. `messages` and `conversations` are **not** added to the `supabase_realtime` publication (Broadcast replaces Postgres Changes here).

`seq` is assigned inside `send_message` by `update conversations set last_seq = last_seq + 1 ... returning last_seq` (a row lock that serializes sends per conversation, gap-free and cheap at this scale). History is keyset-paginated on `(conversation_id, seq)` through the unique index.

### 2.3 Membership helpers (private schema, not in the API)

```sql
private.chat_role(p_conversation uuid, p_user uuid) returns text
  -- 'owner' | 'admin' | 'member' | null. Evaluates the table in 2.1 live:
  -- dm/group from conversation_members (left_at and removed_at null);
  -- event from events + rsvps + chapter_members; hub from hub_members
  -- (not sensitive, hub active); chapter from chapter_members (active).
  -- Null for an inactive account, a moderated event, imported plans,
  -- or a removed_at row.
private.chat_can_read(p_conversation uuid) returns boolean   -- caller; chat_role is not null
private.chat_can_post(p_conversation uuid) returns text       -- null = ok, else the error code
  -- photo_required, onboarding_required, conversation_closed, read_only,
  -- request_pending, account_too_new, blocked (dm only, never named as such:
  -- returns conversation_closed), slow_mode.
private.chat_shared_context(p_a uuid, p_b uuid) returns boolean
  -- true when any of: both on the same plan (host or going/waitlisted/checked-in
  -- RSVP, not removed) that is upcoming or ended in the last 180 days; both
  -- members of the same non-sensitive hub, each for at least 24 hours; both in
  -- the same active chapter; a mutual event_meets pair; an accepted DM between them.
private.chat_topic_conversation(p_topic text) returns uuid
  -- 'conv:<uuid>' -> uuid, anything else -> null (no cast errors).
```

All are `security definer set search_path = ''`, `revoke all from public, anon`, `grant execute to authenticated, service_role` (the realtime policies run as the signed-in role). The hub rule's 24-hour membership age stops "join a big hub to skip the request" from working instantly.

## 3. Message requests

When `start_dm(p_user)` finds no `chat_shared_context` between the caller and `p_user`:

- The caller must have an account at least **24 hours** old (`profiles.created_at`), a profile photo, and fewer than **10** requests in the last 24 hours. Otherwise `account_too_new`, `photo_required` or `rate_limited`.
- A `dm` conversation is created with both member rows and a `message_requests` row `pending`. The requester may send **one** message, text only: no image, and no link (section 8's detector; `link_not_allowed`). A second send before acceptance is `request_pending`.
- The recipient sees it under **Requests** in Chats, never in the main list, with the requester's first name, photo, handle and the one message. Actions: **Accept** (the DM opens normally, images and links allowed), **Decline** (silent: the requester still sees "Sent"; they cannot request this person again for 30 days, `request_cooldown`), **Block** (`block_user` plus decline) and **Report** (message report plus decline).
- Pending requests expire after 30 days (declined by the purge job). The recipient's reply counts as acceptance.
- A notification `message_request` is queued for the recipient (in-app and push, never email; section 11). It is social: dropped across a block or a mute.
- If shared context appears later (both RSVP to the same plan), the pending request is accepted automatically at the next send.

## 4. Who may message at all

`private.chat_can_post` holds the account rules for every kind:

| Rule                                                                                     | Error                                       | Notes                                                                                                                                                                                 |
| ---------------------------------------------------------------------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Signed in, active, onboarded, adult (`viewer_is_adult()`)                                | `not_authenticated` / `onboarding_required` | banned and suspended accounts read nothing either                                                                                                                                     |
| `profiles.avatar_url` is set and its `image_hashes` row is not `blocked` or `unreadable` | `photo_required`                            | PLAN 4.6. Reading is allowed without a photo; sending and requesting are not. The composer links to `/you/photo`.                                                                     |
| Account at least 24 hours old                                                            | `account_too_new`                           | for message requests, images, links and hub chats; DMs and groups with shared context, and event and chapter chats, allow text from day one under the new-account limits in section 9 |
| Not blocked with the other person (dm)                                                   | `conversation_closed`                       | the same answer as a deleted account, so the block is not revealed                                                                                                                    |
| Conversation open (`closed_at` null, plan not cancelled, not past the read-only time)    | `read_only`                                 |                                                                                                                                                                                       |

## 5. Realtime: Broadcast from the database on private channels

Checked against the Supabase docs (Realtime Broadcast, "Broadcast from the database" with `realtime.send` and `realtime.broadcast_changes`, and Realtime Authorization with RLS on `realtime.messages` and `realtime.topic()`).

### 5.1 Topics

| Topic                    | Who joins                                                | Sent by                              | Events                                                                                 |
| ------------------------ | -------------------------------------------------------- | ------------------------------------ | -------------------------------------------------------------------------------------- |
| `conv:<conversation id>` | anyone with `private.chat_can_read` on that conversation | database trigger; clients for typing | `msg` (new), `msg_update` (deleted, moderated, image state changed), `typing` (client) |
| `user:<user id>:chats`   | that user only                                           | database trigger                     | `chat_activity` (a dm or group you are in, or a request to you, has news), `request`   |

Both are joined with `supabase.channel(topic, { config: { private: true } })` after `supabase.realtime.setAuth()`. The existing public `notifications:<uid>:...` Postgres Changes channel stays as it is; "Allow public access" in the Realtime settings therefore stays on, and the chat channels rely on being private plus the policies below. Slice 1's staging test checks that a non-private subscriber to `conv:<id>` receives nothing.

### 5.2 Trigger

```sql
create or replace function private.messages_broadcast() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform realtime.send(
    jsonb_build_object('conversation_id', new.conversation_id, 'message_id', new.id,
                       'seq', new.seq, 'op', lower(tg_op)),
    case when tg_op = 'INSERT' then 'msg' else 'msg_update' end,
    'conv:' || new.conversation_id::text,
    true);                                     -- private
  -- dm and group only: one personal signal per member (at most 50), skipping
  -- the author, people who left, and blocked pairs.
  ...
  return null;
end $$;
create trigger messages_broadcast after insert or update of deleted_at, moderation_state, image_state
  on public.messages for each row execute function private.messages_broadcast();
```

The payload never contains a body, an author id or an image path. Each recipient's client then calls `get_messages(conversation, after_seq => <highest seq it has>)`, which filters blocked authors, moderated messages and images that are not yet visible. That costs one small read per recipient per message and buys immediate enforcement of blocks, removals and bans despite the cached channel authorization. Event, hub and chapter rooms get no personal `user:` fan-out (they can be large); their unread badges refresh when the chat list is open (every 60 s and on focus) and when the person is subscribed to the room.

Broadcast Replay (private channels, up to 25 messages) is not used: history always comes from `get_messages`.

### 5.3 RLS on `realtime.messages`

```sql
drop policy if exists "chat_topics_read" on realtime.messages;
create policy "chat_topics_read" on realtime.messages for select to authenticated
  using (
    realtime.messages.extension = 'broadcast' and (
      (select realtime.topic()) = 'user:' || (select auth.uid())::text || ':chats'
      or private.chat_can_read(private.chat_topic_conversation((select realtime.topic())))
    ));

drop policy if exists "chat_topics_typing" on realtime.messages;
create policy "chat_topics_typing" on realtime.messages for insert to authenticated
  with check (
    realtime.messages.extension = 'broadcast'
    and private.chat_can_post(private.chat_topic_conversation((select realtime.topic()))) is null);
```

Clients may write only to `conv:` topics they can post in, and only typing is expected there. Clients ignore any client-sent event other than `typing` and validate its shape; a forged `msg` signal only makes a client fetch, which returns nothing new. Typing payloads carry the sender's user id, which a hostile member could forge; the client shows typing only for ids that are members it can see, and shows nothing in hub chats.

## 6. RLS and grants

| Object                                                    | anon | authenticated                                                                                                                                                                                                                                                                              | Policy                                                                                                                                         |
| --------------------------------------------------------- | ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `conversations`                                           | none | `select (id, kind, event_id, hub_id, chapter_id, title, last_seq, last_message_at, closed_at, created_at)`                                                                                                                                                                                 | `private.chat_can_read(id)` or moderator                                                                                                       |
| `conversation_members`                                    | none | `select`                                                                                                                                                                                                                                                                                   | own rows, or rows of a dm/group the caller can read whose user is not blocked with the caller; moderators                                      |
| `message_requests`                                        | none | `select`                                                                                                                                                                                                                                                                                   | `from_user` or `to_user` is the caller                                                                                                         |
| `messages`                                                | none | none                                                                                                                                                                                                                                                                                       | no direct reads; `get_messages` and `chat_list` only (they apply block, moderation and image-state rules that a policy cannot express cheaply) |
| `message_report_evidence`                                 | none | none                                                                                                                                                                                                                                                                                       | moderators through `mod_message_evidence` only                                                                                                 |
| Storage `chat-images` (private, 2 MiB, `image/jpeg` only) | none | insert into `<auth.uid()>/<conversation id>/` when `private.chat_can_post` is null and images are enabled; select (for signed URLs) when the object is the caller's own, or a `messages` row with that `image_path` has `image_state = 'visible'` and the caller can read the conversation | no update; delete own objects only before they are sent                                                                                        |
| Storage `chat-evidence` (private)                         | none | none                                                                                                                                                                                                                                                                                       | service role only; moderators get 10-minute signed URLs from `mod_message_evidence` via the image-guard function                               |

All writes are RPCs. No `insert`, `update` or `delete` grant on any message table goes to `authenticated`.

## 7. RPC list (all `security definer set search_path = ''`, check `auth.uid()`, `revoke all from public, anon`, `grant execute to authenticated` unless marked)

Conversations and requests:

| Signature                                                                                           | Returns                                                              | Errors                                                                                                                                                                                                                                    |
| --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `start_dm(p_user uuid)`                                                                             | `{conversation_id, state: 'open' \| 'request' \| 'request_pending'}` | `user_not_found` (also for a blocked pair, a banned or hidden profile), `cannot_message_self`, `photo_required`, `account_too_new`, `rate_limited`, `request_cooldown`                                                                    |
| `create_group(p_title text, p_users uuid[])`                                                        | `{conversation_id, added, skipped}`                                  | `too_many_members` (49 others), `photo_required`, `rate_limited` (5 groups a day). People without shared context with the creator, or blocked with any existing member, are skipped, not refused, and the count is returned without names |
| `add_group_members(p_conversation uuid, p_users uuid[])`                                            | `{added, skipped}`                                                   | `forbidden` (owner or admin), `too_many_members`                                                                                                                                                                                          |
| `remove_conversation_member(p_conversation uuid, p_user uuid)`                                      | `void`                                                               | `forbidden`; group owner/admin, or event/chapter admin (sets `removed_at`)                                                                                                                                                                |
| `set_conversation_role(p_conversation uuid, p_user uuid, p_role conversation_role)`                 | `void`                                                               | owner only, groups only                                                                                                                                                                                                                   |
| `rename_group(p_conversation uuid, p_title text)`                                                   | `void`                                                               | owner or admin                                                                                                                                                                                                                            |
| `leave_conversation(p_conversation uuid)`                                                           | `void`                                                               | dm and group only; an owner leaving hands ownership to the oldest admin, else the oldest member                                                                                                                                           |
| `open_event_chat(p_event uuid)` / `open_hub_chat(p_hub uuid)` / `open_chapter_chat(p_chapter uuid)` | `{conversation_id}` (creates the room on first call)                 | `forbidden` (not a member), `chat_unavailable` (imported plan, sensitive hub, moderated or inactive)                                                                                                                                      |
| `respond_message_request(p_conversation uuid, p_action text)`                                       | `void`                                                               | `accept`, `decline`; `not_found`                                                                                                                                                                                                          |

Reading:

| Signature                                                                                                                      | Returns                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `chat_list(p_tab text default 'chats', p_before timestamptz default null, p_limit int default 30)`                             | newest activity first: `{conversation_id, kind, title, other: {id, first_name, handle, avatar_url} \| null, event/hub/chapter label, last_message: {preview, at, mine, kind}, unread (capped at 99), muted, closed}`; tab `requests` lists pending requests to the caller. Previews of hidden, removed or blocked-author messages are replaced by a neutral line                                                                                          |
| `chat_unread_total()`                                                                                                          | `{chats: int, requests: int}` for the top-bar badge (dm, group, and event chats of upcoming or recent plans; not muted)                                                                                                                                                                                                                                                                                                                                   |
| `get_messages(p_conversation uuid, p_before_seq bigint default null, p_after_seq bigint default null, p_limit int default 50)` | newest first, `limit` capped at 100. Each row `{id, seq, author: {id, first_name, avatar_url} \| null, kind, body, image: {state, path} \| null, created_at, deleted: 'author' \| 'room_admin' \| 'moderator' \| null, hidden, mine, client_id (own only)}`. Leaves out messages by authors blocked with the caller, by banned authors, and other people's images that are not `visible`; a deleted or moderated message keeps its row with an empty body |
| `conversation_info(p_conversation uuid)`                                                                                       | title, kind, role, members (dm and group: list; derived rooms: count plus the admins), mute state, notify, can_post (null or the error code), images_enabled                                                                                                                                                                                                                                                                                              |
| `people_you_met(p_before timestamptz default null, p_limit int default 30)`                                                    | mutual `event_meets` pairs plus people both checked in at the same plan, last 365 days, newest shared plan first: `{user, last_plan: {id, title, starts_at}, can_message: boolean}`; never across a block, never banned or hidden profiles. One-sided picks stay private (migration 20)                                                                                                                                                                   |

Writing:

| Signature                                                                                          | Returns                            | Errors                                                                                                                                                                                                                                                                                                                     |
| -------------------------------------------------------------------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `send_message(p_conversation uuid, p_client_id uuid, p_body text, p_image_path text default null)` | `{id, seq, created_at, duplicate}` | everything in section 4, `body_length` (1 to 2000 after trimming and `stripControlChars`-equivalent cleanup), `message_filtered` (section 8), `link_not_allowed`, `images_disabled`, `image_invalid` (path not the caller's folder for this conversation, or object missing), `rate_limited` and `slow_mode` (with `hint`) |
| `delete_message(p_message uuid)`                                                                   | `void`                             | author, or a room admin for others' messages in group, event and chapter chats; moderators use `mod_moderate`                                                                                                                                                                                                              |
| `mark_conversation_read(p_conversation uuid, p_seq bigint)`                                        | `void`                             | raises `last_read_seq` (never lowers it), stamps `last_read_at`, and sets `read_at` on the caller's pending `message` notifications for that conversation so the worker does not push what was already seen                                                                                                                |
| `mute_conversation(p_conversation uuid, p_until timestamptz)`                                      | `void`                             | `null` unmutes; the client offers 1 hour, 8 hours, 1 week, until I turn it back on (`infinity`)                                                                                                                                                                                                                            |
| `set_conversation_notify(p_conversation uuid, p_notify boolean)`                                   | `void`                             |                                                                                                                                                                                                                                                                                                                            |

Idempotent send: `p_client_id` is a UUID the device makes before showing the bubble. A retry with the same `(author, client_id)` returns the existing row with `duplicate = true` and does not count against rate limits.

Service role only:

| Signature                                                                           | Use                                                                                                                                                                            |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `chat_image_classified(p_bucket text, p_path text, p_verdict text, p_scores jsonb)` | image-guard records `visible`, `queued` or `blocked` (section 10)                                                                                                              |
| `purge_messaging()`                                                                 | pg_cron daily: expired requests, `deleted_body` older than 30 days, event chats 90 days after the plan ended, evidence past `retain_until`, abandoned uploads older than a day |

Moderators (`forbidden` otherwise; second-moderator rule applies):

| Signature                             | Use                                                                                                                                          |
| ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `mod_message_evidence(p_report uuid)` | the evidence row with context; a signed URL for an evidence image is minted by image-guard (`op: "evidence_url"`). Logged in `admin_lookups` |

## 8. Link and profanity filter

Server-side in `send_message`, mirrored in `packages/core` for instant feedback (the server is authoritative):

- **Normalization:** lowercase, NFKC, strip zero-width characters, fold common look-alikes and leetspeak (`0→o`, `1→i`, `3→e`, `4→a`, `5→s`, `@→a`, `$→s`), collapse repeated letters to two.
- **Links:** a match on a scheme (`https?://`), `www.`, or a bare `label.tld` where the TLD is in a short list kept in the migration (com, net, org, io, co, app, me, ly, gg, xyz, info, biz, tv, link, site, online, and country codes). Phone numbers and email addresses are **not** links. Links are refused in message requests and from accounts under 24 hours (`link_not_allowed`); shorteners (`bit.ly`, `tinyurl.com`, `t.co`, `goo.gl`, `is.gd`, `cutt.ly`, `rb.gy`, and the rest of a list in `private.chat_link_denylist`) are refused everywhere because they hide the destination. Allowed links are stored as text (`has_link = true`), rendered as plain links with `rel="noopener noreferrer nofollow ugc"`, never fetched (no previews, P), and open through a "Leaving Activity Planet" confirmation.
- **Profanity:** adults swear; ordinary profanity is allowed. A short list of high-confidence slurs and sexual-solicitation phrases in `private.chat_filter_terms (term text primary key, applies_to text)` is refused (`message_filtered`, a neutral "This message can't be sent. It may break the Community Guidelines."). `applies_to = 'requests'` terms are refused only in message requests. Three refusals in an hour put the sender in a 1-hour send cooldown and file an automatic open report on the profile (`reason = 'harassment'`, no reporter) for a moderator to look at. The list lives in the migration (the repo is public; that is acceptable for a list of this kind) and grows by migration.

## 9. Rate limits and the new-account cooldown

Counted from `messages (author_id, created_at)` under `pg_advisory_xact_lock(hashtext('chat:' || uid))`, as `report_content` does. Moderators are exempt. Duplicates (same client id) are free.

| Limit                                  | Normal                  | Account under 24 hours          |
| -------------------------------------- | ----------------------- | ------------------------------- |
| Messages per minute, all conversations | 30                      | 10                              |
| Messages per day                       | 1,000                   | 100                             |
| In one conversation                    | 1 per second            | 1 per 5 seconds                 |
| Hub chats (slow mode)                  | 1 per 10 seconds        | not allowed (`account_too_new`) |
| New message requests                   | 10 a day                | not allowed                     |
| Images                                 | 30 a day                | not allowed                     |
| Links                                  | allowed except requests | not allowed                     |
| New groups                             | 5 a day                 | 1 a day                         |

`rate_limited` and `slow_mode` carry a `hint` with the wait in seconds; the composer shows it and keeps the draft.

## 10. Images

**State: off at launch unless a classifier key exists.** PLAN 4.6 and TRUST-SAFETY-LEGAL 7 require every uploaded chat image to be classified before anyone else sees it. The pHash check alone only catches copies of images moderators already removed, so it is not enough. `meta.chat_images` (`'off'` by default) is set to `'on'` on a project only after the `SIGHTENGINE_API_USER` and `SIGHTENGINE_API_SECRET` Edge Function secrets are set there (FOUNDER-TODO). While it is `off`, `send_message` with an image answers `images_disabled`, the storage insert policy refuses uploads, and the composer hides the photo button. If the flag is on but the function finds no key, it fails closed: the image is `blocked` with `last_error = 'no_classifier'` and is never shown.

Flow when on:

1. The client resizes to at most 1600 px on the long side, re-encodes JPEG (quality 0.85, metadata dropped by the canvas) under 2 MiB, and uploads to `chat-images/<uid>/<conversation id>/<uuid>.jpg`.
2. `send_message(..., p_image_path)` checks the path and the object, inserts the message with `image_state = 'pending'`, and a trigger on `messages.image_path` reuses migration 52's `image_guard_on_reference` path: an `image_hashes` row and an `image-guard` `check` dispatch. A path whose hash row is already `blocked` or `unreadable` is refused (`image_blocked`).
3. On `hashed` (an `after update` trigger on `image_hashes` for bucket `chat-images`), the message goes to `classifying` and image-guard gets `{op: "classify", bucket, path}`. It downloads the object with the service role, sends it to Sightengine (models `nudity-2.1,offensive,gore-2.0,self-harm`), and calls `chat_image_classified`: **block** at high confidence (any sexual or gore score at or above 0.85, or any minor-related signal), **queue** at medium (0.5 to 0.85: hidden, an open report with no reporter, `reason = 'sexual_content'` or `'violence'`, for a moderator), **visible** otherwise. Only the verdict and the scores are stored, never the image.
4. A `blocked` or `unreadable` hash, a takedown match (`mod_takedown_block_image`), or a classifier block sets `image_state = 'blocked'`; `image_clear_references` (migration 52) is rebuilt from its latest body to also set matching `messages` rows to `image_state = 'blocked'`, so an NCII takedown clears chat copies too. The object is deleted by image-guard's sweep, after a copy goes to `chat-evidence` if a report exists.
5. Until `visible`, recipients see a placeholder "Photo is being checked"; the sender sees their own image with the same label.

Sightengine's free plan has a small monthly allowance. `meta.chat_classifier_monthly_cap` (default 1,800, set below the plan's allowance) and a per-month counter row in `collector_budget` (no user id) bound it; once the cap is reached image-guard stops calling the classifier and answers `queued`, so images wait for a moderator rather than appearing unchecked.

## 11. Notifications

New `notification_kind` values `message` and `message_request` (`alter type ... add value if not exists`).

Producer (inside `send_message`, same transaction):

- **dm and group:** one notification per recipient, batched with `p_batch = true` and the dedupe key `message:<conversation>:<recipient>:<10-minute bucket>`, so a burst becomes one row with a count. Payload: `{conversation_id, kind, title (group) or null, seq, count}`; the actor is the sender. **No message text** in the payload, the email or the push ("New message from Sam", "3 new messages in Thursday climbers").
- **event chats:** going and waitlisted members, batched per 30 minutes, default on for upcoming plans; off once the plan has ended.
- **hub and chapter chats:** off by default; `set_conversation_notify(true)` turns them on per room.
- **requests:** `message_request` to the recipient, one per request.

Skipped when: the recipient's `muted_until > now()`; `notify = false` (or the kind's default is off); the recipient muted the sender (`mutes`); a block in either direction; the recipient is the author; the recipient has read past the message.

`enqueue_notification` is rebuilt from its migration 51 body with two changes: `message` and `message_request` join `attendee_joined` and `hub_new_event` as social kinds (dropped across a block or a mute), and their topic switch is `notification_prefs.messages`. Email is always `skipped` for both kinds (Resend's free daily cap is 90 emails, kept for plan logistics). Quiet hours hold the push through `push_after` as for every kind.

`claim_pending_notifications` is rebuilt from its migration 56 body with the same social list and topic, plus: a `message` row is skipped when the conversation is muted now, the member has read up to `payload.seq` (`mark_conversation_read` also stamps `read_at`, so the existing `read_in_app` check covers the open-chat case), or the conversation is closed. The inbox (`inboxQuery`) and `unread_notification_count` leave out `message` and `message_request` (rebuilt from migration 18 with that filter); the Chats icon has its own badge from `chat_unread_total`.

## 12. Delete, moderate, report, evidence

- **Delete own message:** `delete_message` sets `deleted_at`, `deleted_by = 'author'`, moves the body to `deleted_body` and empties `body`; an image goes to `image_state = 'removed'` and its object is deleted by the sweep. Everyone sees "Message deleted". `deleted_body` is nulled after 30 days, so a harasser cannot erase evidence by deleting fast: a participant who saw the message can still report the deleted message within those 30 days and the evidence copy takes `deleted_body`.
- **Room admin delete:** group owner and admins, event hosts and chapter captains and organizers may delete others' messages in their room ("Removed by the host"); same storage rules; logged as a `moderation_actions` row with `action = 'remove'`, `target_kind = 'message'` and a note `room_admin`.
- **Moderator soft delete:** `mod_moderate('message', id, 'hide' | 'remove' | 'restore' | 'dismiss', note)`. Rebuilt from its migration 51 body (and `moderation_set_state`, `moderation_is_own` from 54, `mod_queue` from 54) to accept `message`. The `reports_target_kind` and `moderation_actions_kind` check constraints are dropped and re-added with `'message'`. Removed reads "Removed by moderators"; hidden reads "Hidden while we review it" (the author sees their own with that label). Nothing is hard-deleted by moderators.
- **Report:** `report_content('message', id, reason, note)`, rebuilt from its migration 54 body with a `message` branch: the reporter must be able to read the conversation and the message (or a deleted one within 30 days), cannot report their own, and `target_user_id` is the author. In the same transaction a `message_report_evidence` row is written with the body (or `deleted_body`), the author, the conversation kind and up to 10 earlier and 5 later messages that the reporter could see (ids, authors, bodies, times); an image is copied into `chat-evidence` by image-guard (`op: "evidence_copy"`). Auto-hide at three different reporters (migration 51 and 54 rules) applies to messages unchanged; in a DM that cannot happen, so a DM report always goes to a moderator inside the 24-hour target (4 hours for child safety).
- **What moderators can read:** reported messages and their captured context, through `mod_message_evidence`, logged. There is no RPC that lets a moderator open an arbitrary conversation. This matches the Privacy Policy line "moderators can read reported messages".
- **Ban:** no change to `mod_ban_user`; `get_messages` hides a banned author's messages from everyone but moderators, and their DMs read as closed.
- **Block:** `block_user` (migration 51) is rebuilt from its latest body to also close any DM between the pair (`closed_at`, decline a pending request); the DM reappears only if both unblock and someone writes again.

Evidence retention: `retain_until` is set when the report closes: **one year** for `child_safety`, `ncii` and `underage`, **90 days** for other reasons; open reports keep their evidence indefinitely. `purge_messaging()` deletes rows past `retain_until` and their `chat-evidence` objects. Evidence survives the author's and the reporter's account deletion (the reporter link is already cleared by migration 51's deletion rules).

## 13. Account deletion

`request_account_deletion` is rebuilt from its migration 53 body (the latest), adding, in the same transaction:

- `conversation_members` rows of the caller are deleted; a group they owned passes to the oldest admin, else the oldest member; a group left empty is deleted with its messages.
- `message_requests` the caller sent and that are still pending are deleted together with their one message; pending requests to the caller are declined.
- DMs with the caller get `closed_at` (the other person sees "Deleted user" and cannot send).
- Messages the caller wrote that others received stay, **anonymized**: `author_id` keeps pointing at the tombstone profile ("Deleted user", no photo), `client_id` and `deleted_body` are nulled, and image messages become `image_state = 'removed'` with the object queued for deletion. Content in `message_report_evidence` stays until its `retain_until` (moderation evidence, TRUST-SAFETY-LEGAL section 11).
- Notifications about the caller already lose the actor (migration 18).

The `delete-account` Edge Function replaces `TODO(messages)` with: list and remove every object under `chat-images/<uid>/`. Reported images were already copied to `chat-evidence` when the report was filed, so the originals can always go. TRUST-SAFETY-LEGAL section 11's retention table gains a "Messages" row: text others received kept as "Deleted user" until the conversation is deleted or expires; images deleted; reported messages kept per section 12.

Retention without deletion: event chats are purged 90 days after the plan ends; deleted message bodies after 30 days; expired requests after 30 days. DMs and groups are kept while a member remains.

## 14. Client

### 14.1 Routes (`apps/app/src/routes/_app/`)

| File                                   | Path              | What                                                                                                                                |
| -------------------------------------- | ----------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `chats.tsx` (replaces the Coming Soon) | `/chats`          | list with two tabs, Chats and Requests (`?tab=requests`, with its count); "New message" button                                      |
| `chats_.new.tsx`                       | `/chats/new`      | picker: People you've met first, then people from your plans, hubs and chapters, then handle search; select several to make a group |
| `chats_.$id.tsx`                       | `/chats/$id`      | the conversation: history, composer, typing line, request banner (Accept / Decline / Block / Report)                                |
| `chats_.$id_.info.tsx`                 | `/chats/$id/info` | members, mute, notify, rename and add (groups), leave, report, block (dm), Safety Center link                                       |
| `you_.met.tsx`                         | `/you/met`        | People you've met, each with Message                                                                                                |

Entry points: "Chat" on the plan page (members only, `open_event_chat` then navigate), on hub and chapter pages, and "Message" on the profile card (`start_dm`). The tab bar is unchanged (Map keeps the slot). `ChatsButton` gains an unread badge and sits beside `InboxBell` in the top bar of every top-level tab (Home, Hubs, Map, You). The Safety Center link stays in the DM composer's menu (TRUST-SAFETY-LEGAL 6).

### 14.2 Behaviour

- **History:** newest first, `get_messages` pages of 50 with `p_before_seq` as the cursor (TanStack Query `useInfiniteQuery`), rendered bottom-up; scrolling up loads older pages. New signals fetch with `p_after_seq` and merge by `seq`.
- **Optimistic send:** the composer creates `client_id = crypto.randomUUID()`, shows the bubble as "Sending", calls `send_message`; on success the bubble takes the server `id` and `seq`; on a network error it retries with the same `client_id` (exponential backoff, 3 tries) then shows "Not sent, tap to retry"; on a rule error (`rate_limited`, `message_filtered`, `photo_required` and the rest) it shows the reason and keeps the text in the composer. The outbox survives a reload in memory only (no message text in browser storage).
- **Typing:** the client sends `typing` on `conv:<id>` at most every 3 seconds while the composer changes, and the indicator expires after 5 seconds. DMs and groups only.
- **Read state:** `mark_conversation_read` when the newest message is on screen and the tab is visible, debounced to once a second.
- **Realtime lifecycle:** one `user:<uid>:chats` channel while signed in; one `conv:` channel per open conversation, removed on leave; `setAuth()` on token refresh; a 30-second poll fallback while a channel is not `SUBSCRIBED` (as `useNotificationsLive` does).
- **Images (when enabled):** file input with `accept="image/*"` and `capture` support (the week 7 camera path), the resize from `lib/avatar.ts`'s approach, signed URLs (`createSignedUrl`, 1 hour) cached per path.
- **Privacy:** no analytics event carries message text; `message_sent` (PLAN 4.10) sends only the conversation kind. If PostHog session replay is ever enabled, `/chats` routes are excluded and inputs masked (ROADMAP week 8 "replay excluded on chat routes"; TRUST-SAFETY-LEGAL 8). Sentry breadcrumbs drop request bodies on chat RPCs.
- Copy is neutral and for everyone (D-040).

### 14.3 `packages/core`

`packages/core/src/messaging/`: topic builders (`conversationTopic(id)`, `userChatsTopic(uid)`), Zod schemas for the RPC results, `MESSAGE_MAX = 2000`, the link detector and normalization that mirror section 8 (with a test that runs the same fixtures the SQL test uses), the outbox reducer (`pending → sent | failed`, dedupe by `client_id`, merge by `seq`), and the error-code to copy map. The Supabase calls and query options live in `apps/app/src/lib/messaging.ts`, following `lib/notifications.ts`.

## 15. Build slices

Exactly two.

### Slice 1: database

Migration 58 (`supabase/migrations/20261222000100_messaging.sql`, after `20261221000100_feed_distance.sql`), idempotent, `meta.schema_version` 2.53 to **2.54**:

1. Enums, the five tables in 2.2, indexes, RLS, explicit grants and revokes; buckets `chat-images` and `chat-evidence` with their storage policies; `meta.chat_images = 'off'`.
2. Private helpers (2.3), the link denylist and filter terms tables.
3. RPCs in section 7, including `people_you_met`.
4. Triggers: `messages_broadcast`, the image-guard reference trigger on `messages.image_path`, the `image_hashes` hashed-to-classify trigger.
5. Realtime policies on `realtime.messages` (5.3).
6. Rebuilt from their latest bodies with changes marked "Migration 58": `enqueue_notification` (51), `claim_pending_notifications` (56), `unread_notification_count` (18), `report_content`, `moderation_is_own`, `mod_queue` (54), `mod_moderate`, `moderation_set_state`, `block_user` (51), `image_clear_references` (52), `request_account_deletion` (53); new enum values `message`, `message_request`; the `reports` and `moderation_actions` kind constraints with `message`.
7. pg_cron `purge-messaging` daily (unscheduled by name first).
8. `image-guard` gains `classify`, `evidence_copy` and `evidence_url` ops (no-op `skipped: no key` without the Sightengine secrets); `delete-account` removes `chat-images/<uid>/`.

Tests: `supabase/tests/messaging.sql` and `supabase/tests/messaging_safety.sql` (added to `regression.txt`), each one transaction ending in `ROLLBACK`, `set local role authenticated` and `request.jwt.claims` per actor, pass/fail only: shared-context DM opens; no context gives a request; a 23-hour account cannot request; no photo cannot send; a request refuses a second message, an image and a link; decline then re-request is `request_cooldown`; a block closes the DM and hides each side's messages in an event chat; a non-member reads nothing (table, RPC and `realtime.messages` policy with `realtime.topic` set); a removed RSVP loses the event chat; a sensitive hub has no chat; idempotent `client_id`; keyset pages have no gaps or repeats; rate limit and slow mode; `message_filtered` and shortener refusal; `images_disabled` while off; mute and quiet hours on the queued notification; message notifications not in `unread_notification_count`; report writes evidence with context; moderator remove and the second-moderator rule; account deletion anonymizes and keeps evidence. Then regenerate `packages/core/src/types/database.ts` from the staging run.

### Slice 1 as built (2026-11-05)

Migration 58 is `supabase/migrations/20261222000100_messaging.sql` (`meta.schema_version` 2.54); checks are `supabase/tests/messaging.sql` and `supabase/tests/messaging_safety.sql` (both in `regression.txt`). Where the build differs from the sections above, the build is right and this list is the record:

- **Filter refusals are returned, not raised.** `send_message` answers `{error: 'message_filtered'}` instead of raising, because a raised error rolls back the `chat_filter_strikes` row that the three-in-an-hour cooldown and the automatic report count. Every other error is raised as listed.
- **Error codes added:** `forbidden` from `send_message` and `chat_can_post` when the caller is not a member; `not_found` for an unknown conversation; `request_text_only` for an image in a message request (with images on; while off, `images_disabled` comes first); `client_id_required`; `invalid_title` and `too_few_members` for groups (a group needs at least two people the creator can add). A hub member whose membership is under 24 hours gets `account_too_new` (section 2.1's 24-hour hub rule).
- **The decline stays silent in the table too.** `message_requests` grants `authenticated` only `conversation_id, from_user, to_user, created_at`; `status` and `decided_at` are read through `chat_list` (`request: sent | received`), so a requester cannot select the decline.
- **The one-message rule** counts the requester's messages since the request's `created_at` (a request renewed after the 30-day cooldown allows one more).
- **Shared context** leaves out imported plans (a large imported listing would make strangers "share a plan"). **Chapter chats** in a sensitive hub are `chat_unavailable`, like hub chats (chapter membership is hidden there too).
- **Message batching:** `enqueue_notification` gets a `message` branch: on a dedupe hit `payload.count` counts messages (not distinct senders), `payload.seq` takes the newest seq and the row is unread again. Chat notices are queued without `event_id`, so the push opens `/chats/<id>` (send-notifications `pathFor`) and the plan-staleness check does not apply. The email channel is `skipped` at queueing and again at claim.
- **`mark_notifications_read`** (migration 18) is rebuilt too: "mark all read" in the inbox leaves `message` and `message_request` alone, so it does not silently stop pushes the chat has not shown; the inbox query (`apps/app/src/lib/notifications.ts`) leaves them out.
- **Realtime policies** are created only where `realtime.messages` exists (the CLI rehearsal starts without Realtime). The SQL test checks the policies with `realtime.topic` set (member reads `conv:<id>` and their own `user:<id>:chats`, a non-member reads and sends nothing). That a non-private subscriber receives nothing is Realtime server behaviour and is checked by hand in slice 2.
- **`mod_queue`** labels message reports "Message"; `mod_report_queue` (the older queue) is unchanged and shows no label for them. `moderation_is_own` also covers a message in a dm or group the moderator is in.
- **Deferred to the images work** (chat images stay `off` until then): image-guard's `classify`, `evidence_copy` and `evidence_url` operations (the database already dispatches `classify` and records verdicts through `chat_image_classified`; until the function knows `classify`, an image stays `classifying` and is never shown), `image_evidence_path` (null until `evidence_copy` exists), the monthly classifier cap counter, and the purge of abandoned uploads (it needs the Storage API, so it belongs in image-guard's sweep).

### Slice 2: client

`packages/core/src/messaging/` with unit tests; `apps/app/src/lib/messaging.ts`; the routes in 14.1; the badge on `ChatsButton` and its placement on every top-level top bar; entry points on plan, hub, chapter pages and the profile card; People you've met on the You tab; the image composer behind `images_enabled`; copy pass. Done when `pnpm typecheck`, `lint`, `test` and `build` pass and the slice 1 test file passes on staging.

## 16. Open items for Sai

- Add the Sightengine secrets to staging and production when chat images should turn on, then set `meta.chat_images` to `on` (FOUNDER-TODO). Without them, chats are text only, and the app says "Photos in chats are coming soon".
- The Privacy Policy and the Play Data safety form gain the message retention lines in sections 12 and 13.
