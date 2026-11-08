-- ============================================================================
-- Staging check for migration 20270109000100_launch_audit_ops.sql
-- (migration 77). One transaction, asserts in DO blocks that raise on
-- failure, rolled back at the end. Prints pass/fail only, never ids, emails or
-- rows (the repo and its Action logs are public). Run as the staging_file of a
-- staging_only migrate.yml run.
--   1 Static: schema_version 2.73 or later; the new kinds, tables (RLS on),
--     bucket (private), jobs and grants.
--   2 Email budget: email_budget_take counts against the day's total and
--     refuses past it; an unknown source is refused.
--   3 Moderator alerts: a child-safety report and a takedown each queue a
--     notice for a moderator (email pending), none for a member;
--     moderation_due_alerts sends once per set of items; a staff email is
--     claimed past notify_email_daily_cap.
--   4 Evidence hold, acceptance and stamps: accept_legal_terms; a member under
--     a child-safety report deletes their account: the ledger row is held a
--     year and legal_hold_saved takes only their own paths; the acceptance
--     row, the hub request note and the role stamp go; a member with no
--     report is not held.
--   5 Sweep: an unfinished deletion over 10 minutes old is claimed once and
--     its error stored sanitized.
--   6 purge_handle_history keeps the 30-day hold; ops_health_alerts runs.
-- ============================================================================
begin;

create function pg_temp.act(p_id uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_id::text, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;
create function pg_temp.member(p_tag text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'lao-' || p_tag || '-' || substr(md5(random()::text), 1, 8) || '@example.com', now(), now(), now());
  update public.profile_private set birth_date = date '1990-02-02' where user_id = v_id;
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
         created_at = now() - interval '5 days'
   where id = v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
declare
  v_kind text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 73] then
    raise exception 'FAIL 1 schema_version is older than 2.73';
  end if;
  foreach v_kind in array array['report_new', 'takedown_new', 'moderation_due', 'ops_alert'] loop
    if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                    where t.typname = 'notification_kind' and e.enumlabel = v_kind) then
      raise exception 'FAIL 1 notification_kind lacks a new value';
    end if;
  end loop;
  if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relname in ('email_send_days', 'legal_holds', 'legal_acceptances')
                and not c.relrowsecurity) then
    raise exception 'FAIL 1 a new table has RLS off';
  end if;
  if has_table_privilege('authenticated', 'public.email_send_days', 'select')
     or has_table_privilege('anon', 'public.legal_holds', 'select')
     or has_table_privilege('authenticated', 'public.legal_acceptances', 'insert') then
    raise exception 'FAIL 1 table grants';
  end if;
  if has_function_privilege('authenticated', 'public.email_budget_take(text,integer)', 'execute')
     or not has_function_privilege('service_role', 'public.email_budget_take(text,integer)', 'execute')
     or has_function_privilege('authenticated', 'public.account_deletion_sweep_claim(integer)', 'execute')
     or has_function_privilege('authenticated', 'public.legal_hold_saved(uuid,text,text,integer)', 'execute')
     or has_function_privilege('anon', 'public.accept_legal_terms(text,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.accept_legal_terms(text,text)', 'execute')
     or has_function_privilege('authenticated', 'public.account_deletion_verify_secret(text)', 'execute') then
    raise exception 'FAIL 1 function grants';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname in ('public', 'private') and p.prosecdef
                and p.proname in ('email_budget_take', 'email_budget_room', 'notify_moderators', 'moderation_due_alerts',
                                  'ops_health_alerts', 'legal_hold_saved', 'account_deletion_sweep_claim',
                                  'account_deletion_dispatch', 'accept_legal_terms', 'purge_handle_history',
                                  'claim_pending_notifications', 'enqueue_notification', 'request_account_deletion')
                and p.proconfig is distinct from array['search_path=""']) then
    raise exception 'FAIL 1 a definer function lacks search_path';
  end if;
  if to_regclass('storage.buckets') is not null
     and coalesce((select public from storage.buckets where id = 'legal-hold'), true) then
    raise exception 'FAIL 1 the legal-hold bucket is missing or public';
  end if;
  if to_regclass('cron.job') is not null and (select count(*) from cron.job
       where jobname in ('moderation-due-alerts', 'ops-health-alerts', 'account-deletion-sweep', 'purge-handle-history')) <> 4 then
    raise exception 'FAIL 1 a pg_cron job is missing';
  end if;
  if to_regclass('vault.secrets') is not null
     and not exists (select 1 from vault.secrets where name = 'account_deletion_secret') then
    raise exception 'FAIL 1 account_deletion_secret is missing';
  end if;
  if public.account_deletion_verify_secret('short') or public.account_deletion_verify_secret(repeat('x', 64)) then
    raise exception 'FAIL 1 a wrong secret verified';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Email budget
-- ---------------------------------------------------------------------------
do $$
declare
  v_today integer := coalesce((select sum(sent) from public.email_send_days
                                where day = (now() at time zone 'UTC')::date), 0);
begin
  insert into public.meta (key, value) values ('email_daily_cap_total', (v_today + 1)::text)
    on conflict (key) do update set value = excluded.value;
  insert into public.meta (key, value) values ('email_monthly_cap_total', '9999999')
    on conflict (key) do update set value = excluded.value;
  if not public.email_budget_take('verification') then
    raise exception 'FAIL 2 the last email of the day was refused';
  end if;
  if public.email_budget_take('scorecard') then
    raise exception 'FAIL 2 an email past the day''s total was allowed';
  end if;
  if (select sum(sent) from public.email_send_days where day = (now() at time zone 'UTC')::date) <> v_today + 1 then
    raise exception 'FAIL 2 the day''s count is wrong';
  end if;
  if pg_temp.err($q$select public.email_budget_take('notify')$q$) !~ 'invalid_source' then
    raise exception 'FAIL 2 an unknown source was accepted';
  end if;
  update public.meta set value = '9999999' where key = 'email_daily_cap_total';
end $$;

-- ---------------------------------------------------------------------------
-- 3. Moderator alerts
-- ---------------------------------------------------------------------------
do $$
declare
  v_mod  uuid := pg_temp.member('mod');
  v_mem  uuid := pg_temp.member('mem');
  v_rep  uuid := pg_temp.member('rep');
  v_tgt  uuid := pg_temp.member('tgt');
  v_r    uuid;
  v_t    uuid;
  v_n    uuid;
  v_out  jsonb;
begin
  perform set_config('test.mod', v_mod::text, true);
  insert into public.user_roles (user_id, role) values (v_mod, 'moderator');

  insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, priority, due_at)
  values (v_rep, 'profile', v_tgt, v_tgt, 'child_safety', 0, now() + interval '4 hours')
  returning id into v_r;
  if not exists (select 1 from public.notifications
                  where user_id = v_mod and kind = 'report_new' and dedupe_key = 'report_new:' || v_r || ':' || v_mod
                    and email_status = 'pending') then
    raise exception 'FAIL 3 a child-safety report did not alert the moderator by email';
  end if;
  if exists (select 1 from public.notifications where user_id in (v_mem, v_rep, v_tgt) and kind = 'report_new') then
    raise exception 'FAIL 3 a member got a moderator alert';
  end if;
  if public.enqueue_notification(v_mem, 'ops_alert', 'lao-test:' || v_mem, null, null, null, null, '{}'::jsonb) is not null then
    raise exception 'FAIL 3 enqueue_notification sent an ops alert to a member';
  end if;

  insert into public.takedown_requests (reference, requester_name, requester_email, email_hash, relationship,
                                        locations, good_faith, signature, involves_minor, priority, due_at)
  values ('TD-LAO' || substr(md5(random()::text), 1, 6), 'Test Person', 'lao-td@example.com', md5('lao-td'), 'self',
          'https://example.com/x', true, 'Test Person', false, 1, now() + interval '48 hours')
  returning id into v_t;
  if not exists (select 1 from public.notifications
                  where user_id = v_mod and kind = 'takedown_new' and dedupe_key = 'takedown_new:' || v_t || ':' || v_mod) then
    raise exception 'FAIL 3 a takedown did not alert the moderator';
  end if;

  if public.moderation_due_alerts() < 1 then
    raise exception 'FAIL 3 a report due within 4 hours sent no moderation_due';
  end if;
  if not exists (select 1 from public.notifications where user_id = v_mod and kind = 'moderation_due'
                    and (payload ->> 'reports_due')::int >= 1) then
    raise exception 'FAIL 3 moderation_due payload';
  end if;
  if public.moderation_due_alerts() <> 0 then
    raise exception 'FAIL 3 the same set of items was alerted twice';
  end if;

  -- Past the notify cap, a staff email still goes out (the account budget is open above).
  insert into public.meta (key, value) values ('notify_email_daily_cap', '0')
    on conflict (key) do update set value = excluded.value;
  select id into v_n from public.notifications
   where user_id = v_mod and kind = 'report_new' and dedupe_key = 'report_new:' || v_r || ':' || v_mod;
  update public.notifications set created_at = now() - interval '2 days' + interval '1 minute' where id = v_n;
  v_out := public.claim_pending_notifications(100);
  if not exists (select 1 from jsonb_array_elements(v_out) x
                  where x ->> 'id' = v_n::text and x -> 'email' is not null and x -> 'email' <> 'null'::jsonb) then
    raise exception 'FAIL 3 a staff email was not claimed past notify_email_daily_cap';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Evidence hold, acceptance and stamps
-- ---------------------------------------------------------------------------
do $$
declare
  v_u     uuid := pg_temp.member('held');
  v_free  uuid := pg_temp.member('free');
  v_other uuid := pg_temp.member('other');
  v_rep   uuid := pg_temp.member('rep2');
begin
  perform set_config('test.held', v_u::text, true);
  perform set_config('test.free', v_free::text, true);
  perform set_config('test.other', v_other::text, true);
  insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, priority, due_at)
  values (v_rep, 'profile', v_u, v_u, 'child_safety', 0, now() + interval '4 hours');
  insert into public.user_roles (user_id, role, granted_by) values (v_other, 'moderator', v_u);
  insert into public.hub_requests (user_id, name, note) values (v_u, 'Zzq test hub', 'a private note');
  perform pg_temp.act(v_u);
end $$;

set local role authenticated;
do $$
begin
  perform public.accept_legal_terms('terms 2026-11.2', 'privacy 2026-11.2');
  begin
    perform public.accept_legal_terms('anything', 'privacy 2026-11.2');
    raise exception 'FAIL 4 accept_legal_terms took a bad version';
  exception when others then
    if sqlerrm <> 'invalid_version' then raise exception 'FAIL 4 accept_legal_terms: %', sqlerrm; end if;
  end;
  if (select count(*) from public.legal_acceptances) <> 1 then
    raise exception 'FAIL 4 the member does not read exactly their own acceptance';
  end if;
  perform public.request_account_deletion('test');
end $$;
reset role;

do $$
begin
  perform pg_temp.act(current_setting('test.free')::uuid);
end $$;
set local role authenticated;
do $$
begin
  perform public.request_account_deletion(null);
end $$;
reset role;

do $$
declare
  v_u     uuid := current_setting('test.held')::uuid;
  v_free  uuid := current_setting('test.free')::uuid;
  v_other uuid := current_setting('test.other')::uuid;
  v_d     public.account_deletions%rowtype;
begin
  select * into v_d from public.account_deletions where user_id = v_u;
  if v_d.legal_hold_until is null or v_d.legal_hold_until < now() + interval '364 days'
     or v_d.retain_evidence_until < now() + interval '364 days' then
    raise exception 'FAIL 4 a deletion under a child-safety report is not held a year';
  end if;
  if public.legal_hold_saved(v_u, 'avatars', v_u::text || '/a.jpg') is distinct from v_u::text || '/avatars/a.jpg' then
    raise exception 'FAIL 4 legal_hold_saved did not record the account''s own photo';
  end if;
  if public.legal_hold_saved(v_u, 'avatars', v_other::text || '/a.jpg') is not null
     or public.legal_hold_saved(v_u, 'chat-evidence', v_u::text || '/a.jpg') is not null then
    raise exception 'FAIL 4 legal_hold_saved took another path or bucket';
  end if;
  if exists (select 1 from public.legal_acceptances where user_id = v_u) then
    raise exception 'FAIL 4 the acceptance row outlived the account';
  end if;
  if exists (select 1 from public.hub_requests where user_id = v_u and note <> '')
     or exists (select 1 from public.user_roles where user_id = v_other and granted_by = v_u) then
    raise exception 'FAIL 4 a note or stamp naming the deleted account stayed';
  end if;
  if (select legal_hold_until from public.account_deletions where user_id = v_free) is not null
     or public.legal_hold_saved(v_free, 'avatars', v_free::text || '/a.jpg') is not null then
    raise exception 'FAIL 4 a deletion with no report was held';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Sweep
-- ---------------------------------------------------------------------------
do $$
declare
  v_u   uuid := current_setting('test.held')::uuid;
  v_ids jsonb;
begin
  update public.account_deletions set requested_at = now() - interval '20 minutes' where user_id = v_u;
  v_ids := public.account_deletion_sweep_claim(20);
  if not (v_ids @> to_jsonb(array[v_u::text])) then
    raise exception 'FAIL 5 an unfinished deletion was not claimed';
  end if;
  if (select attempts from public.account_deletions where user_id = v_u) <> 1 then
    raise exception 'FAIL 5 the try was not counted';
  end if;
  if public.account_deletion_sweep_claim(20) @> to_jsonb(array[v_u::text]) then
    raise exception 'FAIL 5 a deletion was claimed twice within 30 minutes';
  end if;
  perform public.account_deletion_failed(v_u, 'Auth_Delete_Failed <x@y>');
  if (select last_error from public.account_deletions where user_id = v_u) is distinct from 'uth_elete_ailedxy' then
    raise exception 'FAIL 5 the error was not sanitized';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Handles and daily health
-- ---------------------------------------------------------------------------
do $$
declare
  v_u uuid := current_setting('test.mod')::uuid;
begin
  insert into public.handle_history (user_id, handle, released_at)
  values (v_u, 'zzq_lao_old', now() - interval '40 days'), (v_u, 'zzq_lao_new', now() - interval '10 days');
  perform public.purge_handle_history();
  if exists (select 1 from public.handle_history where handle = 'zzq_lao_old')
     or not exists (select 1 from public.handle_history where handle = 'zzq_lao_new') then
    raise exception 'FAIL 6 purge_handle_history';
  end if;
  if public.ops_health_alerts() is null then
    raise exception 'FAIL 6 ops_health_alerts returned null';
  end if;
end $$;

select 'launch_audit_ops: PASS' as result;

rollback;
