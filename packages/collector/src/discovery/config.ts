// Discovery settings (data/discovery.json): per-region daily caps, the EU gate's country list
// and the Atlanta quality gate (D-042 slice 8, design 6.4 and 7).

import { readFileSync } from "node:fs";

export interface DiscoveryCaps {
  /** Collector regions whose candidates are built per night (design 7: new event regions). */
  newRegionsPerDay: number;
  /** Candidate hosts probed per region per UTC day (design 7). */
  probeHostsPerRegionPerDay: number;
  /** Requests one probe may send to one host, robots.txt included (design 6.2). */
  requestsPerHostPerProbe: number;
  /** Event pages read per probe after the homepage (design 6.2 step 3). */
  eventPagesPerProbe: number;
  /** Candidates kept per region when building (best cheap score first). */
  candidatesPerRegion: number;
  /** Wikidata entity lookups (50 ids each) per region (design 7). */
  wikidataEntityCallsPerRegion: number;
  /** Wikidata "around" queries per region (design 7). */
  wikidataSparqlPerRegion: number;
  /** Radius of the Wikidata around query (design 6.1: 25 km). */
  wikidataAroundKm: number;
  /** Candidates probed at once (different hosts; per-host spacing still holds). */
  probeConcurrency: number;
  /** No request starts after this many minutes of a probe run. */
  probeRunMinutes: number;
}

export interface GateExpectation {
  /** The hand-written seed id in the city file. */
  seed: string;
  /** Its site (siteOf of the seed's host): a probe result on this site counts as found. */
  site: string;
}

export interface DiscoveryConfig {
  caps: DiscoveryCaps;
  euGate: { enabled: boolean; countries: string[] };
  gate: { city: string; required: number; expected: GateExpectation[] };
}

export const DISCOVERY_CONFIG_PATH = new URL("../../data/discovery.json", import.meta.url);

export function parseDiscoveryConfig(text: string): DiscoveryConfig {
  const d = JSON.parse(text) as Record<string, unknown>;
  const fail = (m: string): never => {
    throw new Error(`discovery.json: ${m}`);
  };
  const caps = (d.caps ?? {}) as Record<string, unknown>;
  const names: (keyof DiscoveryCaps)[] = [
    "newRegionsPerDay",
    "probeHostsPerRegionPerDay",
    "requestsPerHostPerProbe",
    "eventPagesPerProbe",
    "candidatesPerRegion",
    "wikidataEntityCallsPerRegion",
    "wikidataSparqlPerRegion",
    "wikidataAroundKm",
    "probeConcurrency",
    "probeRunMinutes",
  ];
  for (const n of names) {
    const v = caps[n];
    if (typeof v !== "number" || !Number.isInteger(v) || v < 0 || v > 10_000)
      fail(`caps.${n} must be a whole number`);
  }
  if ((caps.requestsPerHostPerProbe as number) > 8 || (caps.requestsPerHostPerProbe as number) < 2)
    fail("caps.requestsPerHostPerProbe must be 2..8 (design 6.2)");
  if ((caps.eventPagesPerProbe as number) > 3) fail("caps.eventPagesPerProbe must be at most 3");
  const eu = (d.euGate ?? {}) as Record<string, unknown>;
  if (typeof eu.enabled !== "boolean") fail("euGate.enabled must be true or false");
  if (
    !Array.isArray(eu.countries) ||
    eu.countries.some((c) => typeof c !== "string" || !/^[A-Z]{2}$/.test(c))
  )
    fail("euGate.countries must be ISO 3166-1 alpha-2 codes");
  const gate = (d.gate ?? {}) as Record<string, unknown>;
  if (typeof gate.city !== "string" || !/^[a-z0-9-]{2,40}$/.test(gate.city))
    fail("gate.city must be a city file id");
  if (!Array.isArray(gate.expected) || gate.expected.length === 0)
    fail("gate.expected must list seeds");
  for (const e of gate.expected as unknown[]) {
    const o = (e ?? {}) as Record<string, unknown>;
    if (typeof o.seed !== "string" || typeof o.site !== "string")
      fail("gate.expected entries need seed and site");
  }
  const req = gate.required;
  if (
    typeof req !== "number" ||
    !Number.isInteger(req) ||
    req < 1 ||
    req > (gate.expected as unknown[]).length
  )
    fail("gate.required must be 1..expected");
  return d as unknown as DiscoveryConfig;
}

export function loadDiscoveryConfig(path: URL | string = DISCOVERY_CONFIG_PATH): DiscoveryConfig {
  return parseDiscoveryConfig(readFileSync(path, "utf8"));
}
