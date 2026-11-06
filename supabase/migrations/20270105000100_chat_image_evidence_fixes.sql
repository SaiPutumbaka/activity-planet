-- ============================================================================
-- Activity Planet schema v2 — migration 73: review fixes for chat photo
-- evidence (migration 72) and the classifier cap (migration 71).
--   Builds on migrations 1 to 72, which reached staging and are not edited.
--
--     1. message_report_evidence.image_evidence_missing_at: a reported photo
--        whose original could not be read when its copy was due is marked
--        handled (chat_image_evidence_saved with a null path now records it),
--        so it is not listed again every sweep. chat_image_evidence_list,
--        chat_image_evidence_saved and chat_image_purge_list are rebuilt from
--        their migration 72 bodies for it.
--     2. chat_image_evidence_list_for(user) (service role): every pending
--        copy of one account's photos, for delete-account, which copies them
--        before it deletes the originals (it asked for the 100 oldest of
--        everyone's before).
--     3. image_guard_purge_list, rebuilt from its migration 52 body: a
--        blocked chat photo is not deleted while a report's evidence copy is
--        still to be made (the sweep copies first; the copy then lets it go).
--     4. Moderators read a chat-evidence object only after opening its report
--        through mod_message_evidence in the last hour: admin_lookups gets a
--        report_id column, mod_message_evidence (migration 69 body) records
--        it, and chat_evidence_select_mod checks it, so listing the bucket
--        shows nothing a moderator has not opened through the logged path.
--     5. chat_classifier_reserve (migration 71 body) also returns the month
--        it reserved in, and chat_classifier_settle takes it (p_month), so a
--        call settled after midnight UTC on the last day of a month corrects
--        the month it was counted in. The two-argument settle is dropped.
--     6. meta.schema_version 2.69.
--
--   meta.chat_images stays 'off'. Account deletion: no new table and no new
--   user reference (admin_lookups.report_id points at a report, and
--   admin_lookups already follows migration 53's deletion rule).
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Missing originals are recorded
-- ---------------------------------------------------------------------------
alter table public.message_report_evidence add column if not exists image_evidence_missing_at timestamptz;
comment on column public.message_report_evidence.image_evidence_missing_at is
  'Migration 73: set when the reported photo''s original could not be read when its evidence copy was due, so the copy is not asked for again.';

create or replace function public.chat_image_evidence_list(p_limit integer default 25)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('report_id', q.report_id, 'path', q.path)), '[]'::jsonb)
    from (select ev.report_id, m.image_path as path
            from public.message_report_evidence ev
            join public.messages m on m.id = ev.message_id
           where m.kind = 'image' and m.image_path is not null and ev.image_evidence_path is null
             and ev.image_evidence_missing_at is null   -- Migration 73
             and ev.created_at > now() - interval '30 days'
             and exists (select 1 from storage.objects o where o.bucket_id = 'chat-images' and o.name = m.image_path)
           order by ev.created_at
           limit greatest(1, least(coalesce(p_limit, 25), 100))) q;
$$;
comment on function public.chat_image_evidence_list(integer) is
  'Migration 72 (73), service role (image-guard sweep): reported chat photos (message_report_evidence of an image message, last 30 days) whose evidence copy is not made yet, not marked missing, and whose original still exists: [{report_id, path}].';
revoke all on function public.chat_image_evidence_list(integer) from public, anon, authenticated;
grant execute on function public.chat_image_evidence_list(integer) to service_role;

create or replace function public.chat_image_evidence_saved(p_report uuid, p_path text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  -- Migration 73: a null path records that the original could not be read.
  if p_report is not null and p_path is null then
    update public.message_report_evidence set image_evidence_missing_at = now()
     where report_id = p_report and image_evidence_path is null and image_evidence_missing_at is null;
    return found;
  end if;
  if p_report is null or p_path is null or p_path <> p_report::text || '.jpg' then
    return false;
  end if;
  update public.message_report_evidence set image_evidence_path = p_path
   where report_id = p_report and image_evidence_path is null;
  return found;
end $$;
comment on function public.chat_image_evidence_saved(uuid, text) is
  'Migration 72 (73), service role (image-guard sweep, delete-account): records the chat-evidence copy (<report id>.jpg) of a reported chat photo, or with a null path that its original could not be read (image_evidence_missing_at). Anything else is ignored (false).';
revoke all on function public.chat_image_evidence_saved(uuid, text) from public, anon, authenticated;
grant execute on function public.chat_image_evidence_saved(uuid, text) to service_role;

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
                              and ev.image_evidence_missing_at is null   -- Migration 73
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
  'Migration 72 (73), service role (image-guard sweep): chat-images objects of deleted messages (kept while a report''s evidence copy is pending), chat uploads never sent after a day, and chat-evidence objects whose evidence record is gone: [{bucket, path}]. The sweep deletes them through the Storage API.';
revoke all on function public.chat_image_purge_list(integer) from public, anon, authenticated;
grant execute on function public.chat_image_purge_list(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 2. One account's pending copies (delete-account)
-- ---------------------------------------------------------------------------
create or replace function public.chat_image_evidence_list_for(p_user uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('report_id', q.report_id, 'path', q.path)), '[]'::jsonb)
    from (select ev.report_id, m.image_path as path
            from public.message_report_evidence ev
            join public.messages m on m.id = ev.message_id
           where p_user is not null
             and m.kind = 'image' and m.image_path is not null
             and left(m.image_path, 37) = p_user::text || '/'
             and ev.image_evidence_path is null and ev.image_evidence_missing_at is null
             and ev.created_at > now() - interval '30 days'
             and exists (select 1 from storage.objects o where o.bucket_id = 'chat-images' and o.name = m.image_path)
           order by ev.created_at
           limit 1000) q;
$$;
comment on function public.chat_image_evidence_list_for(uuid) is
  'Migration 73, service role (delete-account): the pending evidence copies of one account''s chat photos (paths under <user id>/), as chat_image_evidence_list, up to 1000: [{report_id, path}].';
revoke all on function public.chat_image_evidence_list_for(uuid) from public, anon, authenticated;
grant execute on function public.chat_image_evidence_list_for(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 3. image_guard_purge_list (migration 52 body)
-- ---------------------------------------------------------------------------
create or replace function public.image_guard_purge_list(p_limit integer default 50)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'bucket', q.bucket, 'path', q.path)), '[]'::jsonb)
    from (select h.id, h.bucket, h.path from public.image_hashes h
           where h.status in ('blocked', 'unreadable') and h.purged_at is null
             -- Migration 73: a reported chat photo waits for its evidence copy.
             and not (h.bucket = 'chat-images'
                      and exists (select 1 from public.message_report_evidence ev
                                    join public.messages m on m.id = ev.message_id
                                   where m.image_path = h.path and ev.image_evidence_path is null
                                     and ev.image_evidence_missing_at is null
                                     and ev.created_at > now() - interval '30 days'))
           order by h.blocked_at nulls first
           limit greatest(1, least(coalesce(p_limit, 50), 200))) q;
$$;
comment on function public.image_guard_purge_list(integer) is
  'Migration 52 (73), service role (image-guard): blocked or unreadable objects not yet deleted from Storage, [{id, bucket, path}]; a reported chat photo is left out while its evidence copy is pending.';
revoke all on function public.image_guard_purge_list(integer) from public, anon, authenticated;
grant execute on function public.image_guard_purge_list(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 4. Evidence is read only through the logged path
-- ---------------------------------------------------------------------------
alter table public.admin_lookups add column if not exists report_id uuid references public.reports (id) on delete set null;
create index if not exists admin_lookups_report_idx on public.admin_lookups (report_id, moderator_id)
  where report_id is not null;
comment on column public.admin_lookups.report_id is
  'Migration 73: the message report a moderator opened through mod_message_evidence (via open); chat_evidence_select_mod lets that moderator read its evidence copy for an hour.';

-- mod_message_evidence: from 20270101000100_not_found_404.sql (migration 69); the log row
-- now carries the report (migration 73).
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
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  select * into rp from public.reports where id = p_report;
  if public.moderation_is_own('message', ev.message_id, ev.author_id) then
    raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews this one.';
  end if;
  insert into public.admin_lookups (moderator_id, via, target_user_id, result_count, report_id)
  values (uid, 'open', ev.author_id, 1, ev.report_id);
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

revoke all on function public.mod_message_evidence(uuid) from public, anon;
grant execute on function public.mod_message_evidence(uuid) to authenticated, service_role;

create or replace function private.chat_evidence_readable(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null
     and public.is_moderator()
     and exists (select 1 from public.message_report_evidence ev
                   join public.admin_lookups l on l.report_id = ev.report_id
                  where ev.image_evidence_path = p_name
                    and l.moderator_id = (select auth.uid()) and l.via = 'open'
                    and l.created_at > now() - interval '1 hour');
$$;
revoke all on function private.chat_evidence_readable(text) from public, anon;
grant execute on function private.chat_evidence_readable(text) to authenticated;

do $$
begin
  if to_regclass('storage.objects') is null then
    raise notice 'storage is missing; chat_evidence_select_mod not created';
    return;
  end if;
  execute 'drop policy if exists "chat_evidence_select_mod" on storage.objects';
  execute $p$
    create policy "chat_evidence_select_mod" on storage.objects for select to authenticated
      using (bucket_id = 'chat-evidence' and private.chat_evidence_readable(name))
  $p$;
end $$;

-- ---------------------------------------------------------------------------
-- 5. The classifier cap settles in the month it reserved in
-- ---------------------------------------------------------------------------
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
  -- Migration 73: the month, for chat_classifier_settle.
  return jsonb_build_object('pending', true, 'allowed', true, 'used', v_used, 'cap', v_cap, 'month', v_month);
end $$;
comment on function public.chat_classifier_reserve(text, integer) is
  'Migration 71 (73), service role (image-guard classify): whether a chat image waits for a verdict (a pending or classifying message, its object hashed) and, if so, reserves p_operations Sightengine operations under meta.chat_classifier_monthly_cap in collector_budget (day = first of the UTC month, source sightengine_ops). Returns {pending, allowed, used, cap, month}; allowed false past the cap; month (the reservation''s, when allowed) goes to chat_classifier_settle.';
revoke all on function public.chat_classifier_reserve(text, integer) from public, anon, authenticated;
grant execute on function public.chat_classifier_reserve(text, integer) to service_role;

drop function if exists public.chat_classifier_settle(integer, integer);
create or replace function public.chat_classifier_settle(p_reserved integer, p_used integer, p_month date default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  -- Migration 73: the month the operations were reserved in (this month when not given).
  v_month date := coalesce(date_trunc('month', p_month)::date,
                           date_trunc('month', now() at time zone 'utc')::date);
  v_used  integer;
begin
  update public.collector_budget
     set used = greatest(0, used + greatest(0, least(coalesce(p_used, 0), 50))
                              - greatest(0, least(coalesce(p_reserved, 0), 50)))
   where day = v_month and source = 'sightengine_ops'
  returning used into v_used;
  return coalesce(v_used, 0);
end $$;
comment on function public.chat_classifier_settle(integer, integer, date) is
  'Migration 71 (73), service role (image-guard classify): corrects the sightengine_ops count of the month the operations were reserved in (p_month, from chat_classifier_reserve; this month when null) from the operations reserved to the operations Sightengine reported (0 for a refused or failed call). Returns that month''s count.';
revoke all on function public.chat_classifier_settle(integer, integer, date) from public, anon, authenticated;
grant execute on function public.chat_classifier_settle(integer, integer, date) to service_role;

-- ---------------------------------------------------------------------------
-- 6. Version
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.69')
  on conflict (key) do update set value = excluded.value, updated_at = now();
