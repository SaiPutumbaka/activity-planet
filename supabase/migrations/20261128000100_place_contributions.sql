-- ============================================================================
-- Activity Planet schema v2 — migration 34: members add, correct and report
--   places, and moderators review them (D-041,
--   docs/design/hub-map/HUB_MAP_DESIGN.md sections 5, 6, 7 and 9; build
--   slices 11 and 12).
--   Fixes forward; the one rebuilt function (request_account_deletion)
--   starts from its latest body (migration 27,
--   20261122000100_places_schema.sql) and only gains the lines for the two
--   new tables. places_guard (migration 27) is unchanged and stays the last
--   line of defence for every write below. Checks:
--   supabase/tests/place_contributions.sql (schema_version 2.30).
--
--   What this file does
--     1. place_edits: a correction to a place (allowlisted changes: name,
--        kind, location {lat,lng}, address_text, locality, opening_hours,
--        website, closed, hubs_add), its proposer, note and review state
--        (pending, approved, rejected, superseded, applied = the creator's
--        own unreviewed pin, changed at once). place_reports: one open
--        report per person per place (reason closed, wrong_location,
--        wrong_info, not_public, private_residence, unsafe, spam, other).
--        Both are readable by their author and moderators only; the author
--        and reviewer columns are never client-readable; no client writes.
--     2. Internal helpers (no client execute):
--          * place_caller_can_see(id): the places RLS rule for the caller
--            (own rows, moderators, active public imports for everyone
--            signed in, active public member and meeting spot rows for
--            adults), so the definer RPCs act only on what the caller sees;
--          * place_check_hubs(hubs, kind, default): 0 to 3 distinct active
--            hubs that are not events-only and not sensitive (design 7
--            rule 6: hub_not_allowed); none passed = up to 3 of the
--            caller's joined hubs whose rules show this kind;
--          * place_near_private(uid, point): near_your_home (150 m of the
--            saved home point or location) or near_private_venue (50 m of
--            one of the caller's private venues), else null (rule 2; the
--            same test places_guard applies);
--          * place_duplicates(kind, name, point, exclude): up to 5 places
--            the caller can see within 60 m with the same kind or the same
--            or a close name (trigram 0.45), nearest first;
--          * place_apply_changes(place, changes, via, lock): applies a
--            validated change set; with lock (an imported row) the changed
--            fields go into locked_fields so the extract never overwrites
--            them (design 5).
--     3. add_place(args jsonb), onboarded users: name (2 to 120), kind,
--        lat/lng, hub_ids (0 to 3; a public place needs one), is_public
--        (default false: "Only me"), confirm_public (required for
--        "Everyone": "This is a public place, not a home or private
--        residence"), website, opening_hours, address_text, locality,
--        allow_duplicate. Rules, in order: rate_limited (10 new places a
--        day, moderators exempt), near_your_home / near_private_venue
--        (public only), duplicate_candidates (detail = the candidates as
--        JSON, unless allow_duplicate). A private pin is active and seen
--        only by its creator; a public one is pending until a moderator
--        approves it (rules 1 and 3); a moderator's public place is active
--        at once (founder answer 6: outreach seeds reviewed places). Member
--        hub links are via 'member'. Returns {id, status, is_public,
--        hub_ids}.
--     4. suggest_place_edit(place, changes, note), onboarded users, 30 a
--        day (rate_limited): on a place the caller can see. The caller's
--        own private or pending pin changes at once (status 'applied'); a
--        moderator's change applies at once (approved, imported fields
--        locked); everything else is queued as 'pending' and replaces the
--        caller's earlier pending edit of that place (superseded). Meeting
--        spots follow their venue and take reports only (meeting_spot).
--     5. report_place(place, reason, note), onboarded users, 20 a day
--        (rate_limited), not on one's own place (own_place); a second
--        report of the same place while one is open returns it (already).
--        Rule 4: private_residence or unsafe on a member or meeting spot
--        place hides it at once; three open reports from different
--        accounts hide any place. Hidden rows stay hidden through the
--        extract and the meeting spot refresh until a moderator decides.
--     6. set_my_place_visibility(place, public, confirm) and
--        delete_my_place(place): the creator's own pin. Private to public
--        needs confirm_public and a hub, passes rule 2 and goes pending;
--        pending back to private is a withdrawal. A reviewed public place
--        is a shared ODbL fact and can only be corrected or reported
--        (reviewed_place).
--     7. Moderation (slice 12), moderators only:
--          * place_mod_actions: a log of every decision (place, item,
--            action, moderator, note); moderators read.
--          * mod_place_queue(limit): oldest first, pending public member
--            places, pending edits (with the current values and how far a
--            move goes) and places with open reports (counts, distinct
--            reporters, reasons, up to 20 reports), each with the place's
--            facts, explicit hub links, the adding account's age in days
--            and up to three public places within 150 m. Never who added,
--            proposed or reported anything.
--          * mod_resolve_place(kind, id, action, note): place approve
--            (active; places_guard re-checks rule 2) / reject (back to the
--            member's private pin) / remove; edit approve (applied; an
--            imported row's changed fields join locked_fields, design 5) /
--            reject; reports dismiss (a place they hid comes back) / hide /
--            remove / close (an imported row locks closed). Never on the
--            moderator's own place or suggestion (own_item).
--     8. request_account_deletion (migration 27 body): the caller's pending
--        edits go; the rest of their edits and every report lose the
--        author and note (reports keep their reason, so a place hidden by
--        them stays in the queue); reviewer stamps and the moderator link in
--        place_mod_actions are cleared.
--     * Grants: the RPCs are executable by authenticated and service_role
--       only (the moderation ones refuse non-moderators with forbidden);
--       the helpers by nobody but service_role. meta.schema_version
--       2.30.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. place_edits and place_reports
-- ---------------------------------------------------------------------------
create table if not exists public.place_edits (
  id          uuid primary key default gen_random_uuid(),
  place_id    uuid not null references public.places (id) on delete cascade,
  proposed_by uuid references public.profiles (id) on delete set null,
  changes     jsonb not null,
  note        text not null default '',
  status      text not null default 'pending',
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  review_note text,
  created_at  timestamptz not null default now(),
  constraint place_edits_status check (status in ('pending', 'approved', 'rejected', 'superseded', 'applied')),
  constraint place_edits_note_length check (char_length(note) <= 500),
  constraint place_edits_review_note_length check (review_note is null or char_length(review_note) <= 500),
  constraint place_edits_changes_shape check (
    jsonb_typeof(changes) = 'object' and changes <> '{}'::jsonb and pg_column_size(changes) <= 2048
    and (changes - array['name', 'kind', 'location', 'address_text', 'locality', 'opening_hours', 'website',
                         'closed', 'hubs_add']::text[]) = '{}'::jsonb)
);
create index if not exists place_edits_queue_idx on public.place_edits (created_at) where status = 'pending';
create index if not exists place_edits_place_idx on public.place_edits (place_id);
create index if not exists place_edits_proposer_idx on public.place_edits (proposed_by, created_at)
  where proposed_by is not null;
create unique index if not exists place_edits_one_pending on public.place_edits (place_id, proposed_by)
  where status = 'pending' and proposed_by is not null;
comment on table public.place_edits is
  'Hub map corrections (D-041, design 5 and 7): an allowlisted change set to a place. pending = waiting for a moderator; applied = the creator changed their own unreviewed pin; approved and rejected = reviewed; superseded = replaced by a later edit or the place went. Readable by the proposer and moderators; written only by suggest_place_edit and the moderation RPCs.';

create table if not exists public.place_reports (
  id          uuid primary key default gen_random_uuid(),
  place_id    uuid not null references public.places (id) on delete cascade,
  reporter_id uuid references public.profiles (id) on delete set null,
  reason      text not null,
  note        text not null default '',
  status      text not null default 'open',
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  created_at  timestamptz not null default now(),
  constraint place_reports_reason check (reason in ('closed', 'wrong_location', 'wrong_info', 'not_public',
                                                   'private_residence', 'unsafe', 'spam', 'other')),
  constraint place_reports_status check (status in ('open', 'actioned', 'dismissed')),
  constraint place_reports_note_length check (char_length(note) <= 500)
);
create unique index if not exists place_reports_one_open on public.place_reports (place_id, reporter_id)
  where status = 'open';
create index if not exists place_reports_queue_idx on public.place_reports (place_id, created_at) where status = 'open';
create index if not exists place_reports_reporter_idx on public.place_reports (reporter_id, created_at)
  where reporter_id is not null;
comment on table public.place_reports is
  'Hub map reports (D-041, design 7 rule 4): one open report per person per place. private_residence or unsafe hides a member or meeting spot place at once; three open reports from different accounts hide any place. Readable by the reporter and moderators; written only by report_place and the moderation RPCs.';

alter table public.place_edits   enable row level security;
alter table public.place_reports enable row level security;
revoke all on public.place_edits, public.place_reports from public, anon, authenticated;
grant all on public.place_edits, public.place_reports to service_role;
-- Author and reviewer ids are never client-readable; RLS still keys on them.
grant select (id, place_id, changes, note, status, reviewed_at, review_note, created_at)
  on public.place_edits to authenticated;
grant select (id, place_id, reason, note, status, resolved_at, created_at)
  on public.place_reports to authenticated;

drop policy if exists "place_edits_select" on public.place_edits;
create policy "place_edits_select" on public.place_edits for select to authenticated
  using (proposed_by = (select auth.uid()) or (select public.is_moderator()));
drop policy if exists "place_reports_select" on public.place_reports;
create policy "place_reports_select" on public.place_reports for select to authenticated
  using (reporter_id = (select auth.uid()) or (select public.is_moderator()));

-- ---------------------------------------------------------------------------
-- 2. Internal helpers
-- ---------------------------------------------------------------------------
create or replace function public.place_caller_can_see(p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and exists (
    select 1 from public.places p
     where p.id = p_id
       and (p.created_by = (select auth.uid())
            or public.is_moderator()
            or (p.status = 'active' and p.is_public
                and (p.source in ('osm', 'geoapify') or public.viewer_is_adult()))));
$$;
comment on function public.place_caller_can_see(uuid) is
  'Hub map (D-041), internal: the places_select_authenticated rule for the signed-in caller, so definer RPCs only act on a place the caller can read.';

create or replace function public.place_check_hubs(p_hubs jsonb, p_kind text, p_default boolean)
returns uuid[] language plpgsql stable security definer set search_path = '' as $$
declare
  v_ids uuid[];
  v_n   integer;
begin
  if p_hubs is null or jsonb_typeof(p_hubs) = 'null' then
    if not p_default then
      return '{}'::uuid[];
    end if;
    -- Pre-filled from the kind's rules (design 9): the caller's joined hubs
    -- that show this kind, specific hubs first, at most three.
    return coalesce(array(
      select h.id
        from public.hub_members hm
        join public.hubs h on h.id = hm.hub_id
        left join public.hub_categories c on c.slug = h.category_slug
       where hm.user_id = (select auth.uid())
         and h.is_active and h.place_mode <> 'none' and not coalesce(c.is_sensitive, false)
         and exists (select 1 from public.hub_place_rules hr
                       join public.place_rules r on r.id = hr.rule_id
                      where hr.hub_id = h.id and r.kind = p_kind)
       order by (h.place_mode = 'specific') desc, hm.joined_at, h.id
       limit 3), '{}'::uuid[]);
  end if;
  if jsonb_typeof(p_hubs) <> 'array' then
    raise exception 'invalid_hubs' using errcode = 'check_violation';
  end if;
  begin
    v_ids := array(select distinct (x #>> '{}')::uuid from jsonb_array_elements(p_hubs) x);
  exception when invalid_text_representation then
    raise exception 'invalid_hubs' using errcode = 'check_violation';
  end;
  if cardinality(v_ids) > 3 then
    raise exception 'too_many_hubs' using errcode = 'check_violation', hint = 'Up to three hubs.';
  end if;
  select count(*) into v_n
    from public.hubs h
    left join public.hub_categories c on c.slug = h.category_slug
   where h.id = any (v_ids) and h.is_active and h.place_mode <> 'none' and not coalesce(c.is_sensitive, false);
  if v_n <> cardinality(v_ids) then
    raise exception 'hub_not_allowed' using errcode = 'check_violation',
      hint = 'Events-only hubs and hubs for faith, identity or health take no member places.';
  end if;
  return v_ids;
end $$;
comment on function public.place_check_hubs(jsonb, text, boolean) is
  'Hub map (D-041), internal: validates 0 to 3 hub ids for a member place (active, not events-only, not sensitive: design 7 rule 6). With none passed and p_default, up to three of the caller''s joined hubs whose rules show the kind.';

create or replace function public.place_near_private(p_uid uuid, p_point extensions.geography)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when exists (select 1 from public.profile_private pp
                  where pp.user_id = p_uid
                    and ((pp.home_point is not null and extensions.ST_DWithin(pp.home_point, p_point, 150))
                      or (pp.location is not null and extensions.ST_DWithin(pp.location, p_point, 150))))
      then 'near_your_home'
    when exists (select 1 from public.venues v
                  where v.created_by = p_uid and not v.is_public and v.location is not null
                    and extensions.ST_DWithin(v.location, p_point, 50))
      then 'near_private_venue'
  end;
$$;
comment on function public.place_near_private(uuid, extensions.geography) is
  'Hub map (D-041, design 7 rule 2), internal: near_your_home within 150 m of the member''s saved home point or location, near_private_venue within 50 m of one of their private venues, else null. places_guard applies the same test to every write.';

create or replace function public.place_raise_near(p_why text)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if p_why = 'near_your_home' then
    raise exception 'near_your_home' using errcode = 'check_violation',
      hint = 'A public place cannot be within 150 m of your saved home. Keep it as a private pin instead.';
  elsif p_why = 'near_private_venue' then
    raise exception 'near_private_venue' using errcode = 'check_violation',
      hint = 'A public place cannot be within 50 m of one of your private addresses.';
  end if;
end $$;
comment on function public.place_raise_near(text) is
  'Hub map (D-041), internal: raises near_your_home or near_private_venue with the explanation the client shows; does nothing for null.';

create or replace function public.place_duplicates(p_kind text, p_name text, p_point extensions.geography,
                                                   p_exclude uuid default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'kind', d.kind,
                                               'distance_m', d.dist, 'mine', d.mine)
                            order by d.dist, d.id), '[]'::jsonb)
    from (select p.id, p.name, p.kind, round(extensions.ST_Distance(p.location, p_point))::integer as dist,
                 (p.created_by = (select auth.uid())) as mine
            from public.places p
           where p.geom operator(extensions.&&) extensions.ST_Expand(p_point::extensions.geometry, 0.002)
             and extensions.ST_DWithin(p.location, p_point, 60)
             and p.id is distinct from p_exclude
             and p.merged_into is null
             and ((p.created_by = (select auth.uid()) and p.status in ('active', 'pending'))
                  or (p.status = 'active' and p.is_public
                      and (p.source in ('osm', 'geoapify') or public.viewer_is_adult())))
             and (p.kind = p_kind
                  or lower(p.name) = lower(p_name)
                  or extensions.similarity(lower(p.name), lower(p_name)) >= 0.45)
           order by extensions.ST_Distance(p.location, p_point), p.id
           limit 5) d;
$$;
comment on function public.place_duplicates(text, text, extensions.geography, uuid) is
  'Hub map (D-041, design 9 step 4), internal: up to five places the caller can see within 60 m with the same kind or the same or a close name (trigram 0.45), nearest first: id, name, kind, distance_m, mine.';

-- Validates a change set and returns it normalised (trimmed text, empty
-- strings as null for the optional fields). Raises on anything else.
create or replace function public.place_clean_changes(p_changes jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  c   jsonb := coalesce(p_changes, '{}'::jsonb);
  o   jsonb := '{}'::jsonb;
  v_t text;
  v_lat double precision;
  v_lng double precision;
begin
  if jsonb_typeof(c) <> 'object' then
    raise exception 'invalid_changes' using errcode = 'check_violation';
  end if;
  if (c - array['name', 'kind', 'location', 'address_text', 'locality', 'opening_hours', 'website',
                'closed', 'hubs_add']::text[]) <> '{}'::jsonb then
    raise exception 'invalid_changes' using errcode = 'check_violation',
      hint = 'Name, kind, location, address, area, hours, website, closed or hubs only.';
  end if;
  if c ? 'name' then
    v_t := btrim(coalesce(c ->> 'name', ''));
    if char_length(v_t) not between 2 and 120 then
      raise exception 'name_length' using errcode = 'check_violation', hint = '2 to 120 characters.';
    end if;
    o := o || jsonb_build_object('name', v_t);
  end if;
  if c ? 'kind' then
    v_t := c ->> 'kind';
    if v_t is null or not exists (select 1 from public.place_kinds k where k.slug = v_t) then
      raise exception 'kind_not_found' using errcode = 'check_violation';
    end if;
    o := o || jsonb_build_object('kind', v_t);
  end if;
  if c ? 'location' then
    begin
      v_lat := (c #>> '{location,lat}')::double precision;
      v_lng := (c #>> '{location,lng}')::double precision;
    exception when others then
      raise exception 'invalid_coordinates' using errcode = 'check_violation';
    end;
    if v_lat is null or v_lng is null or v_lat not between -90 and 90 or v_lng not between -180 and 180 then
      raise exception 'invalid_coordinates' using errcode = 'check_violation';
    end if;
    o := o || jsonb_build_object('location', jsonb_build_object('lat', round(v_lat::numeric, 6), 'lng', round(v_lng::numeric, 6)));
  end if;
  if c ? 'address_text' then
    v_t := btrim(coalesce(c ->> 'address_text', ''));
    if char_length(v_t) > 200 then
      raise exception 'address_length' using errcode = 'check_violation', hint = 'Up to 200 characters.';
    end if;
    o := o || jsonb_build_object('address_text', v_t);
  end if;
  if c ? 'locality' then
    v_t := btrim(coalesce(c ->> 'locality', ''));
    if char_length(v_t) > 120 then
      raise exception 'locality_length' using errcode = 'check_violation', hint = 'Up to 120 characters.';
    end if;
    o := o || jsonb_build_object('locality', v_t);
  end if;
  if c ? 'opening_hours' then
    v_t := nullif(btrim(coalesce(c ->> 'opening_hours', '')), '');
    if v_t is not null and char_length(v_t) > 255 then
      raise exception 'hours_length' using errcode = 'check_violation', hint = 'Up to 255 characters.';
    end if;
    o := o || jsonb_build_object('opening_hours', v_t);
  end if;
  if c ? 'website' then
    v_t := nullif(btrim(coalesce(c ->> 'website', '')), '');
    if v_t is not null and (v_t !~ '^https?://[^\s/$.?#][^\s]*$' or char_length(v_t) > 500) then
      raise exception 'website_invalid' using errcode = 'check_violation', hint = 'A link starting with https://.';
    end if;
    o := o || jsonb_build_object('website', v_t);
  end if;
  if c ? 'closed' then
    if jsonb_typeof(c -> 'closed') <> 'boolean' then
      raise exception 'invalid_changes' using errcode = 'check_violation';
    end if;
    o := o || jsonb_build_object('closed', c -> 'closed');
  end if;
  if c ? 'hubs_add' then
    o := o || jsonb_build_object('hubs_add', to_jsonb(public.place_check_hubs(c -> 'hubs_add', null, false)));
    if o -> 'hubs_add' = '[]'::jsonb then
      o := o - 'hubs_add';
    end if;
  end if;
  return o;
end $$;
comment on function public.place_clean_changes(jsonb) is
  'Hub map (D-041), internal: validates and normalises a place change set (name 2 to 120, kind, location {lat,lng}, address_text up to 200, locality up to 120, opening_hours up to 255, website http(s) up to 500, closed boolean, hubs_add up to 3 allowed hubs). Raises invalid_changes, name_length, kind_not_found, invalid_coordinates, address_length, locality_length, hours_length, website_invalid, too_many_hubs, hub_not_allowed.';

create or replace function public.place_apply_changes(p_place uuid, p_changes jsonb, p_via text, p_lock boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c      jsonb := coalesce(p_changes, '{}'::jsonb);
  p      public.places%rowtype;
  v_lock text[];
  v_hub  uuid;
begin
  select * into p from public.places where id = p_place for update;
  if not found then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;
  v_lock := p.locked_fields;
  if p_lock then
    v_lock := array(select distinct f from unnest(v_lock || array(
                select k from jsonb_object_keys(c - 'hubs_add') k)) f order by f);
  end if;

  update public.places
     set name          = case when c ? 'name' then c ->> 'name' else name end,
         kind          = case when c ? 'kind' then c ->> 'kind' else kind end,
         location      = case when c ? 'location' then
                           extensions.ST_SetSRID(extensions.ST_MakePoint((c #>> '{location,lng}')::double precision,
                                                                         (c #>> '{location,lat}')::double precision),
                                                 4326)::extensions.geography
                         else location end,
         address_text  = case when c ? 'address_text' then c ->> 'address_text' else address_text end,
         locality      = case when c ? 'locality' then c ->> 'locality' else locality end,
         opening_hours = case when c ? 'opening_hours' then c ->> 'opening_hours' else opening_hours end,
         website       = case when c ? 'website' then c ->> 'website' else website end,
         status        = case when c ? 'closed' and (c ->> 'closed')::boolean and status = 'active'
                                then 'closed'::public.place_status
                              when c ? 'closed' and not (c ->> 'closed')::boolean and status = 'closed'
                                then 'active'::public.place_status
                              else status end,
         locked_fields = v_lock
   where id = p.id;

  if c ? 'hubs_add' then
    for v_hub in select (x #>> '{}')::uuid from jsonb_array_elements(c -> 'hubs_add') x loop
      insert into public.place_hubs (place_id, hub_id, via)
      values (p.id, v_hub, p_via)
      on conflict (place_id, hub_id) do update
         set via = excluded.via, weight = greatest(public.place_hubs.weight, 1)
       where public.place_hubs.via = 'events';   -- an explicit link outranks a plan count
    end loop;
  end if;
end $$;
comment on function public.place_apply_changes(uuid, jsonb, text, boolean) is
  'Hub map (D-041), internal: applies a cleaned change set to a place (closed true closes an active place, false reopens a closed one; hubs_add adds explicit links via member or moderator). With p_lock (an imported row) the changed fields join locked_fields, so the extract keeps them (design 5). places_guard still checks the result.';

-- ---------------------------------------------------------------------------
-- 3. add_place
-- ---------------------------------------------------------------------------
create or replace function public.add_place(p_args jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  a        jsonb := coalesce(p_args, '{}'::jsonb);
  v_mod    boolean;
  v_public boolean;
  v_clean  jsonb;
  v_kind   text := a ->> 'kind';
  v_lat    double precision;
  v_lng    double precision;
  v_point  extensions.geography;
  v_hubs   uuid[];
  v_why    text;
  v_dups   jsonb;
  v_id     uuid;
  v_status public.place_status;
  v_hub    uuid;
  v_c      text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and deleted_at is null
                    and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(a) <> 'object' then
    raise exception 'invalid_args' using errcode = 'check_violation';
  end if;
  v_mod := public.is_moderator();
  begin
    v_public := coalesce((a ->> 'is_public')::boolean, false);   -- "Only me" unless asked (design 7 rule 1)
    v_lat := (a ->> 'lat')::double precision;
    v_lng := (a ->> 'lng')::double precision;
  exception when invalid_text_representation then
    raise exception 'invalid_args' using errcode = 'check_violation';
  end;
  if v_lat is null or v_lng is null or v_lat not between -90 and 90 or v_lng not between -180 and 180 then
    raise exception 'invalid_coordinates' using errcode = 'check_violation';
  end if;
  if v_kind is null then
    raise exception 'kind_not_found' using errcode = 'check_violation';
  end if;
  v_clean := public.place_clean_changes(jsonb_strip_nulls(jsonb_build_object(
    'name', coalesce(a ->> 'name', ''), 'kind', v_kind,
    'address_text', a ->> 'address_text', 'locality', a ->> 'locality',
    'opening_hours', a ->> 'opening_hours', 'website', a ->> 'website')));
  v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography;
  v_hubs := public.place_check_hubs(a -> 'hub_ids', v_kind, true);

  if v_public then
    if coalesce((a ->> 'confirm_public')::boolean, false) is not true then
      raise exception 'confirm_public_required' using errcode = 'check_violation',
        hint = 'Confirm this is a public place, not a home or private residence.';
    end if;
    if cardinality(v_hubs) = 0 then
      raise exception 'hub_required' using errcode = 'check_violation',
        hint = 'Pick at least one hub this place is for.';
    end if;
  end if;

  -- Rule 9: ten new places a day (places_guard counts the same rows).
  if not v_mod then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('places_new:' || uid::text));
    if (select count(*) from public.places x
         where x.created_by = uid and x.source = 'user' and x.created_at > now() - interval '1 day') >= 10 then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = 'Up to ten new places a day.';
    end if;
  end if;

  -- Rule 2: never a public pin at or beside the member's home.
  if v_public then
    perform public.place_raise_near(public.place_near_private(uid, v_point));
  end if;

  -- Duplicate check (design 9 step 4): the client shows the candidates and
  -- can send allow_duplicate after the member says theirs is different.
  if coalesce((a ->> 'allow_duplicate')::boolean, false) is not true then
    v_dups := public.place_duplicates(v_kind, v_clean ->> 'name', v_point, null);
    if jsonb_array_length(v_dups) > 0 then
      raise exception 'duplicate_candidates' using errcode = 'check_violation',
        detail = v_dups::text, hint = 'A place like this is already here.';
    end if;
  end if;

  v_status := case when v_public and not v_mod then 'pending'::public.place_status
                   else 'active'::public.place_status end;
  insert into public.places (source, name, kind, location, address_text, locality, opening_hours, website,
                             is_public, status, created_by, attribution)
  values ('user', v_clean ->> 'name', v_kind, v_point,
          coalesce(v_clean ->> 'address_text', ''), coalesce(v_clean ->> 'locality', ''),
          v_clean ->> 'opening_hours', v_clean ->> 'website',
          v_public, v_status, uid, 'Added by an Activity Planet member')
  returning id, status into v_id, v_status;

  foreach v_hub in array v_hubs loop
    insert into public.place_hubs (place_id, hub_id, via)
    values (v_id, v_hub, case when v_mod then 'moderator' else 'member' end)
    on conflict (place_id, hub_id) do nothing;
  end loop;

  return jsonb_build_object('id', v_id, 'status', v_status, 'is_public', v_public, 'hub_ids', to_jsonb(v_hubs));
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;
comment on function public.add_place(jsonb) is
  'Hub map (D-041, design 5, 7 and 9), onboarded users: adds a member place. Args: name, kind, lat, lng, hub_ids (0 to 3; none = up to 3 joined hubs that show the kind; a public place needs one), is_public (default false), confirm_public (required when public), address_text, locality, opening_hours, website, allow_duplicate. Errors: not_authenticated, onboarding_required, invalid_coordinates, kind_not_found, name_length, website_invalid, hub_not_allowed, too_many_hubs, hub_required, confirm_public_required, rate_limited (10 a day), near_your_home, near_private_venue, duplicate_candidates (detail: JSON candidates). A private pin is active for its creator only; a public one is pending until a moderator approves (a moderator''s is active). Returns {id, status, is_public, hub_ids}.';

-- ---------------------------------------------------------------------------
-- 4. suggest_place_edit
-- ---------------------------------------------------------------------------
create or replace function public.suggest_place_edit(p_place uuid, p_changes jsonb, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  p       public.places%rowtype;
  v_mod   boolean;
  v_clean jsonb;
  v_note  text := left(btrim(coalesce(p_note, '')), 500);
  v_own   boolean;
  v_id    uuid;
  v_st    text;
  v_why   text;
  v_c     text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and deleted_at is null
                    and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_place is null or not public.place_caller_can_see(p_place) then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;
  select * into p from public.places where id = p_place for update;
  if p.status in ('hidden', 'removed') or p.merged_into is not null then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;
  if p.source = 'venue' then
    raise exception 'meeting_spot' using errcode = 'check_violation',
      hint = 'Meeting spots follow their plans'' venue. Report it if something is wrong.';
  end if;
  v_mod := public.is_moderator();
  v_clean := public.place_clean_changes(p_changes);
  if v_clean = '{}'::jsonb then
    raise exception 'no_changes' using errcode = 'check_violation';
  end if;

  -- Rule 9: thirty edits a day (every kind of edit counts).
  if not v_mod then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('place_edits:' || uid::text));
    if (select count(*) from public.place_edits e
         where e.proposed_by = uid and e.created_at > now() - interval '1 day') >= 30 then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = 'Up to thirty edits a day.';
    end if;
  end if;

  v_own := p.source = 'user' and p.created_by = uid and (not p.is_public or p.status = 'pending');

  -- Rule 2 for a move of a public member place: refuse it here with a clear
  -- reason (places_guard refuses it again on apply).
  if v_clean ? 'location' and p.source = 'user' and p.is_public and p.created_by is not null then
    v_why := public.place_near_private(p.created_by,
               extensions.ST_SetSRID(extensions.ST_MakePoint((v_clean #>> '{location,lng}')::double precision,
                                                             (v_clean #>> '{location,lat}')::double precision),
                                     4326)::extensions.geography);
    if v_why is not null and (p.created_by = uid or v_mod) then
      perform public.place_raise_near(v_why);
    end if;
  end if;

  if v_own or v_mod then
    perform public.place_apply_changes(p.id, v_clean,
                                       case when v_mod then 'moderator' else 'member' end,
                                       v_mod and p.source in ('osm', 'geoapify'));
    v_st := case when v_own and not v_mod then 'applied' else 'approved' end;
    update public.place_edits set status = 'superseded'
     where place_id = p.id and proposed_by = uid and status = 'pending';
    insert into public.place_edits (place_id, proposed_by, changes, note, status, reviewed_by, reviewed_at)
    values (p.id, uid, v_clean, v_note, v_st, case when v_mod then uid end, now())
    returning id into v_id;
    return jsonb_build_object('id', v_id, 'status', v_st, 'applied', true);
  end if;

  update public.place_edits set status = 'superseded'
   where place_id = p.id and proposed_by = uid and status = 'pending';
  insert into public.place_edits (place_id, proposed_by, changes, note)
  values (p.id, uid, v_clean, v_note)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'status', 'pending', 'applied', false);
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;
comment on function public.suggest_place_edit(uuid, jsonb, text) is
  'Hub map corrections (D-041, design 5 and 7), onboarded users, 30 a day (rate_limited): an allowlisted change set (place_clean_changes) to a place the caller can see. The creator''s own private or pending pin changes at once (applied); a moderator''s change applies at once (approved; an imported row''s changed fields are locked); otherwise it is queued (pending) and replaces the caller''s earlier pending edit of the place. Meeting spots refuse edits (meeting_spot). Moving a public member place next to its creator''s home or private venue is refused (near_your_home, near_private_venue). Returns {id, status, applied}.';

-- ---------------------------------------------------------------------------
-- 5. report_place
-- ---------------------------------------------------------------------------
create or replace function public.report_place(p_place uuid, p_reason text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  p       public.places%rowtype;
  v_note  text := left(btrim(coalesce(p_note, '')), 500);
  v_id    uuid;
  v_n     integer;
  v_hide  boolean := false;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and deleted_at is null
                    and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_reason is null or p_reason not in ('closed', 'wrong_location', 'wrong_info', 'not_public',
                                          'private_residence', 'unsafe', 'spam', 'other') then
    raise exception 'invalid_reason' using errcode = 'check_violation';
  end if;
  if p_place is null or not public.place_caller_can_see(p_place) then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;
  select * into p from public.places where id = p_place for update;
  if p.status not in ('active', 'closed') then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;
  if p.created_by = uid then
    raise exception 'own_place' using errcode = 'check_violation',
      hint = 'Edit or delete your own place instead.';
  end if;

  select r.id into v_id from public.place_reports r
   where r.place_id = p.id and r.reporter_id = uid and r.status = 'open';
  if v_id is not null then
    return jsonb_build_object('id', v_id, 'already', true, 'hidden', p.status = 'hidden');
  end if;

  -- Rule 9: twenty reports a day.
  if not public.is_moderator() then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('place_reports:' || uid::text));
    if (select count(*) from public.place_reports r
         where r.reporter_id = uid and r.created_at > now() - interval '1 day') >= 20 then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = 'Up to twenty reports a day.';
    end if;
  end if;

  insert into public.place_reports (place_id, reporter_id, reason, note)
  values (p.id, uid, p_reason, v_note)
  returning id into v_id;

  -- Rule 4.
  if p.status = 'active' then
    if p_reason in ('private_residence', 'unsafe') and p.source in ('user', 'venue') then
      v_hide := true;
    else
      select count(distinct r.reporter_id) into v_n from public.place_reports r
       where r.place_id = p.id and r.status = 'open' and r.reporter_id is not null;
      v_hide := v_n >= 3;
    end if;
    if v_hide then
      update public.places set status = 'hidden' where id = p.id;
    end if;
  end if;

  return jsonb_build_object('id', v_id, 'already', false, 'hidden', v_hide);
end $$;
comment on function public.report_place(uuid, text, text) is
  'Hub map reports (D-041, design 7 rules 4 and 9), onboarded users, 20 a day (rate_limited): one open report per person per place (a repeat returns it with already = true), on an active or closed place the caller can see that is not their own (own_place). private_residence or unsafe hides a member or meeting spot place at once; three open reports from different accounts hide any place. Errors: invalid_reason, place_not_found. Returns {id, already, hidden}.';

-- ---------------------------------------------------------------------------
-- 6. The creator's own pin: visibility and delete
-- ---------------------------------------------------------------------------
create or replace function public.set_my_place_visibility(p_place uuid, p_public boolean, p_confirm boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid   uuid := (select auth.uid());
  p     public.places%rowtype;
  v_why text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into p from public.places where id = p_place and created_by = uid and source = 'user' for update;
  if not found or p.status not in ('active', 'pending') then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;
  if p_public is null then
    raise exception 'invalid_args' using errcode = 'check_violation';
  end if;
  if p.is_public and p.status = 'active' then
    raise exception 'reviewed_place' using errcode = 'check_violation',
      hint = 'A reviewed public place stays on the map for everyone. Suggest a correction or report it instead.';
  end if;
  if p_public = p.is_public then
    return jsonb_build_object('id', p.id, 'status', p.status, 'is_public', p.is_public);
  end if;

  if p_public then
    if not coalesce(p_confirm, false) then
      raise exception 'confirm_public_required' using errcode = 'check_violation',
        hint = 'Confirm this is a public place, not a home or private residence.';
    end if;
    if not exists (select 1 from public.place_hubs ph where ph.place_id = p.id) then
      raise exception 'hub_required' using errcode = 'check_violation',
        hint = 'Pick at least one hub this place is for.';
    end if;
    perform public.place_raise_near(public.place_near_private(uid, p.location));
    update public.places
       set is_public = true,
           status    = case when public.is_moderator() then 'active'::public.place_status
                            else 'pending'::public.place_status end
     where id = p.id
     returning * into p;
  else
    update public.places set is_public = false, status = 'active' where id = p.id returning * into p;
  end if;
  return jsonb_build_object('id', p.id, 'status', p.status, 'is_public', p.is_public);
end $$;
comment on function public.set_my_place_visibility(uuid, boolean, boolean) is
  'Hub map (D-041, design 7 rules 1 to 3): the creator''s own pin. Private to public needs p_confirm (confirm_public_required) and a hub link (hub_required), passes rule 2 (near_your_home, near_private_venue) and goes pending (a moderator''s goes active); pending back to private withdraws the request. A reviewed public place is refused (reviewed_place). Returns {id, status, is_public}.';

create or replace function public.delete_my_place(p_place uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  p   public.places%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into p from public.places where id = p_place and created_by = uid and source = 'user' for update;
  if not found then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;
  if p.is_public and p.status not in ('pending') then
    raise exception 'reviewed_place' using errcode = 'check_violation',
      hint = 'A reviewed public place stays on the map for everyone. Report it as closed if it is gone.';
  end if;
  delete from public.places where id = p.id;
end $$;
comment on function public.delete_my_place(uuid) is
  'Hub map (D-041): deletes the caller''s own private pin or still-pending request (its links, edits and reports go with it). A reviewed public place is refused (reviewed_place).';

-- ---------------------------------------------------------------------------
-- 7. Moderation: place_mod_actions, mod_place_queue, mod_resolve_place
--    (slice 12)
-- ---------------------------------------------------------------------------
create table if not exists public.place_mod_actions (
  id           uuid primary key default gen_random_uuid(),
  place_id     uuid not null references public.places (id) on delete cascade,
  item_kind    text not null,
  item_id      uuid not null,
  action       text not null,
  moderator_id uuid references public.profiles (id) on delete set null,
  note         text,
  created_at   timestamptz not null default now(),
  constraint place_mod_actions_kind check (item_kind in ('place', 'edit', 'reports')),
  constraint place_mod_actions_action check (action in ('approve', 'reject', 'remove', 'dismiss', 'hide', 'close')),
  constraint place_mod_actions_note_length check (note is null or char_length(note) <= 500)
);
create index if not exists place_mod_actions_place_idx on public.place_mod_actions (place_id, created_at);
create index if not exists place_mod_actions_moderator_idx on public.place_mod_actions (moderator_id)
  where moderator_id is not null;
comment on table public.place_mod_actions is
  'Hub map moderation log (D-041, slice 12): every mod_resolve_place decision with its moderator and note. Moderators read; written only by mod_resolve_place. The moderator link is cleared on account deletion.';

alter table public.place_mod_actions enable row level security;
revoke all on public.place_mod_actions from public, anon, authenticated;
grant all on public.place_mod_actions to service_role;
grant select on public.place_mod_actions to authenticated;
drop policy if exists "place_mod_actions_select_mod" on public.place_mod_actions;
create policy "place_mod_actions_select_mod" on public.place_mod_actions for select to authenticated
  using ((select public.is_moderator()));

-- The facts a moderator needs about one place (never who added it).
create or replace function public.mod_place_facts(p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'name', p.name, 'kind', p.kind, 'kind_label', k.label,
    'lat', round(p.lat::numeric, 6)::double precision, 'lng', round(p.lng::numeric, 6)::double precision,
    'address_text', nullif(p.address_text, ''), 'locality', nullif(p.locality, ''),
    'opening_hours', p.opening_hours, 'website', p.website,
    'source', p.source, 'status', p.status, 'is_public', p.is_public, 'locked_fields', to_jsonb(p.locked_fields),
    'member_added', p.source = 'user',
    'osm_url', case when p.osm_ref is not null then
                 'https://www.openstreetmap.org/'
                 || case left(p.osm_ref, 1) when 'n' then 'node' when 'w' then 'way' else 'relation' end
                 || '/' || substr(p.osm_ref, 2) end,
    'creator_account_days', case when p.source = 'user' and p.created_by is not null then
        (select (current_date - pr.created_at::date) from public.profiles pr where pr.id = p.created_by) end,
    'hubs', coalesce((
        select jsonb_agg(jsonb_build_object('id', h.id, 'slug', h.slug, 'name', h.name, 'emoji', h.emoji,
                                            'via', ph.via) order by h.name, h.id)
          from public.place_hubs ph join public.hubs h on h.id = ph.hub_id
         where ph.place_id = p.id), '[]'::jsonb),
    'nearby', coalesce((
        select jsonb_agg(jsonb_build_object('id', n.id, 'name', n.name, 'kind', n.kind, 'distance_m', n.dist)
                         order by n.dist, n.id)
          from (select q.id, q.name, q.kind, round(extensions.ST_Distance(q.location, p.location))::integer as dist
                  from public.places q
                 where q.id <> p.id and q.status = 'active' and q.is_public
                   and q.geom operator(extensions.&&) extensions.ST_Expand(p.geom, 0.003)
                   and extensions.ST_DWithin(q.location, p.location, 150)
                 order by extensions.ST_Distance(q.location, p.location), q.id
                 limit 3) n), '[]'::jsonb))
    from public.places p
    join public.place_kinds k on k.slug = p.kind
   where p.id = p_id;
$$;
comment on function public.mod_place_facts(uuid) is
  'Hub map moderation (D-041), internal: a place''s card for the queue (name, kind, point, address, hours, website, source, status, visibility, locked fields, OSM link, explicit hub links, how many days old the adding account is, up to three active public places within 150 m). Never who added it.';

create or replace function public.mod_place_queue(p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_items jsonb;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  with q as (
    -- Pending public member places (design 7 rules 1 and 3).
    select 'place'::text as kind, p.id, p.id as place_id, p.created_at,
           jsonb_build_object('own', p.created_by = uid) as extra
      from public.places p
     where p.source = 'user' and p.is_public and p.status = 'pending'
    union all
    -- Pending corrections on places that still exist.
    select 'edit', e.id, e.place_id, e.created_at,
           jsonb_build_object(
             'changes', e.changes, 'note', nullif(e.note, ''),
             'current', (select jsonb_strip_nulls(jsonb_build_object(
                           'name', case when e.changes ? 'name' then to_jsonb(p.name) end,
                           'kind', case when e.changes ? 'kind' then to_jsonb(p.kind) end,
                           'location', case when e.changes ? 'location' then
                             jsonb_build_object('lat', round(p.lat::numeric, 6), 'lng', round(p.lng::numeric, 6)) end,
                           'address_text', case when e.changes ? 'address_text' then to_jsonb(p.address_text) end,
                           'locality', case when e.changes ? 'locality' then to_jsonb(p.locality) end,
                           'opening_hours', case when e.changes ? 'opening_hours' then coalesce(to_jsonb(p.opening_hours), '""'::jsonb) end,
                           'website', case when e.changes ? 'website' then coalesce(to_jsonb(p.website), '""'::jsonb) end,
                           'closed', case when e.changes ? 'closed' then to_jsonb(p.status = 'closed') end))
                           from public.places p where p.id = e.place_id),
             'move_m', case when e.changes ? 'location' then
               (select round(extensions.ST_Distance(p.location,
                  extensions.ST_SetSRID(extensions.ST_MakePoint((e.changes #>> '{location,lng}')::double precision,
                                                                (e.changes #>> '{location,lat}')::double precision),
                                        4326)::extensions.geography))::integer
                  from public.places p where p.id = e.place_id) end,
             'own', e.proposed_by = uid)
      from public.place_edits e
      join public.places p on p.id = e.place_id
     where e.status = 'pending' and p.status <> 'removed'
    union all
    -- Places with open reports, one item per place.
    select 'reports', r.place_id, r.place_id, min(r.created_at),
           jsonb_build_object(
             'open', count(*),
             'reporters', count(distinct r.reporter_id),
             'reasons', (select jsonb_object_agg(x.reason, x.n)
                           from (select r2.reason, count(*) as n from public.place_reports r2
                                  where r2.place_id = r.place_id and r2.status = 'open'
                                  group by r2.reason) x),
             'reports', (select jsonb_agg(jsonb_build_object('id', r3.id, 'reason', r3.reason,
                                                             'note', nullif(r3.note, ''), 'created_at', r3.created_at)
                                          order by r3.created_at, r3.id)
                           from (select * from public.place_reports r4
                                  where r4.place_id = r.place_id and r4.status = 'open'
                                  order by r4.created_at, r4.id limit 20) r3),
             'own', bool_and(r.reporter_id is not distinct from uid))
      from public.place_reports r
     where r.status = 'open'
     group by r.place_id
  ), picked as (
    select * from q order by q.created_at, q.kind, q.id limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'id', x.id, 'created_at', x.created_at,
                                               'place', public.mod_place_facts(x.place_id))
                            || x.extra
                            order by x.created_at, x.kind, x.id), '[]'::jsonb)
    into v_items
    from picked x;

  return jsonb_build_object(
    'v', 1,
    'items', v_items,
    'counts', jsonb_build_object(
      'places', (select count(*) from public.places p where p.source = 'user' and p.is_public and p.status = 'pending'),
      'edits', (select count(*) from public.place_edits e join public.places p on p.id = e.place_id
                 where e.status = 'pending' and p.status <> 'removed'),
      'reports', (select count(distinct r.place_id) from public.place_reports r where r.status = 'open')));
end $$;
comment on function public.mod_place_queue(integer) is
  'Hub map moderation queue (D-041, slice 12), moderators only (forbidden): oldest first, up to p_limit (1 to 200, default 50) items of three kinds: place (a pending public member place), edit (a pending correction with changes, the current values of those fields, move_m for a move and the note) and reports (a place with open reports: count, distinct reporters, reasons, up to 20 reports). Each item carries the place facts (mod_place_facts) and own (the moderator''s own item, which another moderator decides). counts gives the totals. Never who added, proposed or reported anything.';

create or replace function public.mod_resolve_place(p_kind text, p_id uuid, p_action text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_note  text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  p       public.places%rowtype;
  e       public.place_edits%rowtype;
  v_clean jsonb;
  v_c     text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_kind is null or p_kind not in ('place', 'edit', 'reports') or p_id is null then
    raise exception 'invalid_item' using errcode = 'check_violation';
  end if;
  if p_action is null or not (
       (p_kind = 'place'   and p_action in ('approve', 'reject', 'remove'))
    or (p_kind = 'edit'    and p_action in ('approve', 'reject'))
    or (p_kind = 'reports' and p_action in ('dismiss', 'hide', 'remove', 'close'))) then
    raise exception 'invalid_action' using errcode = 'check_violation';
  end if;

  if p_kind = 'edit' then
    select * into e from public.place_edits where id = p_id for update;
    if not found or e.status <> 'pending' then
      raise exception 'item_not_pending' using errcode = 'check_violation';
    end if;
    if e.proposed_by = uid then
      raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews your own suggestion.';
    end if;
    select * into p from public.places where id = e.place_id for update;
  else
    select * into p from public.places where id = p_id for update;
    if not found then
      raise exception 'item_not_pending' using errcode = 'check_violation';
    end if;
  end if;

  if p_kind = 'place' then
    if not (p.source = 'user' and p.is_public and p.status = 'pending') then
      raise exception 'item_not_pending' using errcode = 'check_violation';
    end if;
    if p.created_by = uid then
      raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews your own place.';
    end if;
    if p_action = 'approve' then
      -- places_guard re-checks rule 2 against the creator's home and private venues.
      update public.places set status = 'active' where id = p.id returning * into p;
    elsif p_action = 'reject' and p.created_by is not null then
      -- Not on the map for everyone; it stays the member's own private pin.
      update public.places set is_public = false, status = 'active' where id = p.id returning * into p;
    else
      update public.places set status = 'removed' where id = p.id returning * into p;
    end if;

  elsif p_kind = 'edit' then
    if p_action = 'approve' then
      if p.status in ('hidden', 'removed') then
        raise exception 'place_not_editable' using errcode = 'check_violation',
          hint = 'The place is hidden or removed; reject the edit or restore the place first.';
      end if;
      v_clean := public.place_clean_changes(e.changes);   -- hubs may have changed since
      perform public.place_apply_changes(p.id, v_clean, 'member', p.source in ('osm', 'geoapify'));
      select * into p from public.places where id = p.id;
    end if;
    update public.place_edits
       set status = case when p_action = 'approve' then 'approved' else 'rejected' end,
           reviewed_by = uid, reviewed_at = now(), review_note = v_note
     where id = e.id;

  else
    if not exists (select 1 from public.place_reports r where r.place_id = p.id and r.status = 'open') then
      raise exception 'item_not_pending' using errcode = 'check_violation';
    end if;
    if p_action = 'dismiss' then
      -- The reports were wrong: a place they hid comes back.
      if p.status = 'hidden' then
        update public.places set status = 'active' where id = p.id returning * into p;
      end if;
    elsif p_action = 'hide' then
      update public.places set status = 'hidden' where id = p.id returning * into p;
    elsif p_action = 'remove' then
      update public.places set status = 'removed' where id = p.id returning * into p;
    else
      update public.places
         set status = 'closed',
             locked_fields = case when source in ('osm', 'geoapify') and not ('closed' = any (locked_fields))
                                  then array_append(locked_fields, 'closed') else locked_fields end
       where id = p.id
       returning * into p;
    end if;
    update public.place_reports
       set status = case when p_action = 'dismiss' then 'dismissed' else 'actioned' end,
           resolved_by = uid, resolved_at = now()
     where place_id = p.id and status = 'open';
  end if;

  -- A removed place takes its open items with it.
  if p.status = 'removed' then
    update public.place_edits set status = 'superseded', reviewed_by = uid, reviewed_at = now()
     where place_id = p.id and status = 'pending';
    update public.place_reports set status = 'actioned', resolved_by = uid, resolved_at = now()
     where place_id = p.id and status = 'open';
  end if;

  insert into public.place_mod_actions (place_id, item_kind, item_id, action, moderator_id, note)
  values (p.id, p_kind, p_id, p_action, uid, v_note);

  return jsonb_build_object('kind', p_kind, 'id', p_id, 'action', p_action,
                            'place_id', p.id, 'place_status', p.status, 'is_public', p.is_public,
                            'locked_fields', to_jsonb(p.locked_fields));
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;
comment on function public.mod_resolve_place(text, uuid, text, text) is
  'Hub map moderation (D-041, slice 12), moderators only (forbidden). place (a pending public member place): approve (active; places_guard re-checks the creator''s home and private venues), reject (back to the member''s private pin), remove. edit: approve (applies the change set; an imported row''s changed fields join locked_fields so the extract keeps them) or reject. reports (by place id): dismiss (a place they hid comes back), hide, remove, close (an imported row locks closed). Never on one''s own place or suggestion (own_item). A removed place supersedes its pending edits and actions its open reports. Logged in place_mod_actions. Errors: invalid_item, invalid_action, item_not_pending, place_not_editable. Returns {kind, id, action, place_id, place_status, is_public, locked_fields}.';

-- ---------------------------------------------------------------------------
-- 8. request_account_deletion (migration 27 body, 20261122000100_places_schema.sql)
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
    now() + interval '30 days',
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
  'Deletes the caller''s account immediately: ledger row, tombstone profile, profile_private (home area and radius) deleted, handle released, private data, memberships, chapter claims, notifications, attendance reports, meets naming the caller (either direction) and the city waitlist row removed, claimed_by / reviewed_by / checked_in_by / notification actor / broadcast sender references cleared, hosted series and future events cancelled with their addresses (attendees notified), private venues deleted, private and pending places deleted and reviewed places unattributed, pending place edits deleted and other place edits and reports unattributed with their notes cleared, RSVPs removed (waitlists promoted), auth user banned. The delete-account Edge Function finishes (soft-deletes the auth user, removes avatars, stamps completed_at). Idempotent.';

-- ---------------------------------------------------------------------------
-- 9. Function grants (explicit)
-- ---------------------------------------------------------------------------
revoke all on function public.place_caller_can_see(uuid) from public, anon, authenticated;
revoke all on function public.place_check_hubs(jsonb, text, boolean) from public, anon, authenticated;
revoke all on function public.place_near_private(uuid, extensions.geography) from public, anon, authenticated;
revoke all on function public.place_duplicates(text, text, extensions.geography, uuid) from public, anon, authenticated;
revoke all on function public.place_clean_changes(jsonb) from public, anon, authenticated;
revoke all on function public.place_raise_near(text) from public, anon, authenticated;
revoke all on function public.place_apply_changes(uuid, jsonb, text, boolean) from public, anon, authenticated;
grant execute on function public.place_caller_can_see(uuid) to service_role;
grant execute on function public.place_check_hubs(jsonb, text, boolean) to service_role;
grant execute on function public.place_near_private(uuid, extensions.geography) to service_role;
grant execute on function public.place_duplicates(text, text, extensions.geography, uuid) to service_role;
grant execute on function public.place_clean_changes(jsonb) to service_role;
grant execute on function public.place_raise_near(text) to service_role;
grant execute on function public.place_apply_changes(uuid, jsonb, text, boolean) to service_role;

revoke all on function public.add_place(jsonb) from public, anon;
revoke all on function public.suggest_place_edit(uuid, jsonb, text) from public, anon;
revoke all on function public.report_place(uuid, text, text) from public, anon;
revoke all on function public.set_my_place_visibility(uuid, boolean, boolean) from public, anon;
revoke all on function public.delete_my_place(uuid) from public, anon;
grant execute on function public.add_place(jsonb) to authenticated, service_role;
grant execute on function public.suggest_place_edit(uuid, jsonb, text) to authenticated, service_role;
grant execute on function public.report_place(uuid, text, text) to authenticated, service_role;
grant execute on function public.set_my_place_visibility(uuid, boolean, boolean) to authenticated, service_role;
grant execute on function public.delete_my_place(uuid) to authenticated, service_role;

revoke all on function public.mod_place_facts(uuid) from public, anon, authenticated;
grant execute on function public.mod_place_facts(uuid) to service_role;
revoke all on function public.mod_place_queue(integer) from public, anon;
revoke all on function public.mod_resolve_place(text, uuid, text, text) from public, anon;
grant execute on function public.mod_place_queue(integer) to authenticated, service_role;
grant execute on function public.mod_resolve_place(text, uuid, text, text) to authenticated, service_role;

revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.30')
  on conflict (key) do update set value = excluded.value, updated_at = now();
