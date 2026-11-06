-- ============================================================================
-- Activity Planet schema v2 — migration 71: the chat-image classifier step.
--   Builds on migrations 1 to 70, which reached staging and are not edited.
--
--   Design: docs/design/messaging/MESSAGING_DESIGN.md section 10 (D-043),
--   TRUST-SAFETY-LEGAL section 7. Migration 58 already dispatches image-guard
--   {op: classify} once a chat image's pHash check passes and records verdicts
--   through chat_image_classified; the function now knows the op
--   (supabase/functions/image-guard/classify.ts, Sightengine's free plan, only
--   when SIGHTENGINE_API_USER and SIGHTENGINE_API_SECRET are set). This adds:
--
--     1. chat_classifier_reserve and chat_classifier_settle (service role):
--        the monthly cap. Sightengine counts one operation per model per
--        image; image-guard reserves its operations before each call in a
--        collector_budget row (day = the first of the UTC month, source
--        sightengine_ops, no user id) under meta.chat_classifier_monthly_cap
--        (1,800 by migration 58, below the free plan's 2,000 a month), and
--        settles with what Sightengine reported. Past the cap the image is
--        queued for a moderator, never shown unchecked. The reservation also
--        answers whether anything waits (a pending or classifying message
--        whose object is hashed), so a repeated request spends nothing.
--     2. chat_image_classified, rebuilt from its migration 58 body: visible
--        only when the object's pHash check passed (image_hashes hashed), so a
--        photo is shown only after both checks; nothing happens when no
--        message was waiting (a repeated verdict files no second report); the
--        automatic report takes the classifier's category (sexual_content,
--        violence, hate, else other) and a note saying why (unsure, monthly
--        allowance used, classifier error); a block is logged as image_remove
--        with the rounded scores (numbers only, never the image).
--     3. Moderators decide queued photos: mod_chat_image_queue (the photos
--        waiting) and mod_chat_image(message, allow | block, note): allow
--        shows the photo and dismisses the automatic reports; block hides it
--        for good, closes the reports and queues the object for deletion. The
--        second-moderator rule holds (moderation_is_own). A storage policy
--        lets moderators read a queued photo (signed URLs in the admin queue).
--     4. image_guard_tick, rebuilt from its migration 52 body: also re-sends
--        classify for a chat image left classifying 10 to 60 minutes (no
--        answer), and queues one left longer for a moderator.
--     5. meta.schema_version 2.67.
--
--   meta.chat_images stays 'off': chat images are refused until Sai adds the
--   Sightengine secrets and asks for it to be turned on (FOUNDER-TODO 10).
--   Account deletion: no new table; collector_budget holds no user id, and
--   moderation_actions rows already follow migration 51's deletion rules.
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The monthly cap
-- ---------------------------------------------------------------------------
create or replace function private.chat_classifier_cap()
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce((select case when m.value ~ '^[0-9]{1,9}$' then m.value::integer end
                     from public.meta m where m.key = 'chat_classifier_monthly_cap'), 1800);
$$;
revoke all on function private.chat_classifier_cap() from public, anon, authenticated;

create or replace function public.chat_classifier_reserve(p_path text, p_operations integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_month   date := date_trunc('month', now() at time zone 'utc')::date;
  v_cap     integer := private.chat_classifier_cap();
  v_n       integer := greatest(1, least(coalesce(p_operations, 1), 50));
  v_used    integer;
  v_pending boolean;
begin
  v_pending := p_path is not null
    and exists (select 1 from public.messages m
                 where m.image_path = p_path and m.image_state in ('pending', 'classifying'))
    and exists (select 1 from public.image_hashes h
                 where h.bucket = 'chat-images' and h.path = p_path and h.status = 'hashed');
  if not v_pending then
    return jsonb_build_object('pending', false, 'allowed', false, 'cap', v_cap);
  end if;
  insert into public.collector_budget (day, source, used) values (v_month, 'sightengine_ops', 0)
    on conflict (day, source) do nothing;
  update public.collector_budget set used = used + v_n
   where day = v_month and source = 'sightengine_ops' and used + v_n <= v_cap
  returning used into v_used;
  if not found then
    select b.used into v_used from public.collector_budget b
     where b.day = v_month and b.source = 'sightengine_ops';
    return jsonb_build_object('pending', true, 'allowed', false, 'used', v_used, 'cap', v_cap);
  end if;
  return jsonb_build_object('pending', true, 'allowed', true, 'used', v_used, 'cap', v_cap);
end $$;
comment on function public.chat_classifier_reserve(text, integer) is
  'Migration 71, service role (image-guard classify): whether a chat image waits for a verdict (a pending or classifying message, its object hashed) and, if so, reserves p_operations Sightengine operations under meta.chat_classifier_monthly_cap in collector_budget (day = first of the UTC month, source sightengine_ops). Returns {pending, allowed, used, cap}; allowed false past the cap.';
revoke all on function public.chat_classifier_reserve(text, integer) from public, anon, authenticated;
grant execute on function public.chat_classifier_reserve(text, integer) to service_role;

create or replace function public.chat_classifier_settle(p_reserved integer, p_used integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_month date := date_trunc('month', now() at time zone 'utc')::date;
  v_used  integer;
begin
  update public.collector_budget
     set used = greatest(0, used + greatest(0, least(coalesce(p_used, 0), 50))
                              - greatest(0, least(coalesce(p_reserved, 0), 50)))
   where day = v_month and source = 'sightengine_ops'
  returning used into v_used;
  return coalesce(v_used, 0);
end $$;
comment on function public.chat_classifier_settle(integer, integer) is
  'Migration 71, service role (image-guard classify): corrects this month''s sightengine_ops count from the operations reserved to the operations Sightengine reported (0 for a refused or failed call). Returns the month''s count.';
revoke all on function public.chat_classifier_settle(integer, integer) from public, anon, authenticated;
grant execute on function public.chat_classifier_settle(integer, integer) to service_role;

-- ---------------------------------------------------------------------------
-- 2. chat_image_classified (migration 58 body)
-- ---------------------------------------------------------------------------
create or replace function public.chat_image_classified(p_bucket text, p_path text, p_verdict text,
                                                        p_scores jsonb default '{}'::jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_n        integer;
  v_m        record;
  v_reason   text := coalesce(p_scores ->> 'reason', 'classified');   -- Migration 71
  v_category text;
  v_hash     uuid;
  v_owner    uuid;
  v_scores   jsonb;
begin
  if p_bucket is distinct from 'chat-images' or p_path is null then
    raise exception 'invalid_object' using errcode = '22023';
  end if;
  if p_verdict is null or p_verdict not in ('visible', 'queued', 'blocked') then
    raise exception 'invalid_verdict' using errcode = '22023';
  end if;
  -- Migration 71: shown only after both checks, so a pass needs a passed pHash check.
  if p_verdict = 'visible' and not exists (select 1 from public.image_hashes h
                                            where h.bucket = p_bucket and h.path = p_path and h.status = 'hashed') then
    return 0;
  end if;
  update public.messages set image_state = p_verdict
   where image_path = p_path and image_state in ('pending', 'classifying');
  get diagnostics v_n = row_count;
  -- Migration 71: nothing was waiting (a repeated verdict): no second report or log.
  if v_n = 0 then
    return 0;
  end if;
  -- Migration 71: numbers only.
  select coalesce(jsonb_object_agg(s.key, s.value), '{}'::jsonb) into v_scores
    from jsonb_each(coalesce(p_scores, '{}'::jsonb)) s
   where s.key in ('sexual', 'gore', 'hate', 'weapon') and jsonb_typeof(s.value) = 'number';
  if p_verdict = 'queued' then
    v_category := case when p_scores ->> 'category' in ('sexual_content', 'violence', 'hate')
                       then p_scores ->> 'category' else 'other' end;
    for v_m in select m.id, m.author_id from public.messages m
                where m.image_path = p_path and m.image_state = 'queued' loop
      insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, note)
      values (null, 'message', v_m.id, v_m.author_id, v_category,
              case v_reason
                when 'cap' then 'Automatic: the monthly image-check allowance is used up; check this photo.'
                when 'classifier_error' then 'Automatic: the image classifier did not answer; check this photo.'
                else 'Automatic: the image classifier was unsure.' end);
    end loop;
  elsif p_verdict = 'blocked' then
    update public.image_hashes set status = 'blocked', blocked_at = coalesce(blocked_at, now())
     where bucket = p_bucket and path = p_path and status <> 'blocked'
    returning id, owner_id into v_hash, v_owner;
    if v_hash is not null then
      insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note, snapshot)
      values (null, 'image_remove', 'image', v_hash, v_owner,
              'chat image blocked by the classifier: ' || left(v_reason, 40)
                || coalesce('; ' || left(p_scores ->> 'category', 40), ''),
              v_scores);
    end if;
  end if;
  return v_n;
end $$;
comment on function public.chat_image_classified(text, text, text, jsonb) is
  'Migration 58 (71), service role (image-guard): records the classifier verdict for a chat image waiting in pending or classifying: visible (shown; only once its pHash check passed), queued (hidden, an open report with no reporter for a moderator, reason from p_scores.category, note from p_scores.reason: cap, classifier_error or unsure) or blocked (never shown; the object is queued for deletion and the block logged with the rounded scores). Only the verdict and numbers are stored. Returns the messages changed (0 when none waited).';
revoke all on function public.chat_image_classified(text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.chat_image_classified(text, text, text, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Moderators decide queued photos
-- ---------------------------------------------------------------------------
create or replace function private.chat_image_moderatable(p_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_moderator()
     and exists (select 1 from public.messages m where m.image_path = p_path and m.image_state = 'queued');
$$;
revoke all on function private.chat_image_moderatable(text) from public, anon;
grant execute on function private.chat_image_moderatable(text) to authenticated;

do $$
begin
  if to_regclass('storage.objects') is null then
    raise notice 'storage is missing; chat_images_select_mod not created';
    return;
  end if;
  execute 'drop policy if exists "chat_images_select_mod" on storage.objects';
  execute $p$
    create policy "chat_images_select_mod" on storage.objects for select to authenticated
      using (bucket_id = 'chat-images' and private.chat_image_moderatable(name))
  $p$;
end $$;

create or replace function public.mod_chat_image_queue(p_limit integer default 50)
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
    select jsonb_agg(q.item order by q.created_at)
      from (select m.created_at,
                   jsonb_build_object(
                     'message_id', m.id,
                     'image_path', m.image_path,
                     'conversation_kind', c.kind,
                     'created_at', m.created_at,
                     'author', case when p.id is null then null
                                    else jsonb_build_object('id', p.id, 'first_name', p.first_name) end,
                     'reason', (select r.reason from public.reports r
                                 where r.target_kind = 'message' and r.target_id = m.id and r.status = 'open'
                                 order by r.created_at limit 1),
                     'note', (select r.note from public.reports r
                               where r.target_kind = 'message' and r.target_id = m.id and r.status = 'open'
                                 and r.reporter_id is null
                               order by r.created_at limit 1),
                     'own', public.moderation_is_own('message', m.id, m.author_id)) as item
              from public.messages m
              join public.conversations c on c.id = m.conversation_id
              left join public.profiles p on p.id = m.author_id
             where m.image_state = 'queued' and m.deleted_at is null and m.moderation_state is null
             order by m.created_at
             limit greatest(1, least(coalesce(p_limit, 50), 200))) q), '[]'::jsonb);
end $$;
comment on function public.mod_chat_image_queue(integer) is
  'Migration 71, moderators: chat photos the classifier queued (hidden until decided), oldest first: [{message_id, image_path, conversation_kind, created_at, author {id, first_name}, reason, note, own}]. The photo is read with a signed URL (storage policy chat_images_select_mod). Errors: not_authenticated, forbidden.';
revoke all on function public.mod_chat_image_queue(integer) from public, anon;
grant execute on function public.mod_chat_image_queue(integer) to authenticated;

create or replace function public.mod_chat_image(p_message uuid, p_decision text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_note  text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  m       public.messages%rowtype;
  v_ids   uuid[];
  v_n     integer;
  v_open  integer;
  v_hash  uuid;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_decision is null or p_decision not in ('allow', 'block') then
    raise exception 'invalid_action' using errcode = 'check_violation';
  end if;
  select * into m from public.messages where id = p_message for update;
  if not found or m.kind <> 'image' or m.image_path is null then
    raise exception 'target_not_found' using errcode = 'PT404';
  end if;
  if m.image_state is distinct from 'queued' then
    raise exception 'item_not_pending' using errcode = 'check_violation';
  end if;
  if public.moderation_is_own('message', m.id, m.author_id) then
    raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews this one.';
  end if;

  if p_decision = 'allow' then
    update public.messages set image_state = 'visible'
     where image_path = m.image_path and image_state = 'queued';
    get diagnostics v_n = row_count;
    select coalesce(array_agg(x.id), '{}') into v_ids from public.messages x where x.image_path = m.image_path;
    -- The automatic reports were the classifier's doubt; reports people filed stay open.
    update public.reports set status = 'dismissed', resolved_by = uid, resolved_at = now()
     where target_kind = 'message' and target_id = any(v_ids) and status = 'open' and reporter_id is null;
    get diagnostics v_open = row_count;
  else
    update public.messages set image_state = 'blocked'
     where image_path = m.image_path and image_state in ('pending', 'classifying', 'queued');
    get diagnostics v_n = row_count;
    select coalesce(array_agg(x.id), '{}') into v_ids from public.messages x where x.image_path = m.image_path;
    update public.reports set status = 'actioned', resolved_by = uid, resolved_at = now()
     where target_kind = 'message' and target_id = any(v_ids) and status = 'open';
    get diagnostics v_open = row_count;
    update public.image_hashes set status = 'blocked', blocked_at = coalesce(blocked_at, now())
     where bucket = 'chat-images' and path = m.image_path and status <> 'blocked'
    returning id into v_hash;
  end if;

  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id,
                                         report_count, note)
  values (uid, case when p_decision = 'allow' then 'dismiss' else 'image_remove' end, 'message', m.id,
          m.author_id, v_open, coalesce(v_note, 'chat photo ' || case when p_decision = 'allow' then 'allowed' else 'blocked' end));

  if p_decision = 'block' then
    perform public.image_guard_dispatch(jsonb_build_object('op', 'sweep'));
  end if;
  return jsonb_build_object('state', case when p_decision = 'allow' then 'visible' else 'blocked' end,
                            'messages', v_n, 'reports', v_open);
end $$;
comment on function public.mod_chat_image(uuid, text, text) is
  'Migration 71, moderators: decides a chat photo the classifier queued. allow: visible to the room, its automatic reports dismissed (reports people filed stay open). block: never shown, every open report on it actioned, the object queued for deletion (image-guard sweep). Logged; the second-moderator rule holds. Errors: not_authenticated, forbidden, invalid_action, target_not_found (PT404), item_not_pending, own_item.';
revoke all on function public.mod_chat_image(uuid, text, text) from public, anon;
grant execute on function public.mod_chat_image(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. image_guard_tick (migration 52 body)
-- ---------------------------------------------------------------------------
create or replace function public.image_guard_tick()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_r     record;
  v_sent  integer := 0;
  v_sweep boolean;
  v_class integer := 0;   -- Migration 71
  v_stale integer := 0;   -- Migration 71
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
  -- Migration 71: a chat image whose classify request got no answer is asked again for an
  -- hour, then waits for a moderator (never shown unchecked).
  for v_r in
    select m.image_path, min(m.created_at) as first_at from public.messages m
     where m.image_state = 'classifying' and m.created_at < now() - interval '10 minutes'
     group by m.image_path
     order by min(m.created_at)
     limit 20
  loop
    if v_r.first_at < now() - interval '1 hour' then
      perform public.chat_image_classified('chat-images', v_r.image_path, 'queued',
                                           jsonb_build_object('reason', 'classifier_error', 'category', 'other'));
      v_stale := v_stale + 1;
    elsif public.image_guard_dispatch(jsonb_build_object('op', 'classify', 'bucket', 'chat-images',
                                                         'path', v_r.image_path)) is not null then
      v_class := v_class + 1;
    end if;
  end loop;
  v_sweep := exists (select 1 from public.image_hashes h
                      where h.status in ('blocked', 'unreadable') and h.purged_at is null);
  if v_sweep then
    perform public.image_guard_dispatch(jsonb_build_object('op', 'sweep'));
  end if;
  return jsonb_build_object('checks', v_sent, 'sweep', v_sweep, 'classify', v_class, 'classify_queued', v_stale);
end $$;
comment on function public.image_guard_tick() is
  'Migration 52 (71), pg_cron image-guard-tick every 10 minutes: re-sends pending checks (5 tries), re-sends classify for chat images left classifying 10 to 60 minutes and queues older ones for a moderator, and asks for a sweep when objects wait for deletion.';
revoke all on function public.image_guard_tick() from public, anon, authenticated;
grant execute on function public.image_guard_tick() to service_role;

-- ---------------------------------------------------------------------------
-- 5. Version
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.67')
  on conflict (key) do update set value = excluded.value, updated_at = now();
