-- ============================================================================
-- Staging check for migration 20261216000100_ncii_takedown.sql (migration 52).
-- One transaction: sets up throwaway accounts, asserts with DO blocks that
-- raise on failure, then rolls everything back (pg_net requests queued by the
-- triggers go with it). Prints pass/fail only (no user rows; the accounts
-- and requests are invented, and the hashes are those of the synthetic
-- fixtures in supabase/functions/image-guard/fixtures).
-- Run as the staging_file of a staging_only migrate.yml run.
--
--   1 static: schema_version 2.48, grants, the match rule, cron jobs.
--   2 the public request: anon files one without an account; validation;
--     3 a day per email; 48 hours, 4 hours and priority 0 for a minor;
--     anon cannot read requests.
--   3 the moderator queue: forbidden to members, most urgent first.
--   4 the upload path: a new photo is recorded pending; hashes recorded.
--   5 a moderator blocks an image: it and its stored copy are cleared and
--     queued for deletion; second-moderator rule.
--   6 re-uploads: a near copy and an exact copy are blocked on check; a
--     blocked object cannot be set again; an unrelated picture passes.
--   7 an unreadable upload is cleared.
--   8 blocking before hashing: state hashing, blocked on the answer.
--   9 purge list and mark purged; image_guard_tick.
--  10 resolve: removed, waiting, rejected, reopen, own_item.
--  11 retention: contacts cleared a year after closing.
--  12 account deletion: resolver stamp cleared, unblocked hashes go,
--     blocked ones stay.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if (select value from public.meta where key = 'schema_version') <> '2.48' then
    raise exception 'FAIL 1 schema_version is not 2.48';
  end if;
  if has_table_privilege('anon', 'public.takedown_requests', 'select')
     or has_table_privilege('anon', 'public.takedown_requests', 'insert')
     or has_table_privilege('authenticated', 'public.takedown_requests', 'select')
     or has_table_privilege('authenticated', 'public.image_hashes', 'select')
     or has_table_privilege('authenticated', 'public.blocked_image_hashes', 'select')
     or has_table_privilege('anon', 'public.image_hashes', 'select')
     or not has_table_privilege('service_role', 'public.image_hashes', 'select') then
    raise exception 'FAIL 1 table grants';
  end if;
  if not has_function_privilege('anon', 'public.submit_takedown_request(text,text,text,text,boolean,text,text,boolean)', 'execute')
     or not has_function_privilege('authenticated', 'public.submit_takedown_request(text,text,text,text,boolean,text,text,boolean)', 'execute')
     or has_function_privilege('anon', 'public.mod_takedown_queue(integer,boolean)', 'execute')
     or not has_function_privilege('authenticated', 'public.mod_takedown_queue(integer,boolean)', 'execute')
     or has_function_privilege('anon', 'public.mod_takedown_block_image(uuid,text)', 'execute')
     or has_function_privilege('anon', 'public.mod_takedown_resolve(uuid,text,text,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.image_guard_record(text,text,text,text,text,text)', 'execute')
     or not has_function_privilege('service_role', 'public.image_guard_record(text,text,text,text,text,text)', 'execute')
     or has_function_privilege('authenticated', 'public.image_guard_purge_list(integer)', 'execute')
     or has_function_privilege('authenticated', 'public.image_guard_mark_purged(uuid[])', 'execute')
     or has_function_privilege('authenticated', 'public.image_guard_verify_secret(text)', 'execute')
     or has_function_privilege('anon', 'public.image_guard_verify_secret(text)', 'execute')
     or has_function_privilege('authenticated', 'public.image_guard_dispatch(jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.image_clear_references(text,text)', 'execute')
     or has_function_privilege('authenticated', 'public.image_block_matches(uuid,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.image_guard_tick()', 'execute')
     or has_function_privilege('authenticated', 'public.purge_takedown_contacts()', 'execute')
     or has_function_privilege('anon', 'public.request_account_deletion(text)', 'execute') then
    raise exception 'FAIL 1 function grants';
  end if;
  if public.image_guard_verify_secret('short') or public.image_guard_verify_secret(repeat('0', 64)) then
    raise exception 'FAIL 1 verify_secret accepts a wrong secret';
  end if;

  -- The match rule against the fixture hashes (hash_test.ts pins the same pairs).
  if not public.image_hash_close(public.image_hash_from_hex('cd73ca7ac411565a'), public.image_hash_from_hex('cd72ca7ac451565a'),
                                 public.image_hash_from_hex('fefcf9797d7f071f'), public.image_hash_from_hex('fefcf979fd7f071f'))
     or not public.image_hash_close(public.image_hash_from_hex('cd73ca7ac411565a'), public.image_hash_from_hex('cd70ca73c4d1545b'),
                                    public.image_hash_from_hex('fefcf9797d7f071f'), public.image_hash_from_hex('fefc79796c60060e'))
     or public.image_hash_close(public.image_hash_from_hex('cd73ca7ac411565a'), public.image_hash_from_hex('a65946a6b3e499c5'),
                                public.image_hash_from_hex('fefcf9797d7f071f'), public.image_hash_from_hex('44ce0c6420183832'))
     or public.image_hash_close(public.image_hash_from_hex('d7e028d708c2c3d5'), public.image_hash_from_hex('d7e028d708c2c3d5'),
                                public.image_hash_from_hex('0000000000000000'), public.image_hash_from_hex('0000000000000000')) then
    raise exception 'FAIL 1 image_hash_close';
  end if;
  if public.image_hash_from_hex('ffffffffffffffff') <> -1 or public.image_hash_from_hex('8000000000000000') >= 0 then
    raise exception 'FAIL 1 image_hash_from_hex';
  end if;
  begin
    perform public.image_hash_from_hex('XYZ');
    raise exception 'FAIL 1 bad hex accepted';
  exception when others then
    if sqlerrm <> 'invalid_hash' then raise exception 'FAIL 1 bad hex: %', sqlerrm; end if;
  end;

  if to_regclass('cron.job') is not null
     and (select count(*) from cron.job where jobname in ('image-guard-tick', 'takedown-contacts-purge')) <> 2 then
    raise exception 'FAIL 1 cron jobs missing';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['u', 'c', 'z', 'x', 'p', 'm', 'm2', 'mem'];
  v_id    uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  -- A project URL so own-Storage URLs exist (staging has its own; rolled back either way).
  insert into public.meta (key, value) values ('project_url', 'https://abcdefghijklmnopqrst.supabase.co')
  on conflict (key) do nothing;
  if public.project_url() is null then
    update public.meta set value = 'https://abcdefghijklmnopqrst.supabase.co' where key = 'project_url';
  end if;
  perform set_config('test.base', public.project_url() || '/storage/v1/object/public/avatars/', true);
  perform set_config('test.tag', v_tag, true);

  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'nc-' || v_names[i] || '-' || v_tag || '@example.com', now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
           created_at = now() - interval '3 days'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  insert into public.user_roles (user_id, role) values
    (current_setting('test.m')::uuid, 'moderator'),
    (current_setting('test.m2')::uuid, 'moderator');
end $$;

-- ---------------------------------------------------------------------------
-- 2. The public request (anon, no account)
-- ---------------------------------------------------------------------------
set local role anon;
do $$
declare
  v_email text := 'requester-' || current_setting('test.tag') || '@example.com';
  j       jsonb;
  v_err   text;
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  j := public.submit_takedown_request('Pat Requester', v_email, 'self',
         'https://activityplanet.app/u/someone (profile photo)', true, 'Pat Requester', 'It was shared without my consent.');
  if j ->> 'reference' !~ '^NCII-[0-9A-F]{8}$'
     or (j ->> 'due_at')::timestamptz not between now() + interval '47 hours 59 minutes' and now() + interval '48 hours 1 minute' then
    raise exception 'FAIL 2 first request answer';
  end if;
  perform set_config('test.ref1', j ->> 'reference', true);

  for v_err in select unnest(array['good_faith_required', 'invalid_email', 'invalid_relationship', 'signature_required',
                                   'location_required', 'name_required']) loop
    begin
      case v_err
        when 'good_faith_required' then
          perform public.submit_takedown_request('Pat', v_email, 'self', 'somewhere', false, 'Pat');
        when 'invalid_email' then
          perform public.submit_takedown_request('Pat', 'not-an-email', 'self', 'somewhere', true, 'Pat');
        when 'invalid_relationship' then
          perform public.submit_takedown_request('Pat', v_email, 'friend', 'somewhere', true, 'Pat');
        when 'signature_required' then
          perform public.submit_takedown_request('Pat', v_email, 'self', 'somewhere', true, ' ');
        when 'location_required' then
          perform public.submit_takedown_request('Pat', v_email, 'self', '', true, 'Pat');
        else
          perform public.submit_takedown_request('', v_email, 'self', 'somewhere', true, 'Pat');
      end case;
      raise exception 'FAIL 2 % accepted', v_err;
    exception when others then
      if sqlerrm <> v_err then raise exception 'FAIL 2 % gave %', v_err, sqlerrm; end if;
    end;
  end loop;

  -- A minor may be shown: priority 0, 4 hours.
  j := public.submit_takedown_request('Pat Requester', v_email, 'authorized', 'a plan cover photo', true,
                                      'Pat Requester', '', true);
  if (j ->> 'due_at')::timestamptz > now() + interval '4 hours 1 minute' then
    raise exception 'FAIL 2 minor due_at';
  end if;
  perform set_config('test.ref2', j ->> 'reference', true);
  -- Third today from this address is fine, the fourth is not (case does not matter).
  j := public.submit_takedown_request('Pat Requester', v_email, 'self', 'another link', true, 'Pat Requester');
  perform set_config('test.ref3', j ->> 'reference', true);
  begin
    perform public.submit_takedown_request('Pat Requester', upper(v_email), 'self', 'a fourth', true, 'Pat Requester');
    raise exception 'FAIL 2 fourth request accepted';
  exception when others then
    if sqlerrm <> 'rate_limited' then raise exception 'FAIL 2 rate limit: %', sqlerrm; end if;
  end;

  begin
    perform 1 from public.takedown_requests limit 1;
    raise exception 'FAIL 2 anon reads takedown_requests';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.mod_takedown_queue(10, false);
    raise exception 'FAIL 2 anon reads the queue';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
do $$
begin
  perform set_config('test.r1', (select id::text from public.takedown_requests where reference = current_setting('test.ref1')), true);
  perform set_config('test.r2', (select id::text from public.takedown_requests where reference = current_setting('test.ref2')), true);
  perform set_config('test.r3', (select id::text from public.takedown_requests where reference = current_setting('test.ref3')), true);
  if not exists (select 1 from public.takedown_requests
                  where id = current_setting('test.r2')::uuid and priority = 0 and involves_minor and relationship = 'authorized')
     or not exists (select 1 from public.takedown_requests
                     where id = current_setting('test.r1')::uuid and priority = 1 and status = 'open' and good_faith
                       and email_hash ~ '^[0-9a-f]{64}$' and requester_email = lower(requester_email)) then
    raise exception 'FAIL 2 stored request';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. The moderator queue
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  j jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.mem'), 'role', 'authenticated')::text, true);
  begin
    perform public.mod_takedown_queue(10, false);
    raise exception 'FAIL 3 member reads the queue';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 3 member queue: %', sqlerrm; end if;
  end;
  begin
    perform public.mod_takedown_resolve(current_setting('test.r1')::uuid, 'removed', 'x');
    raise exception 'FAIL 3 member resolves';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 3 member resolve: %', sqlerrm; end if;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  j := public.mod_takedown_queue(500, false);
  if (select count(*) from jsonb_array_elements(j) e
       where e ->> 'id' in (current_setting('test.r1'), current_setting('test.r2'), current_setting('test.r3'))) <> 3 then
    raise exception 'FAIL 3 queue misses the requests';
  end if;
  if (select (e ->> 'priority')::integer from jsonb_array_elements(j) e limit 1) <> 0 then
    raise exception 'FAIL 3 queue order';
  end if;
  if not exists (select 1 from jsonb_array_elements(j) e
                  where e ->> 'id' = current_setting('test.r1') and not (e ->> 'overdue')::boolean
                    and (e ->> 'minutes_left')::integer between 2870 and 2880 and (e ->> 'can_act')::boolean
                    and e -> 'requester' ->> 'relationship' = 'self' and e ->> 'signature' <> '') then
    raise exception 'FAIL 3 queue item';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. The upload path
-- ---------------------------------------------------------------------------
do $$
declare
  v_base text := current_setting('test.base');
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.u'), 'role', 'authenticated')::text, true);
  update public.profiles set avatar_url = v_base || current_setting('test.u') || '/1.jpg' where id = current_setting('test.u')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true);
  update public.profiles set avatar_url = v_base || current_setting('test.c') || '/1.jpg' where id = current_setting('test.c')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.x'), 'role', 'authenticated')::text, true);
  update public.profiles set avatar_url = v_base || current_setting('test.x') || '/1.jpg' where id = current_setting('test.x')::uuid;
end $$;
reset role;
do $$
declare
  j jsonb;
begin
  if (select count(*) from public.image_hashes
       where status = 'pending' and bucket = 'avatars' and attempts = 1 and dispatched_at is not null
         and owner_id in (current_setting('test.u')::uuid, current_setting('test.c')::uuid, current_setting('test.x')::uuid)) <> 3 then
    raise exception 'FAIL 4 new photos not recorded pending';
  end if;
  -- u: the base picture; c: a re-encoded copy of it; x: an unrelated picture.
  j := public.image_guard_record('avatars', current_setting('test.u') || '/1.jpg', 'hashed',
                                 repeat('a', 64), 'cd73ca7ac411565a', 'fefcf9797d7f071f');
  if j ->> 'outcome' <> 'ok' then raise exception 'FAIL 4 u outcome %', j; end if;
  j := public.image_guard_record('avatars', current_setting('test.c') || '/1.jpg', 'hashed',
                                 repeat('b', 64), 'cd72ca7ac451565a', 'fefcf979fd7f071f');
  if j ->> 'outcome' <> 'ok' then raise exception 'FAIL 4 c outcome %', j; end if;
  j := public.image_guard_record('avatars', current_setting('test.x') || '/1.jpg', 'hashed',
                                 repeat('c', 64), 'a65946a6b3e499c5', '44ce0c6420183832');
  if j ->> 'outcome' <> 'ok' then raise exception 'FAIL 4 x outcome %', j; end if;
  if (select count(*) from public.image_hashes
       where status = 'hashed'
         and owner_id in (current_setting('test.u')::uuid, current_setting('test.c')::uuid, current_setting('test.x')::uuid)) <> 3 then
    raise exception 'FAIL 4 hashes not stored';
  end if;
  begin
    perform public.image_guard_record('avatars', '../escape.jpg', 'missing');
    raise exception 'FAIL 4 bad path accepted';
  exception when others then
    if sqlerrm <> 'invalid_object' then raise exception 'FAIL 4 bad path: %', sqlerrm; end if;
  end;
  begin
    perform public.image_guard_record('avatars', 'a/b.jpg', 'hashed', repeat('d', 64), 'nothex', 'fefcf9797d7f071f');
    raise exception 'FAIL 4 bad hash accepted';
  exception when others then
    if sqlerrm <> 'invalid_hash' then raise exception 'FAIL 4 bad hash: %', sqlerrm; end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 5. A moderator blocks an image
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_base text := current_setting('test.base');
  j      jsonb;
begin
  -- Second-moderator rule: m2 cannot act on m2's own image.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m2'), 'role', 'authenticated')::text, true);
  begin
    perform public.mod_takedown_block_image(current_setting('test.r3')::uuid, v_base || current_setting('test.m2') || '/1.jpg');
    raise exception 'FAIL 5 own image accepted';
  exception when others then
    if sqlerrm <> 'own_item' then raise exception 'FAIL 5 own image: %', sqlerrm; end if;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  begin
    perform public.mod_takedown_block_image(current_setting('test.r1')::uuid, 'https://example.com/a.jpg');
    raise exception 'FAIL 5 foreign URL accepted';
  exception when others then
    if sqlerrm <> 'invalid_image_url' then raise exception 'FAIL 5 foreign URL: %', sqlerrm; end if;
  end;
  j := public.mod_takedown_block_image(current_setting('test.r1')::uuid, v_base || current_setting('test.u') || '/1.jpg');
  if j ->> 'state' <> 'blocked' or (j ->> 'copies')::integer <> 2 or (j ->> 'references_cleared')::integer <> 1 then
    raise exception 'FAIL 5 block answer %', j;
  end if;
  j := public.mod_takedown_queue(500, false);
  if not exists (select 1 from jsonb_array_elements(j) e
                  where e ->> 'id' = current_setting('test.r1') and (e ->> 'images_blocked')::integer = 2
                    and jsonb_array_length(e -> 'images') = 2
                    and e -> 'target_user' ->> 'id' = current_setting('test.u')) then
    raise exception 'FAIL 5 queue after block';
  end if;
end $$;
reset role;
do $$
begin
  if exists (select 1 from public.profiles
              where id in (current_setting('test.u')::uuid, current_setting('test.c')::uuid) and avatar_url is not null)
     or not exists (select 1 from public.profiles where id = current_setting('test.x')::uuid and avatar_url is not null) then
    raise exception 'FAIL 5 references';
  end if;
  if (select count(*) from public.image_hashes
       where status = 'blocked' and blocked_at is not null and purged_at is null
         and owner_id in (current_setting('test.u')::uuid, current_setting('test.c')::uuid)) <> 2
     or exists (select 1 from public.image_hashes where owner_id = current_setting('test.x')::uuid and status <> 'hashed') then
    raise exception 'FAIL 5 image statuses';
  end if;
  if (select count(*) from public.blocked_image_hashes where request_id = current_setting('test.r1')::uuid) <> 1
     or (select target_user_id from public.takedown_requests where id = current_setting('test.r1')::uuid) <> current_setting('test.u')::uuid then
    raise exception 'FAIL 5 blocked hash or target';
  end if;
  if not exists (select 1 from public.moderation_actions
                  where action = 'image_block' and target_kind = 'takedown' and target_id = current_setting('test.r1')::uuid
                    and moderator_id = current_setting('test.m')::uuid)
     or (select count(*) from public.moderation_actions
          where action = 'image_remove' and target_kind = 'image'
            and target_user_id in (current_setting('test.u')::uuid, current_setting('test.c')::uuid)) <> 2 then
    raise exception 'FAIL 5 log';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Re-uploads
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_base text := current_setting('test.base');
begin
  -- u cannot point at the blocked object again.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.u'), 'role', 'authenticated')::text, true);
  begin
    update public.profiles set avatar_url = v_base || current_setting('test.u') || '/1.jpg' where id = current_setting('test.u')::uuid;
    raise exception 'FAIL 6 blocked object set again';
  exception when others then
    if sqlerrm <> 'image_blocked' then raise exception 'FAIL 6 blocked object: %', sqlerrm; end if;
  end;
  -- z uploads a cropped copy (new bytes), then an exact copy under a new name.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.z'), 'role', 'authenticated')::text, true);
  update public.profiles set avatar_url = v_base || current_setting('test.z') || '/1.jpg' where id = current_setting('test.z')::uuid;
end $$;
reset role;
do $$
declare
  j jsonb;
begin
  j := public.image_guard_record('avatars', current_setting('test.z') || '/1.jpg', 'hashed',
                                 repeat('e', 64), 'cd72da7ac515445a', 'fefcfd7dfdff871f');
  if j ->> 'outcome' <> 'blocked' then raise exception 'FAIL 6 near copy outcome %', j; end if;
  if (select avatar_url from public.profiles where id = current_setting('test.z')::uuid) is not null then
    raise exception 'FAIL 6 near copy still shown';
  end if;
  -- The exact bytes (same SHA-256) with unrelated-looking perceptual hashes.
  update public.profiles set avatar_url = current_setting('test.base') || current_setting('test.z') || '/2.jpg'
   where id = current_setting('test.z')::uuid;
  j := public.image_guard_record('avatars', current_setting('test.z') || '/2.jpg', 'hashed',
                                 repeat('a', 64), '8c31e38c91671ff8', '00c0c0c8cc989818');
  if j ->> 'outcome' <> 'blocked' then raise exception 'FAIL 6 exact copy outcome %', j; end if;
  -- An unrelated picture passes.
  update public.profiles set avatar_url = current_setting('test.base') || current_setting('test.z') || '/3.jpg'
   where id = current_setting('test.z')::uuid;
  j := public.image_guard_record('avatars', current_setting('test.z') || '/3.jpg', 'hashed',
                                 repeat('f', 64), 'f4cdfcc00549d03f', 'cbdbdf3f337373f3');
  if j ->> 'outcome' <> 'ok'
     or (select avatar_url from public.profiles where id = current_setting('test.z')::uuid) is null then
    raise exception 'FAIL 6 unrelated picture %', j;
  end if;
  -- A blocked row is never unblocked by a later check.
  j := public.image_guard_record('avatars', current_setting('test.u') || '/1.jpg', 'hashed',
                                 repeat('1', 64), 'f4cdfcc00549d03f', 'cbdbdf3f337373f3');
  if j ->> 'outcome' <> 'blocked' then raise exception 'FAIL 6 recheck unblocked %', j; end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. An unreadable upload
-- ---------------------------------------------------------------------------
do $$
declare
  j jsonb;
begin
  update public.profiles set avatar_url = current_setting('test.base') || current_setting('test.x') || '/2.webp'
   where id = current_setting('test.x')::uuid;
  j := public.image_guard_record('avatars', current_setting('test.x') || '/2.webp', 'unreadable');
  if j ->> 'outcome' <> 'unreadable'
     or (select avatar_url from public.profiles where id = current_setting('test.x')::uuid) is not null
     or not exists (select 1 from public.image_hashes where path = current_setting('test.x') || '/2.webp'
                     and status = 'unreadable' and sha256 is null and purged_at is null) then
    raise exception 'FAIL 7 unreadable %', j;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 8. Blocking before hashing
-- ---------------------------------------------------------------------------
do $$
begin
  update public.profiles set avatar_url = current_setting('test.base') || current_setting('test.p') || '/1.jpg'
   where id = current_setting('test.p')::uuid;
end $$;
set local role authenticated;
do $$
declare
  j jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  j := public.mod_takedown_block_image(current_setting('test.r3')::uuid,
                                       current_setting('test.base') || current_setting('test.p') || '/1.jpg');
  if j ->> 'state' <> 'hashing' or (j ->> 'references_cleared')::integer <> 1 then
    raise exception 'FAIL 8 answer %', j;
  end if;
end $$;
reset role;
do $$
declare
  j jsonb;
begin
  if (select avatar_url from public.profiles where id = current_setting('test.p')::uuid) is not null
     or not exists (select 1 from public.image_hashes where owner_id = current_setting('test.p')::uuid
                     and status = 'pending' and block_request_id = current_setting('test.r3')::uuid) then
    raise exception 'FAIL 8 pending block';
  end if;
  j := public.image_guard_record('avatars', current_setting('test.p') || '/1.jpg', 'hashed',
                                 repeat('9', 64), 'a36ed61174ce312b', '00103c3828202003');
  if j ->> 'outcome' <> 'blocked'
     or not exists (select 1 from public.blocked_image_hashes where request_id = current_setting('test.r3')::uuid)
     or (select status from public.image_hashes where owner_id = current_setting('test.p')::uuid) <> 'blocked' then
    raise exception 'FAIL 8 blocked on the answer %', j;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 9. Purge list, mark purged, tick
-- ---------------------------------------------------------------------------
do $$
declare
  j     jsonb;
  v_ids uuid[];
  v_n   integer;
begin
  j := public.image_guard_purge_list(200);
  select array_agg((e ->> 'id')::uuid) into v_ids from jsonb_array_elements(j) e
   where split_part(e ->> 'path', '/', 1) in (current_setting('test.u'), current_setting('test.c'), current_setting('test.z'),
                                             current_setting('test.x'), current_setting('test.p'));
  -- u/1, c/1, z/1, z/2, x/2.webp, p/1
  if coalesce(array_length(v_ids, 1), 0) <> 6 then
    raise exception 'FAIL 9 purge list has % of ours', coalesce(array_length(v_ids, 1), 0);
  end if;
  v_n := public.image_guard_mark_purged(v_ids);
  if v_n <> 6 or public.image_guard_mark_purged(v_ids) <> 0 then
    raise exception 'FAIL 9 mark purged';
  end if;
  update public.profiles set avatar_url = current_setting('test.base') || current_setting('test.mem') || '/1.jpg'
   where id = current_setting('test.mem')::uuid;
  update public.image_hashes set dispatched_at = now() - interval '10 minutes'
   where owner_id = current_setting('test.mem')::uuid;
  j := public.image_guard_tick();
  if j ->> 'checks' is null
     or (select attempts from public.image_hashes where owner_id = current_setting('test.mem')::uuid) <> 2 then
    raise exception 'FAIL 9 tick %', j;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Resolve
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  j jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  begin
    perform public.mod_takedown_resolve(current_setting('test.r1')::uuid, 'waiting', '');
    raise exception 'FAIL 10 waiting without a note';
  exception when others then
    if sqlerrm <> 'note_required' then raise exception 'FAIL 10 waiting: %', sqlerrm; end if;
  end;
  begin
    perform public.mod_takedown_resolve(current_setting('test.r2')::uuid, 'removed', 'x', current_setting('test.m')::uuid);
    raise exception 'FAIL 10 own target accepted';
  exception when others then
    if sqlerrm <> 'own_item' then raise exception 'FAIL 10 own target: %', sqlerrm; end if;
  end;
  j := public.mod_takedown_resolve(current_setting('test.r1')::uuid, 'waiting', 'Asked for the exact link');
  if j ->> 'status' <> 'waiting' then raise exception 'FAIL 10 waiting %', j; end if;
  j := public.mod_takedown_resolve(current_setting('test.r1')::uuid, 'removed', 'Photo and two copies removed');
  if j ->> 'status' <> 'removed' then raise exception 'FAIL 10 removed %', j; end if;
  begin
    perform public.mod_takedown_resolve(current_setting('test.r1')::uuid, 'rejected', 'again');
    raise exception 'FAIL 10 closed request resolved again';
  exception when others then
    if sqlerrm <> 'request_closed' then raise exception 'FAIL 10 closed: %', sqlerrm; end if;
  end;
  begin
    perform public.mod_takedown_block_image(current_setting('test.r1')::uuid,
                                            current_setting('test.base') || current_setting('test.x') || '/1.jpg');
    raise exception 'FAIL 10 block on a closed request';
  exception when others then
    if sqlerrm <> 'request_closed' then raise exception 'FAIL 10 block closed: %', sqlerrm; end if;
  end;
  j := public.mod_takedown_queue(500, true);
  if not exists (select 1 from jsonb_array_elements(j) e
                  where e ->> 'id' = current_setting('test.r1') and e ->> 'status' = 'removed' and not (e ->> 'overdue')::boolean) then
    raise exception 'FAIL 10 closed queue';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m2'), 'role', 'authenticated')::text, true);
  j := public.mod_takedown_resolve(current_setting('test.r2')::uuid, 'rejected', 'Not on Activity Planet');
  if j ->> 'status' <> 'rejected' then raise exception 'FAIL 10 rejected %', j; end if;
  j := public.mod_takedown_resolve(current_setting('test.r2')::uuid, 'reopen', null);
  if j ->> 'status' <> 'open' then raise exception 'FAIL 10 reopen %', j; end if;
  j := public.mod_takedown_resolve(current_setting('test.r2')::uuid, 'rejected', 'Still not found');
  j := public.mod_takedown_resolve(current_setting('test.r3')::uuid, 'removed', 'Cover removed');
end $$;
reset role;
do $$
begin
  if (select resolved_by from public.takedown_requests where id = current_setting('test.r1')::uuid) <> current_setting('test.m')::uuid
     or (select resolved_at from public.takedown_requests where id = current_setting('test.r1')::uuid) is null
     or (select status from public.takedown_requests where id = current_setting('test.r2')::uuid) <> 'rejected' then
    raise exception 'FAIL 10 stored state';
  end if;
  if (select count(*) from public.moderation_actions
       where target_kind = 'takedown' and action in ('ncii_remove', 'ncii_reject', 'ncii_update')
         and target_id in (current_setting('test.r1')::uuid, current_setting('test.r2')::uuid, current_setting('test.r3')::uuid)) <> 6 then
    raise exception 'FAIL 10 log';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 11. Retention
-- ---------------------------------------------------------------------------
do $$
begin
  update public.takedown_requests set resolved_at = now() - interval '400 days' where id = current_setting('test.r2')::uuid;
  if public.purge_takedown_contacts() < 1 then
    raise exception 'FAIL 11 nothing purged';
  end if;
  if not exists (select 1 from public.takedown_requests
                  where id = current_setting('test.r2')::uuid and contact_cleared_at is not null
                    and requester_name = '' and requester_email = '' and email_hash = '' and signature = ''
                    and locations = '' and status = 'rejected')
     or exists (select 1 from public.takedown_requests
                 where id = current_setting('test.r1')::uuid and contact_cleared_at is not null) then
    raise exception 'FAIL 11 purge';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 12. Account deletion
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  perform public.request_account_deletion(null);
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true);
  perform public.request_account_deletion(null);
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.z'), 'role', 'authenticated')::text, true);
  perform public.request_account_deletion(null);
end $$;
reset role;
do $$
begin
  if exists (select 1 from public.takedown_requests where resolved_by = current_setting('test.m')::uuid)
     or (select status from public.takedown_requests where id = current_setting('test.r1')::uuid) <> 'removed' then
    raise exception 'FAIL 12 resolver stamp';
  end if;
  -- c's blocked copy stays as evidence; z's allowed picture goes, its blocked ones stay.
  if not exists (select 1 from public.image_hashes where owner_id = current_setting('test.c')::uuid and status = 'blocked')
     or exists (select 1 from public.image_hashes where owner_id = current_setting('test.z')::uuid and status <> 'blocked')
     or (select count(*) from public.image_hashes where owner_id = current_setting('test.z')::uuid and status = 'blocked') <> 2 then
    raise exception 'FAIL 12 image hashes';
  end if;
  if (select target_user_id from public.takedown_requests where id = current_setting('test.r1')::uuid) <> current_setting('test.u')::uuid then
    raise exception 'FAIL 12 request about u lost its target';
  end if;
end $$;

select 'ncii_takedown: PASS' as result;

rollback;
