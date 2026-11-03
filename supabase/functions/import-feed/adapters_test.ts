// deno test supabase/functions/import-feed --allow-read
import { assert, assertEquals, assertStrictEquals } from "jsr:@std/assert@1.0.19";
import {
  decodeEntities,
  excerpt,
  EXCERPT_CHARS,
  htmlToText,
  httpsUrl,
  parseEngageRss,
  parseLocalistPage,
} from "./adapters.ts";

const fixture = (name: string) => Deno.readTextFile(new URL(`./fixtures/${name}`, import.meta.url));

Deno.test("localist: one item per instance, private events left out, paging read", async () => {
  const page = parseLocalistPage(JSON.parse(await fixture("localist-page1.json")));
  assertEquals(page.page, 1);
  assertEquals(page.totalPages, 2);
  assertEquals(
    page.items.map((i) => i.external_id),
    ["51234567:9001", "51234567:9002", "51234569:9004"],
  );
});

Deno.test("localist: fields map to the item shape", async () => {
  const [first, second, art] = parseLocalistPage(
    JSON.parse(await fixture("localist-page1.json")),
  ).items;
  assertEquals(first.title, "Panther Pickup Basketball & Open Gym");
  assertEquals(first.starts_at, "2026-11-12T23:00:00.000Z");
  assertEquals(first.ends_at, "2026-11-13T01:00:00.000Z");
  assertEquals(first.location, "Recreation Center, Court 2");
  assertEquals(first.lat, 33.7537);
  assertEquals(first.lng, -84.3826);
  // The http url is refused; the calendar page is https.
  assertEquals(first.url, "https://calendar.gsu.edu/event/panther-pickup-basketball");
  assertEquals(first.cover_url, "https://localist-images.azureedge.net/photos/1/huge/abc.jpg");
  assertStrictEquals(first.is_free, true);
  assertStrictEquals(first.open_to_public, true);
  assertEquals(first.host_org, "Recreational Services");
  assertEquals(first.categories, ["Recreation"]);
  assert(first.description.length <= EXCERPT_CHARS);
  assert(first.description.endsWith("…"));
  assertStrictEquals(first.cancelled, false);
  // A missing end stays null; the database applies the two-hour default.
  assertStrictEquals(second.ends_at, null);

  assertEquals(art.description, "Paintings & prints\nby students.");
  assertEquals(art.location, "Welch Gallery");
  assertStrictEquals(art.all_day, true);
  assertStrictEquals(art.is_free, false);
  assertEquals(art.price_text, "$5 suggested donation");
  assertStrictEquals(art.cancelled, true);
  // No audience filter: the source says nothing about the public.
  assertStrictEquals(art.open_to_public, null);
});

Deno.test("localist: tolerates missing fields and junk entries", async () => {
  const page = parseLocalistPage(JSON.parse(await fixture("localist-sparse.json")));
  assertEquals(page.totalPages, 1);
  assertEquals(page.items.length, 1);
  const [item] = page.items;
  assertEquals(item.external_id, "77:2026-12-01T10:00:00.000Z");
  assertStrictEquals(item.url, null);
  assertEquals(item.location, "");
  assertStrictEquals(item.lat, null);
  assertStrictEquals(item.host_org, null);
  assertEquals(parseLocalistPage(null).items, []);
  assertEquals(parseLocalistPage({ events: "nope" }).items, []);
});

Deno.test("engage rss: plain elements", async () => {
  const items = parseEngageRss(await fixture("engage.rss"));
  assertEquals(
    items.map((i) => i.external_id),
    ["10458123", "10458999", "10459000"],
  );
  const [tt] = items;
  assertEquals(tt.title, "Table Tennis Club: Weekly Rally Night");
  assertEquals(tt.url, "https://gsu.campuslabs.com/engage/event/10458123");
  assertEquals(tt.starts_at, "2026-11-12T23:00:00.000Z");
  assertEquals(tt.ends_at, "2026-11-13T01:00:00.000Z");
  assertEquals(tt.location, "Student Center East, Room 216");
  assertEquals(tt.host_org, "Table Tennis Club");
  assertEquals(tt.categories, ["Sports", "Social"]);
  assertEquals(tt.description, "All skill levels. Paddles provided & snacks.");
  assertEquals(tt.cover_url, "https://se-images.campuslabs.com/clink/images/abc.png?preset=med-w");
  assertStrictEquals(tt.open_to_public, null);
  assertStrictEquals(tt.cancelled, false);
});

Deno.test("engage rss: hCalendar markup in an escaped description", async () => {
  const anime = parseEngageRss(await fixture("engage.rss"))[1];
  assertEquals(anime.starts_at, "2026-11-20T23:30:00.000Z");
  assertEquals(anime.ends_at, "2026-11-21T02:00:00.000Z");
  assertEquals(anime.location, "Aderhold Learning Center 102");
  assertEquals(anime.description, "Screening & pizza.");
  assertEquals(anime.host_org, "Anime Society");
  assertStrictEquals(anime.cover_url, null);
});

Deno.test("engage rss: status and missing end", async () => {
  const bake = parseEngageRss(await fixture("engage.rss"))[2];
  assertStrictEquals(bake.cancelled, true);
  assertStrictEquals(bake.ends_at, null);
  assertEquals(bake.location, "");
  assertEquals(parseEngageRss("not xml"), []);
});

Deno.test("text helpers", () => {
  assertEquals(
    decodeEntities("Tom &amp; Jerry &#8217;s &#x2014; &nbsp;x &bogus;"),
    "Tom & Jerry ’s —  x &bogus;",
  );
  assertEquals(htmlToText("<p>One</p><p>Two<br/>Three</p><script>x()</script>"), "One\nTwo\nThree");
  assertEquals(excerpt("short"), "short");
  const long = "word ".repeat(100);
  const cut = excerpt(long, 50);
  assert(cut.length <= 50);
  assert(cut.endsWith("…"));
  assertStrictEquals(httpsUrl("http://x.org"), null);
  assertStrictEquals(httpsUrl("javascript:alert(1)"), null);
  assertEquals(httpsUrl(" https://x.org/a "), "https://x.org/a");
});
