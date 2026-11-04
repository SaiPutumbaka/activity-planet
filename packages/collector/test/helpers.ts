import { readFileSync } from "node:fs";
import type { Transport } from "../src/net/fetcher.ts";
import type { Region } from "../src/types.ts";

export function fixture(name: string): string {
  return readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8");
}

export const ATL: Region = {
  id: "atl",
  label: "Atlanta",
  lat: 33.749,
  lng: -84.388,
  radiusKm: 60,
  timezone: "America/New_York",
};

/** The run's "now" in every test: Wednesday 2026-11-04, 7 am in Atlanta. */
export const NOW = new Date("2026-11-04T12:00:00Z");
export const WINDOW_END = new Date(NOW.getTime() + 60 * 86_400_000);

export interface FakeResponse {
  status?: number;
  headers?: Record<string, string>;
  body?: string;
}

export interface Recorded {
  url: string;
  at: number;
  headers: Record<string, string>;
}

/**
 * A transport serving fixed responses by exact URL (404 otherwise), recording each request and
 * the fake clock at that moment. No network.
 */
export function fakeTransport(
  routes: Record<string, FakeResponse | ((headers: Record<string, string>) => FakeResponse)>,
  clock: { now: number },
): { transport: Transport; log: Recorded[] } {
  const log: Recorded[] = [];
  const transport: Transport = async (url, init) => {
    const headers = { ...(init.headers as Record<string, string>) };
    log.push({ url, at: clock.now, headers });
    const route = routes[url];
    const r = typeof route === "function" ? route(headers) : route;
    if (!r) return new Response("not found", { status: 404 });
    return new Response(r.status === 304 ? null : (r.body ?? ""), {
      status: r.status ?? 200,
      headers: r.headers ?? {},
    });
  };
  return { transport, log };
}

/**
 * A clock that only moves when the fetcher sleeps. Sleeps that overlap in real code overlap
 * here too: each moves the clock to its own wake-up time, never past a later one.
 */
export function fakeClock(start = NOW.getTime()) {
  const clock = { now: start };
  return {
    clock,
    now: () => clock.now,
    sleep: async (ms: number) => {
      const wake = clock.now + ms;
      await Promise.resolve();
      clock.now = Math.max(clock.now, wake);
    },
  };
}
