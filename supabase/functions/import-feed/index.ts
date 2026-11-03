// import-feed: reads one allowlisted public feed and hands its items to import_upsert_batch()
// (D-037, D-004, D-014, PLAN 4.4).
//
// Called by pg_cron through pg_net (public.import_dispatch), hourly per enabled source, with
// body {"source": "<feed_sources.slug>"} and the header x-import-secret. The secret is
// generated inside the database (vault secret import_feed_secret) and checked here through
// import_verify_secret(), which only the service role can call; nothing secret is in code,
// files or GitHub. The gateway JWT check is off for this function (config.toml) because the
// caller is the database, not a user.
//
// Polite polling: an identifying User-Agent; Localist pages fetched one after another with a
// gap of more than one second (under 1 request per second); the Engage RSS feed fetched once
// per run. One run sends the complete item set in one RPC call, so missed-run counting sees
// the whole feed.
//
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected by Supabase.
import { parseEngageRss, parseLocalistPage, type ImportItem } from "./adapters.ts";

const USER_AGENT =
  "ActivityPlanetImporter/1.0 (+https://activityplanet.app; support@activityplanet.app)";
const LOCALIST_PAGE_SIZE = 100;
const LOCALIST_DAYS = 60;
const LOCALIST_MAX_PAGES = 15;
const LOCALIST_GAP_MS = 1100;
const FETCH_TIMEOUT_MS = 20_000;

interface Source {
  slug: string;
  kind: string;
  url: string;
  enabled: boolean;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function fetchText(url: string, accept: string): Promise<string> {
  const res = await fetch(url, {
    headers: { "User-Agent": USER_AGENT, Accept: accept },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  const text = await res.text();
  if (!res.ok)
    throw new Error(`HTTP ${res.status} from ${new URL(url).host}: ${text.slice(0, 200)}`);
  return text;
}

async function readLocalist(base: string): Promise<{ items: ImportItem[]; sample: unknown }> {
  const items: ImportItem[] = [];
  let sample: unknown = null;
  for (let page = 1; page <= LOCALIST_MAX_PAGES; page++) {
    if (page > 1) await sleep(LOCALIST_GAP_MS);
    const url = new URL(base);
    url.searchParams.set("pp", String(LOCALIST_PAGE_SIZE));
    url.searchParams.set("days", String(LOCALIST_DAYS));
    url.searchParams.set("page", String(page));
    const body = await fetchText(url.toString(), "application/json");
    const payload = JSON.parse(body);
    if (page === 1) {
      const first = Array.isArray(payload?.events) ? payload.events[0] : null;
      sample = { page: payload?.page ?? null, first_event: first };
    }
    const parsed = parseLocalistPage(payload);
    items.push(...parsed.items);
    if (parsed.page >= parsed.totalPages) return { items, sample };
    if (page === LOCALIST_MAX_PAGES) {
      // A cut-off read is not the complete feed: sending it would count every listing past the
      // cap as missed and cancel it. Fail the run instead; import_record_error records why.
      throw new Error(
        `Localist feed has ${parsed.totalPages} pages, more than the ${LOCALIST_MAX_PAGES} read per run; nothing imported`,
      );
    }
  }
  return { items, sample };
}

async function readEngage(url: string): Promise<{ items: ImportItem[]; sample: unknown }> {
  const xml = await fetchText(url, "application/rss+xml, application/xml;q=0.9, */*;q=0.5");
  const firstItem = /<item\b[\s\S]*?<\/item>/i.exec(xml)?.[0] ?? xml.slice(0, 2000);
  return { items: parseEngageRss(xml), sample: { first_item_xml: firstItem.slice(0, 4000) } };
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return json({ error: "misconfigured" }, 500);

  const rest = async (path: string, init: RequestInit = {}) => {
    const res = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
      ...init,
      headers: {
        apikey: serviceKey,
        Authorization: `Bearer ${serviceKey}`,
        "Content-Type": "application/json",
        ...(init.headers ?? {}),
      },
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`${path}: HTTP ${res.status} ${text.slice(0, 300)}`);
    return text ? JSON.parse(text) : null;
  };
  const rpc = (name: string, args: Record<string, unknown>) =>
    rest(`rpc/${name}`, { method: "POST", body: JSON.stringify(args) });

  const secret = req.headers.get("x-import-secret") ?? "";
  let allowed = false;
  try {
    allowed =
      secret.length >= 32 && (await rpc("import_verify_secret", { p_secret: secret })) === true;
  } catch (err) {
    console.error("import-feed: secret check failed", String(err));
    return json({ error: "secret_check_failed" }, 500);
  }
  if (!allowed) return json({ error: "unauthorized" }, 401);

  let slug = "";
  try {
    const body = await req.json();
    slug = typeof body?.source === "string" ? body.source : "";
  } catch {
    return json({ error: "invalid_body" }, 400);
  }
  if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(slug)) return json({ error: "invalid_source" }, 400);

  const rows = (await rest(`feed_sources?slug=eq.${slug}&select=slug,kind,url,enabled`)) as
    Source[] | null;
  const source = rows?.[0];
  if (!source) return json({ error: "source_not_found" }, 404);
  if (!source.enabled) return json({ error: "source_disabled" }, 409);

  let sample: unknown = null;
  try {
    let read: { items: ImportItem[]; sample: unknown };
    if (source.kind === "localist") read = await readLocalist(source.url);
    else if (source.kind === "engage_rss") read = await readEngage(source.url);
    else return json({ error: "unsupported_kind" }, 422);
    sample = read.sample;

    const result = await rpc("import_upsert_batch", { p_source_slug: slug, p_items: read.items });
    console.log("import-feed", slug, JSON.stringify(result));
    // Keep one verbatim payload sample next to the run status, so field names can be checked
    // with a read-only query (the GSU hosts are not reachable from development sessions).
    await rest(`feed_sources?slug=eq.${slug}`, {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        last_sample: { source: sample, first_items: read.items.slice(0, 2) },
      }),
    }).catch((err) => console.error("import-feed: sample not stored", String(err)));
    return json(result);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("import-feed", slug, message);
    try {
      await rpc("import_record_error", {
        p_source_slug: slug,
        p_error: message,
        p_sample: sample ?? null,
      });
    } catch (recordErr) {
      console.error("import-feed: could not record the error", String(recordErr));
    }
    return json({ error: "import_failed", message }, 502);
  }
});
