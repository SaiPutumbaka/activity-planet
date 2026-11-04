// Conditional GET cache: the validators (ETag, Last-Modified) and body of each URL's last 200,
// so the next run sends If-None-Match / If-Modified-Since and a 304 costs the source nothing.
// The file form is one JSON file the GitHub Actions job can keep between runs with actions/cache.

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

export interface CachedResponse {
  url: string;
  etag: string | null;
  lastModified: string | null;
  contentType: string | null;
  xRobotsTag: string | null;
  body: string;
  fetchedAt: number;
}

export interface HttpCache {
  get(url: string): CachedResponse | undefined;
  set(entry: CachedResponse): void;
  /** Persist, when the cache has somewhere to go. */
  save(): void;
}

export class MemoryHttpCache implements HttpCache {
  protected readonly entries = new Map<string, CachedResponse>();
  get(url: string): CachedResponse | undefined {
    return this.entries.get(url);
  }
  set(entry: CachedResponse): void {
    this.entries.set(entry.url, entry);
  }
  save(): void {}
}

/** Entries older than this are dropped on load, so the file does not grow forever. */
const MAX_AGE_MS = 30 * 24 * 3600 * 1000;

export class FileHttpCache extends MemoryHttpCache {
  private readonly path: string;

  constructor(path: string, now: number = Date.now()) {
    super();
    this.path = path;
    try {
      const data = JSON.parse(readFileSync(path, "utf8")) as CachedResponse[];
      for (const e of data) if (now - e.fetchedAt < MAX_AGE_MS) this.entries.set(e.url, e);
    } catch {
      // No cache yet, or unreadable: start empty.
    }
  }

  override save(): void {
    mkdirSync(dirname(this.path), { recursive: true });
    writeFileSync(this.path, JSON.stringify([...this.entries.values()]));
  }
}
