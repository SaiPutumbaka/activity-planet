import { useState } from "react";
import { Link, createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleAlert, ExternalLink, Inbox, ShieldX } from "lucide-react";
import { toast } from "sonner";

import { AdminTabs } from "@/components/admin/admin-tabs";
import { ListSkeleton } from "@/components/hubs/hub-states";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { FieldTextArea } from "@/components/ui/textarea";
import { isModeratorQuery } from "@/lib/chapters";
import { formatRelativeDay } from "@/lib/datetime";
import { formatDistance, mapKeys } from "@/lib/map";
import {
  MOD_ACTIONS,
  describeChange,
  modPlaceKeys,
  modPlaceQueueQuery,
  modResolvePlace,
  placeErrorMessage,
  reportReasonLabel,
  type ModAction,
  type ModItem,
} from "@/lib/place-contributions";

const appRoute = getRouteApi("/_app");

/**
 * The moderator queue for places (HUB_MAP_DESIGN slice 12; mod_place_queue and
 * mod_resolve_place, migration 34): pending public member places, corrections and reported
 * places, oldest first. Nothing here says who added, suggested or reported anything. The RPCs
 * refuse non-moderators and a moderator's own items regardless of what this page shows.
 */
export const Route = createFileRoute("/_app/admin/places")({
  component: PlacesQueuePage,
});

function PlacesQueuePage() {
  const { session } = appRoute.useRouteContext();
  const isMod = useQuery(isModeratorQuery(session.user.id));

  return (
    <>
      <TopBar title="Moderation" back />
      <main className="flex flex-col gap-4 pt-2 pb-8 safe-px">
        <AdminTabs current="/admin/places" />
        {isMod.isPending ? (
          <ListSkeleton rows={3} rowClassName="h-32" />
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
            body="This page is for the people who review places."
            action={
              <Link to="/" className={buttonVariants({ variant: "secondary" })}>
                Go home
              </Link>
            }
          />
        ) : (
          <Queue />
        )}
      </main>
    </>
  );
}

function Queue() {
  const queue = useQuery(modPlaceQueueQuery());
  if (queue.isPending) return <ListSkeleton rows={3} rowClassName="h-32" />;
  if (queue.isError) {
    return (
      <EmptyState
        icon={CircleAlert}
        title="Couldn't load the queue"
        body={placeErrorMessage(queue.error)}
        action={
          <Button variant="secondary" onClick={() => void queue.refetch()}>
            Try again
          </Button>
        }
      />
    );
  }
  const { items, counts } = queue.data;
  if (items.length === 0) {
    return (
      <EmptyState
        icon={Inbox}
        title="Nothing to review"
        body="New places, corrections and reports show up here."
      />
    );
  }
  return (
    <>
      <p className="text-[14px] text-text-2" aria-live="polite">
        {counts.places} new {counts.places === 1 ? "place" : "places"} · {counts.edits}{" "}
        {counts.edits === 1 ? "correction" : "corrections"} · {counts.reports} reported
      </p>
      <ul className="flex flex-col gap-3">
        {items.map((it) => (
          <li key={`${it.kind}:${it.id}`}>
            <ItemCard item={it} />
          </li>
        ))}
      </ul>
    </>
  );
}

const KIND_LABEL: Record<ModItem["kind"], string> = {
  place: "New public place",
  edit: "Correction",
  reports: "Reported",
};

const SOURCE_LABEL: Record<string, string> = {
  osm: "OpenStreetMap",
  geoapify: "Geoapify",
  user: "Member-added",
  venue: "Meeting spot",
};

function osmViewUrl(lat: number, lng: number): string {
  return `https://www.openstreetmap.org/?mlat=${lat}&mlon=${lng}#map=18/${lat}/${lng}`;
}

function ItemCard({ item }: { item: ModItem }) {
  const queryClient = useQueryClient();
  const [note, setNote] = useState("");
  const p = item.place;
  const resolve = useMutation({
    mutationFn: (action: ModAction) => modResolvePlace(item.kind, item.id, action, note),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: modPlaceKeys.queue });
      void queryClient.invalidateQueries({ queryKey: mapKeys.all });
      toast.success("Done.");
    },
    onError: (err) => toast.error(placeErrorMessage(err)),
  });

  const facts: [string, string | null][] = [
    ["Kind", p.kindLabel],
    ["Source", SOURCE_LABEL[p.source] ?? p.source],
    ["Status", `${p.status}${p.isPublic ? "" : " · private"}`],
    ["Address", p.address],
    ["Area", p.locality],
    ["Hours", p.hours],
    ["Website", p.website],
    ["Hubs", p.hubs.map((h) => `${h.emoji} ${h.name}`.trim()).join(", ") || null],
    [
      "Account age",
      p.creatorAccountDays === null
        ? null
        : `${p.creatorAccountDays} day${p.creatorAccountDays === 1 ? "" : "s"}`,
    ],
    ["Locked", p.lockedFields.length ? p.lockedFields.join(", ") : null],
  ];

  return (
    <article className="flex flex-col gap-3 rounded-card border border-border p-4">
      <header>
        <p className="text-[13px] text-text-2">
          {KIND_LABEL[item.kind]}
          {item.createdAt ? ` · ${formatRelativeDay(item.createdAt)}` : ""}
        </p>
        <h2 className="text-[17px] font-bold break-words">{p.name}</h2>
      </header>

      {item.kind === "edit" && item.changes ? (
        <ul className="flex flex-col gap-1 rounded-tile bg-surface-2 p-3 text-[14px]">
          {Object.entries(item.changes).map(([field, after]) => (
            <li key={field} className="break-words">
              {describeChange(field, item.current?.[field], after)}
            </li>
          ))}
          {item.moveM !== null && item.moveM !== undefined ? (
            <li className="text-text-2">Moves the pin {formatDistance(item.moveM)}</li>
          ) : null}
          {item.note ? (
            <li className="pt-1 whitespace-pre-wrap text-text-2">“{item.note}”</li>
          ) : null}
        </ul>
      ) : null}

      {item.kind === "reports" && item.reports ? (
        <div className="flex flex-col gap-1 rounded-tile bg-surface-2 p-3 text-[14px]">
          <p className="font-semibold">
            {item.open} open {item.open === 1 ? "report" : "reports"} from {item.reporters}{" "}
            {item.reporters === 1 ? "person" : "people"}
          </p>
          <ul className="flex flex-col gap-1">
            {item.reports.map((r) => (
              <li key={r.id} className="break-words">
                {reportReasonLabel(r.reason)}
                {r.note ? <span className="text-text-2"> · “{r.note}”</span> : null}
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[14px]">
        {facts
          .filter(([, v]) => v)
          .map(([k, v]) => (
            <div key={k} className="contents">
              <dt className="text-text-2">{k}</dt>
              <dd className="min-w-0 break-words">{v}</dd>
            </div>
          ))}
      </dl>

      {p.nearby.length ? (
        <div className="text-[14px]">
          <p className="text-text-2">Nearby on the map</p>
          <ul>
            {p.nearby.map((n) => (
              <li key={n.id}>
                {n.name} · {formatDistance(n.distanceM)}
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      <div className="flex flex-wrap gap-x-4 gap-y-1 text-[14px]">
        <a
          href={osmViewUrl(p.lat, p.lng)}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex items-center gap-1 font-semibold text-link underline-offset-2 hover:underline"
        >
          See the spot on OpenStreetMap
          <ExternalLink className="size-3.5" aria-hidden="true" />
        </a>
        {p.osmUrl ? (
          <a
            href={p.osmUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-1 font-semibold text-link underline-offset-2 hover:underline"
          >
            OSM element
            <ExternalLink className="size-3.5" aria-hidden="true" />
          </a>
        ) : null}
      </div>

      {item.own ? (
        <p className="text-[14px] text-text-2">This one is yours. Another moderator decides it.</p>
      ) : (
        <>
          <FieldTextArea
            label="Note for the log (optional)"
            rows={2}
            maxLength={500}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            disabled={resolve.isPending}
          />
          <div className="flex flex-wrap justify-end gap-2">
            {MOD_ACTIONS[item.kind].map((a, i, all) => (
              <Button
                key={a.action}
                size="sm"
                variant={
                  i === all.length - 1 ? "primary" : a.action === "remove" ? "danger" : "secondary"
                }
                loading={resolve.isPending && resolve.variables === a.action}
                disabled={resolve.isPending}
                onClick={() => resolve.mutate(a.action)}
              >
                {a.label}
              </Button>
            ))}
          </div>
        </>
      )}
    </article>
  );
}
