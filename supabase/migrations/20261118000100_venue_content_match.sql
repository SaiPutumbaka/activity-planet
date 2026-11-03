-- ============================================================================
-- Migration 23: upsert_venue hands over another user's public venue only when
-- its content matches what the caller sent (security re-check, staging run
-- 41689352735, P1).
--
-- Migration 22 stopped a bare place_id from handing over someone else's public
-- row, but still matched on place_id plus a point within 300 m. Both are public
-- (the same Geoapify autocomplete returns them), so a planted row with the real
-- place_id and coordinates and a false name or address was still handed to an
-- honest host who picked that place, and the app shows the returned row's text.
-- Another user's row now also needs the same name, address lines, city, state,
-- postal code and country (case-insensitive, trimmed as the caller's values
-- are); otherwise the caller gets their own row.
--
-- Changes:
--   * public.upsert_venue: body of migration 22 (20261117000100); only the
--     cross-user lookup gained the content conditions, the creator's fill of
--     empty fields (address_line2, campus, ...) is skipped once another host's
--     event uses the row (otherwise a planted row could match with an empty
--     address_line2 and gain false text after being handed over), and the
--     comment says so.
--   * meta.schema_version 2.19.
-- No new tables, so account deletion coverage is unchanged.
-- ============================================================================

-- upsert_venue: body of migration 22 (20261117000100); only the cross-user
-- public lookup and the fill condition changed.
create or replace function public.upsert_venue(p_args jsonb)
returns public.venues language plpgsql security definer set search_path = '' as $$
declare
  uid        uuid := (select auth.uid());
  a          jsonb := coalesce(p_args, '{}'::jsonb);
  v          public.venues%rowtype;
  v_mod      boolean;
  v_name     text := btrim(coalesce(a ->> 'name', ''));
  v_addr1    text := btrim(coalesce(a ->> 'address_line1', ''));
  v_addr2    text := btrim(coalesce(a ->> 'address_line2', ''));
  v_city     text := btrim(coalesce(a ->> 'city', ''));
  v_state    text := btrim(coalesce(a ->> 'state', ''));
  v_postal   text := btrim(coalesce(a ->> 'postal_code', ''));
  v_country  text := upper(coalesce(nullif(btrim(coalesce(a ->> 'country', '')), ''), 'US'));
  v_place_id text := nullif(btrim(coalesce(a ->> 'place_id', '')), '');
  v_campus   uuid := (a ->> 'campus_id')::uuid;
  v_public   boolean;
  v_lat      double precision := (a ->> 'lat')::double precision;
  v_lng      double precision := (a ->> 'lng')::double precision;
  v_point    extensions.geography;
  v_c        text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  v_mod    := public.is_moderator();
  v_public := coalesce((a ->> 'is_public')::boolean, false);   -- D-038: private unless the caller says so
  if v_name = '' then
    raise exception 'name_required' using errcode = 'check_violation';
  end if;
  if char_length(v_name) > 120 then
    raise exception 'name_length' using errcode = 'check_violation', hint = 'Up to 120 characters.';
  end if;
  if v_country !~ '^[A-Z]{2}$' then
    raise exception 'country_invalid' using errcode = 'check_violation', hint = 'Two-letter country code.';
  end if;
  if (v_lat is null) <> (v_lng is null)
     or (v_lat is not null and (v_lat not between -90 and 90 or v_lng not between -180 and 180)) then
    raise exception 'invalid_coordinates' using errcode = 'check_violation';
  end if;
  if v_lat is not null then
    v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography;
  end if;
  if v_campus is not null and not exists (select 1 from public.org_campuses where id = v_campus) then
    raise exception 'campus_not_found' using errcode = 'P0002';
  end if;

  -- Serialize concurrent creates of the same place; hashtext is stable per key.
  perform pg_advisory_xact_lock(hashtext('venue:' || coalesce(v_place_id, lower(v_name) || '|' || v_postal)));

  if v_public then
    -- A place_id is client-supplied, so it never hands over someone else's
    -- row by itself (migration 22): the caller's own public row for the
    -- place, else another public row whose stored point is within 300 m of
    -- the coordinates the caller sent and whose name and address equal the
    -- ones sent (migration 23). Otherwise the caller gets a new row.
    if v_place_id is not null then
      select * into v from public.venues
       where place_id = v_place_id and is_public and created_by = uid
       order by created_at
       limit 1;
      if v.id is null and v_point is not null then
        select * into v from public.venues x
         where x.place_id = v_place_id and x.is_public and x.location is not null
           and extensions.ST_DWithin(x.location, v_point, 300)
           -- Migration 23: the row's content must match what the caller sent.
           and lower(x.name)          = lower(v_name)
           and lower(x.address_line1) = lower(v_addr1)
           and lower(x.address_line2) = lower(v_addr2)
           and lower(x.city)          = lower(v_city)
           and lower(x.state)         = lower(v_state)
           and x.postal_code          = v_postal
           and x.country              = v_country
         order by extensions.ST_Distance(x.location, v_point), x.created_at
         limit 1;
      end if;
    end if;
    if v.id is null and v_postal <> '' then
      select * into v from public.venues
       where lower(name) = lower(v_name) and postal_code = v_postal and is_public and created_by = uid
       order by created_at
       limit 1;
    end if;
  else
    if v_place_id is not null then
      select * into v from public.venues where place_id = v_place_id and not is_public and created_by = uid
       order by created_at limit 1;
    end if;
    if v.id is null and v_postal <> '' then
      select * into v from public.venues
       where lower(name) = lower(v_name) and postal_code = v_postal and not is_public and created_by = uid
       order by created_at
       limit 1;
    end if;
  end if;

  if v.id is not null then
    -- Migration 23: the creator fills empty fields only while no other
    -- host's event uses the row, so a shared venue's text cannot change
    -- after someone else attached it.
    if v_mod or (v.created_by = uid
                 and not exists (select 1 from public.event_addresses ea
                                   join public.events e on e.id = ea.event_id
                                  where ea.venue_id = v.id and e.host_id is distinct from uid)) then
      update public.venues
         set address_line1 = case when address_line1 = '' then v_addr1 else address_line1 end,
             address_line2 = case when address_line2 = '' then v_addr2 else address_line2 end,
             city          = case when city = ''          then v_city  else city end,
             state         = case when state = ''         then v_state else state end,
             postal_code   = case when postal_code = ''   then v_postal else postal_code end,
             location      = coalesce(location, v_point),
             campus_id     = coalesce(campus_id, v_campus),
             place_id      = case when place_id is null and v_place_id is not null
                                   and not exists (select 1 from public.venues x where x.place_id = v_place_id and x.is_public)
                                  then v_place_id else place_id end
       where id = v.id
       returning * into v;
    end if;
    return v;
  end if;

  if not v_mod then
    perform pg_advisory_xact_lock(hashtext('venues:' || uid::text));
    if (select count(*) from public.venues where created_by = uid and created_at > now() - interval '24 hours') >= 20 then
      raise exception 'too_many_venues' using errcode = 'check_violation', hint = 'Up to twenty new venues a day.';
    end if;
  end if;

  insert into public.venues (name, address_line1, address_line2, city, state, postal_code, country,
                             location, place_id, campus_id, created_by, is_public)
  values (v_name, v_addr1, v_addr2, v_city, v_state, v_postal, v_country,
          v_point, v_place_id, v_campus, uid, v_public)
  returning * into v;
  return v;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

comment on function public.upsert_venue(jsonb) is
  'Finds or creates a venue for the caller. New venues are private unless is_public = true is passed (D-038). Public requests match place_id among the caller''s own public venues, then among other public venues whose point is within 300 m of the lat/lng sent and whose name and address (lines, city, state, postal code, country) equal the ones sent (never by place_id or coordinates alone; the creator fills empty fields only while no other host''s event uses the row), then (name, postal code) among the caller''s own; private requests match the caller''s own private rows. Twenty new venues a day. Errors: not_authenticated, onboarding_required, name_required, name_length, country_invalid, invalid_coordinates, campus_not_found, too_many_venues, or a table constraint name.';

revoke all on function public.upsert_venue(jsonb) from public, anon;
grant execute on function public.upsert_venue(jsonb) to authenticated;

-- Version stamp
insert into public.meta (key, value) values ('schema_version', '2.19')
  on conflict (key) do update set value = excluded.value, updated_at = now();
