-- ============================================================================
-- Activity Planet schema v2 — migration 66: collector Slice 2 review fixes.
--   Builds on migrations 62 to 65, which reached staging and are not edited.
--   Each function starts from its latest body and changes only the lines
--   marked "Migration 66":
--
--     * start_organizer_claim (migration 62 body): a feed claim on a source
--       (p_source or p_event) is on that source's own ICS feed; a calendar the
--       caller names is refused (feed_mismatch), a source without one too
--       (feed_unavailable). A feed claim's host is always the feed's host.
--       Before, a feed claim could name any calendar and still carry the
--       found source, so verifying the caller's own calendar took the source.
--     * organizer_claim_apply (migration 62 body): the same rule again where
--       the owner is written, so an older claim cannot take a source either.
--     * my_organizer_claims (migration 62 body): feed_url hidden for a pending
--       feed claim on a found source (it is that source's moderator-only URL).
--     * organizer_claim_target (migration 65 body): feed_proof (boolean) in
--       place of feed_url; an organizer-connected feed's URL host is no longer
--       in hosts. feed_sources.url stays moderator-only.
--     * collector_claims_due (migration 62 body): pending claims whose host or
--       feed host became denylisted fail (host_denied) and are never fetched.
--     * Cleanup: pending feed claims on a found source that is not their feed
--       fail (feed_mismatch); a verified one loses that source (the source
--       loses that owner and hub). Staging held none when this was written.
--     * meta.schema_version 2.62.
--
--   Account deletion: no new table or column.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. start_organizer_claim
-- ---------------------------------------------------------------------------
create or replace function public.start_organizer_claim(
  p_source uuid default null, p_event uuid default null, p_host text default null,
  p_method text default 'meta', p_feed_url text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_method text := coalesce(nullif(btrim(coalesce(p_method, '')), ''), 'meta');
  v_src    public.feed_sources%rowtype;
  v_host   text := regexp_replace(regexp_replace(lower(btrim(coalesce(p_host, ''))), '\.+$', ''), '^www\.', '');
  v_feed   text;
  v_chk    jsonb;
  v_hosts  text[];
  v_claim  public.organizer_claims%rowtype;
  v_own    jsonb;   -- Migration 66
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p where p.id = uid and p.status = 'active' and p.deleted_at is null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p where p.id = uid and p.created_at <= now() - interval '24 hours') then
    raise exception 'account_too_new' using errcode = 'P0001';
  end if;
  if v_method not in ('meta', 'well_known', 'dns_txt', 'feed') then
    raise exception 'invalid_method' using errcode = '22023';
  end if;

  if p_event is not null then
    select f.* into v_src
      from public.event_imports ei
      join public.feed_sources f on f.id = ei.source_id
      join public.events e on e.id = ei.event_id and e.kind = 'imported'
     where ei.event_id = p_event
     order by ei.is_primary desc, ei.first_seen_at
     limit 1;
    if not found then
      raise exception 'not_imported' using errcode = '22023';
    end if;
  elsif p_source is not null then
    select * into v_src from public.feed_sources where id = p_source;
    if not found then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
  end if;

  if v_method = 'feed' then
    -- Migration 66: a feed claim on a source proves control of that source's own ICS feed, never
    -- of a calendar the caller names; and the claim's host is always the feed's host.
    if v_src.id is not null then
      v_own := case when v_src.kind = 'ics' then public.source_url_check(v_src.url) end;
      if v_own is null or not coalesce((v_own ->> 'ok')::boolean, false) then
        raise exception 'feed_unavailable' using errcode = '22023';
      end if;
      if nullif(btrim(coalesce(p_feed_url, '')), '') is not null then
        v_chk := public.source_url_check(p_feed_url);
        if not coalesce((v_chk ->> 'ok')::boolean, false) or (v_chk ->> 'url') is distinct from (v_own ->> 'url') then
          raise exception 'feed_mismatch' using errcode = '22023';
        end if;
      end if;
      v_chk := v_own;
    else
      v_chk := public.source_url_check(p_feed_url);
      if not (v_chk ->> 'ok')::boolean then
        raise exception '%', v_chk ->> 'error' using errcode = '22023';
      end if;
    end if;
    v_feed := v_chk ->> 'url';
    if v_host <> '' and v_host <> (v_chk ->> 'host') then
      raise exception 'host_mismatch' using errcode = '22023';
    end if;
    v_host := v_chk ->> 'host';
  elsif v_src.id is null then
    raise exception 'source_required' using errcode = '22023';
  end if;

  if v_host = '' or v_host !~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$' then
    raise exception 'invalid_host' using errcode = '22023';
  end if;
  if v_src.id is not null and v_method <> 'feed' then
    v_hosts := array_remove(array[public.source_url_host(v_src.url), public.source_url_host(v_src.homepage_url)], null);
    if not (v_host = any (v_hosts)
            or v_host = any (array(select public.registrable_domain(h) from unnest(v_hosts) h))) then
      raise exception 'host_mismatch' using errcode = '22023';
    end if;
    if public.collector_shared_host(v_host) then
      raise exception 'host_mismatch' using errcode = '22023';
    end if;
  end if;
  if public.collector_host_denied(v_host) is not null then
    raise exception 'host_denied' using errcode = '22023';
  end if;
  if v_src.id is not null and v_src.organizer_id is not null and v_src.organizer_id <> uid then
    raise exception 'already_claimed' using errcode = 'P0001';
  end if;

  -- One person at a time, so two quick taps cannot both pass the limit.
  perform pg_advisory_xact_lock(hashtextextended('start_organizer_claim:' || uid::text, 0));
  select * into v_claim from public.organizer_claims c
   where c.user_id = uid and c.status = 'pending' and c.host = v_host and c.method = v_method
     and c.source_id is not distinct from v_src.id and c.feed_url is not distinct from v_feed
   order by c.created_at desc limit 1;
  if not found then
    if (select count(*) from public.organizer_claims c
         where c.user_id = uid and c.created_at > now() - interval '1 day') >= 5 then
      raise exception 'rate_limited' using errcode = 'P0001';
    end if;
    insert into public.organizer_claims (user_id, source_id, event_id, host, method, feed_url, token)
    values (uid, v_src.id, p_event, v_host, v_method, v_feed, public.organizer_token())
    returning * into v_claim;
  end if;
  return jsonb_build_object('claim_id', v_claim.id, 'status', v_claim.status, 'method', v_claim.method,
                            'host', v_claim.host, 'token', v_claim.token,
                            'proofs', public.organizer_claim_proofs(v_claim.host, v_claim.token));
end $$;
comment on function public.start_organizer_claim(uuid, uuid, text, text, text) is
  'Migration 62, authenticated: starts a claim on an imported source (p_source, or p_event, which resolves to its source) for p_host, which must be the source URL''s or homepage''s host or registrable domain (not a shared calendar host). p_method meta | well_known | dns_txt | feed. Migration 66, feed: with a source, the claim is on that source''s own ICS feed (feed_unavailable when it has none; p_feed_url may be left out, and if given must be that same feed: feed_mismatch); without a source, p_feed_url is the calendar to connect. The host of a feed claim is always the feed''s host (host_mismatch when p_host differs). Account at least 24 hours old (account_too_new), 5 claims a day (rate_limited); a pending claim for the same thing is returned again. Errors: not_authenticated, forbidden, invalid_method, not_imported, not_found, source_required, feed_unavailable, feed_mismatch, invalid_host, host_mismatch, host_denied, already_claimed, the url_* errors of source_url_check. Returns {claim_id, status, method, host, token, proofs}.';

-- ---------------------------------------------------------------------------
-- 2. organizer_claim_apply
-- ---------------------------------------------------------------------------
create or replace function public.organizer_claim_apply(p_claim uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_claim public.organizer_claims%rowtype;
begin
  select * into v_claim from public.organizer_claims where id = p_claim;
  if v_claim.status <> 'verified' then
    return;
  end if;
  update public.feed_sources
     set organizer_id = v_claim.user_id, organizer_verified_at = coalesce(v_claim.verified_at, now())
   where (id = v_claim.source_id or organizer_claim_id = v_claim.id)
     and (organizer_id is null or organizer_id = v_claim.user_id)
     -- Migration 66: a feed claim owns its found source only when the feed is that source's own.
     and (v_claim.method <> 'feed' or id <> v_claim.source_id or organizer_claim_id = v_claim.id
          or (kind = 'ics' and (public.source_url_check(url) ->> 'url') is not distinct from v_claim.feed_url));
end $$;
comment on function public.organizer_claim_apply(uuid) is 'Migration 62: copies a verified claim''s owner onto its source and connected feeds. Migration 66: a feed claim''s found source only when the claimed feed is that source''s own ICS URL. Internal.';

-- ---------------------------------------------------------------------------
-- 3. my_organizer_claims
-- ---------------------------------------------------------------------------
create or replace function public.my_organizer_claims()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'claim_id', c.id, 'status', c.status, 'method', c.method, 'host', c.host,
             -- Migration 66: a pending feed claim on a found source does not show that source's URL.
             'feed_url', case when c.source_id is null or c.status = 'verified' then c.feed_url end,
             'token', case when c.status = 'pending' then c.token end,
             'proofs', case when c.status = 'pending' then public.organizer_claim_proofs(c.host, c.token) end,
             'attempts', c.attempts, 'last_checked_at', c.last_checked_at, 'verified_at', c.verified_at,
             'failure', c.failure, 'created_at', c.created_at,
             'source', (select jsonb_build_object('id', f.id, 'name', f.name, 'enabled', f.enabled, 'origin', f.origin)
                          from public.feed_sources f where f.id = c.source_id),
             'connected', (select coalesce(jsonb_agg(jsonb_build_object(
                                     'id', f.id, 'name', f.name, 'url', f.url, 'kind', f.kind,
                                     'enabled', f.enabled, 'stopped', f.organizer_stopped_at is not null,
                                     'last_ok_at', f.last_ok_at, 'images_licensed', f.images_licensed)
                                     order by f.created_at), '[]'::jsonb)
                             from public.feed_sources f where f.organizer_claim_id = c.id))
           order by c.created_at desc)
      from public.organizer_claims c where c.user_id = uid), '[]'::jsonb);
end $$;
comment on function public.my_organizer_claims() is
  'Migration 62, authenticated: the caller''s organizer claims, newest first, with the token and proofs while pending, the claimed source and the connected feeds. Migration 66: feed_url is null for a feed claim on a found source until it is verified (the source''s URL is moderator-only).';

-- ---------------------------------------------------------------------------
-- 4. organizer_claim_target
-- ---------------------------------------------------------------------------
create or replace function public.organizer_claim_target(p_event uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_src  public.feed_sources%rowtype;
  v_hosts text[];
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select f.* into v_src
    from public.event_imports ei
    join public.feed_sources f on f.id = ei.source_id
    join public.events e on e.id = ei.event_id and e.kind = 'imported'
   where ei.event_id = p_event and public.can_read_event(e.id)
   order by ei.is_primary desc, ei.first_seen_at
   limit 1;
  if not found then
    raise exception 'not_imported' using errcode = '22023';
  end if;
  select coalesce(array_agg(distinct h order by h), '{}') into v_hosts
    -- Migration 66: an organizer-connected feed's URL host is not shown (the URL is the owner's).
    from (select case when v_src.origin = 'collector' then public.source_url_host(v_src.url) end as h
          union all select public.source_url_host(v_src.homepage_url)
          union all select case when v_src.origin = 'collector' then public.registrable_domain(public.source_url_host(v_src.url)) end
          union all select public.registrable_domain(public.source_url_host(v_src.homepage_url))) x
   where h is not null and h <> '' and not public.collector_shared_host(h)
     and public.collector_host_denied(h) is null;
  return jsonb_build_object(
    'source_name', v_src.name,
    'source_kind', v_src.kind,
    'origin', v_src.origin,
    'hosts', to_jsonb(v_hosts),
    -- Migration 66: whether the feed proof is offered, never the feed's URL (moderator-only).
    'feed_proof', v_src.kind = 'ics' and coalesce((public.source_url_check(v_src.url) ->> 'ok')::boolean, false),
    'claimed', v_src.organizer_id is not null,
    'mine', v_src.organizer_id is not distinct from uid and v_src.organizer_id is not null,
    'source_id', case when v_src.organizer_id = uid then v_src.id end);
end $$;
comment on function public.organizer_claim_target(uuid) is
  'Migration 65, authenticated: for an imported event the caller can read, what a claim of its source may name: {source_name, source_kind, origin, hosts (the source page''s and homepage''s hosts and registrable domains, without shared calendar hosts or denylisted ones; migration 66: the URL''s host only for a found source), feed_proof (migration 66, in place of feed_url: the source is an ICS feed, so start_organizer_claim(method feed) can claim it; the URL itself is never returned), claimed, mine, source_id (only when the caller owns it)}. Errors: not_authenticated, not_imported.';

-- ---------------------------------------------------------------------------
-- 5. collector_claims_due
-- ---------------------------------------------------------------------------
create or replace function public.collector_claims_due(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_out jsonb;
begin
  -- Claims past 7 days or 10 checks fail.
  update public.organizer_claims
     set status = 'failed', failure = coalesce(failure, 'expired')
   where status = 'pending' and (created_at < now() - interval '7 days' or attempts >= 10);
  -- Migration 66: a host denylisted after the claim started (an owner's removal request) is
  -- never fetched again; the claim fails.
  update public.organizer_claims
     set status = 'failed', failure = 'host_denied', check_requested_at = null
   where status = 'pending' and method <> 'dns_txt'
     and (public.collector_host_denied(host) is not null
          or (feed_url is not null and public.collector_host_denied(public.source_url_host(feed_url)) is not null));
  select coalesce(jsonb_agg(jsonb_build_object(
           'claim_id', q.id, 'method', q.method, 'host', q.host, 'token', q.token,
           'urls', q.urls) order by q.ord), '[]'::jsonb)
    into v_out
    from (select c.id, c.method, c.host, c.token,
                 row_number() over (order by c.check_requested_at nulls last, c.last_checked_at nulls first, c.id) as ord,
                 case c.method
                   when 'feed' then jsonb_build_array(c.feed_url)
                   when 'well_known' then jsonb_build_array('https://' || c.host || '/.well-known/activityplanet-verification.txt')
                   else (select coalesce(jsonb_agg(distinct u), '[]'::jsonb) from unnest(array_remove(array[
                           'https://' || c.host || '/',
                           case when public.source_url_host(f.homepage_url) = c.host then f.homepage_url end,
                           case when f.kind = 'jsonld' and public.source_url_host(f.url) = c.host then f.url end], null)) u)
                 end as urls
            from public.organizer_claims c
            left join public.feed_sources f on f.id = c.source_id
           where c.status = 'pending' and c.method <> 'dns_txt'
             and (c.check_requested_at is not null or c.last_checked_at is null
                  or c.last_checked_at < now() - interval '6 hours')
           order by c.check_requested_at nulls last, c.last_checked_at nulls first, c.id
           limit greatest(1, least(coalesce(p_limit, 50), 200))) q;
  return v_out;
end $$;
comment on function public.collector_claims_due(integer) is
  'Migration 62, service role (GET /collector/claims/due): fails claims older than 7 days or with 10 checks, then lists pending meta, well_known and feed claims due a check (asked for now, never checked, or not checked for 6 hours) with the URLs to read (at most 3: the host''s home page and the source''s homepage or page for meta, the .well-known file, or the feed) and the token to look for. At most 200. Migration 66: first fails (host_denied) pending claims whose host or feed host is now denylisted.';

-- ---------------------------------------------------------------------------
-- 6. Cleanup of feed claims whose feed is not their source's
-- ---------------------------------------------------------------------------
update public.organizer_claims c
   set status = 'failed', failure = 'feed_mismatch', check_requested_at = null
 where c.status = 'pending' and c.method = 'feed' and c.source_id is not null
   and not exists (select 1 from public.feed_sources f
                    where f.id = c.source_id and f.kind = 'ics'
                      and (public.source_url_check(f.url) ->> 'url') is not distinct from c.feed_url);

update public.feed_sources f
   set organizer_id = null, organizer_verified_at = null, organizer_hub_id = null
  from public.organizer_claims c
 where c.status = 'verified' and c.method = 'feed' and c.source_id = f.id
   and f.organizer_id = c.user_id and f.organizer_claim_id is distinct from c.id
   and not (f.kind = 'ics' and (public.source_url_check(f.url) ->> 'url') is not distinct from c.feed_url);

update public.organizer_claims c
   set source_id = null
 where c.status = 'verified' and c.method = 'feed' and c.source_id is not null
   and not exists (select 1 from public.feed_sources f
                    where f.id = c.source_id and f.kind = 'ics'
                      and (public.source_url_check(f.url) ->> 'url') is not distinct from c.feed_url);

-- ---------------------------------------------------------------------------
-- 7. Grants (unchanged) and version stamp (last)
-- ---------------------------------------------------------------------------
revoke all on function public.start_organizer_claim(uuid, uuid, text, text, text) from public, anon;
grant execute on function public.start_organizer_claim(uuid, uuid, text, text, text) to authenticated;
revoke all on function public.my_organizer_claims() from public, anon;
grant execute on function public.my_organizer_claims() to authenticated;
revoke all on function public.collector_claims_due(integer) from public, anon, authenticated;
grant execute on function public.collector_claims_due(integer) to service_role;
revoke all on function public.organizer_claim_apply(uuid) from public, anon, authenticated;
revoke all on function public.organizer_claim_target(uuid) from public, anon;
grant execute on function public.organizer_claim_target(uuid) to authenticated;

insert into public.meta (key, value) values ('schema_version', '2.62')
  on conflict (key) do update set value = excluded.value, updated_at = now();
