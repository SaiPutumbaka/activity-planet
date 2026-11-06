-- ============================================================================
-- Activity Planet schema v2 — migration 72: chat photo evidence and storage
-- clean-up.
--   Builds on migrations 1 to 71, which reached staging and are not edited.
--
--   The rest of chat images' storage side (MESSAGING_DESIGN.md sections 10,
--   12 and 13; slice 1's "deferred to the images work" list), done through
--   image-guard's sweep, which now runs these before it deletes anything:
--
--     1. chat_image_evidence_list and chat_image_evidence_saved (service
--        role): a reported chat photo is copied into the private
--        chat-evidence bucket as <report id>.jpg and the path is stored in
--        message_report_evidence.image_evidence_path (mod_message_evidence
--        already returns it), so the evidence outlives the original (deleted
--        by its sender, a host, a block or account deletion). Moderators may
--        read chat-evidence objects (policy chat_evidence_select_mod); they
--        learn a path only through mod_message_evidence, which is logged.
--     2. chat_image_purge_list (service role): chat-images objects whose
--        message was deleted (image_state removed; kept while a report's copy
--        is pending), chat uploads never sent after a day, and chat-evidence
--        objects whose evidence record purge_messaging deleted.
--     3. image_guard_tick, rebuilt from its migration 71 body: also asks for
--        a sweep when a copy or a purge waits.
--     4. meta.schema_version 2.68.
--
--   meta.chat_images stays 'off'. Account deletion: no new table; the
--   delete-account function already removes chat-images/<uid>/, and the
--   evidence copies follow message_report_evidence's retention (section 12).
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Evidence copies
-- ---------------------------------------------------------------------------
create or replace function public.chat_image_evidence_list(p_limit integer default 25)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('report_id', q.report_id, 'path', q.path)), '[]'::jsonb)
    from (select ev.report_id, m.image_path as path
            from public.message_report_evidence ev
            join public.messages m on m.id = ev.message_id
           where m.kind = 'image' and m.image_path is not null and ev.image_evidence_path is null
             and ev.created_at > now() - interval '30 days'
             and exists (select 1 from storage.objects o where o.bucket_id = 'chat-images' and o.name = m.image_path)
           order by ev.created_at
           limit greatest(1, least(coalesce(p_limit, 25), 100))) q;
$$;
comment on function public.chat_image_evidence_list(integer) is
  'Migration 72, service role (image-guard sweep): reported chat photos (message_report_evidence of an image message, last 30 days) whose evidence copy is not made yet and whose original still exists: [{report_id, path}].';
revoke all on function public.chat_image_evidence_list(integer) from public, anon, authenticated;
grant execute on function public.chat_image_evidence_list(integer) to service_role;

create or replace function public.chat_image_evidence_saved(p_report uuid, p_path text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if p_report is null or p_path is null or p_path <> p_report::text || '.jpg' then
    return false;
  end if;
  update public.message_report_evidence set image_evidence_path = p_path
   where report_id = p_report and image_evidence_path is null;
  return found;
end $$;
comment on function public.chat_image_evidence_saved(uuid, text) is
  'Migration 72, service role (image-guard sweep): records the chat-evidence copy (<report id>.jpg) of a reported chat photo. Anything else is ignored (false).';
revoke all on function public.chat_image_evidence_saved(uuid, text) from public, anon, authenticated;
grant execute on function public.chat_image_evidence_saved(uuid, text) to service_role;

do $$
begin
  if to_regclass('storage.objects') is null then
    raise notice 'storage is missing; chat_evidence_select_mod not created';
    return;
  end if;
  execute 'drop policy if exists "chat_evidence_select_mod" on storage.objects';
  execute $p$
    create policy "chat_evidence_select_mod" on storage.objects for select to authenticated
      using (bucket_id = 'chat-evidence' and (select public.is_moderator()))
  $p$;
end $$;

-- ---------------------------------------------------------------------------
-- 2. What the sweep deletes besides blocked objects
-- ---------------------------------------------------------------------------
create or replace function public.chat_image_purge_list(p_limit integer default 50)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('bucket', q.bucket, 'path', q.path)), '[]'::jsonb)
    from (
      select x.bucket, x.path from (
        -- Deleted by the sender or a host (or anonymized by account deletion), unless a
        -- report's copy is still to be made.
        select 'chat-images'::text as bucket, o.name as path, o.created_at
          from storage.objects o
         where o.bucket_id = 'chat-images'
           and exists (select 1 from public.messages m where m.image_path = o.name and m.image_state = 'removed')
           and not exists (select 1 from public.message_report_evidence ev
                             join public.messages m on m.id = ev.message_id
                            where m.image_path = o.name and ev.image_evidence_path is null
                              and ev.created_at > now() - interval '30 days')
        union all
        -- Uploaded and never sent.
        select 'chat-images', o.name, o.created_at
          from storage.objects o
         where o.bucket_id = 'chat-images' and o.created_at < now() - interval '1 day'
           and not exists (select 1 from public.messages m where m.image_path = o.name)
        union all
        -- Evidence copies whose record is gone (purge_messaging, past retain_until).
        select 'chat-evidence', o.name, o.created_at
          from storage.objects o
         where o.bucket_id = 'chat-evidence' and o.created_at < now() - interval '1 day'
           and not exists (select 1 from public.message_report_evidence ev where ev.image_evidence_path = o.name)
      ) x
      order by x.created_at
      limit greatest(1, least(coalesce(p_limit, 50), 200))) q;
$$;
comment on function public.chat_image_purge_list(integer) is
  'Migration 72, service role (image-guard sweep): chat-images objects of deleted messages (kept while a report''s evidence copy is pending), chat uploads never sent after a day, and chat-evidence objects whose evidence record is gone: [{bucket, path}]. The sweep deletes them through the Storage API.';
revoke all on function public.chat_image_purge_list(integer) from public, anon, authenticated;
grant execute on function public.chat_image_purge_list(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 3. image_guard_tick (migration 71 body)
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
                      where h.status in ('blocked', 'unreadable') and h.purged_at is null)
             -- Migration 72: evidence copies and chat clean-up run in the sweep too.
             or jsonb_array_length(public.chat_image_evidence_list(1)) > 0
             or jsonb_array_length(public.chat_image_purge_list(1)) > 0;
  if v_sweep then
    perform public.image_guard_dispatch(jsonb_build_object('op', 'sweep'));
  end if;
  return jsonb_build_object('checks', v_sent, 'sweep', v_sweep, 'classify', v_class, 'classify_queued', v_stale);
end $$;
comment on function public.image_guard_tick() is
  'Migration 52 (71, 72), pg_cron image-guard-tick every 10 minutes: re-sends pending checks (5 tries), re-sends classify for chat images left classifying 10 to 60 minutes and queues older ones for a moderator, and asks for a sweep when objects wait for deletion, a reported chat photo waits for its evidence copy, or chat storage waits for clean-up.';
revoke all on function public.image_guard_tick() from public, anon, authenticated;
grant execute on function public.image_guard_tick() to service_role;

-- ---------------------------------------------------------------------------
-- 4. Version
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.68')
  on conflict (key) do update set value = excluded.value, updated_at = now();
