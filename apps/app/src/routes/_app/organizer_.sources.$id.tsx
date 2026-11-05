import { useState } from "react";
import { Link, createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleAlert } from "lucide-react";
import { toast } from "sonner";
import { checkFeedUrl, organizerErrorMessage } from "@ap/core/organizer";

import { ListSkeleton } from "@/components/hubs/hub-states";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { Field } from "@/components/ui/field";
import { FieldSelect } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { formatWhen } from "@/lib/admin";
import { hubCatalogQuery } from "@/lib/profile";
import {
  organizerKeys,
  sourceDetailQuery,
  updateSource,
  type SourceDetail,
  type SourceItem,
} from "@/lib/organizer";

/**
 * /organizer/sources/$id (COLLECTOR_COMPLETION Slice 2; organizer_source_detail and
 * organizer_source_update, migrations 62 and 65): what a verified owner (or a moderator) controls
 * on a source: its default hub, hiding single upcoming items, stopping the listing, and for a
 * connected calendar its feed link, "Refresh now" and the image licence. Imported items still
 * rank below plans and never take RSVPs, whoever owns them.
 */
export const Route = createFileRoute("/_app/organizer_/sources/$id")({
  component: SourcePage,
});

function SourcePage() {
  const { id } = Route.useParams();
  const source = useQuery(sourceDetailQuery(id));
  return (
    <>
      <TopBar title="Your listing" back />
      <main className="flex flex-col gap-5 pt-2 pb-8 safe-px">
        {source.isPending ? (
          <ListSkeleton rows={3} rowClassName="h-24" />
        ) : source.isError ? (
          <EmptyState
            icon={CircleAlert}
            title="Couldn't open this source"
            body={organizerErrorMessage(source.error)}
            action={
              <Link to="/organizer" className={buttonVariants({ variant: "secondary" })}>
                Organizer page
              </Link>
            }
          />
        ) : (
          <Settings source={source.data} />
        )}
      </main>
    </>
  );
}

function stateLine(s: SourceDetail): string {
  if (s.stopped) return "Stopped: nothing from it is listed.";
  if (!s.enabled && s.origin === "organizer")
    return s.verified
      ? "Waiting for its first read. It starts listing after one good read."
      : "Waiting for the code: it starts listing once we find it in the calendar.";
  if (!s.enabled) return "Not listed right now.";
  return s.last_ok_at ? `Listing. Last read ${formatWhen(s.last_ok_at)}.` : "Listing.";
}

function Settings({ source }: { source: SourceDetail }) {
  const queryClient = useQueryClient();
  const hubs = useQuery(hubCatalogQuery);
  const [feedUrl, setFeedUrl] = useState(source.url ?? "");
  const [feedError, setFeedError] = useState<string | null>(null);
  const update = useMutation({
    mutationFn: (args: Record<string, unknown>) => updateSource(source.id, args),
    onSuccess: (_, args) => {
      void queryClient.invalidateQueries({ queryKey: organizerKeys.all });
      toast.success("refresh" in args ? "We'll read it again within the hour." : "Saved.");
    },
    onError: (err) => toast.error(organizerErrorMessage(err)),
  });
  const can = source.can_manage;
  const connected = source.origin === "organizer";
  const adultHubs = (hubs.data?.hubs ?? []).filter((h) => h.min_age === 18);

  return (
    <>
      <header className="flex flex-col gap-1">
        <h2 className="text-[22px] font-bold tracking-tight break-words">{source.name}</h2>
        <p className="text-[14px] text-text-2">{stateLine(source)}</p>
        {source.has_error ? (
          <p className="text-[14px] text-warning">
            The last read had a problem. We try again on the next run.
          </p>
        ) : null}
        {!can ? (
          <p className="text-[14px] text-text-2">
            You can change these once your claim is verified.
          </p>
        ) : null}
      </header>

      <section className="flex flex-col gap-3 rounded-card border border-border p-4">
        <FieldSelect
          label="Default hub"
          hint="Where your events show up when they don't match a hub on their own."
          value={source.default_hub ?? ""}
          disabled={!can || update.isPending}
          onChange={(e) =>
            update.mutate({ default_hub: e.target.value === "" ? null : e.target.value })
          }
        >
          <option value="">Let Activity Planet choose</option>
          {adultHubs.map((h) => (
            <option key={h.slug} value={h.slug}>
              {h.emoji} {h.name}
            </option>
          ))}
        </FieldSelect>
        <Switch
          label="Stop listing"
          hint="Takes every upcoming event from this source off Activity Planet. Turn it off to list them again."
          checked={source.stopped}
          disabled={!can || update.isPending}
          onCheckedChange={(v) => update.mutate({ stop: v })}
        />
      </section>

      {connected ? (
        <section className="flex flex-col gap-3 rounded-card border border-border p-4">
          <h3 className="text-[15px] font-semibold">Connected calendar</h3>
          <form
            className="flex flex-col gap-2"
            noValidate
            onSubmit={(e) => {
              e.preventDefault();
              const checked = checkFeedUrl(feedUrl);
              if (!checked.ok) {
                setFeedError(checked.error);
                return;
              }
              setFeedError(null);
              update.mutate({ feed_url: checked.url });
            }}
          >
            <Field
              label="Feed link"
              type="url"
              inputMode="url"
              autoCapitalize="none"
              spellCheck={false}
              maxLength={500}
              value={feedUrl}
              onChange={(e) => setFeedUrl(e.target.value)}
              error={feedError ?? undefined}
              disabled={!can || update.isPending}
            />
            <div className="flex flex-wrap justify-end gap-2">
              <Button
                type="button"
                size="sm"
                variant="secondary"
                disabled={!can || update.isPending || source.refresh_requested_at !== null}
                onClick={() => update.mutate({ refresh: true })}
              >
                {source.refresh_requested_at ? "Refresh asked" : "Refresh now"}
              </Button>
              <Button
                type="submit"
                size="sm"
                disabled={!can || update.isPending || feedUrl.trim() === (source.url ?? "")}
              >
                Save link
              </Button>
            </div>
          </form>
          <Switch
            label="Show my event images"
            hint="I own the images in this calendar, or may share them, and license Activity Planet to show them with my events."
            checked={source.images_licensed}
            disabled={!can || update.isPending}
            onCheckedChange={(v) => update.mutate({ images_licensed: v })}
          />
        </section>
      ) : null}

      <section className="flex flex-col gap-2">
        <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
          Upcoming events
        </h3>
        {source.items.length === 0 ? (
          <p className="text-[14px] text-text-2">Nothing upcoming from this source right now.</p>
        ) : (
          <ul className="divide-y divide-border overflow-hidden rounded-card border border-border">
            {source.items.map((item) => (
              <ItemRow
                key={item.event_id}
                item={item}
                disabled={!can || update.isPending}
                onToggle={() =>
                  update.mutate(item.hidden ? { unhide: item.event_id } : { hide: item.event_id })
                }
              />
            ))}
          </ul>
        )}
      </section>
    </>
  );
}

function ItemRow({
  item,
  disabled,
  onToggle,
}: {
  item: SourceItem;
  disabled: boolean;
  onToggle: () => void;
}) {
  return (
    <li className="flex items-center justify-between gap-3 px-4 py-3">
      <div className="min-w-0">
        {item.hidden ? (
          <p className="text-[15px] font-semibold break-words text-text-2">{item.title}</p>
        ) : (
          <Link
            to="/events/$id"
            params={{ id: item.event_id }}
            className="text-[15px] font-semibold break-words underline-offset-2 hover:underline"
          >
            {item.title}
          </Link>
        )}
        <p className="text-[13px] text-text-2">
          {formatWhen(item.starts_at)}
          {item.hidden ? " · hidden" : ""}
        </p>
      </div>
      <Button
        size="sm"
        variant={item.hidden ? "secondary" : "outline"}
        disabled={disabled}
        onClick={onToggle}
      >
        {item.hidden ? "Show" : "Hide"}
      </Button>
    </li>
  );
}
