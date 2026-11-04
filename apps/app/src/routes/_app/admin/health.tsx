import type { ReactNode } from "react";
import { Link, createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { CircleAlert, ShieldX, TriangleAlert } from "lucide-react";

import { AdminTabs } from "@/components/admin/admin-tabs";
import { ListSkeleton } from "@/components/hubs/hub-states";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { isModeratorQuery } from "@/lib/chapters";
import { cn } from "@/lib/cn";
import {
  TILE_STATUSES,
  formatBytes,
  percentOf,
  placeHealthQuery,
  sizeMessage,
  type HealthRun,
  type PlaceHealth,
} from "@/lib/place-health";

const appRoute = getRouteApi("/_app");

/**
 * The hub map health panel (HUB_MAP_DESIGN slice 15; mod_place_health, migration 35): tiles,
 * rows, sizes against the 120 MB alarm and 150 MB cap, the last runs and today's budget.
 * Moderators only; the RPC refuses everyone else whatever this page shows.
 */
export const Route = createFileRoute("/_app/admin/health")({
  component: HealthPage,
});

function HealthPage() {
  const { session } = appRoute.useRouteContext();
  const isMod = useQuery(isModeratorQuery(session.user.id));
  return (
    <>
      <TopBar title="Moderation" back />
      <main className="flex flex-col gap-4 pt-2 pb-8 safe-px">
        <AdminTabs current="/admin/health" />
        {isMod.isPending ? (
          <ListSkeleton rows={3} rowClassName="h-24" />
        ) : isMod.isError ? (
          <EmptyState
            icon={CircleAlert}
            title="Couldn't check your access"
            body="Check your connection and try again."
            action={
              <Button variant="secondary" onClick={() => void isMod.refetch()}>
                Try again
              </Button>
            }
          />
        ) : !isMod.data ? (
          <EmptyState
            icon={ShieldX}
            title="Moderators only"
            body="This page is for the people who look after the map."
            action={
              <Link to="/" className={buttonVariants({ variant: "secondary" })}>
                Go home
              </Link>
            }
          />
        ) : (
          <Panel />
        )}
      </main>
    </>
  );
}

function Panel() {
  const health = useQuery(placeHealthQuery());
  if (health.isPending) return <ListSkeleton rows={4} rowClassName="h-24" />;
  if (health.isError) {
    return (
      <EmptyState
        icon={CircleAlert}
        title="Couldn't load the health panel"
        body="Check your connection and try again."
        action={
          <Button variant="secondary" onClick={() => void health.refetch()}>
            Try again
          </Button>
        }
      />
    );
  }
  const h = health.data;
  return (
    <div className="flex flex-col gap-4">
      <SizeCard size={h.size} />
      <Card title="Tiles">
        <p className="text-[14px] text-text-2 tabular">{h.tilesTotal} in all</p>
        <dl className="grid grid-cols-5 gap-2 pt-1">
          {TILE_STATUSES.map((s) => (
            <div key={s} className="rounded-control bg-surface-2 px-2 py-2 text-center">
              <dt className="text-[12px] text-text-2 capitalize">{s}</dt>
              <dd className="text-[17px] font-semibold tabular">{h.tilesByStatus[s]}</dd>
            </div>
          ))}
        </dl>
        <TileList tiles={h.tiles} />
      </Card>
      <Card title="Place rows">
        <p className="text-[14px] text-text-2 tabular">{h.rowsTotal.toLocaleString()} in all</p>
        <ul className="flex flex-col gap-1 pt-1 text-[14px]">
          {h.rows.map((r) => (
            <li
              key={`${r.source}:${r.status}:${r.isPublic}`}
              className="flex justify-between gap-2"
            >
              <span>
                {r.source} · {r.status}
                {r.isPublic ? "" : " · private"}
              </span>
              <span className="tabular">{r.n.toLocaleString()}</span>
            </li>
          ))}
        </ul>
      </Card>
      <Card title="Last runs">
        <ul className="flex flex-col gap-1.5 text-[14px]">
          <RunLine
            label="OpenStreetMap extract"
            at={h.runs.extract?.at ?? null}
            detail={
              h.runs.extract
                ? `tile ${h.runs.extract.tileId}, ${h.runs.extract.received} rows`
                : null
            }
          />
          <RunLine
            label="Geoapify fill"
            at={h.runs.geoapify?.at ?? null}
            detail={
              h.runs.geoapify
                ? `tile ${h.runs.geoapify.tileId}, ${h.runs.geoapify.received} rows`
                : null
            }
          />
          <RunLine
            label="Tile lifecycle"
            at={h.runs.retire?.at ?? null}
            detail={retireDetail(h.runs.retire)}
          />
          <RunLine
            label="Size check"
            at={h.runs.size?.at ?? null}
            detail={stat(h.runs.size, "level")}
          />
          <RunLine
            label="ODbL dump"
            at={h.runs.dump?.at ?? null}
            detail={dumpDetail(h.runs.dump)}
          />
          {h.runs.cron.map((c) => (
            <RunLine
              key={c.job}
              label={`Scheduled: ${c.job}`}
              at={c.lastStart}
              detail={`${c.schedule}${c.active ? "" : " · paused"}${c.lastStatus ? ` · ${c.lastStatus}` : ""}`}
            />
          ))}
        </ul>
      </Card>
      <Card title="Budget today (UTC)">
        {h.budget.length === 0 ? (
          <p className="text-[14px] text-text-2">No credits used today.</p>
        ) : (
          <ul className="flex flex-col gap-2 text-[14px]">
            {h.budget.map((b) => (
              <li key={b.source} className="flex flex-col gap-1">
                <div className="flex justify-between gap-2">
                  <span>{b.source}</span>
                  <span className="tabular">
                    {b.used}
                    {b.cap !== null ? ` of ${b.cap}` : ""}
                  </span>
                </div>
                {b.cap !== null ? <Meter percent={percentOf(b.used, b.cap)} /> : null}
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}

function Card({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="flex flex-col gap-2 rounded-card border border-border bg-surface px-4 py-3">
      <h2 className="text-[15px] font-semibold">{title}</h2>
      {children}
    </section>
  );
}

function Meter({ percent, tone = "normal" }: { percent: number; tone?: "normal" | "warn" }) {
  return (
    <div
      className="h-2 w-full overflow-hidden rounded-full bg-surface-2"
      role="meter"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={percent}
    >
      <div
        className={cn("h-full rounded-full", tone === "warn" ? "bg-danger" : "bg-primary")}
        style={{ width: `${percent}%` }}
      />
    </div>
  );
}

function SizeCard({ size }: { size: PlaceHealth["size"] }) {
  const warn = size.level !== "ok";
  return (
    <Card title="Size">
      <p
        className={cn(
          "flex items-start gap-2 text-[14px]",
          warn ? "font-semibold text-danger" : "text-text-2",
        )}
        role={warn ? "alert" : undefined}
      >
        {warn ? <TriangleAlert className="mt-0.5 size-4 shrink-0" aria-hidden="true" /> : null}
        {sizeMessage(size)}
      </p>
      <div className="flex justify-between gap-2 text-[14px]">
        <span>Places table</span>
        <span className="tabular">
          {formatBytes(size.placesBytes)} of {formatBytes(size.capBytes)}
        </span>
      </div>
      <Meter percent={percentOf(size.placesBytes, size.capBytes)} tone={warn ? "warn" : "normal"} />
      <p className="text-[12px] text-text-2 tabular">Alarm at {formatBytes(size.alarmBytes)}</p>
      <div className="flex justify-between gap-2 pt-1 text-[14px]">
        <span>Whole database</span>
        <span className="tabular">
          {formatBytes(size.dbBytes)} of {formatBytes(size.dbCapBytes)}
        </span>
      </div>
      <Meter
        percent={percentOf(size.dbBytes, size.dbCapBytes)}
        tone={size.level === "cap" ? "warn" : "normal"}
      />
    </Card>
  );
}

function TileList({ tiles }: { tiles: PlaceHealth["tiles"] }) {
  if (tiles.length === 0) return null;
  return (
    <details className="pt-1">
      <summary className="cursor-pointer text-[14px] font-semibold">Recently changed tiles</summary>
      <ul className="flex flex-col gap-1.5 pt-2 text-[13px]">
        {tiles.map((t) => (
          <li key={t.id} className="flex flex-col rounded-control bg-surface-2 px-3 py-2">
            <span className="font-semibold tabular">
              Tile {t.id} · {t.south.toFixed(1)}, {t.west.toFixed(1)} · {t.status}
              {t.keep ? " · kept" : ""}
            </span>
            <span className="text-text-2 tabular">
              {t.rows.toLocaleString()} rows · demand {t.demand} · OSM {day(t.osmRunAt)} · member{" "}
              {day(t.lastMemberAt)}
              {t.idleSince ? ` · idle since ${day(t.idleSince)}` : ""}
            </span>
          </li>
        ))}
      </ul>
    </details>
  );
}

function RunLine({ label, at, detail }: { label: string; at: Date | null; detail: string | null }) {
  return (
    <li className="flex flex-col">
      <span className="flex justify-between gap-2">
        <span>{label}</span>
        <span className="text-text-2 tabular">{at ? when(at) : "never"}</span>
      </span>
      {detail ? <span className="text-[12px] text-text-2">{detail}</span> : null}
    </li>
  );
}

function day(d: Date | null): string {
  return d ? d.toISOString().slice(0, 10) : "never";
}

function when(d: Date): string {
  return `${d.toISOString().slice(0, 16).replace("T", " ")} UTC`;
}

function stat(r: HealthRun | null, key: string): string | null {
  const v = r?.stats[key];
  return typeof v === "string" || typeof v === "number" ? String(v) : null;
}

function retireDetail(r: HealthRun | null): string | null {
  if (!r) return null;
  const n = (k: string) => Number(r.stats[k] ?? 0);
  return `${n("idled")} idled · ${n("retired")} retired (${n("deleted_rows")} rows) · ${n("woken")} woken · ${n("wanted")} wanted again`;
}

function dumpDetail(r: HealthRun | null): string | null {
  if (!r) return null;
  const rows = Number(r.stats.rows ?? 0);
  return `${String(r.stats.month ?? "")} · ${rows.toLocaleString()} rows · ${r.stats.published === true ? "released" : "artifact only"}`;
}
