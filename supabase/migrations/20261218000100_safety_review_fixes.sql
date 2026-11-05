-- ============================================================================
-- Activity Planet schema v2 — migration 54: trust and safety review fixes
--   (PLAN.md 4.6 and 4.11; TRUST-SAFETY-LEGAL.md sections 3 and 7). Fixes
--   from the review of migrations 51 to 53. Rebuilt functions and policies
--   start from their latest bodies and each change is marked "Migration 54":
--   the profiles, hub_members, chapter_members and rsvps policies and
--   pending_attendance_prompts, report_content, moderation_is_own,
--   mod_ban_user (migration 51); is_chapter_captain (migration 6);
--   viewer_can_manage (migration 22); submit_takedown_request and
--   purge_takedown_contacts (migration 52); mod_queue and mod_user_search
--   (migration 53). Checks: supabase/tests/safety_review_fixes.sql.
--
--   What this file does
--     1. is_blocked_with moves to the private schema (not exposed by the
--        API). Called through PostgREST it told anyone whether a given
--        person had blocked them. The four policies and
--        pending_attendance_prompts call private.is_blocked_with;
--        public.is_blocked_with is dropped.
--     2. is_chapter_captain and viewer_can_manage need an active account,
--        so a banned or suspended captain or host manages nothing.
--     3. report_content: no auto-hide within 30 days of a moderator
--        dismissing or restoring the target (only a moderator hides it
--        again); reporters the target (or a captain or organizer of the
--        chapter) blocked do not count toward the three, though their
--        report is still filed; hidden in the answer says only whether this
--        report hid it; a hidden or removed plan the caller cannot read, and
--        an inactive chapter or hub, is target_not_found.
--     4. Second-moderator rule: moderation_is_own covers plans in a chapter
--        the moderator runs; mod_queue's place reports refuse a moderator
--        who filed any of the open reports.
--     5. mod_ban_user: every session ends (auth.sessions), chapter roles
--        drop to member (a chapter left without an organizer gets an open
--        report, no reporter, for a moderator to hand it over), and plans
--        already under way are cancelled with the upcoming ones.
--     6. mod_user_search: an email or id search records the matched account
--        in admin_lookups.target_user_id (the email is still never kept);
--        200 searches a day per moderator (rate_limited). Not audited:
--        moderators' direct table reads through their RLS branches
--        (profiles, rsvps, chapter_members and others); the panel uses the
--        logged RPCs, and docs/TRUST-SAFETY-LEGAL.md section 7 says so.
--     7. submit_takedown_request: service role only (the site's
--        /api/takedown route calls it after a Turnstile check); a new
--        p_client_hash (HMAC of the caller's IP, made by the route) caps a
--        client at 5 a day; the per-email and per-client counts take an
--        advisory lock; over 200 an hour overall a request is still taken,
--        at priority 2 instead of refused (same 48-hour due time).
--        takedown_requests.client_hash is cleared after two days.
--     8. purge_takedown_contacts also strips the moderator's free-text note
--        from the ncii_remove, ncii_reject and ncii_update log rows of
--        purged requests (the action word stays).
--     * meta.schema_version 2.50.
--
--   No new table references a user, so request_account_deletion is
--   unchanged (admin_lookups.target_user_id is already cleared by it).
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The block check moves out of the API (finding: block oracle)
-- ---------------------------------------------------------------------------
-- private is not in config.toml's exposed schemas, so PostgREST never offers
-- it as an RPC; the signed-in role still needs usage and execute because the
-- profiles, hub_members, chapter_members and rsvps policies call it.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

create or replace function private.is_blocked_with(p_other uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_other is not null and (select auth.uid()) is not null and exists (
    select 1 from public.blocks b
     where (b.blocker_id = (select auth.uid()) and b.blocked_id = p_other)
        or (b.blocker_id = p_other and b.blocked_id = (select auth.uid())));
$$;
comment on function private.is_blocked_with(uuid) is
  'Migration 54 (was public.is_blocked_with, migration 51): true when the signed-in caller blocked p_other or p_other blocked the caller. Only for RLS policies and definer read paths; not reachable through the API, so nobody can ask whether a given person blocked them.';
revoke all on function private.is_blocked_with(uuid) from public, anon;
grant execute on function private.is_blocked_with(uuid) to authenticated, service_role;

-- The four policies (migration 51 bodies; only the function's schema changes).

-- profiles (migration 22) plus: never a banned or hidden profile, never
-- across a block.
drop policy if exists "profiles_read_authenticated" on public.profiles;
create policy "profiles_read_authenticated" on public.profiles for select to authenticated
  using (
    id = (select auth.uid())
    or (select public.is_moderator())
    or (deleted_at is null and (select public.viewer_is_adult())
        -- Migration 51 (Migration 54: private.is_blocked_with)
        and status <> 'banned' and moderation_state is null
        and not private.is_blocked_with(id))
  );

-- hub_members (migration 22) plus blocks.
drop policy if exists "hub_members_read" on public.hub_members;
create policy "hub_members_read" on public.hub_members for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.is_moderator())
    or (
      (select public.viewer_is_adult())
      and not exists (
        select 1 from public.hubs h
        join public.hub_categories c on c.slug = h.category_slug
        where h.id = hub_members.hub_id and c.is_sensitive
      )
      -- Migration 51 (Migration 54: private.is_blocked_with)
      and not private.is_blocked_with(user_id)
    )
  );

-- chapter_members (migration 22) plus blocks.
drop policy if exists "chapter_members_read" on public.chapter_members;
create policy "chapter_members_read" on public.chapter_members for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.is_moderator())
    or (
      (select public.viewer_is_adult())
      and not exists (
        select 1 from public.hub_chapters ch
        join public.hubs h on h.id = ch.hub_id
        join public.hub_categories c on c.slug = h.category_slug
        where ch.id = chapter_members.chapter_id and c.is_sensitive
      )
      -- Migration 51 (Migration 54: private.is_blocked_with)
      and not private.is_blocked_with(user_id)
    )
  );

-- rsvps (migration 22) plus blocks.
drop policy if exists "rsvps_select" on public.rsvps;
create policy "rsvps_select" on public.rsvps for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.is_moderator())
    or (
      status <> 'cancelled'
      and (select public.viewer_is_adult())
      -- Migration 51 (Migration 54: private.is_blocked_with)
      and not private.is_blocked_with(user_id)
      and exists (
        select 1 from public.events e
          join public.hubs h on h.id = e.hub_id
          join public.hub_categories c on c.slug = h.category_slug
         where e.id = rsvps.event_id
           and (
             not c.is_sensitive
             or e.host_id = (select auth.uid())
             or public.is_chapter_captain(e.chapter_id)
             or public.viewer_is_attending(e.id)
           )
      )
    )
  );

-- pending_attendance_prompts (migration 51 body; only the block check moves).
create or replace function public.pending_attendance_prompts()
returns table (
  event_id      uuid,
  title         text,
  starts_at     timestamptz,
  ends_at       timestamptz,
  timezone      text,
  location_hint text,
  cover_url     text,
  hub_id        uuid,
  hub_slug      text,
  hub_name      text,
  hub_emoji     text,
  chapter_id    uuid,
  chapter_name  text,
  going_count   integer,
  checked_in    boolean,
  attendees     jsonb
)
language sql stable security definer set search_path = '' as $$
  select e.id, e.title, e.starts_at, e.ends_at, e.timezone, e.location_hint, e.cover_url,
         h.id, h.slug, h.name, h.emoji, e.chapter_id, ch.name, e.going_count,
         r.checked_in_at is not null,
         coalesce((
           select jsonb_agg(jsonb_build_object('id', p.id, 'first_name', p.first_name, 'avatar_url', p.avatar_url)
                            order by (o.checked_in_at is null), p.first_name, p.id)
             from public.rsvps o
             join public.profiles p on p.id = o.user_id and p.status = 'active'
            where o.event_id = e.id and o.status = 'going' and o.user_id <> r.user_id
              and not private.is_blocked_with(o.user_id)   -- Migration 51, Migration 54
         ), '[]'::jsonb)
    from public.rsvps r
    join public.events e on e.id = r.event_id
    join public.hubs h on h.id = e.hub_id
    left join public.hub_chapters ch on ch.id = e.chapter_id
   where r.user_id = (select auth.uid())
     and r.status = 'going'
     and e.status = 'published'
     and e.kind <> 'imported'
     and e.host_id is distinct from r.user_id
     and e.ends_at <= now()
     and e.ends_at > now() - interval '7 days'
     and not exists (select 1 from public.event_attendance_reports a
                      where a.event_id = r.event_id and a.user_id = r.user_id)
   order by e.ends_at desc, e.id
   limit 5;
$$;
comment on function public.pending_attendance_prompts() is
  'Up to 5 events (not imported, not hosted by the caller) that ended in the last 7 days where the caller was going and has neither answered nor dismissed, newest first. attendees: the other going people with an active profile and no block with the caller (migration 51; private.is_blocked_with since migration 54), [{id, first_name, avatar_url}], checked-in first.';

drop function if exists public.is_blocked_with(uuid);

-- ---------------------------------------------------------------------------
-- 2. Leadership needs an active account (finding: a ban leaves roles)
-- ---------------------------------------------------------------------------
create or replace function public.is_chapter_captain(p_chapter uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_chapter is not null and exists (
    select 1 from public.chapter_members
     where chapter_id = p_chapter and user_id = (select auth.uid())
       and role in ('captain', 'organizer')
  )
  -- Migration 54: a banned, suspended or deleted account runs nothing.
  and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.status = 'active');
$$;
comment on function public.is_chapter_captain(uuid) is
  'True when the caller is a captain or organizer of the chapter and their account is active (the status check since migration 54).';

create or replace function public.viewer_can_manage(p_host uuid, p_chapter uuid, p_min_age smallint)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and (
    public.is_moderator()
    or (
      (p_host = (select auth.uid()) or public.is_chapter_captain(p_chapter))
      and coalesce(public.viewer_age() >= p_min_age, false)
      -- Migration 54: never a banned or suspended account.
      and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.status = 'active')
    )
  );
$$;
comment on function public.viewer_can_manage(uuid, uuid, smallint) is
  'Manager rule for an event or series: a moderator, or the host or a captain/organizer of its chapter who is at least its min_age (migration 22) and whose account is active (migration 54).';

-- ---------------------------------------------------------------------------
-- 3. report_content (migration 51 body): auto-hide after a dismissal, blocked
--    reporters, and what the answer reveals
-- ---------------------------------------------------------------------------
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
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  -- Places keep their own reasons, rules and queue (migration 34).
  if p_kind = 'place' then
    return public.report_place(p_id, p_reason, p_note);
  end if;
  if p_kind is null or p_kind not in ('profile', 'event', 'chapter', 'hub') or p_id is null then
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
  'Migration 51 (54): report a profile, event, chapter or hub (kind place hands over to report_place). Reasons: harassment, hate, sexual_content, violence, spam, scam, impersonation, underage, unsafe, ncii, child_safety, other. One open report per person per target (a repeat returns already true). Hides a profile, plan or chapter pending review at three reports from different active accounts older than a day, not counting anyone the target (or a captain of the chapter) blocked, and never within 30 days of a moderator dismissing or restoring it. Returns {id, already, hidden}; hidden is true only when this report hid it. A plan the caller cannot read, and an inactive chapter or hub, is target_not_found. Errors: not_authenticated, invalid_kind, onboarding_required, invalid_reason, target_not_found, own_item, rate_limited (20 a day).';

-- ---------------------------------------------------------------------------
-- 4. Second-moderator rule gaps
-- ---------------------------------------------------------------------------
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
  );
$$;
comment on function public.moderation_is_own(text, uuid, uuid) is
  'Migration 51 (54), internal: the second-moderator rule. True when the target is the caller, the caller''s plan or a plan in a chapter the caller runs, a chapter the caller runs, or the caller filed an open report on it.';

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
comment on function public.mod_queue(integer) is
  'Migration 53, moderators: one queue across reports (grouped by target), NCII takedowns, place reports, pending public places, corrections, chapter claims and member calendar suggestions, most urgent first (priority, then due_at), up to p_limit (1 to 500, default 200). Each item: source, id, title, detail, priority, received_at, due_at, overdue, minutes_left, count, can_act (second-moderator rule), ref (what the action page needs). Due times: reports and takedowns their own due_at; the rest mod_sla_hours. Never reporter, proposer or requester ids.';


-- ---------------------------------------------------------------------------
-- 5. mod_ban_user (migration 51 body): roles, plans under way, sessions
-- ---------------------------------------------------------------------------
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

  update public.reports
     set status = 'actioned', resolved_by = uid, resolved_at = now()
   where target_kind = 'profile' and target_id = p_user and status = 'open';
  get diagnostics v_open = row_count;

  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, report_count, note)
  values (uid, 'ban', 'profile', p_user, p_user, v_open, v_note);

  return jsonb_build_object('banned', true, 'already', false, 'events_cancelled', cardinality(v_ids),
                            'rsvps_removed', v_rsvps, 'reports_closed', v_open,
                            'chapter_roles_removed', cardinality(v_chapters),             -- Migration 54
                            'chapters_need_organizer', cardinality(v_orphans));
end $$;
comment on function public.mod_ban_user(uuid, text) is
  'Migration 51 (54), moderators: bans an account. Profile status banned (reads and RSVPs close at once), sign-in blocked for 100 years and every session ended, roles removed, chapter roles dropped to member (a chapter left without an organizer gets an open report for a moderator), hosted plans that have not ended and series cancelled with the audience told, live RSVPs on upcoming plans removed (waitlist promoted), open reports on the profile actioned, logged. Only an admin bans a moderator; nobody bans an admin. Returns {banned, already, events_cancelled, rsvps_removed, reports_closed, chapter_roles_removed, chapters_need_organizer}. Errors: not_authenticated, forbidden, own_item, user_not_found, cannot_ban_admin.';

-- ---------------------------------------------------------------------------
-- 6. mod_user_search (migration 53 body): who was looked up, and a limit
-- ---------------------------------------------------------------------------
create or replace function public.mod_user_search(p_query text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_q     text := btrim(coalesce(p_query, ''));
  v_via   text;
  v_id    uuid;
  v_rows  jsonb;
  v_n     integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- Migration 54: 200 searches a day per moderator.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('admin_lookups:' || uid::text));
  if (select count(*) from public.admin_lookups a
       where a.moderator_id = uid and a.via <> 'open' and a.created_at > now() - interval '1 day') >= 200 then
    raise exception 'rate_limited' using errcode = 'check_violation', hint = 'Up to 200 searches a day.';
  end if;

  if v_q ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_via := 'id';
    v_id := v_q::uuid;
  elsif position('@' in v_q) > 1 then
    v_via := 'email';
    if char_length(v_q) > 254 then
      raise exception 'invalid_query' using errcode = '22023';
    end if;
    select u.id into v_id from auth.users u where lower(u.email) = lower(v_q) limit 1;
  else
    v_via := 'handle';
    v_q := lower(ltrim(v_q, '@'));
    if char_length(v_q) < 2 or char_length(v_q) > 24 or v_q !~ '^[a-z0-9_]+$' then
      raise exception 'invalid_query' using errcode = '22023';
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'handle', p.handle, 'first_name', p.first_name, 'avatar_url', p.avatar_url,
           'status', p.status, 'joined_at', p.created_at) order by lower(p.handle)), '[]'::jsonb),
         count(*)::integer
    into v_rows, v_n
    from (select * from public.profiles p
           where case when v_via = 'handle'
                      then lower(p.handle) like replace(v_q, '_', '\_') || '%'
                      else p.id = v_id end
           order by lower(p.handle)
           limit 20) p;

  -- Migration 54: an email or id search records the account it matched (the
  -- email itself is still never kept).
  insert into public.admin_lookups (moderator_id, via, query, target_user_id, result_count)
  values (uid, v_via, case when v_via = 'handle' then v_q end,
          case when v_via <> 'handle' and v_n > 0 then v_id end, v_n);

  return v_rows;
end $$;
comment on function public.mod_user_search(text) is
  'Migration 53 (54), moderators: find accounts by handle prefix (2 to 24 characters, a leading @ ignored), exact account email (the email is never returned or logged) or user id. Up to 20 rows {id, handle, first_name, avatar_url, status, joined_at}. Every search is logged in admin_lookups; an email or id search also records the account it matched. 200 searches a day per moderator. Errors: not_authenticated, forbidden, invalid_query, rate_limited.';

-- ---------------------------------------------------------------------------
-- 7. The public NCII request: service role, per-client limit, no lockout
-- ---------------------------------------------------------------------------
alter table public.takedown_requests add column if not exists client_hash text;
alter table public.takedown_requests drop constraint if exists takedown_requests_client_hash;
alter table public.takedown_requests add constraint takedown_requests_client_hash
  check (client_hash is null or client_hash ~ '^[0-9a-f]{64}$');
create index if not exists takedown_requests_client_idx on public.takedown_requests (client_hash, created_at)
  where client_hash is not null;
comment on column public.takedown_requests.client_hash is
  'Migration 54: HMAC-SHA256 of the submitting client''s IP address, made by the site''s /api/takedown route (never the address). Used only for the 5-a-day per-client limit; cleared after two days by purge_takedown_contacts.';

drop function if exists public.submit_takedown_request(text, text, text, text, boolean, text, text, boolean);
create or replace function public.submit_takedown_request(
  p_name text, p_email text, p_relationship text, p_locations text, p_good_faith boolean, p_signature text,
  p_description text default '', p_involves_minor boolean default false, p_client_hash text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_name      text := left(btrim(coalesce(p_name, '')), 200);
  v_email     text := lower(btrim(coalesce(p_email, '')));
  v_locations text := btrim(coalesce(p_locations, ''));
  v_desc      text := btrim(coalesce(p_description, ''));
  v_sig       text := btrim(coalesce(p_signature, ''));
  v_minor     boolean := coalesce(p_involves_minor, false);
  v_client    text := nullif(lower(btrim(coalesce(p_client_hash, ''))), '');   -- Migration 54
  v_priority  smallint;                                                       -- Migration 54
  v_hash      text;
  v_ref       text;
  v_due       timestamptz;
begin
  if char_length(v_name) < 2 then
    raise exception 'name_required' using errcode = '22023';
  end if;
  if char_length(v_email) > 254 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'invalid_email' using errcode = '22023';
  end if;
  if coalesce(p_relationship, '') not in ('self', 'authorized') then
    raise exception 'invalid_relationship' using errcode = '22023';
  end if;
  if char_length(v_locations) < 3 then
    raise exception 'location_required' using errcode = '22023';
  end if;
  if char_length(v_locations) > 4000 or char_length(v_desc) > 2000 then
    raise exception 'too_long' using errcode = '22023';
  end if;
  if not coalesce(p_good_faith, false) then
    raise exception 'good_faith_required' using errcode = '22023';
  end if;
  if char_length(v_sig) < 2 or char_length(v_sig) > 200 then
    raise exception 'signature_required' using errcode = '22023';
  end if;
  -- Migration 54
  if v_client is not null and v_client !~ '^[0-9a-f]{64}$' then
    raise exception 'bad_request' using errcode = '22023';
  end if;

  v_hash := encode(extensions.digest(v_email, 'sha256'), 'hex');
  -- Migration 54: one request at a time per email and per client, so parallel
  -- calls cannot slip past the counts (always email first, then client).
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('takedown:' || v_hash));
  if v_client is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('takedown-client:' || v_client));
  end if;
  if (select count(*) from public.takedown_requests t
       where t.email_hash = v_hash and t.created_at > now() - interval '1 day') >= 3
     -- Migration 54: 5 a day per client.
     or (v_client is not null
         and (select count(*) from public.takedown_requests t
               where t.client_hash = v_client and t.created_at > now() - interval '1 day') >= 5) then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  -- Migration 54: over 200 an hour overall a request is still taken, at a
  -- lower priority, so a flood cannot shut the form for real requests. The
  -- due time does not change.
  v_priority := case
    when v_minor then 0
    when (select count(*) from public.takedown_requests t where t.created_at > now() - interval '1 hour') >= 200 then 2
    else 1 end;

  loop
    v_ref := 'NCII-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.takedown_requests t where t.reference = v_ref);
  end loop;
  v_due := now() + case when v_minor then interval '4 hours' else interval '48 hours' end;

  insert into public.takedown_requests (reference, requester_name, requester_email, email_hash, relationship,
                                        locations, description, good_faith, signature, involves_minor,
                                        priority, due_at, client_hash)
  values (v_ref, v_name, v_email, v_hash, p_relationship, v_locations, v_desc, true, v_sig, v_minor,
          v_priority, v_due, v_client);
  return jsonb_build_object('reference', v_ref, 'due_at', v_due);
end $$;
comment on function public.submit_takedown_request(text, text, text, text, boolean, text, text, boolean, text) is
  'Migration 52 (54), service role only (the site''s /api/takedown route, after its Turnstile check): files a request to remove non-consensual intimate imagery. Requires a name, a contact email, relationship self | authorized, where the image is, the good-faith statement and a typed signature. 3 a day per email address and 5 a day per p_client_hash (rate_limited); over 200 an hour overall a request is still taken at priority 2. Returns {reference, due_at}: 48 hours, or 4 hours when the person shown may be under 18. Errors also: bad_request (a malformed client hash).';

-- ---------------------------------------------------------------------------
-- 8. Retention (migration 52 body plus log notes and client hashes)
-- ---------------------------------------------------------------------------
create or replace function public.purge_takedown_contacts()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_n integer;
begin
  update public.takedown_requests
     set requester_name = '', requester_email = '', email_hash = '', signature = '', locations = '', description = '',
         resolution_note = '', contact_cleared_at = now(), updated_at = now()
   where status in ('removed', 'rejected') and resolved_at < now() - interval '365 days'
     and contact_cleared_at is null;
  get diagnostics v_n = row_count;
  -- Migration 54: the moderator's free text in the log goes with the request's
  -- (it may name the requester); the action word before the colon stays.
  update public.moderation_actions ma
     set note = split_part(ma.note, ':', 1)
    from public.takedown_requests t
   where ma.target_kind = 'takedown' and ma.target_id = t.id and t.contact_cleared_at is not null
     and ma.action in ('ncii_remove', 'ncii_reject', 'ncii_update')
     and position(':' in ma.note) > 0;
  -- Migration 54: the per-client hash is kept two days.
  update public.takedown_requests
     set client_hash = null
   where client_hash is not null and created_at < now() - interval '2 days';
  return v_n;
end $$;
comment on function public.purge_takedown_contacts() is
  'Migration 52 (54), pg_cron takedown-contacts-purge daily: clears the requester''s name, email, signature and the free text of requests closed more than a year ago, and the moderator''s note on their ncii_remove, ncii_reject and ncii_update log rows (the action word stays). The email hash (used only for the daily rate limit) goes too. Client hashes older than two days are cleared. The reference, dates, outcome and image hashes stay.';

-- ---------------------------------------------------------------------------
-- 9. Privileges (explicit)
-- ---------------------------------------------------------------------------
-- The public form now goes through the site's route with the service role.
revoke all on function public.submit_takedown_request(text, text, text, text, boolean, text, text, boolean, text)
  from public, anon, authenticated;
grant execute on function public.submit_takedown_request(text, text, text, text, boolean, text, text, boolean, text)
  to service_role;
revoke all on function public.purge_takedown_contacts() from public, anon, authenticated;
-- Rebuilt functions keep their grants (create or replace does not change
-- them); restated here.
revoke all on function public.is_chapter_captain(uuid) from public, anon;
grant execute on function public.is_chapter_captain(uuid) to authenticated;
revoke all on function public.viewer_can_manage(uuid, uuid, smallint) from public, anon;
grant execute on function public.viewer_can_manage(uuid, uuid, smallint) to authenticated, service_role;
revoke all on function public.report_content(text, uuid, text, text) from public, anon;
grant execute on function public.report_content(text, uuid, text, text) to authenticated;
revoke all on function public.moderation_is_own(text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.moderation_is_own(text, uuid, uuid) to service_role;
revoke all on function public.mod_ban_user(uuid, text) from public, anon;
grant execute on function public.mod_ban_user(uuid, text) to authenticated;
revoke all on function public.mod_queue(integer) from public, anon;
grant execute on function public.mod_queue(integer) to authenticated;
revoke all on function public.mod_user_search(text) from public, anon;
grant execute on function public.mod_user_search(text) to authenticated;
revoke all on function public.pending_attendance_prompts() from public, anon;
grant execute on function public.pending_attendance_prompts() to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.50')
  on conflict (key) do update set value = excluded.value, updated_at = now();
