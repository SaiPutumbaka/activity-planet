-- ============================================================================
-- Activity Planet schema v2 — migration 69: not-found answers are HTTP 404.
--   Builds on migrations 1 to 68, which reached staging and are not edited.
--
--   The read RPCs a screen calls on load raised their not-found code with
--   SQLSTATE P0002, which PostgREST reports as HTTP 500, so a stale link or a
--   blocked pair looked like a server error in the logs. Each one below is
--   rebuilt from its latest body with one change: the not-found raise uses
--   SQLSTATE PT404, which PostgREST answers with HTTP 404. The message (the
--   documented code: not_found, place_not_found, chapter_not_found,
--   user_not_found) is unchanged, so the app's error mapping still reads it;
--   the app accepts both PT404 and the old P0002 code.
--
--     get_coach, coach_reviews_page, coach_slots, get_booking   (migration 60)
--     conversation_info, get_messages, mod_message_evidence     (migration 58)
--     place_detail                                              (migration 29)
--     venue_preview_for_place                                   (migration 36)
--     organizer_source_detail                                   (migration 65)
--     recs_similar_events                                       (migration 67)
--     chapter_dashboard                                         (migration 20)
--     mod_user_lookup                                           (migration 53)
--
--   Mutations on a missing row (cancel, send, respond and the rest) keep
--   P0002: they are rare and a 5xx there is worth a look.
--     * meta.schema_version 2.65.
--
--   Account deletion: no new table, nothing to add.
--   Idempotent: safe to re-run.
-- ============================================================================

-- get_coach: from 20261224000100_coaching.sql; 2 not-found raise(s) now PT404 (Migration 69).
create or replace function public.get_coach(p_handle text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid  uuid := (select auth.uid());
  p    public.profiles%rowtype;
  cp   public.coach_profiles%rowtype;
  v_own boolean;
  v_age integer := (select public.viewer_age());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into p from public.profiles x where lower(x.handle) = lower(btrim(coalesce(p_handle, '')));
  if not found or not private.coach_visible(p.id) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  select * into cp from public.coach_profiles where user_id = p.id;
  if not found then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  v_own := p.id = uid;
  return jsonb_build_object(
    'user_id', p.id, 'handle', p.handle, 'first_name', p.first_name, 'avatar_url', p.avatar_url,
    'status', cp.status, 'own', v_own,
    'headline', cp.headline, 'about', cp.about, 'timezone', cp.timezone, 'area_label', cp.area_label,
    'in_person', cp.in_person, 'online', cp.online, 'service_radius_km', cp.service_radius_km,
    'rating_avg', cp.rating_avg, 'rating_count', cp.rating_count, 'completed_count', cp.completed_count,
    'published_at', cp.published_at,
    'terms_current', case when v_own then cp.terms_version is not distinct from private.coach_terms_version() end,
    'credentials', coalesce((select jsonb_agg(jsonb_build_object('title', c.title, 'issuer', c.issuer, 'year', c.year,
                                                                 'self_reported', true) order by c.position)
                               from public.coach_credentials c where c.coach_id = p.id), '[]'::jsonb),
    'photos', coalesce((select jsonb_agg(ph.url order by ph.position) from public.coach_photos ph where ph.coach_id = p.id),
                       '[]'::jsonb),
    'hubs', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'slug', h.slug, 'name', h.name, 'emoji', h.emoji)
                                       order by h.name)
                        from public.coach_hubs ch join public.hubs h on h.id = ch.hub_id
                       where ch.coach_id = p.id and h.is_active), '[]'::jsonb),
    'listings', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', l.id, 'title', l.title, 'description', l.description, 'delivery', l.delivery,
                  'format', l.format, 'capacity', l.capacity, 'duration_minutes', l.duration_minutes,
                  'price_minor', l.price_minor, 'currency', l.currency, 'min_age', l.min_age,
                  'hub_id', l.hub_id, 'auto_confirm', l.auto_confirm, 'status', l.status,
                  'min_notice_hours', l.min_notice_hours, 'max_advance_days', l.max_advance_days,
                  'moderation_state', case when v_own then l.moderation_state end,
                  'payable', private.coach_listing_payable(l.id)) order by l.price_minor, l.created_at)
                    from public.coach_listings l
                   where l.coach_id = p.id
                     and ((v_own and l.status <> 'archived')
                          or (l.status = 'active' and l.moderation_state is null and coalesce(v_age >= l.min_age, false)))),
                  '[]'::jsonb),
    'from_prices', coalesce((select jsonb_agg(jsonb_build_object('currency', x.currency, 'price_minor', x.price_minor)
                                              order by x.currency)
                               from (select l.currency, min(l.price_minor) as price_minor from public.coach_listings l
                                      where l.coach_id = p.id and l.status = 'active' and l.moderation_state is null
                                        and coalesce(v_age >= l.min_age, false)
                                      group by l.currency) x), '[]'::jsonb),
    'reviews', public.coach_reviews_page(p.id, null, 10),
    'payments_enabled', private.coach_payments_on());
end $$;

revoke all on function public.get_coach(text) from public, anon;
grant execute on function public.get_coach(text) to authenticated, service_role;

-- coach_reviews_page: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 69).
create or replace function public.coach_reviews_page(p_coach uuid, p_before jsonb default null, p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 50));
  v_at    timestamptz;
  v_id    uuid;
  v_items jsonb;
  v_last  record;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not private.coach_visible(p_coach) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  begin
    v_at := (p_before ->> 'created_at')::timestamptz;
    v_id := (p_before ->> 'booking_id')::uuid;
  exception when others then
    raise exception 'invalid_cursor' using errcode = 'check_violation';
  end;
  with page as (
    select r.booking_id, r.created_at from public.coach_reviews r
     where r.coach_id = p_coach
       and (r.moderation_state is null or uid in (r.coach_id, r.client_id))
       and (r.client_id = uid or not private.is_blocked_with(r.client_id))
       and (v_at is null or (r.created_at, r.booking_id) < (v_at, v_id))
     order by r.created_at desc, r.booking_id desc
     limit v_limit
  )
  select coalesce(jsonb_agg(private.coach_review_json(pg.booking_id) order by pg.created_at desc, pg.booking_id desc), '[]'::jsonb)
    into v_items from page pg;
  select x.created_at, x.booking_id into v_last from (
    select r.created_at, r.booking_id from public.coach_reviews r
     where r.booking_id in (select (e ->> 'booking_id')::uuid from jsonb_array_elements(v_items) e)
     order by r.created_at asc, r.booking_id asc limit 1) x;
  return jsonb_build_object('items', v_items,
                            'next', case when jsonb_array_length(v_items) = v_limit
                                         then jsonb_build_object('created_at', v_last.created_at, 'booking_id', v_last.booking_id) end);
end $$;

revoke all on function public.coach_reviews_page(uuid, jsonb, integer) from public, anon;
grant execute on function public.coach_reviews_page(uuid, jsonb, integer) to authenticated, service_role;

-- coach_slots: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 69).
create or replace function public.coach_slots(p_listing uuid, p_from date, p_to date)
returns table (starts_at timestamptz, ends_at timestamptz, seats_left smallint)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.viewer_is_adult() then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'invalid_range' using errcode = 'check_violation';
  end if;
  if p_to - p_from > 31 then
    raise exception 'range_too_long' using errcode = 'check_violation', hint = 'Up to 31 days.';
  end if;
  if not private.coach_listing_visible(p_listing) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  return query select s.starts_at, s.ends_at, s.seats_left from private.coach_open_slots(p_listing, p_from, p_to) s;
end $$;

revoke all on function public.coach_slots(uuid, date, date) from public, anon;
grant execute on function public.coach_slots(uuid, date, date) to authenticated, service_role;

-- get_booking: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 69).
create or replace function public.get_booking(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v jsonb;
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  v := private.booking_json(p_id, true);
  if v is null then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  return v;
end $$;

revoke all on function public.get_booking(uuid) from public, anon;
grant execute on function public.get_booking(uuid) to authenticated, service_role;

-- conversation_info: from 20261222000100_messaging.sql; 1 not-found raise(s) now PT404 (Migration 69).
create or replace function public.conversation_info(p_conversation uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  c         public.conversations%rowtype;
  me        public.conversation_members%rowtype;
  r         public.message_requests%rowtype;
  e         public.events%rowtype;
  v_members jsonb;
  v_admins  jsonb := '[]'::jsonb;
  v_count   integer;
  v_other   jsonb;
  v_title   text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not private.chat_can_read(p_conversation) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  select * into c from public.conversations where id = p_conversation;
  select * into me from public.conversation_members where conversation_id = c.id and user_id = uid;
  select * into r from public.message_requests where conversation_id = c.id;

  if c.kind in ('dm', 'group') then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', p.id, 'first_name', p.first_name, 'handle', p.handle,
             'avatar_url', case when p.status = 'active' and p.moderation_state is null then p.avatar_url end,
             'role', cm.role) order by cm.joined_at, p.id), '[]'::jsonb), count(*)::integer
      into v_members, v_count
      from public.conversation_members cm
      join public.profiles p on p.id = cm.user_id
     where cm.conversation_id = c.id and cm.left_at is null and cm.removed_at is null
       and (cm.user_id = uid or not private.is_blocked_with(cm.user_id));
    v_title := c.title;
    if c.kind = 'dm' then
      select jsonb_build_object('id', p.id, 'first_name', p.first_name, 'handle', p.handle,
                                'avatar_url', case when p.status = 'active' and p.moderation_state is null
                                                   then p.avatar_url end)
        into v_other
        from public.profiles p
       where p.id = private.chat_dm_other(c.dm_key, uid) and not private.is_blocked_with(p.id);
    end if;
  elsif c.kind = 'event' then
    select * into e from public.events where id = c.event_id;
    v_title := e.title;
    select count(*)::integer + 1 into v_count from public.rsvps rr
     where rr.event_id = e.id and rr.status in ('going', 'waitlisted') and rr.removed_at is null
       and rr.user_id is distinct from e.host_id;
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'first_name', p.first_name, 'handle', p.handle)
                              order by p.first_name, p.id), '[]'::jsonb)
      into v_admins
      from public.profiles p
     where p.status = 'active' and not private.is_blocked_with(p.id)
       and (p.id = e.host_id or p.id in (select cm.user_id from public.chapter_members cm
                                          where cm.chapter_id = e.chapter_id and cm.role in ('captain', 'organizer')));
  elsif c.kind = 'hub' then
    select h.name into v_title from public.hubs h where h.id = c.hub_id;
    select count(*)::integer into v_count from public.hub_members hm where hm.hub_id = c.hub_id;
  else
    select ch.name into v_title from public.hub_chapters ch where ch.id = c.chapter_id;
    select count(*)::integer into v_count from public.chapter_members cm where cm.chapter_id = c.chapter_id;
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'first_name', p.first_name, 'handle', p.handle)
                              order by p.first_name, p.id), '[]'::jsonb)
      into v_admins
      from public.chapter_members cm
      join public.profiles p on p.id = cm.user_id
     where cm.chapter_id = c.chapter_id and cm.role in ('captain', 'organizer') and p.status = 'active'
       and not private.is_blocked_with(p.id);
  end if;

  return jsonb_build_object(
    'conversation_id', c.id,
    'kind', c.kind,
    'title', v_title,
    'role', private.chat_role(c.id, uid),
    'members', v_members,
    'member_count', v_count,
    'admins', v_admins,
    'other', v_other,
    'event_id', c.event_id,
    'hub_id', c.hub_id,
    'chapter_id', c.chapter_id,
    'muted_until', me.muted_until,
    'notify', coalesce(me.notify, c.kind in ('dm', 'group', 'event')),
    'last_read_seq', coalesce(me.last_read_seq, 0),
    'last_seq', c.last_seq,
    'can_post', private.chat_can_post(c.id),
    'images_enabled', private.chat_images_enabled(),
    'request', case when r.conversation_id is not null and r.status <> 'accepted' then
                 case when r.from_user = uid then 'sent' else 'received' end end);
end $$;

revoke all on function public.conversation_info(uuid) from public, anon;
grant execute on function public.conversation_info(uuid) to authenticated, service_role;

-- get_messages: from 20261222000100_messaging.sql; 1 not-found raise(s) now PT404 (Migration 69).
create or replace function public.get_messages(p_conversation uuid, p_before_seq bigint default null,
                                               p_after_seq bigint default null, p_limit integer default 50)
returns table (id uuid, seq bigint, author jsonb, kind text, body text, image jsonb, created_at timestamptz,
               deleted text, hidden boolean, mine boolean, client_id uuid)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid     uuid := (select auth.uid());
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_asc   boolean := p_after_seq is not null and p_before_seq is null;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not private.chat_can_read(p_conversation) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  return query
  with picked as (
    select m.* from public.messages m
     where m.conversation_id = p_conversation
       and (p_before_seq is null or m.seq < p_before_seq)
       and (p_after_seq is null or m.seq > p_after_seq)
       and private.chat_visible_author(m.author_id, uid)
       and (m.author_id = uid or m.kind <> 'image' or m.image_state = 'visible'
            or m.deleted_at is not null or m.moderation_state is not null)
     order by case when v_asc then m.seq end asc, m.seq desc
     limit v_limit
  )
  select x.id, x.seq,
         case when x.author_id is not null then jsonb_build_object(
           'id', p.id, 'first_name', p.first_name,
           'avatar_url', case when p.status = 'active' and p.moderation_state is null then p.avatar_url end) end,
         x.kind,
         case when x.deleted_at is not null or x.moderation_state is not null then '' else x.body end,
         case when x.kind = 'image' and x.deleted_at is null and x.moderation_state is null then jsonb_build_object(
           'state', x.image_state,
           'path', case when x.author_id = uid or x.image_state = 'visible' then x.image_path end) end,
         x.created_at,
         case when x.deleted_at is not null then x.deleted_by when x.moderation_state = 'removed' then 'moderator' end,
         coalesce(x.moderation_state = 'hidden', false),
         coalesce(x.author_id = uid, false),
         case when x.author_id = uid then x.client_id end
    from picked x
    left join public.profiles p on p.id = x.author_id
   order by x.seq desc;
end $$;

revoke all on function public.get_messages(uuid, bigint, bigint, integer) from public, anon;
grant execute on function public.get_messages(uuid, bigint, bigint, integer) to authenticated, service_role;

-- mod_message_evidence: from 20261222000100_messaging.sql; 1 not-found raise(s) now PT404 (Migration 69).
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
  insert into public.admin_lookups (moderator_id, via, target_user_id, result_count)
  values (uid, 'open', ev.author_id, 1);
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

-- place_detail: from 20261124000100_places_read.sql; 2 not-found raise(s) now PT404 (Migration 69).
create or replace function public.place_detail(p_id uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  p        record;
  v_joined uuid[] := '{}';
  v_hubs   jsonb;
  v_more   boolean;
  v_plans  jsonb;
begin
  if p_id is null then
    raise exception 'place_not_found' using errcode = 'PT404';
  end if;
  select x.id, x.source, x.source_id, x.osm_ref, x.name, x.kind, k.label as kind_label, k.icon as kind_icon,
         x.lat, x.lng, x.address_text, x.locality, x.country, x.opening_hours, x.website, x.tags,
         x.is_public, x.status, x.attribution, x.license, x.last_seen_at, x.rule_ids
    into p
    from public.places x
    join public.place_kinds k on k.slug = x.kind
   where x.id = p_id;
  if not found then
    raise exception 'place_not_found' using errcode = 'PT404';
  end if;

  if uid is not null then
    v_joined := array(select hm.hub_id from public.hub_members hm where hm.user_id = uid);
  end if;

  with hs as (
    select h.id, h.slug, h.name, h.emoji, h.place_mode, (h.id = any (v_joined)) as joined
      from public.hubs h
     where h.is_active and h.place_mode <> 'none'
       and (h.id in (select r.hub_id from public.hub_place_rules r where r.rule_id = any (p.rule_ids))
            or h.id in (select ph.hub_id from public.place_hubs ph where ph.place_id = p.id))
     order by (h.id = any (v_joined)) desc, (h.place_mode = 'specific') desc, h.name, h.id
     limit 13
  ), numbered as (
    select hs.*, row_number() over (order by hs.joined desc, (hs.place_mode = 'specific') desc, hs.name, hs.id) as rn
      from hs
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'slug', n.slug, 'name', n.name, 'emoji', n.emoji,
                                               'general', n.place_mode = 'generic', 'joined', n.joined)
                            order by n.rn) filter (where n.rn <= 12), '[]'::jsonb),
         count(*) > 12
    into v_hubs, v_more
    from numbered n;

  -- Plans here: upcoming events with a public address at a public venue that
  -- is this place (venues.place_ref, or the venue a meeting spot came from).
  -- Approved-only events never appear (D-038).
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'title', q.title, 'starts_at', q.starts_at,
                                               'ends_at', q.ends_at, 'timezone', q.timezone,
                                               'hub_id', q.hub_id, 'hub_slug', q.hub_slug, 'kind', q.kind,
                                               'listing_kind', q.listing_kind)
                            order by q.starts_at, q.id), '[]'::jsonb)
    into v_plans
    from (select e.id, e.title, e.starts_at, e.ends_at, e.timezone, e.hub_id, h.slug as hub_slug, e.kind,
                 e.listing_kind
            from public.venues v
            join public.event_addresses ea on ea.venue_id = v.id
            join public.events e on e.id = ea.event_id
            join public.hubs h on h.id = e.hub_id
           where (v.place_ref = p.id or (p.source = 'venue' and v.id::text = p.source_id))
             and v.is_public
             and e.status = 'published'
             and e.address_visibility = 'public'
             and e.ends_at > now()
           order by e.starts_at, e.id
           limit 20) q;

  return jsonb_build_object(
    'v', 1,
    'id', p.id,
    'name', p.name,
    'kind', p.kind,
    'kind_label', p.kind_label,
    'kind_icon', p.kind_icon,
    'lat', round(p.lat::numeric, 6)::double precision,
    'lng', round(p.lng::numeric, 6)::double precision,
    'address_text', case when p.is_public and p.address_text <> '' then p.address_text end,
    'locality', nullif(p.locality, ''),
    'country', p.country,
    'opening_hours', p.opening_hours,
    'website', p.website,
    'tags', p.tags,
    'source', p.source,
    'status', p.status,
    'is_public', p.is_public,
    'mine', public.place_is_mine(p.id),
    'attribution', p.attribution,
    'license', p.license,
    'checked_at', case when p.source in ('osm', 'geoapify') then p.last_seen_at end,
    'osm_url', case when p.osm_ref is not null then
                 'https://www.openstreetmap.org/'
                 || case left(p.osm_ref, 1) when 'n' then 'node' when 'w' then 'way' else 'relation' end
                 || '/' || substr(p.osm_ref, 2) end,
    'hubs', v_hubs,
    'more_hubs', v_more,
    'plans_here', v_plans);
end $$;

revoke all on function public.place_detail(uuid) from public;
grant execute on function public.place_detail(uuid) to anon, authenticated, service_role;

-- venue_preview_for_place: from 20261130000100_places_review_fixes.sql; 2 not-found raise(s) now PT404 (Migration 69).
create or replace function public.venue_preview_for_place(p_place_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  p   record;
  v_id   uuid;
  v_name text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_place_id is null then
    raise exception 'place_not_found' using errcode = 'PT404';
  end if;

  -- The same rows venue_for_place accepts.
  select x.id, x.source, x.source_id, x.name
    into p
    from public.places x
   where x.id = p_place_id and x.status = 'active' and x.is_public
     and (x.source in ('osm', 'geoapify') or coalesce(public.viewer_is_adult(), false));
  if not found then
    raise exception 'place_not_found' using errcode = 'PT404';
  end if;

  if p.source = 'venue' then
    select x.id, x.name into v_id, v_name from public.venues x where x.id::text = p.source_id and x.is_public;
  end if;
  if v_id is null then
    select x.id, x.name into v_id, v_name
      from public.venues x where x.place_ref = p.id and x.is_public order by x.created_at, x.id limit 1;
  end if;
  if v_id is not null then
    return jsonb_build_object('place_id', p.id, 'venue_id', v_id, 'name', v_name);
  end if;
  return jsonb_build_object('place_id', p.id, 'venue_id', null, 'name', left(p.name, 120));
end $$;

revoke all on function public.venue_preview_for_place(uuid) from public, anon;
grant execute on function public.venue_preview_for_place(uuid) to authenticated, service_role;

-- organizer_source_detail: from 20261229000100_collector_ui.sql; 2 not-found raise(s) now PT404 (Migration 69).
create or replace function public.organizer_source_detail(p_source uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_src   public.feed_sources%rowtype;
  v_mod   boolean := coalesce(public.is_moderator(), false);
  v_claim boolean;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into v_src from public.feed_sources where id = p_source;
  if not found then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  v_claim := exists (select 1 from public.organizer_claims c
                      where c.id = v_src.organizer_claim_id and c.user_id = uid
                        and c.status in ('pending', 'verified'));
  if not (v_src.organizer_id = uid or v_claim or v_mod) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  return jsonb_build_object(
    'id', v_src.id,
    'name', v_src.name,
    'kind', v_src.kind,
    'origin', v_src.origin,
    'url', case when v_src.origin = 'organizer' or v_src.organizer_id = uid or v_mod then v_src.url end,
    'homepage_url', v_src.homepage_url,
    'enabled', v_src.enabled,
    'stopped', v_src.organizer_stopped_at is not null,
    'verified', v_src.organizer_id is not null and v_src.organizer_verified_at is not null,
    'can_manage', v_src.organizer_id = uid or v_mod,
    'default_hub', (select h.slug from public.hubs h where h.id = v_src.organizer_hub_id),
    'images_licensed', coalesce(v_src.images_licensed, false),
    'refresh_requested_at', v_src.organizer_refresh_requested_at,
    'last_ok_at', v_src.last_ok_at,
    'collector_seen_at', v_src.collector_seen_at,
    'has_error', v_src.last_error is not null,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'event_id', x.id, 'title', x.title, 'starts_at', x.starts_at, 'status', x.status,
               'hidden', x.hidden) order by x.starts_at, x.id)
        from (select e.id, e.title, e.starts_at, e.status::text as status,
                     (ei.removed_reason = 'organizer_hidden') as hidden
                from public.event_imports ei
                join public.events e on e.id = ei.event_id
               where ei.source_id = p_source and ei.is_primary and e.kind = 'imported'
                 and e.starts_at > now()
                 and (ei.removed_at is null or ei.removed_reason = 'organizer_hidden')
                 and e.moderation_state is distinct from 'removed'
               order by e.starts_at, e.id
               limit 100) x), '[]'::jsonb));
end $$;

revoke all on function public.organizer_source_detail(uuid) from public, anon;
grant execute on function public.organizer_source_detail(uuid) to authenticated, service_role;

-- recs_similar_events: from 20261231000100_recommendations.sql; 2 not-found raise(s) now PT404 (Migration 69).
create or replace function public.recs_similar_events(
  p_event_id  uuid,
  p_lat       double precision default null,
  p_lng       double precision default null,
  p_radius_km integer default null,
  p_timezone  text default null,
  p_limit     integer default 6
)
returns table (
  id uuid, kind public.event_kind, hub_id uuid, hub_slug text, hub_name text, hub_emoji text,
  chapter_id uuid, campus_id uuid, host_id uuid, series_id uuid, occurrence_date date, title text,
  description text, cover_url text, starts_at timestamptz, ends_at timestamptz, timezone text,
  min_age smallint, capacity integer, waitlist_enabled boolean, min_headcount integer,
  members_only boolean, is_free boolean, price_text text, status public.event_status,
  visibility public.event_visibility, address_visibility public.address_visibility,
  location_hint text, going_count integer, waitlist_count integer, interested_count integer,
  external_url text, source_name text, created_at timestamptz, updated_at timestamptz,
  distance_band text, section text, is_imported boolean, matched_by text,
  reasons jsonb, rank integer
)
language plpgsql stable set search_path = '' as $$
#variable_conflict use_column
declare
  uid       uuid := (select auth.uid());
  v_limit   integer := greatest(1, least(coalesce(p_limit, 6), 20));
  v_impcap  integer;
  v_floor   double precision := private.rec_meta_num('recs_similar_floor', 0.82);
  v_tz      text := private.rec_viewer_tz(p_timezone);
  v_hub     uuid;
  v_series  uuid;
  v_has_emb boolean;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.viewer_is_adult() then
    return;
  end if;
  if p_event_id is null or not public.can_read_event(p_event_id) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  select e.hub_id, e.series_id into v_hub, v_series from public.events e where e.id = p_event_id;
  if v_hub is null then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  v_impcap := greatest(2, ceil(v_limit * 0.3)::integer);
  -- Does the anchor have an embedding the scorer will use? (One probe: the anchor scored against itself.)
  select (s.sim is not null) into v_has_emb from private.rec_event_scores(array[p_event_id], p_event_id) s;
  v_has_emb := coalesce(v_has_emb, false);

  return query
  with recursive f as (
    select * from public.feed_events_v2(now(), now() + interval '30 days', p_lat, p_lng, p_radius_km,
                                        null, false, 200, p_timezone, 'plan')
  ), c as (
    select f.*
      from f
      join public.hubs h on h.id = f.hub_id
      join public.hub_categories hc on hc.slug = h.category_slug
     where f.id <> p_event_id
       and (v_series is null or f.series_id is distinct from v_series)
       and f.host_id is distinct from uid
       and not hc.is_sensitive
       and not exists (select 1 from public.rsvps r where r.event_id = f.id and r.user_id = uid and r.status <> 'cancelled')
       and not exists (select 1 from public.rec_dismissals d
                        where d.user_id = uid and d.subject_kind = 'event' and d.subject_id = f.id)
       and not private.is_blocked_with(f.host_id)
       and public.event_block_warning(f.id) = 0
       and not (f.capacity is not null and f.going_count >= f.capacity and not f.waitlist_enabled)
  ), sc as (
    select s.event_id, s.sim from private.rec_event_scores(array(select c.id from c), p_event_id) s
  ), j as (
    select c.*, sc.sim
      from c join sc on sc.event_id = c.id
     where (v_has_emb and sc.sim >= v_floor) or (not v_has_emb and c.hub_id = v_hub)
  ), r1 as (
    select j.*, count(j.sim) over () as n_sim,
           percent_rank() over (partition by (j.sim is null) order by j.sim) as pr
      from j
  ), scored as (
    select r1.*,
           (case when r1.n_sim > 0
                 then 0.6 * (case when r1.sim is null or r1.n_sim <= 1 then 0.5 else r1.pr end)
                      + 0.2 * exp(-greatest(0, extract(epoch from (r1.starts_at - now())) / 86400.0) / 5.0)
                      + 0.2 * private.rec_band_score(r1.distance_band)
                 else 0.5 * exp(-greatest(0, extract(epoch from (r1.starts_at - now())) / 86400.0) / 5.0)
                      + 0.5 * private.rec_band_score(r1.distance_band)
            end) as score
      from r1
  ), ordered as (
    select scored.*,
           row_number() over (order by scored.score desc, scored.is_imported, scored.starts_at, scored.id) as rn
      from scored
  ), walk as (
    select 0::bigint as rn, '{}'::jsonb as hubs, '{}'::uuid[] as series, 0 as imp, 0 as kept,
           false as ok, null::uuid as id
    union all
    select o.rn,
           case when d.ok then w.hubs || jsonb_build_object(o.hub_id::text, coalesce((w.hubs ->> o.hub_id::text)::integer, 0) + 1)
                else w.hubs end,
           case when d.ok and o.series_id is not null then w.series || o.series_id else w.series end,
           w.imp + case when d.ok and o.is_imported then 1 else 0 end,
           w.kept + case when d.ok then 1 else 0 end,
           d.ok, o.id
      from walk w
      join ordered o on o.rn = w.rn + 1
      cross join lateral (
        select (coalesce((w.hubs ->> o.hub_id::text)::integer, 0) < (case when o.hub_id = v_hub then v_limit else 2 end)
                and (o.series_id is null or not (o.series_id = any (w.series)))
                and (not o.is_imported or w.imp < v_impcap)) as ok) d
     where w.kept < v_limit
  ), kept as (
    select o.*, row_number() over (order by w.rn)::integer as k_rank
      from walk w join ordered o on o.id = w.id
     where w.ok
  ), chips as (
    select k.id as cid,
           (select coalesce(jsonb_agg(x.r order by x.o), '[]'::jsonb)
              from (select v.o, v.r
                      from (values
                        (1, case when k.hub_id = v_hub then jsonb_build_object('code', 'same_hub', 'hub_name', k.hub_name) end),
                        (2, (select jsonb_build_object('code', 'when', 'when', w2)
                               from private.rec_when(k.starts_at, coalesce(v_tz, k.timezone)) w2 where w2 is not null)),
                        (3, case when k.distance_band is not null and k.distance_band <> 'approximate'
                                 then jsonb_build_object('code', 'near', 'band', k.distance_band) end),
                        (4, case when k.is_free then jsonb_build_object('code', 'free') end),
                        (5, case when k.going_count >= 5
                                      or (k.capacity is not null and k.capacity - k.going_count between 0 and 3)
                                 then jsonb_build_object('code', 'popular') end)
                      ) v(o, r)
                     where v.r is not null
                     order by v.o
                     limit 2) x) as base
      from kept k
  )
  select k.id, k.kind, k.hub_id, k.hub_slug, k.hub_name, k.hub_emoji, k.chapter_id, k.campus_id, k.host_id,
         k.series_id, k.occurrence_date, k.title, k.description, k.cover_url, k.starts_at, k.ends_at,
         k.timezone, k.min_age, k.capacity, k.waitlist_enabled, k.min_headcount, k.members_only,
         k.is_free, k.price_text, k.status, k.visibility, k.address_visibility, k.location_hint,
         k.going_count, k.waitlist_count, k.interested_count, k.external_url, k.source_name,
         k.created_at, k.updated_at, k.distance_band, k.section, k.is_imported, k.matched_by,
         (case when jsonb_array_length(ch.base) = 0 then jsonb_build_array(jsonb_build_object('code', 'coming_up'))
               else ch.base end)
         || case when k.is_imported and k.source_name is not null
                 then jsonb_build_array(jsonb_build_object('code', 'from_source', 'source_name', k.source_name))
                 else '[]'::jsonb end,
         k.k_rank
    from kept k
    join chips ch on ch.cid = k.id
   order by k.k_rank;
end $$;

revoke all on function public.recs_similar_events(uuid, double precision, double precision, integer, text, integer) from public, anon;
grant execute on function public.recs_similar_events(uuid, double precision, double precision, integer, text, integer) to authenticated, service_role;

-- chapter_dashboard: from 20261115000100_attendance.sql; 1 not-found raise(s) now PT404 (Migration 69).
create or replace function public.chapter_dashboard(p_chapter uuid, p_weeks integer default 12)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_tz     constant text := 'America/New_York';
  v_last   date;
  v_first  date;
  v_weeks  jsonb;
  v_totals jsonb;
  v_members integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.hub_chapters where id = p_chapter) then
    raise exception 'chapter_not_found' using errcode = 'PT404';
  end if;
  if not (public.is_chapter_captain(p_chapter) or public.is_moderator()) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_weeks is null or p_weeks not between 1 and 52 then
    raise exception 'weeks_range' using errcode = 'check_violation', hint = '1 to 52 weeks.';
  end if;

  v_last  := date_trunc('week', now() at time zone v_tz)::date;
  v_first := v_last - 7 * (p_weeks - 1);

  with held as (
    select e.id, e.starts_at, date_trunc('week', e.starts_at at time zone v_tz)::date as week
      from public.events e
     where e.chapter_id = p_chapter and e.status = 'published' and e.ends_at <= now()
  ),
  going as (
    select h.id as event_id, h.starts_at, h.week, r.user_id,
           r.checked_in_at is not null as checked_in,
           r.checked_in_at is null and r.attended_self_reported_at is not null as self_reported,
           (r.checked_in_at is not null or r.attended_self_reported_at is not null) as attended
      from held h
      join public.rsvps r on r.event_id = h.id and r.status = 'going'
  ),
  att as (
    select g.*, exists (select 1 from going g2
                         where g2.attended and g2.user_id = g.user_id and g2.starts_at < g.starts_at) as is_returning
      from going g
     where g.attended and g.week between v_first and v_last
  ),
  weeks as (
    select v_first + 7 * i as week from generate_series(0, p_weeks - 1) as i
  ),
  per_week as (
    select w.week,
           (select count(*) from held h where h.week = w.week)::integer                       as events_held,
           (select count(*) from going g where g.week = w.week)::integer                      as going,
           (select count(*) from going g where g.week = w.week and g.checked_in)::integer     as checked_in,
           (select count(*) from going g where g.week = w.week and g.self_reported)::integer  as self_reported,
           (select count(distinct a.user_id) from att a where a.week = w.week)::integer       as distinct_attendees,
           (select count(distinct a.user_id) from att a where a.week = w.week and a.is_returning)::integer as returning_attendees
      from weeks w
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'week_start', pw.week, 'events_held', pw.events_held, 'going', pw.going,
           'checked_in', pw.checked_in, 'self_reported', pw.self_reported,
           'distinct_attendees', pw.distinct_attendees, 'returning_attendees', pw.returning_attendees)
           order by pw.week), '[]'::jsonb),
         jsonb_build_object(
           'events_held',   coalesce(sum(pw.events_held), 0),
           'going',         coalesce(sum(pw.going), 0),
           'checked_in',    coalesce(sum(pw.checked_in), 0),
           'self_reported', coalesce(sum(pw.self_reported), 0),
           'distinct_attendees',  (select count(distinct a.user_id) from att a),
           'returning_attendees', (select count(distinct a.user_id) from att a where a.is_returning))
    into v_weeks, v_totals
    from per_week pw;

  select count(*)::integer into v_members
    from public.chapter_members cm
    join public.profiles p on p.id = cm.user_id and p.status <> 'deleted'
   where cm.chapter_id = p_chapter;

  return jsonb_build_object(
    'chapter_id', p_chapter,
    'weeks', p_weeks,
    'timezone', v_tz,
    'from', v_first,
    'to', v_last + 6,
    'members_count', v_members,
    'totals', v_totals,
    'by_week', v_weeks);
end $$;

revoke all on function public.chapter_dashboard(uuid, integer) from public, anon;
grant execute on function public.chapter_dashboard(uuid, integer) to authenticated, service_role;

-- mod_user_lookup: from 20261217000100_admin_panel.sql; 1 not-found raise(s) now PT404 (Migration 69).
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
    raise exception 'user_not_found' using errcode = 'PT404';
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

revoke all on function public.mod_user_lookup(uuid) from public, anon;
grant execute on function public.mod_user_lookup(uuid) to authenticated, service_role;

insert into public.meta (key, value) values ('schema_version', '2.65')
  on conflict (key) do update set value = excluded.value, updated_at = now();
