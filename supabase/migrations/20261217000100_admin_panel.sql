-- ============================================================================
-- Activity Planet schema v2 — migration 53: admin panel v1
--   (PLAN.md 4.11 and the admin panel bullet; TRUST-SAFETY-LEGAL.md section
--   7, "24-hour report SLA and 48-hour NCII SLA visible in the admin queue";
--   ROADMAP week 6). Read-side RPCs for the moderator panel in apps/app:
--   one queue across every moderation source with SLA timers, a scorecard,
--   and an audit-logged user lookup. Every action still goes through the
--   existing RPCs (mod_moderate, mod_ban_user, mod_unban_user,
--   mod_takedown_*, mod_resolve_place, review_chapter_claim,
--   mod_review_source_candidate); nothing here changes what they do.
--   Rebuilt: request_account_deletion (migration 52 body plus the lookup
--   log rows, marked "Migration 53"). Checks: supabase/tests/admin_panel.sql.
--
--   What this file does
--     1. admin_lookups: one row per user search or profile opened in the
--        panel (moderator, how they searched, the handle typed when it was a
--        handle search, never an email, the person opened, how many
--        matched). Admins read it (mod_lookup_log); nobody writes it but
--        the lookup RPCs. Kept a year (pg_cron admin-lookups-purge).
--     2. mod_queue(limit): one list, most urgent first (priority, then due
--        time), across
--          report     open reports on a profile, plan, chapter or hub,
--                     grouped by target (due_at from report_content: 24
--                     hours, 4 for child safety)
--          takedown   open or waiting NCII requests (48 hours, 4 when a
--                     minor may be shown)
--          place_report  a place with open reports (24 hours; priority 1
--                     for private_residence or unsafe)
--          place      a pending public member place (72 hours)
--          place_edit a pending correction (72 hours)
--          claim      a pending chapter claim (72 hours)
--          calendar   a pending member calendar suggestion (7 days)
--        Each item: source, id, title, detail, priority, received_at,
--        due_at, overdue, minutes_left, count, can_act (false for the
--        moderator's own item, the second-moderator rule) and the target
--        reference the action page needs. Never reporter or requester ids.
--     3. mod_scorecard(): queue counts (open, overdue, due within 4 hours)
--        per source; SLA breaches in the last 30 days (closed after the due
--        time, plus open and overdue now); resolved in the last 7 days and
--        median hours to close in the last 30 for reports and takedowns;
--        moderation actions in the last 7 days; and platform numbers the
--        database knows (members, signups, banned, human-hosted plans,
--        plans with 4 or more check-ins, active chapters).
--     4. mod_user_search(query): by handle prefix (2+ characters, a leading
--        @ is ignored), by exact account email, or by user id; at most 20
--        rows of minimal fields (id, handle, first name, photo, status, join
--        date). Logged.
--     5. mod_user_lookup(user): one person's minimal record for a
--        moderation decision: public profile fields, status, moderation
--        state, account age, roles, counts (open reports about them and
--        their plans, reports they filed in 30 days, hosted and upcoming
--        plans, upcoming RSVPs, chapters they run, takedown requests about
--        them), the last 20 moderation actions about them, and whether the
--        caller may ban (the mod_ban_user rules). No email, birth date,
--        location, blocks or messages. Logged.
--     6. mod_lookup_log(limit): admins only, the newest lookups.
--     7. request_account_deletion: lookups the caller made lose the
--        moderator link; lookups about the caller stay (who opened which
--        tombstone, kept a year like the rest of the log).
--     * meta.schema_version 2.49.
--
--   SLA targets for the sources that have no due_at column live in
--   mod_sla_hours() so the queue and the scorecard agree.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. admin_lookups
-- ---------------------------------------------------------------------------
create table if not exists public.admin_lookups (
  id             uuid primary key default gen_random_uuid(),
  moderator_id   uuid references public.profiles (id) on delete set null,
  via            text not null,
  query          text,
  target_user_id uuid references public.profiles (id) on delete set null,
  result_count   integer not null default 0,
  created_at     timestamptz not null default now(),
  constraint admin_lookups_via check (via in ('handle', 'email', 'id', 'open')),
  constraint admin_lookups_query check (query is null or (via = 'handle' and char_length(query) <= 40))
);
create index if not exists admin_lookups_created_idx on public.admin_lookups (created_at);
create index if not exists admin_lookups_moderator_idx on public.admin_lookups (moderator_id)
  where moderator_id is not null;
create index if not exists admin_lookups_target_idx on public.admin_lookups (target_user_id)
  where target_user_id is not null;
comment on table public.admin_lookups is
  'Migration 53: audit log of the admin panel''s user lookup. One row per search (via handle, email or id; query holds the typed handle only, never an email) or profile opened (via open, target_user_id). Written only by mod_user_search and mod_user_lookup; admins read through mod_lookup_log. Purged after a year (admin-lookups-purge). Account deletion clears the moderator link.';

alter table public.admin_lookups enable row level security;
revoke all on public.admin_lookups from public, anon, authenticated;
grant all on public.admin_lookups to service_role;

-- ---------------------------------------------------------------------------
-- 2. SLA targets for sources without a due_at column
-- ---------------------------------------------------------------------------
create or replace function public.mod_sla_hours(p_source text)
returns integer language sql immutable set search_path = '' as $$
  select case p_source
           when 'place_report' then 24
           when 'place'        then 72
           when 'place_edit'   then 72
           when 'claim'        then 72
           when 'calendar'     then 168
         end;
$$;
comment on function public.mod_sla_hours(text) is
  'Migration 53, internal: review targets in hours for queue sources without a due_at column. place_report 24 (the report target), place and place_edit 72, claim 72, calendar 168. Reports and takedowns carry their own due_at.';

-- ---------------------------------------------------------------------------
-- 3. mod_queue
-- ---------------------------------------------------------------------------
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
             not bool_and(pr.reporter_id is not distinct from uid),
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
-- 4. mod_scorecard
-- ---------------------------------------------------------------------------
create or replace function public.mod_scorecard()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_soon timestamptz := now() + interval '4 hours';
  v_30   timestamptz := now() - interval '30 days';
  v_7    timestamptz := now() - interval '7 days';
  v_queues jsonb;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Open, overdue and due-soon counts per source, from the same rows mod_queue lists.
  with d as (
    select 'report'::text as source, min(r.due_at) as due_at
      from public.reports r where r.status = 'open' group by r.target_kind, r.target_id
    union all
    select 'takedown', t.due_at from public.takedown_requests t where t.status in ('open', 'waiting')
    union all
    select 'place_report', min(pr.created_at) + make_interval(hours => public.mod_sla_hours('place_report'))
      from public.place_reports pr join public.places pl on pl.id = pr.place_id
     where pr.status = 'open' group by pr.place_id
    union all
    select 'place', pl.created_at + make_interval(hours => public.mod_sla_hours('place'))
      from public.places pl where pl.source = 'user' and pl.is_public and pl.status = 'pending'
    union all
    select 'place_edit', pe.created_at + make_interval(hours => public.mod_sla_hours('place_edit'))
      from public.place_edits pe join public.places pl on pl.id = pe.place_id
     where pe.status = 'pending' and pl.status <> 'removed'
    union all
    select 'claim', cc.created_at + make_interval(hours => public.mod_sla_hours('claim'))
      from public.chapter_claims cc where cc.status = 'pending'
    union all
    select 'calendar', sc.created_at + make_interval(hours => public.mod_sla_hours('calendar'))
      from public.source_candidates sc where sc.review_status = 'pending'
  )
  select jsonb_object_agg(s.source, jsonb_build_object(
           'open',     (select count(*) from d where d.source = s.source),
           'overdue',  (select count(*) from d where d.source = s.source and d.due_at < now()),
           'due_soon', (select count(*) from d where d.source = s.source and d.due_at >= now() and d.due_at < v_soon)))
    into v_queues
    from unnest(array['report', 'takedown', 'place_report', 'place', 'place_edit', 'claim', 'calendar']) as s(source);

  return jsonb_build_object(
    'v', 1,
    'generated_at', now(),
    'queues', v_queues,
    -- Closed after the due time in the last 30 days; open_overdue is the same as queues.*.overdue.
    'breaches_30d', jsonb_build_object(
      'report', (select count(*) from public.reports r
                  where r.status <> 'open' and r.resolved_at >= v_30 and r.resolved_at > r.due_at),
      'takedown', (select count(*) from public.takedown_requests t
                    where t.status in ('removed', 'rejected') and t.resolved_at >= v_30 and t.resolved_at > t.due_at),
      'place_report', (select count(*) from public.place_reports pr
                        where pr.status <> 'open' and pr.resolved_at >= v_30
                          and pr.resolved_at > pr.created_at + make_interval(hours => public.mod_sla_hours('place_report'))),
      'place_edit', (select count(*) from public.place_edits pe
                      where pe.status in ('approved', 'rejected') and pe.reviewed_at >= v_30
                        and pe.reviewed_at > pe.created_at + make_interval(hours => public.mod_sla_hours('place_edit'))),
      'claim', (select count(*) from public.chapter_claims cc
                 where cc.status in ('approved', 'rejected') and cc.reviewed_at >= v_30
                   and cc.reviewed_at > cc.created_at + make_interval(hours => public.mod_sla_hours('claim'))),
      'calendar', (select count(*) from public.source_candidates sc
                    where sc.review_status in ('approved', 'rejected') and sc.origin = 'member' and sc.reviewed_at >= v_30
                      and sc.reviewed_at > sc.created_at + make_interval(hours => public.mod_sla_hours('calendar')))),
    'resolved_7d', jsonb_build_object(
      'report', (select count(*) from public.reports r where r.status <> 'open' and r.resolved_at >= v_7),
      'takedown', (select count(*) from public.takedown_requests t
                    where t.status in ('removed', 'rejected') and t.resolved_at >= v_7)),
    'median_hours_30d', jsonb_build_object(
      'report', (select round((percentile_cont(0.5) within group (
                                 order by (extract(epoch from (r.resolved_at - r.created_at)) / 3600)::double precision))::numeric, 1)
                   from public.reports r where r.status <> 'open' and r.resolved_at >= v_30),
      'takedown', (select round((percentile_cont(0.5) within group (
                                   order by (extract(epoch from (t.resolved_at - t.created_at)) / 3600)::double precision))::numeric, 1)
                     from public.takedown_requests t
                    where t.status in ('removed', 'rejected') and t.resolved_at >= v_30)),
    'actions_7d', coalesce((select jsonb_object_agg(a.action, a.n)
                              from (select ma.action, count(*) as n from public.moderation_actions ma
                                     where ma.created_at >= v_7 group by ma.action) a), '{}'::jsonb),
    'people', jsonb_build_object(
      'members', (select count(*) from public.profiles p
                   where p.status = 'active' and p.deleted_at is null and p.onboarding_completed_at is not null),
      'signups_7d', (select count(*) from public.profiles p where p.created_at >= v_7 and p.deleted_at is null),
      'banned', (select count(*) from public.profiles p where p.status = 'banned')),
    'plans', jsonb_build_object(
      'human_hosted_next_7d', (select count(*) from public.events e
                                where e.host_id is not null and e.status = 'published' and e.moderation_state is null
                                  and e.starts_at >= now() and e.starts_at < now() + interval '7 days'),
      'human_hosted_last_7d', (select count(*) from public.events e
                                where e.host_id is not null and e.status = 'published'
                                  and e.starts_at >= v_7 and e.starts_at < now()),
      'four_plus_checked_in_last_7d', (select count(*) from public.events e
                                        where e.host_id is not null and e.status = 'published'
                                          and e.starts_at >= v_7 and e.starts_at < now()
                                          and (select count(*) from public.rsvps r
                                                where r.event_id = e.id and r.checked_in_at is not null) >= 4)),
    'chapters_active', (select count(*) from public.hub_chapters c where c.is_active)
  );
end $$;
comment on function public.mod_scorecard() is
  'Migration 53, moderators: the admin panel scorecard. queues {source: {open, overdue, due_soon (4 hours)}} over the mod_queue sources; breaches_30d (closed after the due time in the last 30 days) per source; resolved_7d and median_hours_30d for reports and takedowns; actions_7d {action: n}; people {members, signups_7d, banned}; plans {human_hosted_next_7d, human_hosted_last_7d, four_plus_checked_in_last_7d}; chapters_active. Counts only, no rows.';

-- ---------------------------------------------------------------------------
-- 5. User search and lookup (logged)
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

  insert into public.admin_lookups (moderator_id, via, query, result_count)
  values (uid, v_via, case when v_via = 'handle' then v_q end, v_n);

  return v_rows;
end $$;
comment on function public.mod_user_search(text) is
  'Migration 53, moderators: find accounts by handle prefix (2 to 24 characters, a leading @ ignored), exact account email (the email is never returned or logged) or user id. Up to 20 rows {id, handle, first_name, avatar_url, status, joined_at}. Every search is logged in admin_lookups. Errors: not_authenticated, forbidden, invalid_query.';

create or replace function public.mod_user_lookup(p_user uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  p        public.profiles%rowtype;
  v_roles  text[];
  v_admin  boolean;
  v_can    boolean;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into p from public.profiles where id = p_user;
  if not found then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  insert into public.admin_lookups (moderator_id, via, target_user_id, result_count)
  values (uid, 'open', p.id, 1);

  select coalesce(array_agg(ur.role::text order by ur.role::text), '{}') into v_roles
    from public.user_roles ur where ur.user_id = p.id;
  v_admin := public.has_role('admin'::public.app_role);
  -- The mod_ban_user rules, so the panel only offers what the server allows.
  v_can := p.id <> uid and p.status not in ('deleted') and p.deleted_at is null
           and not ('admin' = any (v_roles))
           and (cardinality(v_roles) = 0 or v_admin)
           and not public.moderation_is_own('profile', p.id, p.id);

  return jsonb_build_object(
    'id', p.id,
    'handle', p.handle,
    'first_name', p.first_name,
    'avatar_url', p.avatar_url,
    'bio', p.bio,
    'status', p.status,
    'moderation_state', p.moderation_state,
    'joined_at', p.created_at,
    'account_days', greatest(0, (current_date - p.created_at::date)),
    'onboarded', p.onboarding_completed_at is not null,
    'roles', to_jsonb(v_roles),
    'counts', jsonb_build_object(
      'open_reports', (select count(*) from public.reports r
                        where r.status = 'open' and (r.target_user_id = p.id or (r.target_kind = 'profile' and r.target_id = p.id))),
      'reports_total', (select count(*) from public.reports r
                         where r.target_user_id = p.id or (r.target_kind = 'profile' and r.target_id = p.id)),
      'reports_filed_30d', (select count(*) from public.reports r
                             where r.reporter_id = p.id and r.created_at >= now() - interval '30 days'),
      'hosted_total', (select count(*) from public.events e where e.host_id = p.id),
      'hosted_upcoming', (select count(*) from public.events e
                           where e.host_id = p.id and e.status = 'published' and e.starts_at > now()),
      'rsvps_upcoming', (select count(*) from public.rsvps r join public.events e on e.id = r.event_id
                          where r.user_id = p.id and r.status <> 'cancelled' and e.status = 'published'
                            and e.starts_at > now()),
      'chapters_running', (select count(*) from public.chapter_members cm
                            where cm.user_id = p.id and cm.role in ('captain', 'organizer')),
      'takedowns_about', (select count(*) from public.takedown_requests t where t.target_user_id = p.id)),
    'actions', (select coalesce(jsonb_agg(jsonb_build_object(
                         'action', a.action, 'kind', a.target_kind, 'note', a.note, 'created_at', a.created_at,
                         'by_me', a.moderator_id is not distinct from uid, 'automatic', a.moderator_id is null
                                                                                         and a.action = 'auto_hide')
                       order by a.created_at desc), '[]'::jsonb)
                  from (select * from public.moderation_actions ma
                         where ma.target_user_id = p.id
                         order by ma.created_at desc limit 20) a),
    'is_self', p.id = uid,
    'can_ban', v_can and p.status <> 'banned',
    'can_unban', p.id <> uid and p.status = 'banned' and p.deleted_at is null
  );
end $$;
comment on function public.mod_user_lookup(uuid) is
  'Migration 53, moderators: one account''s minimal record for a moderation decision: id, handle, first_name, avatar_url, bio, status, moderation_state, joined_at, account_days, onboarded, roles, counts {open_reports, reports_total, reports_filed_30d, hosted_total, hosted_upcoming, rsvps_upcoming, chapters_running, takedowns_about}, the last 20 moderation actions about them {action, kind, note, created_at, by_me, automatic}, is_self, can_ban and can_unban (the mod_ban_user rules). Never email, birth date, location, blocks or messages. Logged in admin_lookups. Errors: not_authenticated, forbidden, user_not_found.';

create or replace function public.mod_lookup_log(p_limit integer default 100)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.has_role('admin'::public.app_role) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', l.id, 'created_at', l.created_at, 'via', l.via, 'query', l.query, 'result_count', l.result_count,
             'moderator', (select jsonb_build_object('id', m.id, 'handle', m.handle) from public.profiles m
                            where m.id = l.moderator_id),
             'target', (select jsonb_build_object('id', t.id, 'handle', t.handle) from public.profiles t
                         where t.id = l.target_user_id)) order by l.created_at desc)
      from (select * from public.admin_lookups a
             order by a.created_at desc
             limit least(greatest(coalesce(p_limit, 100), 1), 500)) l), '[]'::jsonb);
end $$;
comment on function public.mod_lookup_log(integer) is
  'Migration 53, admins: the newest admin panel lookups {id, created_at, via, query, result_count, moderator {id, handle}, target {id, handle}}. Errors: not_authenticated, forbidden.';

create or replace function public.purge_admin_lookups()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_n integer;
begin
  delete from public.admin_lookups where created_at < now() - interval '365 days';
  get diagnostics v_n = row_count;
  return v_n;
end $$;
comment on function public.purge_admin_lookups() is
  'Migration 53, pg_cron admin-lookups-purge daily: deletes lookup log rows older than a year.';

-- ---------------------------------------------------------------------------
-- 6. Account deletion (migration 52 body plus the lookup log)
-- ---------------------------------------------------------------------------
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
  'Deletes the caller''s account immediately (migrations 36, 51, 52 and 53): ledger row (a year for a banned account), tombstone profile, private data, memberships, claims, notifications, attendance, blocks, mutes, place and content reports unattributed, moderator stamps and admin lookups by the caller unattributed, image hashes (blocked ones kept), hosted series and future events cancelled (attendees notified), RSVPs removed (waitlists promoted), auth user banned. The delete-account Edge Function finishes. Idempotent.';

-- ---------------------------------------------------------------------------
-- 7. pg_cron
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; admin-lookups-purge not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'admin-lookups-purge') then
    perform cron.unschedule('admin-lookups-purge');
  end if;
  perform cron.schedule('admin-lookups-purge', '37 5 * * *', 'select public.purge_admin_lookups()');
end $$;

-- ---------------------------------------------------------------------------
-- 8. Privileges (explicit)
-- ---------------------------------------------------------------------------
revoke all on function public.mod_sla_hours(text) from public, anon, authenticated;
grant execute on function public.mod_sla_hours(text) to service_role;
revoke all on function public.purge_admin_lookups() from public, anon, authenticated;
-- Moderators (each refuses non-moderators with forbidden; mod_lookup_log is admins only).
revoke all on function public.mod_queue(integer) from public, anon;
grant execute on function public.mod_queue(integer) to authenticated;
revoke all on function public.mod_scorecard() from public, anon;
grant execute on function public.mod_scorecard() to authenticated;
revoke all on function public.mod_user_search(text) from public, anon;
grant execute on function public.mod_user_search(text) to authenticated;
revoke all on function public.mod_user_lookup(uuid) from public, anon;
grant execute on function public.mod_user_lookup(uuid) to authenticated;
revoke all on function public.mod_lookup_log(integer) from public, anon;
grant execute on function public.mod_lookup_log(integer) to authenticated;
-- Rebuilt.
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.49')
  on conflict (key) do update set value = excluded.value, updated_at = now();
