-- ============================================================================
-- Activity Planet schema v2 — migration 59: messaging review fixes
--   (D-043, docs/design/messaging/MESSAGING_DESIGN.md). Builds on migration
--   58 (20261222000100_messaging.sql) and migration 57
--   (20261221000100_feed_distance.sql), which reached staging and are not
--   edited. Every rebuilt function starts from its latest body and each
--   change is marked "Migration 59". Checks:
--   supabase/tests/messaging_review_fixes.sql.
--
--   1. private.chat_has_link: www. counts after any character but a letter,
--      digit, "@" or "_" (before, "-www.x.dev" and ".www.x.dev" were not
--      links to the server while the bubble linked them). The bubble now
--      links only text the same rule calls a link (packages/core text.ts).
--   2. conversation_members: the other people in a dm or group read only
--      conversation_id, user_id, role, joined_at, left_at and removed_at.
--      Mute, notify, read state and removed_by are no longer granted (each
--      person reads their own through conversation_info and chat_list).
--   3. Typing: clients no longer send on conv:<id> (the chat_topics_typing
--      insert policy is dropped). public.chat_typing(conversation) sends
--      {user_id} for the caller from the database, dm and group only, for
--      people who can post, at most once every 2 seconds, so nobody can
--      show "X is typing" for someone else.
--   4. start_dm: a requester who left a pending request is put back in it
--      (left_at cleared), so the conversation id it returns is readable.
--   5. send_message: an advisory lock per (author, client id) before the
--      duplicate check, so a retry that overlaps the first call returns the
--      stored row (duplicate true) instead of failing on messages_client_uq;
--      the message_request notification key carries the request's time, so a
--      new request after a decline is notified again.
--   6. chat_list and people_you_met take p_before_id (keyset on time and
--      id; rows with the same time are no longer skipped). The old
--      signatures are dropped. chat_unread_total pages through chat_list
--      (up to 5,000 chats) instead of reading the newest 100.
--   7. feed_event_area (migration 57 body): needs an onboarded adult
--      (viewer_is_adult) and a known age, as can_read_event does; before, an
--      account with no birth date passed an 18+ plan.
--   8. Grants (explicit) and meta.schema_version 2.55.
--
--   Account deletion: no new table or column. Typing signals are
--   realtime.messages rows holding a user id, like migration 58's signals;
--   Realtime drops them with its daily partitions.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Links
-- ---------------------------------------------------------------------------
-- A link: a scheme, www., or a bare label.tld. Email addresses and phone numbers are not links.
create or replace function private.chat_has_link(p_text text)
returns boolean language sql immutable set search_path = '' as $$
  select private.chat_match_text(p_text) ~
    '(https?://|(^|[^a-z0-9@_])www\.|(^|[^a-z0-9@._-])([a-z0-9-]+\.)+(com|net|org|app|xyz|info|biz|link|site|online|[a-z]{2})([^a-z0-9-]|$))';
$$;

-- ---------------------------------------------------------------------------
-- 2. conversation_members: what other members may read
-- ---------------------------------------------------------------------------
-- Revoking the table privilege also takes away any column privileges; the
-- column list is granted after it.
revoke select on public.conversation_members from authenticated;
grant select (conversation_id, user_id, role, joined_at, left_at, removed_at)
  on public.conversation_members to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Typing from the database
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('realtime.messages') is null then
    raise notice 'realtime.messages is missing; typing policy not dropped';
    return;
  end if;
  execute 'drop policy if exists "chat_topics_typing" on realtime.messages';
end $$;

create or replace function public.chat_typing(p_conversation uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  c   public.conversations%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  -- Silent for anything else: typing is best effort and says nothing about a room.
  select * into c from public.conversations where id = p_conversation;
  if not found or c.kind not in ('dm', 'group') or private.chat_can_post(c.id) is not null then
    return;
  end if;
  if to_regprocedure('realtime.send(jsonb,text,text,boolean)') is null then
    return;
  end if;
  -- At most one signal every 2 seconds per person and room.
  begin
    if exists (select 1 from realtime.messages m
                where m.topic = 'conv:' || c.id::text and m.event = 'typing'
                  and m.inserted_at > localtimestamp - interval '2 seconds'
                  and m.payload ->> 'user_id' = uid::text) then
      return;
    end if;
  exception when others then
    null;
  end;
  begin
    perform realtime.send(jsonb_build_object('user_id', uid), 'typing', 'conv:' || c.id::text, true);
  exception when others then
    raise warning 'chat_typing: %', sqlerrm;
  end;
end $$;
comment on function public.chat_typing(uuid) is
  'Migration 59: sends typing {user_id} for the caller on conv:<id> (dm and group, people who can post, at most once every 2 seconds). Clients cannot send on conv: topics themselves, so a typing line always names the person typing. Silent when the caller cannot post. Errors: not_authenticated.';

-- ---------------------------------------------------------------------------
-- 4. start_dm (migration 58 body)
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
        -- Migration 59: a requester who left their pending request is put back
        -- in it (read only until a reply), so the id returned is readable.
        update public.conversation_members set left_at = null
         where conversation_id = c.id and user_id = uid and left_at is not null;
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
  'Migration 58 (59: a requester who left a pending request is put back in it): opens (or finds) the DM with p_user. With shared context (private.chat_shared_context) state open; without, a message request (state request; request_pending while one is waiting). Errors: not_authenticated, onboarding_required, cannot_message_self, user_not_found (also a blocked pair, a banned or hidden profile), photo_required, account_too_new (requests need 24 hours), rate_limited (10 requests a day), request_cooldown (30 days after a decline).';

-- ---------------------------------------------------------------------------
-- 5. send_message (migration 58 body)
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
  -- Migration 59: one call per client id at a time. A retry that overlaps
  -- the first call waits here, then finds its row below (before, it waited
  -- on the conversation row and failed on messages_client_uq).
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('chat_client:' || uid::text || ':' || p_client_id::text));
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
    -- Migration 59: the request's time is in the key, so a new request after
    -- a decline (start_dm resets created_at) is notified again.
    perform public.enqueue_notification(v_user, 'message_request',
                                        'message_request:' || c.id || ':' || v_user || ':'
                                          || floor(extract(epoch from r.created_at))::bigint::text,
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
  'Migration 58: posts a message. p_client_id makes it idempotent (a retry returns the same row with duplicate true, free of limits; migration 59: also when the retry overlaps the first call). Returns {id, seq, created_at, duplicate}, or {error: message_filtered} when the filter refuses it (not raised, so the refusal counts toward the cooldown). Errors: not_authenticated, client_id_required, not_found, forbidden, onboarding_required, photo_required, conversation_closed, read_only, request_pending, account_too_new, body_length (1 to 2000), images_disabled, request_text_only, image_invalid, image_blocked, link_not_allowed (requests, accounts under a day, shorteners), rate_limited and slow_mode (hint: seconds to wait).';

-- ---------------------------------------------------------------------------
-- 6. Paging: chat_list, chat_unread_total, people_you_met
-- ---------------------------------------------------------------------------
drop function if exists public.chat_list(text, timestamptz, integer);
create or replace function public.chat_list(p_tab text default 'chats', p_before timestamptz default null,
                                            p_limit integer default 30, p_before_id uuid default null)
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
       -- Migration 59: (activity_at, id) keyset, so rows with the same time are not skipped.
       and (p_before is null or coalesce(c.last_message_at, c.created_at) < p_before
            or (p_before_id is not null and coalesce(c.last_message_at, c.created_at) = p_before
                and c.id > p_before_id))
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
comment on function public.chat_list(text, timestamptz, integer, uuid) is
  'Migration 58: the caller''s chats, newest activity first (p_before is the activity_at cursor and, migration 59, p_before_id the conversation_id of the last row held, for rows with the same activity_at; p_limit up to 100). Tab chats: dms (not pending or declined requests to the caller), groups, event chats until 30 days after the plan, hub and chapter chats that exist. Tab requests: pending requests to the caller that carry their message. Each row: conversation_id, kind, title, other (dm), context, last_message {preview, at, mine, kind}, unread (capped at 99), muted, closed, request (sent | received | null), activity_at. Never a blocked person''s dm or message; hidden or deleted messages preview as a neutral line.';

create or replace function public.chat_unread_total()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_chats     integer := 0;
  v_requests  integer := 0;
  v_tab       text;
  v_before    timestamptz;
  v_before_id uuid;
  v_rows      integer;
  v_pages     integer;
  l           record;
begin
  -- Migration 59: every chat, a page of 100 at a time (at most 50 pages),
  -- instead of the newest 100.
  foreach v_tab in array array['chats', 'requests'] loop
    v_before := null;
    v_before_id := null;
    v_pages := 0;
    loop
      v_rows := 0;
      for l in select * from public.chat_list(v_tab, v_before, 100, v_before_id) loop
        v_rows := v_rows + 1;
        v_before := l.activity_at;
        v_before_id := l.conversation_id;
        if v_tab = 'requests' then
          v_requests := v_requests + 1;
        elsif l.unread > 0 and not l.muted
              and (l.kind in ('dm', 'group')
                   or (l.kind = 'event' and (l.context ->> 'ends_at')::timestamptz > now() - interval '7 days')) then
          v_chats := v_chats + 1;
        end if;
      end loop;
      v_pages := v_pages + 1;
      exit when v_rows < 100 or v_pages >= 50;
    end loop;
  end loop;
  return jsonb_build_object('chats', v_chats, 'requests', v_requests);
end $$;
comment on function public.chat_unread_total() is
  'Migration 58: {chats, requests} for the Chats badge: dms, groups and event chats of upcoming or recent plans with unread messages and not muted; pending requests to the caller. Migration 59: counts every chat (paged through chat_list, up to 5,000), not only the newest 100.';

drop function if exists public.people_you_met(timestamptz, integer);
create or replace function public.people_you_met(p_before timestamptz default null, p_limit integer default 30,
                                                 p_before_id uuid default null)
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
     -- Migration 59: (starts_at, user_id) keyset; everyone from one plan shares starts_at.
     and (p_before is null or l.starts_at < p_before
          or (p_before_id is not null and l.starts_at = p_before and p.id > p_before_id))
   order by l.starts_at desc, p.id
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;
comment on function public.people_you_met(timestamptz, integer, uuid) is
  'Migration 58: people the caller met (mutual "who did you meet" picks, or both checked in at the same plan) in the last 365 days, newest shared plan first (p_before is the starts_at cursor and, migration 59, p_before_id the user_id of the last row held): user_id, handle, first_name, avatar_url, last_plan {id, title, starts_at}, can_message. Never across a block, never banned, hidden or deleted profiles; one-sided picks stay private.';

-- ---------------------------------------------------------------------------
-- 7. feed_event_area (migration 57 body)
-- ---------------------------------------------------------------------------
create or replace function public.feed_event_area(p_event_id uuid)
returns extensions.geography language sql stable security definer set search_path = '' as $$
  select coalesce(
           ca.center,
           cc.location,
           ec.location,
           ha.center,
           case when pp.home_point is not null then
             extensions.ST_SetSRID(extensions.ST_MakePoint(
               round(extensions.ST_X(pp.home_point::extensions.geometry)::numeric, 1)::double precision,
               round(extensions.ST_Y(pp.home_point::extensions.geometry)::numeric, 1)::double precision), 4326)::extensions.geography
           end)
    from public.events e
    left join public.hub_chapters ch on ch.id = e.chapter_id
    left join public.areas ca on ca.id = ch.area_id
    left join public.org_campuses cc on cc.id = ch.campus_id
    left join public.org_campuses ec on ec.id = e.campus_id
    left join public.profiles hp on hp.id = e.host_id and hp.deleted_at is null
    left join public.profile_private pp on pp.user_id = hp.id
    left join public.areas ha on ha.id = pp.home_area_id
   where (select auth.uid()) is not null
     and public.viewer_is_adult()              -- Migration 59
     and e.id = p_event_id
     and e.approx_point is null
     and e.kind <> 'imported'
     and e.status = 'published'
     and e.moderation_state is null
     and e.min_age <= (select public.viewer_age())   -- Migration 59: no age, no area
     and (e.visibility = 'public' or public.is_campus_org_member(e.campus_id));
$$;
comment on function public.feed_event_area(uuid) is
  'Migration 57 (D-040): where a published plan with no point stands, for feed_events_v2''s distance check. Its chapter''s area centre, else the chapter''s campus, else its campus, else the host''s home area centre, else the host''s home point rounded to 0.1 degree (about 11 km). Null for imported rows, rows with a point, unpublished or moderated rows, rows over the caller''s age, campus-only rows outside the caller''s campus, and signed-out callers (migration 59: and callers who are not an onboarded adult, as can_read_event).';

-- ---------------------------------------------------------------------------
-- 8. Privileges (explicit) and version stamp (last)
-- ---------------------------------------------------------------------------
revoke all on function private.chat_has_link(text) from public, anon, authenticated;
grant execute on function private.chat_has_link(text) to service_role;
revoke all on function public.chat_typing(uuid) from public, anon;
grant execute on function public.chat_typing(uuid) to authenticated;
revoke all on function public.start_dm(uuid) from public, anon;
grant execute on function public.start_dm(uuid) to authenticated;
revoke all on function public.send_message(uuid, uuid, text, text) from public, anon;
grant execute on function public.send_message(uuid, uuid, text, text) to authenticated;
revoke all on function public.chat_list(text, timestamptz, integer, uuid) from public, anon;
grant execute on function public.chat_list(text, timestamptz, integer, uuid) to authenticated;
revoke all on function public.chat_unread_total() from public, anon;
grant execute on function public.chat_unread_total() to authenticated;
revoke all on function public.people_you_met(timestamptz, integer, uuid) from public, anon;
grant execute on function public.people_you_met(timestamptz, integer, uuid) to authenticated;
revoke all on function public.feed_event_area(uuid) from public, anon;
grant execute on function public.feed_event_area(uuid) to authenticated;

insert into public.meta (key, value) values ('schema_version', '2.55')
  on conflict (key) do update set value = excluded.value, updated_at = now();
