-- ============================================================================
-- Activity Planet schema v2 — migration 51: trust and safety, part 1
--   (PLAN.md 4.6 safety bullet and 4.11; TRUST-SAFETY-LEGAL.md section 7;
--   ROADMAP week 6). Blocks, mutes, one report table for people, plans,
--   chapters and hubs (places keep place_reports and report_place, reached
--   through the same report_content entry point), auto-hide at three
--   reports, moderator hide / soft delete / restore, ban and unban, and an
--   admin-granted moderator role for the second moderator.
--   Rebuilt functions start from their latest bodies and each change is
--   marked "Migration 51": can_read_event (migration 22), event_share_card
--   (migration 9), chapter_public_card (migration 17), enqueue_notification
--   (migration 19), pending_attendance_prompts (migration 20),
--   request_account_deletion (migration 36). Rebuilt policies start from
--   migration 22 (profiles, hub_members, chapter_members, rsvps,
--   events_select_authenticated) and migration 6 (events_select_anon).
--   Checks: supabase/tests/trust_safety.sql.
--
--   What this file does
--     1. blocks (blocker_id, blocked_id) and mutes (muter_id, muted_id). Both
--        owner-select only, written by RPCs. A block is symmetric: neither
--        person sees the other's profile, RSVP rows, hub or chapter
--        membership rows, "who did you meet" list entries or social
--        notifications. A mute is one-sided and silent: the muter stops
--        getting attendee_joined (and later hub_new_event and message)
--        notifications that name the muted person. is_blocked_with(user)
--        answers for the caller only (no list of who blocked you).
--     2. Moderation state: profiles, events, hubs and hub_chapters gain
--        moderation_state ('hidden' | 'removed' | null) and moderated_at.
--        A hidden or removed plan is readable only by its host and
--        moderators (events policies, can_read_event, event_share_card,
--        chapter_public_card's count) and cannot take new RSVPs. A hidden
--        profile is readable only by its owner and moderators. A hidden or
--        removed hub or chapter is also made inactive (every existing read
--        path already honours is_active); restoring makes it active again.
--     3. reports: one row per person per target (profile, event, chapter,
--        hub) while open; reason from a fixed list; note up to 1000
--        characters; priority and due_at give the SLA (child_safety 4
--        hours, ncii and underage 24 hours at priority 1, the rest 24
--        hours). report_content(kind, id, reason, note) files one (kind
--        'place' hands over to report_place unchanged); 20 a day per person
--        across kinds, moderators exempt.
--     4. Auto-hide at N = 3: when three different active accounts older
--        than a day, none of them the target, have open reports on a
--        profile, plan or chapter, it is hidden pending review and the
--        action is logged with no moderator. Hubs (the moderator-curated
--        catalog) are never auto-hidden. Why 3: it matches the hub map's
--        rule (migration 34), one or two reports are too easy for a single
--        grudge or a pair of friends, the step is reversible (dismiss
--        restores it), new accounts do not count, and at launch volume a
--        moderator sees every report inside the 24-hour target anyway.
--     5. moderation_actions: the log of every hide, remove, restore,
--        dismiss, auto-hide, ban, unban and role change, with an optional
--        moderator-only snapshot of removed profile content.
--     6. Moderator RPCs (refuse non-moderators with forbidden):
--        mod_report_queue(limit), mod_moderate(kind, id, action, note) with
--        dismiss | hide | remove | restore, mod_ban_user(user, note),
--        mod_unban_user(user, note), mod_team(). Second-moderator rule: a
--        moderator never acts on reports about themselves, their own plan,
--        a chapter they run, or reports they filed (own_item); only an
--        admin bans a moderator, and nobody bans an admin.
--        admin_set_moderator(user, grant, note) is admin only.
--        Soft delete: a removed profile loses its photo and bio (kept in
--        the log's snapshot); a removed plan is cancelled if it is still
--        upcoming (its attendees hear "taken down by our moderators") and
--        stays readable by its host; a removed hub or chapter goes
--        inactive. Nothing is hard-deleted.
--        Ban: profile status 'banned' (viewer_is_adult() is false at once,
--        so every read and RSVP path closes), auth.users.banned_until 100
--        years, roles removed, hosted upcoming plans and series cancelled
--        with the audience told, live RSVPs on upcoming plans removed with
--        the waitlist promoted, open reports on the profile actioned.
--     7. Member RPCs: block_user, unblock_user, my_blocks, mute_user,
--        unmute_user, event_block_warning(event) (how many people the
--        caller blocked are on this plan; never the other direction).
--     8. Co-attendance warning: when someone RSVPs to an upcoming plan, a
--        person there who blocked them (host or live RSVP) gets a
--        'blocked_attendee' notification, and so does the newcomer if they
--        blocked someone already there. One per plan per person. New
--        notification_kind value 'blocked_attendee' (follows only the
--        channel switches, like other safety and transactional notices).
--     9. enqueue_notification: a block between recipient and actor drops
--        attendee_joined and hub_new_event and strips the actor from
--        everything else (cancellations still arrive); a mute drops
--        attendee_joined and hub_new_event.
--    10. event_meets: a block deletes the pair's meets both ways and a
--        trigger drops new ones; pending_attendance_prompts leaves blocked
--        people out of the attendee list.
--    11. request_account_deletion: blocks and mutes in either direction go;
--        reports the caller filed lose the reporter and the note; resolver
--        and moderator stamps naming the caller are cleared; profile
--        snapshots about the caller are cleared. Reports about the caller
--        and the action log stay (moderation evidence, TRUST-SAFETY-LEGAL
--        section 11). A banned account that is deleted keeps its ledger row
--        for a year instead of 30 days.
--     * meta.schema_version 2.47.
--
--   Not here: the admin panel, NCII requests and perceptual hashes, the
--   Safety Center page, messaging (release B builds on blocks and mutes).
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Enum value and moderation columns
-- ---------------------------------------------------------------------------
alter type public.notification_kind add value if not exists 'blocked_attendee';

alter table public.profiles     add column if not exists moderation_state text;
alter table public.profiles     add column if not exists moderated_at     timestamptz;
alter table public.events       add column if not exists moderation_state text;
alter table public.events       add column if not exists moderated_at     timestamptz;
alter table public.hubs         add column if not exists moderation_state text;
alter table public.hubs         add column if not exists moderated_at     timestamptz;
alter table public.hub_chapters add column if not exists moderation_state text;
alter table public.hub_chapters add column if not exists moderated_at     timestamptz;
do $$ begin
  alter table public.profiles add constraint profiles_moderation_state
    check (moderation_state is null or moderation_state in ('hidden', 'removed'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.events add constraint events_moderation_state
    check (moderation_state is null or moderation_state in ('hidden', 'removed'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.hubs add constraint hubs_moderation_state
    check (moderation_state is null or moderation_state in ('hidden', 'removed'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.hub_chapters add constraint hub_chapters_moderation_state
    check (moderation_state is null or moderation_state in ('hidden', 'removed'));
exception when duplicate_object then null; end $$;
create index if not exists events_moderation_state_idx on public.events (moderated_at) where moderation_state is not null;
comment on column public.profiles.moderation_state is
  'Migration 51: hidden = held for review after reports (readable only by the owner and moderators); null = normal. A removed profile has its photo and bio cleared and goes back to null.';
comment on column public.events.moderation_state is
  'Migration 51: hidden (held for review) or removed (moderator soft delete; an upcoming plan is also cancelled). Either way readable only by the host and moderators, and closed to new RSVPs.';
comment on column public.hubs.moderation_state is
  'Migration 51: hidden or removed by a moderator; the hub is also inactive. Hubs are never auto-hidden.';
comment on column public.hub_chapters.moderation_state is
  'Migration 51: hidden (after reports or by a moderator) or removed; the chapter is also inactive until restored.';
-- anon reads hub_chapters by column list (migration 17); the new columns stay
-- out of it. hubs, events and profiles are granted table-wide already.

-- ---------------------------------------------------------------------------
-- 2. blocks and mutes
-- ---------------------------------------------------------------------------
create table if not exists public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint blocks_not_self check (blocker_id <> blocked_id)
);
create index if not exists blocks_blocked_idx on public.blocks (blocked_id, blocker_id);
comment on table public.blocks is
  'Symmetric blocks (PLAN 4.6, TRUST-SAFETY-LEGAL 7). The blocker reads their own rows; written only by block_user and unblock_user. Read paths call is_blocked_with(). Both directions are deleted with either account.';

create table if not exists public.mutes (
  muter_id   uuid not null references public.profiles (id) on delete cascade,
  muted_id   uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (muter_id, muted_id),
  constraint mutes_not_self check (muter_id <> muted_id)
);
create index if not exists mutes_muted_idx on public.mutes (muted_id);
comment on table public.mutes is
  'One-sided, silent mutes: the muter stops getting social notifications that name the muted person. Owner-select only; written by mute_user and unmute_user; deleted with either account.';

alter table public.blocks enable row level security;
alter table public.mutes  enable row level security;
revoke all on public.blocks, public.mutes from public, anon, authenticated;
grant select on public.blocks, public.mutes to authenticated;
grant all on public.blocks, public.mutes to service_role;
drop policy if exists "blocks_select_own" on public.blocks;
create policy "blocks_select_own" on public.blocks for select to authenticated
  using (blocker_id = (select auth.uid()));
drop policy if exists "mutes_select_own" on public.mutes;
create policy "mutes_select_own" on public.mutes for select to authenticated
  using (muter_id = (select auth.uid()));

-- Whether the caller and p_other are in a block, either direction. Says
-- nothing the caller cannot already tell from a profile they cannot read.
create or replace function public.is_blocked_with(p_other uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_other is not null and (select auth.uid()) is not null and exists (
    select 1 from public.blocks b
     where (b.blocker_id = (select auth.uid()) and b.blocked_id = p_other)
        or (b.blocker_id = p_other and b.blocked_id = (select auth.uid())));
$$;
comment on function public.is_blocked_with(uuid) is
  'Migration 51: true when the signed-in caller blocked p_other or p_other blocked the caller. Used by the profiles, rsvps, hub_members and chapter_members policies and by definer read paths.';

-- Internal: a block between two given people, either direction.
create or replace function public.users_blocked(p_a uuid, p_b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_a is not null and p_b is not null and exists (
    select 1 from public.blocks b
     where (b.blocker_id = p_a and b.blocked_id = p_b) or (b.blocker_id = p_b and b.blocked_id = p_a));
$$;
comment on function public.users_blocked(uuid, uuid) is
  'Migration 51, internal: a block between p_a and p_b in either direction.';

-- ---------------------------------------------------------------------------
-- 3. reports and moderation_actions
-- ---------------------------------------------------------------------------
create table if not exists public.reports (
  id             uuid primary key default gen_random_uuid(),
  reporter_id    uuid references public.profiles (id) on delete set null,
  target_kind    text not null,
  target_id      uuid not null,
  target_user_id uuid references public.profiles (id) on delete set null,
  reason         text not null,
  note           text not null default '',
  status         text not null default 'open',
  priority       smallint not null default 2,
  due_at         timestamptz not null default now() + interval '24 hours',
  resolved_by    uuid references public.profiles (id) on delete set null,
  resolved_at    timestamptz,
  created_at     timestamptz not null default now(),
  constraint reports_target_kind check (target_kind in ('profile', 'event', 'chapter', 'hub')),
  constraint reports_reason check (reason in ('harassment', 'hate', 'sexual_content', 'violence', 'spam', 'scam',
                                              'impersonation', 'underage', 'unsafe', 'ncii', 'child_safety', 'other')),
  constraint reports_status check (status in ('open', 'actioned', 'dismissed')),
  constraint reports_priority check (priority between 0 and 2),
  constraint reports_note_length check (char_length(note) <= 1000)
);
create unique index if not exists reports_one_open on public.reports (target_kind, target_id, reporter_id)
  where status = 'open';
create index if not exists reports_queue_idx on public.reports (target_kind, target_id, created_at) where status = 'open';
create index if not exists reports_due_idx on public.reports (priority, due_at) where status = 'open';
create index if not exists reports_reporter_idx on public.reports (reporter_id, created_at) where reporter_id is not null;
create index if not exists reports_target_user_idx on public.reports (target_user_id) where target_user_id is not null;
create index if not exists reports_resolved_by_idx on public.reports (resolved_by) where resolved_by is not null;
comment on table public.reports is
  'Reports on people, plans, chapters and hubs (migration 51; places use place_reports). One open report per person per target. priority 0 = child safety (due in 4 hours), 1 = NCII or underage (24 hours), 2 = the rest (24 hours). Reporters read their own rows without the reporter or resolver ids; moderators read through mod_report_queue. Written only by report_content and the moderation RPCs. Kept after the target''s account is deleted (evidence); a deleted reporter''s rows lose the reporter and the note.';

create table if not exists public.moderation_actions (
  id             uuid primary key default gen_random_uuid(),
  moderator_id   uuid references public.profiles (id) on delete set null,
  action         text not null,
  target_kind    text not null,
  target_id      uuid not null,
  target_user_id uuid references public.profiles (id) on delete set null,
  report_count   integer not null default 0,
  note           text,
  snapshot       jsonb,
  created_at     timestamptz not null default now(),
  constraint moderation_actions_action check (action in ('auto_hide', 'dismiss', 'hide', 'remove', 'restore', 'ban',
                                                         'unban', 'grant_moderator', 'revoke_moderator')),
  constraint moderation_actions_kind check (target_kind in ('profile', 'event', 'chapter', 'hub')),
  constraint moderation_actions_note_length check (note is null or char_length(note) <= 500),
  constraint moderation_actions_snapshot check (snapshot is null or jsonb_typeof(snapshot) = 'object')
);
create index if not exists moderation_actions_target_idx on public.moderation_actions (target_kind, target_id, created_at);
create index if not exists moderation_actions_moderator_idx on public.moderation_actions (moderator_id)
  where moderator_id is not null;
create index if not exists moderation_actions_target_user_idx on public.moderation_actions (target_user_id)
  where target_user_id is not null;
comment on table public.moderation_actions is
  'Moderation log (migration 51): every hide, remove, restore, dismiss, auto_hide (moderator_id null), ban, unban and moderator grant or revoke. snapshot holds what a removal cleared (a profile''s photo URL and bio). Moderators read; written only by the moderation RPCs. Account deletion clears the moderator link and snapshots about the deleted person.';

alter table public.reports            enable row level security;
alter table public.moderation_actions enable row level security;
revoke all on public.reports, public.moderation_actions from public, anon, authenticated;
grant all on public.reports, public.moderation_actions to service_role;
grant select (id, target_kind, target_id, reason, note, status, priority, due_at, resolved_at, created_at)
  on public.reports to authenticated;
grant select on public.moderation_actions to authenticated;
drop policy if exists "reports_select" on public.reports;
create policy "reports_select" on public.reports for select to authenticated
  using (reporter_id = (select auth.uid()) or (select public.is_moderator()));
drop policy if exists "moderation_actions_select_mod" on public.moderation_actions;
create policy "moderation_actions_select_mod" on public.moderation_actions for select to authenticated
  using ((select public.is_moderator()));

-- ---------------------------------------------------------------------------
-- 4. Read paths: policies
-- ---------------------------------------------------------------------------
-- profiles (migration 22) plus: never a banned or hidden profile, never
-- across a block.
drop policy if exists "profiles_read_authenticated" on public.profiles;
create policy "profiles_read_authenticated" on public.profiles for select to authenticated
  using (
    id = (select auth.uid())
    or (select public.is_moderator())
    or (deleted_at is null and (select public.viewer_is_adult())
        -- Migration 51
        and status <> 'banned' and moderation_state is null
        and not public.is_blocked_with(id))
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
      -- Migration 51
      and not public.is_blocked_with(user_id)
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
      -- Migration 51
      and not public.is_blocked_with(user_id)
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
      -- Migration 51
      and not public.is_blocked_with(user_id)
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

-- events (migration 6 for anon, 22 for authenticated) plus moderation.
drop policy if exists "events_select_anon" on public.events;
create policy "events_select_anon" on public.events for select to anon
  using (status = 'published' and visibility = 'public' and min_age = 18
         and moderation_state is null);   -- Migration 51
drop policy if exists "events_select_authenticated" on public.events;
create policy "events_select_authenticated" on public.events for select to authenticated
  using (
    host_id = (select auth.uid())
    or (select public.is_moderator())
    or (
      moderation_state is null   -- Migration 51
      and ((status = 'published' and (select public.viewer_is_adult())) or public.viewer_has_rsvp(id))
      and min_age <= (select public.viewer_age())
      and (visibility = 'public' or public.is_campus_org_member(campus_id))
    )
  );

-- ---------------------------------------------------------------------------
-- 5. Read paths: rebuilt definer functions
-- ---------------------------------------------------------------------------
create or replace function public.can_read_event(p_event uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.events e
     where e.id = p_event
       and (
         e.host_id = (select auth.uid())
         or public.is_moderator()
         or (
           e.moderation_state is null   -- Migration 51
           and ((e.status = 'published' and public.viewer_is_adult()) or public.viewer_has_rsvp(e.id))
           and e.min_age <= public.viewer_age()
           and (e.visibility = 'public' or public.is_campus_org_member(e.campus_id))
         )
       )
  );
$$;

create or replace function public.event_share_card(p_event_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
           when e.visibility = 'public' and e.min_age = 18 then
             jsonb_build_object(
               'id', e.id,
               'kind', e.kind,
               'title', e.title,
               'description', e.description,
               'cover_url', e.cover_url,
               'starts_at', e.starts_at,
               'ends_at', e.ends_at,
               'timezone', e.timezone,
               'min_age', e.min_age,
               'capacity', e.capacity,
               'min_headcount', e.min_headcount,
               'is_free', e.is_free,
               'price_text', e.price_text,
               'location_hint', e.location_hint,
               'approx_lat', e.approx_lat,
               'approx_lng', e.approx_lng,
               'going_count', e.going_count,
               'interested_count', e.interested_count,
               'external_url', e.external_url,
               'source_name', e.source_name,
               'series_id', e.series_id,
               'hub', jsonb_build_object('id', h.id, 'slug', h.slug, 'name', h.name, 'emoji', h.emoji),
               'chapter', case when ch.id is not null then jsonb_build_object('id', ch.id, 'slug', ch.slug, 'name', ch.name) end,
               'host', case when p.id is not null
                            then jsonb_build_object('handle', p.handle, 'first_name', p.first_name, 'avatar_url', p.avatar_url) end
             )
           else
             jsonb_build_object(
               'id', e.id,
               'restricted', case when e.visibility = 'campus' then 'campus' else 'age' end,
               'hub_name', h.name
             )
         end
    from public.events e
    join public.hubs h on h.id = e.hub_id
    left join public.hub_chapters ch on ch.id = e.chapter_id
    left join public.profiles p on p.id = e.host_id
   where e.id = p_event_id
     and e.status = 'published'
     and e.moderation_state is null   -- Migration 51
     and h.is_active
     and (e.host_id is null or p.status = 'active');
$$;

create or replace function public.chapter_public_card(p_chapter text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_key text := lower(btrim(coalesce(p_chapter, '')));
  v_id  uuid;
  v_out jsonb;
begin
  if v_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_id := v_key::uuid;
  else
    select id into v_id from public.hub_chapters where slug = v_key;
  end if;
  if v_id is null then
    return null;
  end if;

  select jsonb_build_object(
           'id', c.id,
           'slug', c.slug,
           'name', c.name,
           'description', c.description,
           'cover_url', c.cover_url,
           'hub', jsonb_build_object('id', h.id, 'slug', h.slug, 'name', h.name, 'emoji', h.emoji),
           'owner_kind', case when c.org_id is not null then 'org' else 'area' end,
           'org', case when o.id is not null then jsonb_build_object('slug', o.slug, 'name', o.name) end,
           'campus', case when oc.id is not null then jsonb_build_object('slug', oc.slug, 'name', oc.name) end,
           'area', case when ar.id is not null then jsonb_build_object('slug', ar.slug, 'name', ar.name) end,
           'place_label', coalesce(oc.name, o.name, ar.name),
           'rso_name', c.rso_name,
           'pin_url', c.pin_url,
           'verified', c.verified_at is not null
                       and exists (select 1 from public.chapter_members om
                                    where om.chapter_id = c.id and om.role = 'organizer'),
           'member_count', (select count(*) from public.chapter_members cm where cm.chapter_id = c.id),
           'upcoming_public_events', (select count(*) from public.events e
                                       where e.chapter_id = c.id and e.status = 'published'
                                         and e.visibility = 'public' and e.starts_at > now()
                                         and e.moderation_state is null)   -- Migration 51
         )
    into v_out
    from public.hub_chapters c
    join public.hubs h on h.id = c.hub_id
    left join public.organizations o on o.id = c.org_id
    left join public.org_campuses oc on oc.id = c.campus_id
    left join public.areas ar on ar.id = c.area_id
   where c.id = v_id and c.is_active and h.is_active;
  return v_out;
end $$;

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
      if p_kind in ('attendee_joined', 'hub_new_event') then
        return null;
      end if;
      p_actor_id := null;
    elsif p_kind in ('attendee_joined', 'hub_new_event')
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
    else true
  end;
  v_email := case when np.unsubscribed_all_at is not null or not coalesce(np.email_enabled, true) or not v_topic
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

  if p_batch then
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
              and not public.is_blocked_with(o.user_id)   -- Migration 51
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

-- ---------------------------------------------------------------------------
-- 6. Guards on rsvps and event_meets
-- ---------------------------------------------------------------------------
-- A hidden or removed plan takes no new RSVPs (set_rsvp bypasses RLS). Only
-- a move from no row or cancelled into a live status is checked, so the
-- waitlist promotion and leaving keep working; the host, moderators and the
-- service role pass.
create or replace function public.rsvps_moderation_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_state text;
  v_host  uuid;
begin
  if new.status = 'cancelled' or (tg_op = 'UPDATE' and old.status <> 'cancelled') then
    return new;
  end if;
  select e.moderation_state, e.host_id into v_state, v_host from public.events e where e.id = new.event_id;
  if v_state is not null and new.user_id is distinct from v_host and not public.is_privileged() then
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  return new;
end $$;
drop trigger if exists rsvps_moderation_guard on public.rsvps;
create trigger rsvps_moderation_guard before insert or update of status on public.rsvps
  for each row execute function public.rsvps_moderation_guard();

-- Co-attendance warning (TRUST-SAFETY-LEGAL 7): someone who joins an
-- upcoming plan where a person who blocked them is the host or has a live
-- RSVP; that person is told, and the newcomer is told when they blocked
-- someone already there. Nobody learns that they were blocked.
create or replace function public.rsvps_block_warning()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  e         public.events%rowtype;
  v_user    uuid;
  v_payload jsonb;
begin
  if new.status = 'cancelled' or (tg_op = 'UPDATE' and old.status <> 'cancelled') then
    return null;
  end if;
  if not exists (select 1 from public.blocks b where b.blocker_id = new.user_id or b.blocked_id = new.user_id) then
    return null;
  end if;
  select * into e from public.events where id = new.event_id;
  if not found or e.status <> 'published' or e.ends_at < now() then
    return null;
  end if;
  v_payload := public.notification_event_payload(e.id) || jsonb_build_object('reason', 'blocked_attendee');
  for v_user in
    select b.blocker_id from public.blocks b
     where b.blocked_id = new.user_id
       and (b.blocker_id = e.host_id
            or exists (select 1 from public.rsvps r
                        where r.event_id = e.id and r.user_id = b.blocker_id and r.status <> 'cancelled'))
  loop
    perform public.enqueue_notification(v_user, 'blocked_attendee',
                                        'blocked_attendee:' || e.id || ':' || v_user,
                                        e.id, e.hub_id, e.chapter_id, null, v_payload);
  end loop;
  if exists (select 1 from public.blocks b
              where b.blocker_id = new.user_id
                and (b.blocked_id = e.host_id
                     or exists (select 1 from public.rsvps r
                                 where r.event_id = e.id and r.user_id = b.blocked_id and r.status <> 'cancelled'))) then
    perform public.enqueue_notification(new.user_id, 'blocked_attendee',
                                        'blocked_attendee:' || e.id || ':' || new.user_id,
                                        e.id, e.hub_id, e.chapter_id, null, v_payload);
  end if;
  return null;
end $$;
drop trigger if exists rsvps_block_warning on public.rsvps;
create trigger rsvps_block_warning after insert or update of status on public.rsvps
  for each row execute function public.rsvps_block_warning();

-- "Who did you meet": never a pick across a block.
create or replace function public.event_meets_skip_blocked()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if public.users_blocked(new.user_id, new.met_user_id) then
    return null;
  end if;
  return new;
end $$;
drop trigger if exists event_meets_skip_blocked on public.event_meets;
create trigger event_meets_skip_blocked before insert on public.event_meets
  for each row execute function public.event_meets_skip_blocked();

-- ---------------------------------------------------------------------------
-- 7. Member RPCs: block, mute, warning
-- ---------------------------------------------------------------------------
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
  'Migration 51: blocks p_user for the caller (symmetric in every read path). Removes the caller''s mute of them and both people''s "met" picks of each other. Returns {blocked, already, shared_upcoming}: shared_upcoming counts upcoming plans both are on, for a warning. Errors: not_authenticated, cannot_block_self, onboarding_required, user_not_found, too_many_blocks (1000).';

create or replace function public.unblock_user(p_user uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  n   integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  delete from public.blocks where blocker_id = uid and blocked_id = p_user;
  get diagnostics n = row_count;
  return jsonb_build_object('unblocked', n > 0);
end $$;
comment on function public.unblock_user(uuid) is
  'Migration 51: removes the caller''s block of p_user (a block p_user made stays). Returns {unblocked}.';

-- The caller's block list with names: profiles RLS hides blocked people, so
-- this definer function is the one place the blocker sees who they blocked.
create or replace function public.my_blocks()
returns table (user_id uuid, handle text, first_name text, avatar_url text, blocked_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select p.id, p.handle, p.first_name,
         case when p.status = 'active' and p.moderation_state is null then p.avatar_url end,
         b.created_at
    from public.blocks b
    join public.profiles p on p.id = b.blocked_id and p.deleted_at is null
   where b.blocker_id = (select auth.uid())
   order by b.created_at desc;
$$;
comment on function public.my_blocks() is
  'Migration 51: the people the caller blocked, newest first (handle, first name, photo unless banned or hidden).';

create or replace function public.mute_user(p_user uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  n   integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_user is null or p_user = uid then
    raise exception 'cannot_mute_self' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.profiles where id = uid and status = 'active' and deleted_at is null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.profiles where id = p_user and deleted_at is null) then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.blocks where blocker_id = uid and blocked_id = p_user) then
    return jsonb_build_object('muted', true, 'already', true);
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('mutes:' || uid::text));
  if not exists (select 1 from public.mutes where muter_id = uid and muted_id = p_user)
     and (select count(*) from public.mutes where muter_id = uid) >= 1000 then
    raise exception 'too_many_mutes' using errcode = 'check_violation', hint = 'Up to 1000 mutes.';
  end if;
  insert into public.mutes (muter_id, muted_id) values (uid, p_user) on conflict do nothing;
  get diagnostics n = row_count;
  return jsonb_build_object('muted', true, 'already', n = 0);
end $$;
comment on function public.mute_user(uuid) is
  'Migration 51: mutes p_user for the caller (silent, one-sided). Returns {muted, already}; a blocked person counts as already muted. Errors: not_authenticated, cannot_mute_self, onboarding_required, user_not_found, too_many_mutes (1000).';

create or replace function public.unmute_user(p_user uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  n   integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  delete from public.mutes where muter_id = uid and muted_id = p_user;
  get diagnostics n = row_count;
  return jsonb_build_object('unmuted', n > 0);
end $$;
comment on function public.unmute_user(uuid) is
  'Migration 51: removes the caller''s mute of p_user. Returns {unmuted}.';

create or replace function public.event_block_warning(p_event uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select case when (select auth.uid()) is null or not public.can_read_event(p_event) then 0 else (
    select count(*)::integer
      from public.blocks b
      join public.events e on e.id = p_event
     where b.blocker_id = (select auth.uid())
       and (b.blocked_id = e.host_id
            or exists (select 1 from public.rsvps r
                        where r.event_id = e.id and r.user_id = b.blocked_id and r.status <> 'cancelled'))
  ) end;
$$;
comment on function public.event_block_warning(uuid) is
  'Migration 51: how many people the caller blocked are hosting or on this plan (going, interested or waitlisted). Never counts people who blocked the caller. 0 when the plan is unreadable.';

-- ---------------------------------------------------------------------------
-- 8. Reports
-- ---------------------------------------------------------------------------
-- Internal: sets a target's moderation state (and is_active for hubs and
-- chapters). Returns the previous state.
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
  'Migration 51, internal: sets moderation_state on a profile, event, chapter or hub (a hub or chapter also goes inactive, and active again when a state is cleared). Returns the previous state.';

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
    if not found or (v_state is null and not public.can_read_event(p_id)) then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
  elsif p_kind = 'chapter' then
    select c.moderation_state into v_state from public.hub_chapters c
     where c.id = p_id and (c.is_active or c.moderation_state is not null);
    if not found then
      raise exception 'target_not_found' using errcode = 'P0002';
    end if;
    if exists (select 1 from public.chapter_members cm
                where cm.chapter_id = p_id and cm.user_id = uid and cm.role in ('captain', 'organizer')) then
      raise exception 'own_item' using errcode = 'check_violation';
    end if;
  else
    select h.moderation_state into v_state from public.hubs h
     where h.id = p_id and (h.is_active or h.moderation_state is not null);
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
    return jsonb_build_object('id', v_id, 'already', true, 'hidden', v_state is not null);
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
  if p_kind <> 'hub' and v_state is null then
    select count(distinct r.reporter_id) into v_n
      from public.reports r
      join public.profiles rp on rp.id = r.reporter_id
     where r.target_kind = p_kind and r.target_id = p_id and r.status = 'open'
       and rp.status = 'active' and rp.deleted_at is null
       and rp.created_at <= now() - interval '1 day'
       and r.reporter_id is distinct from v_target_user;
    if v_n >= 3 then
      perform public.moderation_set_state(p_kind, p_id, 'hidden');
      insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, report_count)
      values (null, 'auto_hide', p_kind, p_id, v_target_user, v_n);
      v_hidden := true;
    end if;
  end if;

  return jsonb_build_object('id', v_id, 'already', false, 'hidden', v_hidden or v_state is not null);
end $$;
comment on function public.report_content(text, uuid, text, text) is
  'Migration 51: report a profile, event, chapter or hub (kind place hands over to report_place). Reasons: harassment, hate, sexual_content, violence, spam, scam, impersonation, underage, unsafe, ncii, child_safety, other. One open report per person per target (a repeat returns already true). Hides a profile, plan or chapter pending review at three reports from different active accounts older than a day. Returns {id, already, hidden}. Errors: not_authenticated, invalid_kind, onboarding_required, invalid_reason, target_not_found, own_item, rate_limited (20 a day).';

-- ---------------------------------------------------------------------------
-- 9. Moderator RPCs
-- ---------------------------------------------------------------------------
-- Internal: whether the caller may not act on a target (second-moderator
-- rule): it is them, their plan, a chapter they run, or they filed an open
-- report on it.
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
  );
$$;
comment on function public.moderation_is_own(text, uuid, uuid) is
  'Migration 51, internal: the second-moderator rule. True when the target is the caller, the caller''s plan or a chapter the caller runs, or the caller filed an open report on it.';

create or replace function public.mod_report_queue(p_limit integer default 100)
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
    with g as (
      select r.target_kind, r.target_id,
             min(r.priority) as priority, min(r.due_at) as due_at, min(r.created_at) as first_at,
             count(*)::integer as n, count(distinct r.reporter_id)::integer as reporters,
             (array_agg(r.target_user_id) filter (where r.target_user_id is not null))[1] as target_user_id
        from public.reports r
       where r.status = 'open'
       group by r.target_kind, r.target_id
       order by min(r.priority), min(r.due_at)
       limit greatest(1, least(coalesce(p_limit, 100), 500))
    )
    select jsonb_agg(jsonb_build_object(
             'kind', g.target_kind,
             'target_id', g.target_id,
             'priority', g.priority,
             'due_at', g.due_at,
             'overdue', g.due_at < now(),
             'first_reported_at', g.first_at,
             'report_count', g.n,
             'reporter_count', g.reporters,
             'reasons', (select jsonb_object_agg(x.reason, x.c) from (
                           select r2.reason, count(*) as c from public.reports r2
                            where r2.target_kind = g.target_kind and r2.target_id = g.target_id and r2.status = 'open'
                            group by r2.reason) x),
             'notes', (select coalesce(jsonb_agg(y.note order by y.created_at desc), '[]'::jsonb) from (
                         select r3.note, r3.created_at from public.reports r3
                          where r3.target_kind = g.target_kind and r3.target_id = g.target_id and r3.status = 'open'
                            and r3.note <> ''
                          order by r3.created_at desc limit 5) y),
             'label', case g.target_kind
                        when 'profile' then (select p.first_name from public.profiles p where p.id = g.target_id)
                        when 'event'   then (select e.title from public.events e where e.id = g.target_id)
                        when 'chapter' then (select c.name from public.hub_chapters c where c.id = g.target_id)
                        else (select h.name from public.hubs h where h.id = g.target_id) end,
             'state', case g.target_kind
                        when 'profile' then (select p.moderation_state from public.profiles p where p.id = g.target_id)
                        when 'event'   then (select e.moderation_state from public.events e where e.id = g.target_id)
                        when 'chapter' then (select c.moderation_state from public.hub_chapters c where c.id = g.target_id)
                        else (select h.moderation_state from public.hubs h where h.id = g.target_id) end,
             'target_user', (select jsonb_build_object('id', p.id, 'handle', p.handle, 'first_name', p.first_name,
                                                       'status', p.status)
                               from public.profiles p where p.id = g.target_user_id),
             'can_act', not public.moderation_is_own(g.target_kind, g.target_id, g.target_user_id)
           ) order by g.priority, g.due_at)
      from g), '[]'::jsonb);
end $$;
comment on function public.mod_report_queue(integer) is
  'Migration 51, moderators: open reports grouped by target, most urgent first (priority, then due_at; 24-hour target, 4 hours for child safety). Each item: kind, target_id, priority, due_at, overdue, first_reported_at, report_count, reporter_count, reasons {reason: n}, notes (latest 5), label, state, target_user {id, handle, first_name, status}, can_act (false under the second-moderator rule). Never reporter ids.';

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
  if p_kind is null or p_kind not in ('profile', 'event', 'chapter', 'hub') or p_id is null then
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
  'Migration 51, moderators: act on a profile, event, chapter or hub. dismiss (needs open reports) and restore clear a hide or removal and dismiss the open reports; hide holds it for review; remove is the soft delete (a profile loses its photo and bio, kept in the log; an upcoming plan is cancelled and its audience told; a hub or chapter goes inactive). hide and remove action the open reports. Logged in moderation_actions. Errors: not_authenticated, forbidden, invalid_kind, invalid_action, target_not_found, own_item (second-moderator rule), item_not_pending.';

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

  -- Hosted upcoming plans and series end, and their audience hears why
  -- (the same steps as account deletion, migration 36).
  update public.event_series
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'moderator_removed'
   where host_id = p_user and status = 'published';
  with u as (
    update public.events
       set status = 'cancelled', cancelled_at = now(), cancel_reason = 'moderator_removed'
     where host_id = p_user and status = 'published' and starts_at > now()
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
                            'rsvps_removed', v_rsvps, 'reports_closed', v_open);
end $$;
comment on function public.mod_ban_user(uuid, text) is
  'Migration 51, moderators: bans an account. Profile status banned (reads and RSVPs close at once), sign-in blocked for 100 years, roles removed, hosted upcoming plans and series cancelled with the audience told, live RSVPs on upcoming plans removed (waitlist promoted), open reports on the profile actioned, logged. Only an admin bans a moderator; nobody bans an admin. Returns {banned, already, events_cancelled, rsvps_removed, reports_closed}. Errors: not_authenticated, forbidden, own_item, user_not_found, cannot_ban_admin.';

create or replace function public.mod_unban_user(p_user uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  p      public.profiles%rowtype;
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
  if p.status <> 'banned' then
    return jsonb_build_object('unbanned', false);
  end if;
  update public.profiles set status = 'active', moderated_at = now() where id = p_user;
  update auth.users set banned_until = null where id = p_user;
  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
  values (uid, 'unban', 'profile', p_user, p_user, v_note);
  return jsonb_build_object('unbanned', true);
end $$;
comment on function public.mod_unban_user(uuid, text) is
  'Migration 51, moderators: lifts a ban (status active, sign-in allowed). Cancelled plans and removed RSVPs stay as they are. Returns {unbanned}. Errors: not_authenticated, forbidden, own_item, user_not_found.';

create or replace function public.admin_set_moderator(p_user uuid, p_grant boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  n      integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.has_role('admin'::public.app_role) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_user is null or p_user = uid or p_grant is null then
    raise exception 'own_item' using errcode = '42501';
  end if;
  if p_grant then
    if not exists (select 1 from public.profiles p
                     join public.profile_private pp on pp.user_id = p.id
                    where p.id = p_user and p.status = 'active' and p.deleted_at is null
                      and p.onboarding_completed_at is not null
                      and pp.birth_date <= (current_date - interval '18 years')::date) then
      raise exception 'user_not_found' using errcode = 'P0002', hint = 'Moderators are active, onboarded adults.';
    end if;
    insert into public.user_roles (user_id, role, granted_by) values (p_user, 'moderator', uid)
    on conflict do nothing;
  else
    delete from public.user_roles where user_id = p_user and role = 'moderator';
  end if;
  get diagnostics n = row_count;
  if n > 0 then
    insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
    values (uid, case when p_grant then 'grant_moderator' else 'revoke_moderator' end, 'profile', p_user, p_user, v_note);
  end if;
  return jsonb_build_object('moderator', p_grant, 'changed', n > 0);
end $$;
comment on function public.admin_set_moderator(uuid, boolean, text) is
  'Migration 51, admins: grants or revokes the moderator role (the named second moderator, PLAN 12). Never on oneself; a grant needs an active, onboarded adult. Logged. Returns {moderator, changed}. Errors: not_authenticated, forbidden, own_item, user_not_found.';

create or replace function public.mod_team()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('user_id', x.user_id, 'handle', x.handle, 'first_name', x.first_name,
                                        'roles', x.roles, 'since', x.since) order by x.since)
      from (select ur.user_id, p.handle, p.first_name,
                   array_agg(ur.role::text order by ur.role::text) as roles, min(ur.created_at) as since
              from public.user_roles ur
              join public.profiles p on p.id = ur.user_id
             group by ur.user_id, p.handle, p.first_name) x), '[]'::jsonb);
end $$;
comment on function public.mod_team() is
  'Migration 51, moderators: everyone with a role (user_id, handle, first_name, roles, since), oldest first.';

-- ---------------------------------------------------------------------------
-- 10. Account deletion (migration 36 body plus the trust-and-safety rows)
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

-- ---------------------------------------------------------------------------
-- 11. Comments on rebuilt functions
-- ---------------------------------------------------------------------------
comment on function public.event_share_card(uuid) is
  'Logged-out share page and OG image. Published, public, 18+: the event fields anon may read plus host (handle, first name, avatar), hub and chapter. Published campus or 21+: {id, restricted: campus|age, hub_name}. Null for anything else, when the hub is not active, when the host''s account is not active, or when a moderator hid or removed the plan (migration 51).';
comment on function public.enqueue_notification(uuid, public.notification_kind, text, uuid, uuid, uuid, uuid, jsonb, boolean) is
  'Internal. Records one notification honoring notification_prefs (channels, topics, unsubscribed_all_at, quiet hours via push_after). Idempotent by dedupe_key; p_batch keeps a hash per distinct actor in payload.joiners and their number in payload.count. Migration 51: across a block attendee_joined and hub_new_event are dropped and other kinds lose the actor; a mute drops attendee_joined and hub_new_event. Returns the id, or null when nothing was written.';
comment on function public.pending_attendance_prompts() is
  'Up to 5 events (not imported, not hosted by the caller) that ended in the last 7 days where the caller was going and has neither answered nor dismissed, newest first. attendees: the other going people with an active profile and no block with the caller (migration 51), [{id, first_name, avatar_url}], checked-in first.';

-- ---------------------------------------------------------------------------
-- 12. Privileges (explicit)
-- ---------------------------------------------------------------------------
-- Used inside RLS policies, so the signed-in role needs them.
revoke all on function public.is_blocked_with(uuid) from public, anon;
grant execute on function public.is_blocked_with(uuid) to authenticated, service_role;

-- Internal helpers and triggers.
revoke all on function public.users_blocked(uuid, uuid) from public, anon, authenticated;
grant execute on function public.users_blocked(uuid, uuid) to service_role;
revoke all on function public.moderation_set_state(text, uuid, text) from public, anon, authenticated;
grant execute on function public.moderation_set_state(text, uuid, text) to service_role;
revoke all on function public.moderation_is_own(text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.moderation_is_own(text, uuid, uuid) to service_role;
revoke all on function public.rsvps_moderation_guard() from public, anon, authenticated;
revoke all on function public.rsvps_block_warning() from public, anon, authenticated;
revoke all on function public.event_meets_skip_blocked() from public, anon, authenticated;
revoke all on function public.enqueue_notification(uuid, public.notification_kind, text, uuid, uuid, uuid, uuid, jsonb, boolean)
  from public, anon, authenticated;

-- Signed-in RPCs (moderator and admin ones check inside).
revoke all on function public.block_user(uuid) from public, anon;
grant execute on function public.block_user(uuid) to authenticated;
revoke all on function public.unblock_user(uuid) from public, anon;
grant execute on function public.unblock_user(uuid) to authenticated;
revoke all on function public.my_blocks() from public, anon;
grant execute on function public.my_blocks() to authenticated;
revoke all on function public.mute_user(uuid) from public, anon;
grant execute on function public.mute_user(uuid) to authenticated;
revoke all on function public.unmute_user(uuid) from public, anon;
grant execute on function public.unmute_user(uuid) to authenticated;
revoke all on function public.event_block_warning(uuid) from public, anon;
grant execute on function public.event_block_warning(uuid) to authenticated;
revoke all on function public.report_content(text, uuid, text, text) from public, anon;
grant execute on function public.report_content(text, uuid, text, text) to authenticated;
revoke all on function public.mod_report_queue(integer) from public, anon;
grant execute on function public.mod_report_queue(integer) to authenticated;
revoke all on function public.mod_moderate(text, uuid, text, text) from public, anon;
grant execute on function public.mod_moderate(text, uuid, text, text) to authenticated;
revoke all on function public.mod_ban_user(uuid, text) from public, anon;
grant execute on function public.mod_ban_user(uuid, text) to authenticated;
revoke all on function public.mod_unban_user(uuid, text) from public, anon;
grant execute on function public.mod_unban_user(uuid, text) to authenticated;
revoke all on function public.admin_set_moderator(uuid, boolean, text) from public, anon;
grant execute on function public.admin_set_moderator(uuid, boolean, text) to authenticated;
revoke all on function public.mod_team() from public, anon;
grant execute on function public.mod_team() to authenticated;

-- Rebuilt functions keep their grants (create or replace does not change
-- them); restated here.
revoke all on function public.can_read_event(uuid) from public, anon;
grant execute on function public.can_read_event(uuid) to authenticated;
revoke all on function public.event_share_card(uuid) from public;
grant execute on function public.event_share_card(uuid) to anon, authenticated;
revoke all on function public.chapter_public_card(text) from public;
grant execute on function public.chapter_public_card(text) to anon, authenticated;
revoke all on function public.pending_attendance_prompts() from public, anon;
grant execute on function public.pending_attendance_prompts() to authenticated;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Version stamp
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.47')
  on conflict (key) do update set value = excluded.value, updated_at = now();
