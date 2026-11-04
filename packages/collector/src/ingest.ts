// Where a run's batches go. The real implementation (import_upsert_batch over the service
// role, one call per source with its complete item set) is wired once the collector's source
// rows and schema land; until then only the dry run exists, and it prints counts, never items.

import type { SourceBatch } from "./types.ts";

export interface IngestResult {
  sourceKey: string;
  sent: number;
}

export interface Ingest {
  readonly name: string;
  send(batch: SourceBatch): Promise<IngestResult>;
}

export class DryRunIngest implements Ingest {
  readonly name = "dry-run";
  readonly lines: string[] = [];
  private readonly out: (line: string) => void;

  constructor(out: (line: string) => void = (l) => console.log(l)) {
    this.out = out;
  }

  async send(batch: SourceBatch): Promise<IngestResult> {
    const withPoint = batch.items.filter((i) => i.lat !== null).length;
    const cancelled = batch.items.filter((i) => i.cancelled).length;
    const counts = (r: Record<string, number>) =>
      Object.entries(r)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([k, v]) => `${k}=${v}`)
        .join(",");
    const line = `[dry-run] source=${batch.sourceKey} region=${batch.regionId} items=${batch.items.length} with_point=${withPoint} cancelled=${cancelled} skipped={${counts(batch.skipped)}} errors={${counts(batch.errors ?? {})}}`;
    this.lines.push(line);
    this.out(line);
    return { sourceKey: batch.sourceKey, sent: 0 };
  }
}
