import type { ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { CircleAlert, TriangleAlert } from "lucide-react";

import { ListSkeleton } from "@/components/hubs/hub-states";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import { adminErrorMessage, formatWhen } from "@/lib/admin";
import { cn } from "@/lib/cn";
import {
  centroidShare,
  collectorHealthQuery,
  jobLabel,
  type CollectorHealth,
} from "@/lib/collector-admin";

/**
 * The Events section of /admin/health (collector Slice 2; mod_collector_health, migration 63):
 * sources by lane and state, stale and failing sources, each job's last run with the overdue
 * flag (26 hours; organizer checks 2), regions behind, the discovery gate's age, a week of
 * discovery outcomes, geocoding coverage, today's API budgets and open removals and claims.
 * Counts and source names only, never an error text or a member.
 */
export function CollectorHealthSection() {
  const health = useQuery(collectorHealthQuery());
  if (health.isPending) return <ListSkeleton rows={3} rowClassName="h-24" />;
  if (health.isError) {
    return (
      <EmptyState
        icon={CircleAlert}
        title="Couldn't load the collector's health"
        body={adminErrorMessage(health.error)}
        action={
          <Button variant="secondary" onClick={() => void health.refetch()}>
            Try again
          </Button>
        }
      />
    );
  }
  return <Body h={health.data} />;
}

function Card({ title, children, alert }: { title: string; children: ReactNode; alert?: boolean }) {
  return (
    <section
      className={cn(
        "flex flex-col gap-2 rounded-card border bg-surface px-4 py-3",
        alert ? "border-danger" : "border-border",
      )}
    >
      <h3 className="flex items-center gap-2 text-[15px] font-semibold">
        {alert ? <TriangleAlert className="size-4 text-danger" aria-hidden="true" /> : null}
        {title}
      </h3>
      {children}
    </section>
  );
}

function Row({ label, value, warn }: { label: string; value: ReactNode; warn?: boolean }) {
  return (
    <li className="flex justify-between gap-3">
      <span className="min-w-0 break-words">{label}</span>
      <span
        className={cn(
          "shrink-0 text-right tabular",
          warn ? "font-semibold text-danger" : "text-text-2",
        )}
      >
        {value}
      </span>
    </li>
  );
}

function Body({ h }: { h: CollectorHealth }) {
  const jobsOverdue = h.jobs.some((j) => j.overdue);
  const share = centroidShare(h.geocoding);
  return (
    <div className="flex flex-col gap-4">
      <Card title="Jobs" alert={jobsOverdue}>
        <ul className="flex flex-col gap-1.5 text-[14px]">
          {h.jobs.map((j) => (
            <Row
              key={j.job}
              label={jobLabel(j.job)}
              warn={j.overdue || j.outcome === "failed"}
              value={
                j.lastRun
                  ? `${formatWhen(j.lastRun)}${j.outcome && j.outcome !== "ok" ? ` · ${j.outcome}` : ""}${j.overdue ? " · overdue" : ""}`
                  : "never"
              }
            />
          ))}
        </ul>
        {jobsOverdue ? (
          <p className="text-[12px] text-text-2">
            GitHub pauses scheduled workflows after 60 days without a push; re-enable them in the
            repository&apos;s Actions tab.
          </p>
        ) : null}
      </Card>

      <Card title="Sources">
        <ul className="flex flex-col gap-1 text-[14px]">
          {h.sources.length === 0 ? (
            <li className="text-text-2">No collector sources yet.</li>
          ) : null}
          {h.sources.map((s) => (
            <Row key={`${s.lane}:${s.state}`} label={`${s.lane} · ${s.state}`} value={s.count} />
          ))}
        </ul>
      </Card>

      <Card title={`Stale (${h.stale.length})`} alert={h.stale.length > 0}>
        {h.stale.length === 0 ? (
          <p className="text-[14px] text-text-2">
            Every enabled source was read in the last 26 hours.
          </p>
        ) : (
          <ul className="flex flex-col gap-1 text-[14px]">
            {h.stale.map((s) => (
              <Row key={s.slug} label={s.name || s.slug} value={`${s.hours} h`} warn />
            ))}
          </ul>
        )}
      </Card>

      <Card title={`Failing (${h.failing.length})`} alert={h.failing.length > 0}>
        {h.failing.length === 0 ? (
          <p className="text-[14px] text-text-2">No source is failing.</p>
        ) : (
          <ul className="flex flex-col gap-1 text-[14px]">
            {h.failing.map((s) => (
              <Row
                key={s.slug}
                label={s.name || s.slug}
                value={`${s.streak} in a row · ${s.error === "item_error" ? "item error" : "read failed"}`}
                warn
              />
            ))}
          </ul>
        )}
      </Card>

      <Card title="Regions and discovery" alert={h.gate?.expired === true}>
        <ul className="flex flex-col gap-1 text-[14px]">
          <Row
            label="Regions behind (48 h)"
            value={`${h.regions.behind} of ${h.regions.total}`}
            warn={h.regions.behind > 0}
          />
          <Row
            label="Discovery gate"
            value={
              h.gate
                ? `${h.gate.passed ? "passed" : "failed"} ${h.gate.ageDays} d ago${h.gate.expired ? " · expired" : ""}`
                : "never run"
            }
            warn={!h.gate || h.gate.expired || !h.gate.passed}
          />
          {h.discovery7d.map((d) => (
            <Row key={d.outcome} label={`Probes, 7 days: ${d.outcome}`} value={d.count} />
          ))}
        </ul>
      </Card>

      <Card title="Geocoding">
        <ul className="flex flex-col gap-1 text-[14px]">
          <Row label="Upcoming imported events" value={h.geocoding.upcoming} />
          <Row label="Still on an area center" value={`${h.geocoding.onCentroid} (${share}%)`} />
          <Row label="Geocoded" value={h.geocoding.geocoded} />
          <Row
            label="Cache hits / misses"
            value={`${h.geocoding.cacheOk} / ${h.geocoding.cacheMiss}`}
          />
          <Row label="Looked up, 7 days" value={h.geocoding.checked7d} />
          <Row label="Nominatim" value={h.geocoding.nominatim} />
        </ul>
      </Card>

      <Card title="Budgets today (UTC)">
        {h.budgets.length === 0 ? (
          <p className="text-[14px] text-text-2">No API calls today.</p>
        ) : (
          <ul className="flex flex-col gap-1 text-[14px]">
            {h.budgets.map((b) => (
              <Row
                key={b.source}
                label={b.source}
                value={b.cap !== null ? `${b.used} of ${b.cap}` : b.used}
                warn={b.cap !== null && b.used >= b.cap}
              />
            ))}
          </ul>
        )}
      </Card>

      <Card title="Requests">
        <ul className="flex flex-col gap-1 text-[14px]">
          <Row label="Open listing removals" value={h.removalsOpen} />
          <Row label="Organizer claims waiting for proof" value={h.claims.pending} />
          <Row label="Verified claims not reviewed" value={h.claims.verifiedUnreviewed} />
        </ul>
      </Card>
    </div>
  );
}
