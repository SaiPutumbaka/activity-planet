# Recommendations, landing page v2, PWA polish and the weekly scorecard: design (week 11, recorded as D-045)

Date: 2026-11-05. Status: recorded as D-045 (`docs/DECISIONS.md`). Spec: PLAN.md 4.8 item 2 (**B**, recommendations), 4.10 (installable PWA), 4.12 (weekly scorecard auto-emailed to Sai), ROADMAP week 11, D-040 (everyone, anywhere), D-041 (the "Shows and games" row stays separate), TRUST-SAFETY-LEGAL sections 4 (privacy by design) and 11 (account deletion). Builds on the schema as it stands after migration 66 (`20261230000100_collector_review_fixes.sql`, `meta.schema_version` 2.62): `feed_events_v2` (latest body migration 57, `20261221000100_feed_distance.sql`; invoker, events RLS applies), `feed_event_area` (latest body migration 59), the events and rsvps policies (migrations 51 and 54), `people_you_met` (migration 59), `search_coaches` (migration 60), `request_account_deletion` (latest body migration 62, `20261226000100_collector_completion.sql`), `mod_scorecard` (migration 53), the vault secret and pg_net dispatch pattern of `notify_worker_dispatch` (migration 55), the `send-notifications` Resend client and `STARTER_CITIES` in `packages/core/src/places`.

Everyone, anywhere (D-040): every row, chip, email line and landing section is written for adults anywhere. Nothing is limited to students or to Atlanta. Atlanta appears only as the fallback origin for a visitor or member who gives no location, and the Georgia State not-affiliated line appears only on a card or section that names Georgia State.

**Short version.** Every hub, event (member-hosted and imported) and coach listing gets a 384-dimension embedding from **Supabase's built-in `gte-small` model**, run in a new Edge Function `recs-embed` through `new Supabase.ai.Session('gte-small')` with `mean_pool` and `normalize`. No API key and no vendor. Vectors are stored as `halfvec(384)` in pgvector (`vector` extension, not yet enabled; 0.8.2 is available on staging). A trigger-fed queue table is drained by pg_cron every minute in small, capped batches, and there is a one-call backfill. A member's **taste vector** is computed in SQL as a weighted, time-decayed average of the embeddings of their non-sensitive hubs, RSVPs, check-ins and completed coaching sessions. Recommendations **re-rank candidates the member can already see**: the For you row and Similar plans take their candidates from `feed_events_v2` (so its distance, time, RLS, age and campus rules hold), coaches come from `search_coaches`, people come only from **shared context** (met at a plan, the same chapter, going to the same plan). The result blends similarity with the existing distance and time rules. Each card carries up to two **explain-why chips** computed on the server. Blocks, mutes, 18+/21+, sensitive hubs and private venues are respected, and people suggestions have an **opt-out**. Four surfaces: **For you** on Home, **Similar plans** on the event page, **Hubs you may like**, **Coaches for you**, plus **People you might click with** on People you've met. **Landing page v2** in `apps/web` gets a live "this week near you" built without IP lookup (a city picker, or browser geolocation only after a tap; Atlanta otherwise), a trust section, "coming soon" app notes with no official store badges, and no waitlist. **PWA polish**: an install prompt with iPhone instructions, an update toast in place of silent take-over, a complete icon and manifest set, and the app badge. **Weekly scorecard email** to Sai: counts only, sent through Resend from a new `weekly-scorecard` function, and skipped when `RESEND_API_KEY` (or the recipient secret) is absent. Two build slices: (1) database, embeddings, jobs, RPCs and scorecard; (2) app rows, landing v2 and PWA polish.

---

## 1. Principles

1. **Re-rank, never widen.** A recommendation is drawn from a set the member is already allowed to see through an existing read path: `feed_events_v2`, the events and rsvps policies, `search_coaches`, `people_you_met`, the chapter_members policy. Similarity only reorders that set. No recommendation RPC is a `security definer` wrapper around a candidate query. Each public `recs_*` RPC is `security invoker`. The only definer helpers are the scorers in `private`, and they return numbers and reason codes for ids the caller passes in, after re-checking that the caller can read each id.
2. **Free and on-platform.** `gte-small` runs inside the Edge Runtime, so there is no key, no vendor and no per-call cost beyond the plan's function invocations (about 45,000 a month at one a minute, inside the Free plan's 500,000 and Pro's 2,000,000). Nothing in this design needs a key except the scorecard email, which is skipped without one.
3. **Rules still decide when similarity says little.** gte-small is English-only and truncates at 512 tokens (Supabase docs, "Running AI Models"). Its cosine scores bunch up high (about 0.70 to 0.92 between unrelated and related short texts). So similarity enters as a **rank within the candidate set**, not as an absolute score. Distance, time and hub match carry half the weight, and a member with no taste vector gets the rules-only ranking.
4. **Sensitive stays private.** Hubs in a sensitive category (`hub_categories.is_sensitive`) and events in them never feed a taste vector, are never recommended, never appear in a chip and never count as shared context for people suggestions. A member finds them by browsing or search, as today.
5. **Nothing personal leaves the database.** Taste vectors are readable by no client role, not even their owner. RPCs return items and reason codes, never a similarity score, a vector, a distance or a coordinate. People suggestions never say why beyond the shared context both people already have.
6. **Bounded work.** Every job has a per-run cap, a lease, an attempt limit and a daily cap in `meta`. A stuck or failing model degrades rows to rules-only and never fails a request.

## 2. What is embedded

| Subject                                     | Text (built in SQL by `private.rec_text`, at most 1,600 characters, URLs, emails and phone numbers stripped) | Eligible while                                                                                                                        | Table                      |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| Hub                                         | `name. aliases. category name. description`                                                                  | `is_active`, `moderation_state is null`, category not sensitive, `scope = 'general'`                                                  | `hub_embeddings`           |
| Event (member-hosted, `kind <> 'imported'`) | `hub name: title. description`                                                                               | `status = 'published'`, `moderation_state is null`, hub category not sensitive, `starts_at` from now minus 1 day to now plus 120 days | `event_embeddings`         |
| Event (imported, plan or show)              | same                                                                                                         | same, `starts_at` up to now plus 60 days                                                                                              | `event_embeddings`         |
| Coach listing                               | `hub name: title. description. coach headline`                                                               | listing `active`, unmoderated; coach profile `active`                                                                                 | `coach_listing_embeddings` |

Event embeddings stay for 365 days after the event starts, because taste vectors read past RSVPs and check-ins. After that, or once the event is cancelled, moderated or moved into a sensitive hub, `purge_recs` deletes them. Text is trimmed rather than chunked, because titles and the first paragraph carry the meaning and gte-small truncates anyway. Imported text is embedded as stored (D-020's verbatim excerpt). The embedding is a derived number array, and it is deleted together with the row.

`content_hash` (md5 of the built text plus `meta.recs_text_version`) skips the model when nothing changed, and bumping `recs_text_version` re-embeds everything. `model` records `gte-small`, so a later model change can re-embed side by side.

## 3. Tables (migration 67, `20261231000100_recommendations.sql`)

`create extension if not exists vector with schema extensions;` (free, in Supabase's extension list). All new tables have RLS on, `revoke all ... from public, anon, authenticated`, and no client policies unless stated. They are written only by `security definer set search_path = ''` functions.

```sql
do $$ begin create type public.rec_subject_kind as enum ('hub', 'event', 'coach', 'person');
exception when duplicate_object then null; end $$;

create table if not exists public.hub_embeddings (
  hub_id       uuid primary key references public.hubs (id) on delete cascade,
  embedding    extensions.halfvec(384) not null,
  content_hash text not null,
  model        text not null default 'gte-small',
  embedded_at  timestamptz not null default now()
);
create table if not exists public.event_embeddings (
  event_id     uuid primary key references public.events (id) on delete cascade,
  embedding    extensions.halfvec(384) not null,
  content_hash text not null,
  model        text not null default 'gte-small',
  embedded_at  timestamptz not null default now()
);
create table if not exists public.coach_listing_embeddings (
  listing_id   uuid primary key references public.coach_listings (id) on delete cascade,
  embedding    extensions.halfvec(384) not null,
  content_hash text not null,
  model        text not null default 'gte-small',
  embedded_at  timestamptz not null default now()
);

-- Work queue: one row per subject that needs (re)embedding. No user id.
create table if not exists public.rec_embed_queue (
  subject_kind public.rec_subject_kind not null check (subject_kind in ('hub', 'event', 'coach')),
  subject_id   uuid not null,
  queued_at    timestamptz not null default now(),
  priority     smallint not null default 5,          -- 1 hubs, 2 member events, 3 listings, 5 imported, 9 backfill
  claimed_at   timestamptz,                           -- lease, 5 minutes
  attempts     smallint not null default 0,
  last_error   text check (last_error is null or char_length(last_error) <= 80),  -- an error code, never text
  failed_at    timestamptz,                           -- set after 5 attempts; retried by recs_backfill
  primary key (subject_kind, subject_id)
);
create index if not exists rec_embed_queue_due_idx on public.rec_embed_queue (priority, queued_at)
  where failed_at is null;

-- A member's taste. Owner cannot read it either.
create table if not exists public.rec_taste (
  user_id     uuid primary key references public.profiles (id) on delete cascade,
  embedding   extensions.halfvec(384),               -- null: no usable input yet
  inputs      integer not null default 0,
  stale       boolean not null default true,
  computed_at timestamptz
);
create index if not exists rec_taste_stale_idx on public.rec_taste (user_id) where stale;

create table if not exists public.rec_prefs (
  user_id            uuid primary key references public.profiles (id) on delete cascade,
  personalize        boolean not null default true,   -- off: no taste vector, rules-only rows
  people_suggestions boolean not null default true,   -- off: never suggested to anyone, no People row
  updated_at         timestamptz not null default now()
);
-- Owner select only: policy rec_prefs_select_own using (user_id = (select auth.uid())).

create table if not exists public.rec_dismissals (
  user_id      uuid not null references public.profiles (id) on delete cascade,
  subject_kind public.rec_subject_kind not null,
  subject_id   uuid not null,
  created_at   timestamptz not null default now(),
  primary key (user_id, subject_kind, subject_id)
);
-- Owner select only. At most 500 per member (oldest dropped on insert); purged after 180 days.

create table if not exists public.scorecard_runs (
  week_start date primary key,                       -- Monday, America/New_York
  counts     jsonb not null,                          -- counts only, never a row or a name
  status     text not null check (status in ('sent', 'skipped_no_key', 'failed')),
  sent_at    timestamptz,
  error      text check (error is null or char_length(error) <= 80)
);
-- Moderators select (policy using public.is_moderator()); no user reference, so no deletion step.
```

`halfvec` halves storage to 768 bytes a row: 50,000 events come to about 40 MB including overhead. **No ANN index in v1.** Every query scores a candidate set of at most 200 rows that already passed the visibility filters, using exact inner product (the vectors are normalized, so `<#>` equals negative cosine). That avoids HNSW's filtered-recall problem. An HNSW index (`halfvec_ip_ops`) is added only if a later query has to search a whole table.

`meta` keys (`on conflict do nothing`): `recs` = `on` (the kill switch: `off` makes every row rules-only and stops dispatch), `recs_text_version` = `1`, `recs_embed_batch` = `24`, `recs_embed_daily_cap` = `20000`, `recs_weights` = `{"sim":0.5,"time":0.25,"dist":0.25,"hub":0.10,"met":0.05,"imported":-0.05}`, `recs_similar_floor` = `0.82`, `recs_hub_floor` = `0.80`. Thresholds are tuned on staging from read-only `SELECT`s of the score distribution after the backfill (section 11).

## 4. Embedding pipeline

### 4.1 Queueing

- Triggers `rec_enqueue_hub`, `rec_enqueue_event`, `rec_enqueue_listing` (after insert, or after update of the text, `hub_id`, status or moderation columns) upsert a `rec_embed_queue` row (`on conflict` resets `queued_at`, `claimed_at`, `attempts`, `failed_at`). An update of `coach_profiles.headline` or `status` queues that coach's listings. An update of `hubs.name` queues the hub only; its events re-embed when they next change or at the nightly `recs_tick` sweep of events whose `content_hash` no longer matches. The triggers are cheap: no text building and no HTTP.
- The collector's batch upserts (`collector_ingest_events`, `import_upsert_batch`) fire the event trigger per row, so hundreds of imports become hundreds of queue rows drained over minutes. Those functions do not change.

### 4.2 Dispatch and claim

- `public.recs_embed_dispatch()` (pg_cron `recs-embed`, `* * * * *`, unscheduled by name first): returns null unless `meta.recs = 'on'`, a due row exists (unclaimed, or lease older than 5 minutes, `failed_at is null`) and today's embedded count is under `recs_embed_daily_cap`. Otherwise it POSTs `{}` to `/functions/v1/recs-embed` through `net.http_post` with header `x-recs-secret` (vault secret `recs_embed_secret`, generated in the database as migration 55 does for `notify_worker_secret`; `public.project_url()` for the base), timeout 60 s.
- `public.recs_embed_claim(p_limit int)` (service role only): takes up to `least(p_limit, recs_embed_batch)` due rows ordered by `priority, queued_at` with `for update skip locked`, stamps `claimed_at` and `attempts + 1`, and builds each text with `private.rec_text`. A row whose subject is no longer eligible is deleted from the queue, and its embedding is deleted. A row whose `content_hash` equals the stored one is completed without the model. It returns `(subject_kind, subject_id, content_hash, text)`.
- `public.recs_embed_record(p_rows jsonb)` (service role only): for each `{kind, id, hash, embedding}` (embedding as a 384-number JSON array), it validates the length and that the vector is finite and normalized within 1e-3, re-checks eligibility and that the hash still matches the current text (a newer edit wins), upserts the embedding table, deletes the queue row and marks the owners' tastes stale (members of the hub, people with an RSVP to the event, clients with a completed booking of the listing).
- `public.recs_embed_fail(p_kind, p_id, p_error)` (service role only): records an error code. After 5 attempts it sets `failed_at`, and `recs_backfill` clears those.
- `public.recs_embed_verify_secret(text)` (service role only), as `notify_worker_verify_secret`.

### 4.3 `recs-embed` Edge Function

`supabase/functions/recs-embed/` (`index.ts`, `embed.ts`, `embed_test.ts`), `verify_jwt = false`, with its own check:

```ts
const model = new Supabase.ai.Session("gte-small"); // once per worker, reused across requests

// embed.ts (pure, model injected so tests pass a fake)
export async function runBatch(deps, { budgetMs = 50_000, maxRows = 24 }) {
  const started = deps.now();
  const rows = await deps.claim(maxRows);
  const done = [];
  for (const row of rows) {
    if (deps.now() - started > budgetMs) break; // leftovers stay leased and are retried after 5 min
    try {
      const v = await deps.model.run(row.text, { mean_pool: true, normalize: true });
      if (!Array.isArray(v) || v.length !== 384) throw new Error("bad_dimensions");
      done.push({
        kind: row.subject_kind,
        id: row.subject_id,
        hash: row.content_hash,
        embedding: v,
      });
    } catch (e) {
      await deps.fail(row, errorCode(e));
    }
  }
  if (done.length) await deps.record(done);
  return { claimed: rows.length, embedded: done.length };
}
```

- `index.ts`: answers 401 without a matching `x-recs-secret` (checked with `recs_embed_verify_secret` through the service-role client). It runs one batch and returns counts only, and it logs counts and error codes only, never text.
- Limits (Supabase docs, "Limits"): 150 s wall clock on Free (400 s paid), 2 s CPU per request, 256 MB memory. The model is loaded once per worker. Batches are small (24 by default) with a 50 s wall-clock budget. Inference is sequential (one session, no parallel runs) to keep memory flat. If staging shows CPU-limit errors, `recs_embed_batch` comes down without a deploy.
- Throughput at the defaults is about 24 a minute (about 34,000 a day, capped at 20,000). Staging has 613 hubs, about 2,400 upcoming events and 4 listings, so a full backfill takes about 2 hours.
- `supabase/config.toml`: `[functions.recs-embed]` with `verify_jwt = false`. `.github/workflows/ci.yml` runs `deno check` and `deno test` for it. Tests cover the secret gate, the budget cut-off, a model error marking one row failed while the rest record, a wrong length rejected, and the counts-only logging.

### 4.4 Backfill

`public.recs_backfill(p_kind rec_subject_kind default null)` (service role, or moderators through the admin panel) enqueues every eligible subject of that kind (all kinds when null) with `priority 9`, clears `failed_at` rows, and returns the count queued. Migration 67 calls it once at the end. Staging and production drain it through the same cron and caps.

### 4.5 Taste vectors

- Marked stale (an upsert with `stale = true`) by triggers on `hub_members` (insert, delete), `rsvps` (insert, or update of `status` or `checked_in_at`), `bookings` (to `completed`) and `rec_dismissals` (insert), and by `recs_embed_record`.
- `public.recs_taste_refresh(p_limit int default 300)` (service role, called by `recs_tick`) recomputes up to `p_limit` stale rows:

| Input (last 365 days, never in a sensitive category, never a moderated or cancelled event) | Weight | Decay                              |
| ------------------------------------------------------------------------------------------ | ------ | ---------------------------------- |
| Joined hub                                                                                 | 1.0    | none                               |
| RSVP `going` / `waitlisted`                                                                | 1.5    | half-life 90 days from `starts_at` |
| RSVP `interested`                                                                          | 0.75   | same                               |
| Checked in (`rsvps.checked_in_at`), replaces the RSVP weight                               | 2.5    | same                               |
| Completed coaching booking (the listing's embedding)                                       | 2.0    | same                               |
| Dismissed event or hub ("Not interested")                                                  | -0.5   | half-life 30 days                  |

The weighted sum is `sum(embedding::vector * array_fill(w, array[384])::vector)` (pgvector's element-wise `*`), then `l2_normalize`, stored as `halfvec`. With no input that has an embedding, `embedding` is null and `inputs` is 0. When `rec_prefs.personalize` is false, the row is kept with a null embedding and is never recomputed.

## 5. Ranking

Shared scorer: `private.rec_event_scores(p_ids uuid[], p_anchor uuid default null)` (definer, `auth.uid()` required, `viewer_is_adult()` required) returns `(event_id, sim real, reasons jsonb)` only for ids that pass `public.can_read_event`. `sim` is the inner product with the caller's taste vector, or with the anchor event's embedding when `p_anchor` is given and readable. It is null when either side has no embedding.

Score for a candidate `c` in a set `C`:

```
s_sim  = percent_rank of sim(c) within C            (null sim -> median of C; no taste -> weight 0, others renormalized)
s_time = exp(-days_until_start / 5)                 (today 1.0, in a week about 0.25)
s_dist = {'<1 mi': 1.0, '1-5 mi': 0.85, '5-10 mi': 0.65, '10-25 mi': 0.4, '25+ mi': 0.2, 'approximate': 0.5}
score  = w.sim*s_sim + w.time*s_time + w.dist*s_dist
       + w.hub   if c is in a hub the member joined
       + w.met * least(3, people_met_going(c))      (counted under rsvps RLS, see below)
       + w.imported if c is imported
```

Weights come from `meta.recs_weights`. Then comes a greedy diversity pass: at most 2 cards per hub, at most 1 occurrence per series, at most 3 imported cards in 10, and human-hosted cards first on a tie.

**Excluded before scoring** (all rows): events the caller hosts, RSVP'd (any live status) or dismissed; events whose host is blocked either way (`public.is_blocked_with(host_id)`); events where someone the caller blocked is going (`public.event_block_warning(id) > 0`); `listing_kind = 'show'` (Shows and games keeps its own row, D-041); events in sensitive hubs; cancelled or full events without a waitlist.

`people_met_going(c)` counts rows of `public.rsvps` the caller can read under the existing `rsvps_select` policy (which already hides blocked people and sensitive hubs) whose user is in `people_you_met()`. The query runs as the caller, so RLS decides who is counted.

### 5.1 Reason chips

`reasons` is an ordered array of at most two `{code, ...params}` items, chosen by precedence. The client maps codes to copy (`packages/core/src/recs/reasons.ts`) and never builds a reason itself.

| Code               | Params         | Copy                                              | When                                                                                         |
| ------------------ | -------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `people_met_going` | `n`            | "2 people you've met are going"                   | `n >= 1`                                                                                     |
| `like_hub`         | `hub_name`     | "Like Climbing"                                   | the joined, non-sensitive hub whose embedding is most similar to `c`, above `recs_hub_floor` |
| `like_plan`        | `title`        | "Like Tuesday trivia" (a plan the caller went to) | an attended plan in the last 180 days most similar to `c`, above `recs_similar_floor`        |
| `in_your_hub`      | `hub_name`     | "In Running"                                      | `c` is in a joined hub                                                                       |
| `same_hub`         | `hub_name`     | "Also Pickleball"                                 | Similar plans only                                                                           |
| `when`             | `when`         | "Tonight" / "Tomorrow" / "This weekend"           | from `section` and the viewer's zone                                                         |
| `near`             | `band`         | "1-5 mi away"                                     | a non-approximate band                                                                       |
| `free`             |                | "Free"                                            | `is_free`                                                                                    |
| `popular`          |                | "Filling up"                                      | `going_count >= 5` or within 3 of capacity                                                   |
| `from_source`      | `source_name`  | "From Atlanta Parks"                              | imported, always shown as the attribution (D-020); does not count toward the two             |
| `teaches_your_hub` | `hub_name`     | "Coaches Tennis"                                  | coaches                                                                                      |
| `online`           |                | "Online"                                          | coaches                                                                                      |
| `rated`            | `avg`, `n`     | "4.8 from 12 reviews"                             | coaches, `rating_count >= 3`                                                                 |
| `went_to_same`     | `title`        | "You both went to Sunday run club"                | people                                                                                       |
| `same_chapter`     | `chapter_name` | "Both in Midtown Runners"                         | people                                                                                       |
| `going_to_same`    | `title`        | "Also going to Saturday hike"                     | people                                                                                       |
| `nearby_plans`     | `n`            | "6 plans near you this month"                     | hubs                                                                                         |
| `coming_up`        |                | "Coming up near you"                              | rules-only fallback when no other chip applies                                               |

A chip never names a sensitive hub, a person, a coordinate or a score. Titles in chips come only from plans the caller can read.

## 6. RPCs (migration 67)

All public RPCs: `revoke all ... from public, anon`, `grant execute ... to authenticated`, raise `not_authenticated` without `auth.uid()`, and return an empty set (not an error) for a signed-in member who is not onboarded or not adult. Signatures:

| RPC                                                                                                                                                                             | Security | What                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `recs_for_you(p_lat, p_lng, p_radius_km, p_timezone, p_limit int default 10)`                                                                                                   | invoker  | Candidates: `feed_events_v2(now(), now() + 14 days, p_lat, p_lng, p_radius_km, null, false, 200, p_timezone, 'plan')`. Then the exclusions, `private.rec_event_scores`, the score, diversity. Returns the `feed_events_v2` columns plus `reasons jsonb`, `rank int`. Fewer than 3 rows: returns none (the app hides the row).                                                                                          |
| `recs_similar_events(p_event_id, p_lat, p_lng, p_radius_km, p_timezone, p_limit int default 6)`                                                                                 | invoker  | Raises `not_found` unless `can_read_event(p_event_id)`. Candidates: `feed_events_v2(now(), now() + 30 days, ...)` minus the anchor and its series. `sim` against the anchor's embedding, kept above `recs_similar_floor`; with no anchor embedding, same hub only. Weights `sim 0.6, time 0.2, dist 0.2`. Not personal: shown with personalization off too.                                                            |
| `recs_hubs(p_lat, p_lng, p_radius_km, p_limit int default 8)`                                                                                                                   | invoker  | Candidates: hubs readable under `hubs_read`, `moderation_state is null`, category not sensitive, `scope = 'general'`, `min_age <= viewer_age()`, not joined, not dismissed. `nearby_plans` from one `feed_events_v2` call over 30 days grouped by hub. Score `0.6 s_sim + 0.3 s_local (log of nearby plans) + 0.1 s_size (hub_stats.member_count)`. Scorer `private.rec_hub_scores(uuid[])`.                           |
| `recs_coaches(p_lat, p_lng, p_radius_km, p_limit int default 6)`                                                                                                                | invoker  | Candidates: `search_coaches(p_lat, p_lng, p_radius_km, null, null, null, null, null, null, 50)` (its own blocks, age, area and online rules). Returns none on its `onboarding_required`. Scorer `private.rec_coach_scores(uuid[])`: the best `sim` over each coach's active listing embeddings. Score `0.55 s_sim + 0.25 band + 0.1 hub overlap + 0.1 rating (count >= 3)`. Excludes dismissed coaches and the caller. |
| `recs_people(p_limit int default 8)`                                                                                                                                            | invoker  | Section 7.                                                                                                                                                                                                                                                                                                                                                                                                             |
| `rec_dismiss(p_kind rec_subject_kind, p_id uuid)` / `rec_undismiss(p_kind, p_id)`                                                                                               | definer  | Own rows only; at most 60 dismissals an hour (`rate_limited`); marks taste stale.                                                                                                                                                                                                                                                                                                                                      |
| `my_recommendation_prefs()` / `set_recommendation_prefs(p_personalize boolean default null, p_people_suggestions boolean default null)`                                         | definer  | Upserts the caller's `rec_prefs`. Turning `personalize` off nulls the taste embedding at once; turning it on marks it stale.                                                                                                                                                                                                                                                                                           |
| `public_week_near(p_lat double precision default null, p_lng double precision default null, p_limit int default 12)`                                                            | definer  | Landing page (section 8). `grant execute to anon, authenticated`.                                                                                                                                                                                                                                                                                                                                                      |
| `recs_status()`                                                                                                                                                                 | definer  | Moderators: queue due/claimed/failed by kind, embeddings by kind, embedded today, tastes with a vector, last dispatch. Counts only.                                                                                                                                                                                                                                                                                    |
| `recs_embed_dispatch`, `recs_embed_claim`, `recs_embed_record`, `recs_embed_fail`, `recs_embed_verify_secret`, `recs_backfill`, `recs_taste_refresh`, `recs_tick`, `purge_recs` | definer  | Service role only (`revoke ... from authenticated`). `recs_backfill` also allows moderators.                                                                                                                                                                                                                                                                                                                           |
| `scorecard_week(p_week_start date default null)`                                                                                                                                | definer  | Section 10. Service role, or moderators (`is_moderator()`).                                                                                                                                                                                                                                                                                                                                                            |

Because the candidate query inside an invoker RPC runs as the caller, the events policy (moderation, age, published, campus), `feed_events_v2`'s distance rule (never another city's plans), its `approved_only` 8 km slack and its "approximate" band apply unchanged. Private venues and approved-only addresses are never exposed, because the rows carry only the feed's columns (`location_hint`, band), exactly what the feed shows.

### 6.1 Rebuilt from their latest bodies (each change marked "Migration 67")

- `public.request_account_deletion(text)` (migration 62 body): `delete from public.rec_taste`, `public.rec_prefs` and `public.rec_dismissals where user_id = uid`, and `delete from public.rec_dismissals where subject_kind = 'person' and subject_id = uid` (other people's "not interested" in the deleted person). The cascades do not fire because the profile is tombstoned, not deleted. Embeddings of the caller's events go when those events are cancelled (the queue trigger sees them ineligible), and their coach listings' embeddings cascade with the listings. `delete-account` needs no change (no storage, no processor).
- Nothing else is rebuilt: `feed_events_v2`, `search_coaches` and `people_you_met` are called, not changed.

## 7. People suggestions

Candidates (union, each with its context), all read as the caller:

1. **Met**: `people_you_met(null, 100)` (mutual picks or both checked in, 365 days, no blocks, no hidden or deleted profiles). Context `went_to_same` with the latest plan title.
2. **Same chapter**: other members of chapters the caller belongs to, read through the `chapter_members` policy (sensitive-category chapters are already hidden from other members). Context `same_chapter`.
3. **Going to the same plan**: other `going` RSVPs on upcoming plans the caller is going to, read through `rsvps_select` (blocks and sensitive hubs already hidden). Context `going_to_same`.

Hub co-membership alone is **not** context: it is too broad, and for sensitive hubs it would leak membership.

`private.rec_people_scores(p_ids uuid[])` (definer) keeps only ids where both people are active, not deleted, not moderated and adult; `rec_prefs.people_suggestions` is not false for either person; there is no block either way (`users_blocked`); the caller has not muted them; they are not dismissed; and there is no DM between them in the last 30 days. It returns the inner product of the two taste vectors (null when either is missing or either has `personalize` off). Order: context strength (met 3, going to the same plan 2, same chapter 1, summed), then `s_sim`, then the most recent shared plan. Returns `user_id, handle, first_name, avatar_url, reasons`. Never the other person's hubs, RSVPs, score or location.

Opt-out: You, then Privacy and safety, then "Suggest me to people I share plans with" (`people_suggestions`). Off means the member is never in anyone's row and sees no People row. "Use my activity to personalize recommendations" (`personalize`) sits under it.

## 8. Landing page v2 (`apps/web`)

**Data.** `public.public_week_near(p_lat, p_lng, p_limit)` (definer, anon allowed): the origin is the given point rounded to 0.1 degree (about 11 km), else the Atlanta area centre. It returns published events starting from now to now plus 7 days within 40 km of the origin, with `visibility = 'public'`, `min_age = 18`, `moderation_state is null`, `members_only = false`, hub active with category not sensitive, `listing_kind = 'plan'`, and the host (when there is one) `active`. Human-hosted first, then by start time, at most 12 (cap 24). Columns: `id, title, hub {name, emoji, slug}, starts_at, timezone, is_free, price_text, going_bucket ('3+', '10+', null), distance_band, is_imported, source_name`. There is no host, no description, no `location_hint`, no coordinate and no address, so a private venue or approved-only address cannot show. Each card links to `/e/<id>`, which applies its own rules (`event_share_card`). Grants: `revoke all from public`, `grant execute to anon, authenticated`.

**No IP lookup.** The page and its route never read `x-forwarded-for`, `x-vercel-ip-*` or `request.geo`, and they log no request detail. Location comes only from:

1. the **city picker**, a combobox over `STARTER_CITIES` (`@ap/core/places`, `searchStarterCities`), with the choice remembered by city id in `localStorage` (wrapped in try/catch); or
2. a **"Use my location"** button. `navigator.geolocation.getCurrentPosition` is called only after that tap, and the browser rounds to 0.1 degree before any request. The point is never stored.

With neither, the page shows Atlanta and says so: "Showing plans around Atlanta. Pick your city to see yours." The empty state reads "Nothing posted near {city} this week yet. Be the first: post a plan in the app." There is no waitlist anywhere, and the page never calls `join_area_waitlist`.

**Delivery.** The server render fetches Atlanta with `revalidate = 600`. `apps/web/src/app/api/week/route.ts` serves `?lat&lng` (validated, rounded again) with `Cache-Control: public, s-maxage=600, stale-while-revalidate=3600`, so a city is one cached response. The client island (`week-near-you.tsx`) swaps cards without a page reload. Times are formatted in each event's `timezone` (`lib/event-time.ts`).

**Sections** (`apps/web/src/components/landing/`):

1. **Hero**: the current headline and copy, "Open the app" (`APP_URL`), "See what's on this week" (anchor).
2. **This week near you**: the picker, the location button and up to 12 cards (hub, title, day and time, band, Free or price, "10+ going", "From {source}" on imported cards). A card whose `source_name` names Georgia State carries "Not affiliated with or endorsed by Georgia State University." on that card only (`gsu` check as in `apps/web/src/app/e/[id]/page.tsx`). No other section names Georgia State, so no other section carries the line.
3. **How it works**: join hubs for what you're into, see plans near you, show up and meet people.
4. **Trust**: adults 18+ only; distance shown in bands and never your address; report and block on every profile, plan and chat; moderators review reports within 24 hours; meet in public places; you can delete your account in the app. Links: Safety Center (`/safety`), intimate image removal (`/safety/intimate-images`), delete your account (`/account/delete`).
5. **Apps**: "iPhone and Android apps are coming soon. Activity Planet works in your browser today, and you can add it to your home screen." These are two neutral "Coming soon" pills with Apple and Android named in plain text. There is **no official App Store or Google Play badge artwork and no store link**, because both companies' badge rules apply only to apps that are available.
6. **Footer**: Safety, Coach terms, Refund policy, Map data, Delete account (the existing pages). Privacy and Terms are linked once those pages exist in `apps/web` (section 13).

Metadata: title, description, the existing `opengraph-image.tsx`, and the sitemap entry unchanged. Accessibility: a labelled combobox, a visible focus state, a button (not an auto-prompt) for location, and `prefers-reduced-motion`.

## 9. PWA polish (`apps/app`)

Found in the current build:

1. **No install prompt.** Nothing handles `beforeinstallprompt`, and iPhone has no prompt at all (PLAN 4.10 asks for one in onboarding; web push on iPhone needs the app installed). Add `lib/install.ts` (`useInstallPrompt`: captures the event, reports `standalone` from `display-mode: standalone` or `navigator.standalone`, and recognizes iOS Safari) and `components/shell/install-card.tsx`. On Chromium it calls `prompt()`. On iPhone it opens a sheet: "Tap Share, then Add to Home Screen." The card appears on the onboarding finish step, in You, and once after the first RSVP. Dismissal lasts 30 days (`localStorage`, try/catch), and the card is never shown once installed. The push settings link to it when iPhone push is unavailable outside the installed app.
2. **Silent take-over on update.** `registerType: "autoUpdate"` plus an unconditional `self.skipWaiting()` swaps the worker under an open tab, so lazy route chunks from the old build can 404 mid-session. Change to `registerType: "prompt"` and `injectRegister: false`. `sw.ts` drops the top-level `skipWaiting()` and listens for `{type: "SKIP_WAITING"}` (it keeps `clientsClaim`, the caches and the push handlers). `components/shell/update-toast.tsx` uses `useRegisterSW` from `virtual:pwa-register/react` to show "A new version is ready" with a Reload button, and it checks again hourly while the app is visible. Also add a `vite:preloadError` handler that reloads once (guarded by `sessionStorage`).
3. **Icons and manifest.** Add `id: "/"`, a 192 px maskable icon, a `monochrome` icon (Android themed icons), `shortcuts` (Post a plan `/post`, Map `/map`, Chats `/chats`) with 96 px icons, `screenshots` (two `narrow`, one `wide`, for Android's richer install sheet), and `launch_handler: {client_mode: "focus-existing"}`. Add iOS `apple-touch-startup-image` splash screens for the current iPhone sizes. All are generated by the existing `scripts/gen-icons.mts` from `packages/ui/src/brand/scene.ts`, so the brand mark is the single source.
4. **App badge.** For the installed app, `navigator.setAppBadge` shows unread chats plus unread notifications (`chat_unread_total`, `unread_notification_count`, already queried) and clears at 0. Feature-detected and a no-op elsewhere.

## 10. Weekly scorecard email

- `public.scorecard_week(p_week_start date)` returns counts only, for the Monday-to-Sunday week in America/New_York (the last full week when null): `people` {signups, onboarded, wau (distinct `profile_private.last_seen_at` in the week), members}; `plans` {human_hosted_held, human_hosted_next_7d, four_plus_checked_in, unique_attendees, second_attendance_rate (attendees in the last 28 days with 2 or more check-ins over attendees)}; `chapters_active`; `messages` {sent, active_conversations}; `coaching` {requested, confirmed, completed, gmv_minor by currency}; `collector` {imported_upcoming, sources_ok, sources_stale} (from `collector_health_snapshot`'s counts); `recs` {tastes_with_vector, embeddings by kind, queue_due, failed}; `trust` {reports_open, reports_overdue, takedowns_open} (the `mod_scorecard` queries); and `launch_gate` {recurring human-hosted plans in the weeks of 2027-01-11 and 2027-01-18 against 10 each, chapters live against 5}. Imported-shelf clicks live in PostHog, not the database, so the email links to PostHog for them.
- pg_cron `weekly-scorecard`, `7 12 * * 1` (Monday 07:07 or 08:07 Eastern), calls `public.scorecard_dispatch()`, which POSTs to the `weekly-scorecard` Edge Function with `x-scorecard-secret` (vault `scorecard_secret`) unless that week's `scorecard_runs` row says `sent`.
- `supabase/functions/weekly-scorecard/` (`index.ts`, `scorecard.ts`, `scorecard_test.ts`), `verify_jwt = false` with its secret check. It reads `RESEND_API_KEY` and `SCORECARD_TO` (an Edge Function secret, never in the repo) first. If either is missing it records `skipped_no_key` and returns 200 without calling anything. Otherwise it calls `scorecard_week`, computes deltas against last week's stored `counts`, renders plain text and simple HTML (tables of numbers, a link to the admin panel, no names, no rows), sends through the Resend client in `../send-notifications/resend.ts` (imported, not changed) from `NOTIFY_EMAIL_FROM`, and records `sent` or `failed`. Tests cover the key gate, the template from a fixture, the deltas and the idempotent second call.

## 11. Jobs and tuning

| Job (pg_cron, unscheduled by name first) | Schedule      | Does                                                                                                                                                                                                |
| ---------------------------------------- | ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `recs-embed`                             | `* * * * *`   | `recs_embed_dispatch()`                                                                                                                                                                             |
| `recs-tick`                              | `*/5 * * * *` | `recs_tick()`: `recs_taste_refresh(300)`; enqueue events that became eligible by time (entering the 60 or 120 day horizon); nightly at 03:00 UTC, re-queue rows whose stored hash no longer matches |
| `purge-recs`                             | `23 4 * * *`  | `purge_recs()`: embeddings of ineligible or year-old events, dismissals older than 180 days, `failed` queue rows older than 30 days                                                                 |
| `weekly-scorecard`                       | `7 12 * * 1`  | `scorecard_dispatch()`                                                                                                                                                                              |

Tuning after the staging backfill uses read-only `SELECT`s through the connector and counts only. Look at the distribution of event-to-event inner products for same-hub and different-hub pairs and set `recs_similar_floor` and `recs_hub_floor` between their medians. Check that For you for a seeded test member puts same-hub plans above others at equal distance. The weights live in `meta`, so tuning is a one-row update by migration (never by the connector).

## 12. Build slices

Exactly two.

### Slice 1: database, embeddings Edge Function, jobs, RPCs, scorecard

Migration 67, `supabase/migrations/20261231000100_recommendations.sql` (sorts after `20261230000100_collector_review_fixes.sql`), idempotent, `meta.schema_version` **2.62 to 2.63**:

1. `vector` extension; the enum; the tables in section 3 with RLS, explicit grants and revokes, and the owner-select policies (`drop policy if exists` first); the `meta` keys.
2. The queue triggers and taste-stale triggers (section 4); `private.rec_text`; the vault secrets `recs_embed_secret` and `scorecard_secret`.
3. The RPCs in section 6 and the private scorers; `request_account_deletion` rebuilt from its migration 62 body, marked "Migration 67".
4. The pg_cron jobs in section 11; `recs_backfill()` once.
5. Edge Functions `recs-embed` and `weekly-scorecard` (pure modules plus a thin `index.ts`, Deno tests, `config.toml`, CI `deno check` and `deno test`), deployed to staging with `staging_functions`.

Tests (one transaction each, `set local role authenticated` and `request.jwt.claims` per actor, synthetic one-hot 384-dimension vectors written as the test owner, pass/fail only, `ROLLBACK`, added to `supabase/tests/regression.txt`):

- `supabase/tests/recommendations.sql`: queue triggers on insert and edit; claim builds text, skips an unchanged hash and drops ineligible subjects; record validates length and norm and refuses a stale hash; fail after 5 attempts; taste weights, decay, sensitive and moderated inputs ignored, personalize off; For you excludes RSVP'd, dismissed, own, blocked host, blocked attendee, 21+ for a 19-year-old, sensitive hub, campus-only to a non-member, moderated, shows, and another city's plans (London member, Atlanta plan); ordering by similarity at equal distance and by distance at equal similarity; diversity caps; chips never name a sensitive hub; Similar plans refuses an unreadable anchor; hubs excludes joined, sensitive, campus-scope, 21+ and moderated; coaches excludes blocked coaches and the caller; account deletion removes the member's taste, prefs and dismissals and others' person dismissals of them.
- `supabase/tests/recommendations_people.sql`: only shared context (met, same chapter, going to the same plan); hub co-membership alone gives nothing; sensitive chapters give nothing; opt-out on either side; blocks either way; mutes; a recent DM; no score, hub or location in the result.
- `supabase/tests/scorecard_landing.sql`: `scorecard_week` counts on seeded rows, refused for a member, allowed for a moderator; `public_week_near` as `anon` returns only public, 18+, unmoderated, non-members-only, non-sensitive plans in 7 days and 40 km, with no host, description, hint or coordinate columns, and Atlanta with no point; `scorecard_runs` is moderator-read only.

Then regenerate `packages/core/src/types/database.ts` from the staging run's "Staging, print generated Database types" section (keep the header, run prettier), and watch the backfill drain on staging with read-only counts.

### Slice 2: app rows, landing page v2, PWA polish

No migration is planned. Review fixes, if any, go in migration 68.

- `packages/core/src/recs/`: Zod schemas for every RPC result; `reasons.ts` (code to copy, two-chip limit, attribution kept); `landing.ts` (coordinate rounding to 0.1 degree, the week card parser); unit tests.
- `apps/app/src/lib/recs.ts`: query options (stale time 5 minutes; the feed's origin and radius ladder from `lib/location.ts`), `dismiss` with optimistic removal, prefs.
- Components (`apps/app/src/components/recs/`): `for-you-row.tsx` (Home, above the day sections, hidden under 3 cards or while a hub filter is on), `similar-plans.tsx` (event page, below details, up to 6), `hubs-you-may-like.tsx` (top of Hubs and a compact row at the bottom of Home), `coaches-for-you.tsx` (top of `/coaches`), `people-row.tsx` (top of `/you/met`), `reason-chips.tsx`, and `rec-card-menu.tsx` ("Not interested", "Why am I seeing this?" listing the chips in words). Privacy toggles in `you.tsx` under Privacy and safety.
- `apps/web`: section 8 (`page.tsx`, `components/landing/*`, `app/api/week/route.ts`).
- `apps/app`: section 9 (`vite.config.ts`, `src/sw/sw.ts`, `lib/install.ts`, `components/shell/install-card.tsx`, `components/shell/update-toast.tsx`, the badge hook, regenerated icons).
- `apps/app/e2e/10-recs.mjs`: For you renders with chips, Not interested removes a card, Similar plans on an event, the install card hidden in standalone, the update toast on a simulated waiting worker.
- Copy neutral and for everyone (D-040). Done when `pnpm typecheck`, `lint`, `test` and `build` pass and the slice 1 test files pass on staging.

## 13. Open items for Sai

- **Non-English text.** gte-small is English-only. For a member whose plans are mostly in another language, similarity is weak and the rows lean on distance and time. If that share grows, consider a multilingual small model run in an Edge Function through Transformers.js (still free, heavier). It would be a separate decision.
- **Privacy Policy line**: "We use your hubs, RSVPs and check-ins to suggest plans, hubs, coaches and people you share plans with; you can turn this off." The Play Data safety form gets the same line. The Privacy, Terms and Community Guidelines pages are linked from the app (`SITE_URL/privacy`) but are not in `apps/web` yet, so the landing footer links them only once they exist.
- Add the `SCORECARD_TO` Edge Function secret (your address) on production when Resend is set up. Until then the email is skipped and recorded as `skipped_no_key`.
- "What similar users did" (collaborative filtering) and learned ranking are post-launch (**P**), once there are RSVPs to learn from; v1 is content plus rules plus co-attendance.
- Out of scope for this design: the week 11 QA pass, and importer health (the collector health panel from migrations 63 and 66 already covers it).
