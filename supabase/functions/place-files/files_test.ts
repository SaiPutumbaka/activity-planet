import { assert, assertEquals } from "jsr:@std/assert@1";

import {
  bestMatch,
  decodeRows,
  distanceM,
  loadTile,
  parsePlaceRequest,
  placeFromFile,
  runMatch,
  similarity,
  trigrams,
  type FileRow,
} from "./files.ts";

const TILE = 41119;

function fileJson(rows: unknown[]): unknown {
  return { v: 1, tile: TILE, rules_version: 1, rows };
}

const COURT = [
  "w1",
  -140.23,
  -61.23,
  "court_field",
  "POP Court Alpha",
  [7],
  "",
  "",
  null,
  null,
  {},
];
const HALL = [
  "n2",
  -140.3,
  -61.3,
  "community",
  "Corner Hall",
  [9],
  "1 Way",
  "Nowhere",
  "Mo-Fr",
  "https://x.org",
  { sport: "chess", n: 1 },
];

async function hex(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, "0")).join("");
}

async function gzip(text: string): Promise<Uint8Array> {
  const stream = new Blob([new TextEncoder().encode(text)])
    .stream()
    .pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/** A published file: its gzip, path (hash16 of the JSON) and sha256 (of the gzip). */
async function published(rows: unknown[]) {
  const text = JSON.stringify(fileJson(rows));
  const plain = new TextEncoder().encode(text);
  const gz = await gzip(text);
  const hash16 = (await hex(plain)).slice(0, 16);
  return { gz, plain, path: `places/v1/${TILE}.${hash16}.json.gz`, sha256: await hex(gz) };
}

function fetchOf(files: Record<string, Uint8Array>, seen: string[] = []) {
  return (url: string) => {
    seen.push(url);
    const key = Object.keys(files).find((k) => url.endsWith(k));
    return Promise.resolve(
      key ? new Response(files[key]) : new Response("missing", { status: 404 }),
    );
  };
}

Deno.test("trigrams and similarity match pg_trgm", () => {
  assertEquals([...trigrams("cat")].sort(), ["  c", " ca", "at ", "cat"]);
  assertEquals([...trigrams("Cat, CAT!")].sort(), ["  c", " ca", "at ", "cat"]);
  // select similarity('word', 'words') = 0.571429
  assertEquals(similarity("word", "words").toFixed(6), "0.571429");
  assertEquals(similarity("POP Court Alpha", "pop court alpha"), 1);
  assertEquals(similarity("", "abc"), 0);
  // Letters outside ASCII are word characters, as in a UTF-8 database.
  assert(similarity("Sporthalle Süd", "Sporthalle Sued") > 0.45);
  assert(similarity("Riverside Courts", "Downtown Library") < 0.45);
});

Deno.test("distance is in metres", () => {
  const d = distanceM({ lng: -140.2302, lat: -61.2301 }, { lng: -140.23, lat: -61.23 });
  assert(d > 13 && d < 17, String(d));
});

Deno.test("best match: 60 m, same or close name, same name first, then nearest", () => {
  const rows = decodeRows(
    fileJson([
      COURT,
      ["n3", -140.2301, -61.23, "court_field", "POP Court Alpha East", [7]],
      ["n4", -140.2302, -61.2301, "court_field", "Something Else", [7]],
      ["n5", -140.24, -61.24, "court_field", "POP Court Alpha", [7]],
    ]),
    TILE,
  );
  const venue = { lng: -140.2302, lat: -61.2301, name: "POP Court Alpha" };
  assertEquals(bestMatch(rows, venue)?.osm_ref, "w1");
  assertEquals(bestMatch(rows, { ...venue, name: "POP Court Alpha Eas" })?.osm_ref, "n3");
  assertEquals(bestMatch(rows, { ...venue, name: "Library" }), null);
  assertEquals(bestMatch(rows, { ...venue, lng: -140.3 }), null);
});

Deno.test(
  "decodeRows: v1 rows as place_from_file takes them; bad rows dropped; wrong tile throws",
  () => {
    const rows = decodeRows(
      fileJson([COURT, HALL, ["x1", 0, 0, "k", "n", [1]], ["n6", 0, 0, "k", "n", []], "nope"]),
      TILE,
    );
    assertEquals(rows.length, 2);
    assertEquals(rows[1], {
      osm_ref: "n2",
      lng: -140.3,
      lat: -61.3,
      kind: "community",
      name: "Corner Hall",
      rule_ids: [9],
      address_text: "1 Way",
      locality: "Nowhere",
      opening_hours: "Mo-Fr",
      website: "https://x.org",
      tags: { sport: "chess" },
    } satisfies FileRow);
    let threw = false;
    try {
      decodeRows(fileJson([COURT]), TILE + 1);
    } catch {
      threw = true;
    }
    assert(threw);
  },
);

Deno.test(
  "loadTile: gzip checked against sha256, decoded JSON against the name; tampered refused",
  async () => {
    const f = await published([COURT]);
    const base = "https://pages.example/ap/";
    assertEquals(
      (await loadTile(fetchOf({ [f.path]: f.gz }), base, { tile: TILE, ...f })).length,
      1,
    );
    assertEquals(
      (await loadTile(fetchOf({ [f.path]: f.plain }), base, { tile: TILE, ...f })).length,
      1,
    );
    const other = await published([HALL]);
    for (const body of [other.gz, other.plain]) {
      let err = "";
      try {
        await loadTile(fetchOf({ [f.path]: body }), base, { tile: TILE, ...f });
      } catch (e) {
        err = String(e);
      }
      assert(err.includes("file_unverified"), err);
    }
  },
);

Deno.test("runMatch: no base url is a clean skip", async () => {
  const calls: string[] = [];
  const r = await runMatch({
    rpc: (name) => {
      calls.push(name);
      return Promise.resolve({ base: null, venues: [] });
    },
    fetch: () => Promise.reject(new Error("no fetch")),
  });
  assertEquals(r.skipped, "no_base_url");
  assertEquals(calls, ["place_match_queue"]);
});

Deno.test(
  "runMatch: matches, records, reads each file once, leaves unreadable venues",
  async () => {
    const f = await published([COURT, HALL]);
    const seen: string[] = [];
    const recorded: unknown[] = [];
    const ref = { tile: TILE, path: f.path, sha256: f.sha256 };
    const r = await runMatch({
      rpc: (name, args) => {
        if (name === "place_match_queue") {
          return Promise.resolve({
            base: "https://pages.example/ap",
            venues: [
              {
                venue_id: "v1",
                name: "POP Court Alpha",
                lng: -140.2302,
                lat: -61.2301,
                key: "k1",
                files: [ref],
              },
              {
                venue_id: "v2",
                name: "Quiet Room",
                lng: -140.3,
                lat: -61.3,
                key: "k2",
                files: [ref],
              },
              {
                venue_id: "v3",
                name: "Gone",
                lng: -140.3,
                lat: -61.3,
                key: "k3",
                files: [
                  {
                    tile: TILE,
                    path: `places/v1/${TILE}.0000000000000000.json.gz`,
                    sha256: "0".repeat(64),
                  },
                ],
              },
            ],
          });
        }
        recorded.push(args.p_results);
        return Promise.resolve({ checked: 2, rows: 1, linked: 1, refused: 0, skipped: 0 });
      },
      fetch: fetchOf({ [f.path]: f.gz }, seen),
    });
    assertEquals(r.venues, 3);
    assertEquals(r.matched, 1);
    assertEquals(r.file_errors, 1);
    assertEquals(seen.filter((u) => u.endsWith(f.path)).length, 1);
    assert(seen.every((u) => u.startsWith("https://pages.example/ap/places/")));
    const results = recorded[0] as {
      venue_id: string;
      key: string;
      match: { row: FileRow } | null;
    }[];
    assertEquals(
      results.map((x) => x.venue_id),
      ["v1", "v2"],
    );
    assertEquals(results[0].match?.row.osm_ref, "w1");
    assertEquals(results[1].match, null);
  },
);

Deno.test(
  "placeFromFile: verified row to place_from_file; no file, not in the file, moderated",
  async () => {
    const f = await published([COURT]);
    const args: Record<string, unknown>[] = [];
    const rpcWith =
      (
        id: unknown,
        file: unknown = { tile: TILE, path: f.path, sha256: f.sha256, base: "https://p.example/" },
      ) =>
      (name: string, a: Record<string, unknown>) => {
        args.push({ name, ...a });
        return Promise.resolve(name === "place_file_of_tile" ? file : id);
      };
    const fetch = fetchOf({ [f.path]: f.gz });
    assertEquals(await placeFromFile({ rpc: rpcWith("uuid-1"), fetch }, "w1", TILE), {
      id: "uuid-1",
    });
    const call = args.find((a) => a.name === "place_from_file") as Record<string, unknown>;
    assertEquals(call.p_sha256, f.sha256);
    assertEquals((call.p_row as FileRow).name, "POP Court Alpha");
    assertEquals(await placeFromFile({ rpc: rpcWith(null), fetch }, "w1", TILE), {
      id: null,
      reason: "moderated",
    });
    assertEquals(await placeFromFile({ rpc: rpcWith("x"), fetch }, "n77", TILE), {
      id: null,
      reason: "not_in_file",
    });
    assertEquals(await placeFromFile({ rpc: rpcWith("x", null), fetch }, "w1", TILE), {
      id: null,
      reason: "no_file",
    });
    assertEquals(
      await placeFromFile(
        { rpc: rpcWith("x", { tile: TILE, path: f.path, sha256: f.sha256, base: null }), fetch },
        "w1",
        TILE,
      ),
      { id: null, reason: "no_base_url" },
    );
  },
);

Deno.test("parsePlaceRequest", () => {
  assertEquals(parsePlaceRequest({ osm_ref: "w1", tile: 5 }), { osmRef: "w1", tile: 5 });
  assertEquals(parsePlaceRequest({ osm_ref: "x1", tile: 5 }), null);
  assertEquals(parsePlaceRequest({ osm_ref: "w1", tile: 1.5 }), null);
  assertEquals(parsePlaceRequest({ osm_ref: "w1", tile: 999999 }), null);
  assertEquals(parsePlaceRequest(null), null);
});
