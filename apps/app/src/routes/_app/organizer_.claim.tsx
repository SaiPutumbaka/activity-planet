import { useState, type FormEvent } from "react";
import { Link, createFileRoute, useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { BadgeCheck, CircleAlert } from "lucide-react";
import { z } from "zod";
import {
  CLAIM_METHODS,
  checkFeedUrl,
  claimMethodInfo,
  organizerErrorCode,
  organizerErrorMessage,
  sortHosts,
  type ClaimMethod,
} from "@ap/core/organizer";

import { ClaimCard } from "@/components/organizer/claim-card";
import { ListSkeleton } from "@/components/hubs/hub-states";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { Field, FormError } from "@/components/ui/field";
import { cn } from "@/lib/cn";
import {
  claimTargetQuery,
  coarsePosition,
  connectFeed,
  myClaimsQuery,
  organizerKeys,
  startClaim,
  type ClaimTarget,
} from "@/lib/organizer";

const searchSchema = z.object({
  event: z.string().uuid().optional(),
  feed: z.boolean().optional(),
  connect: z.string().uuid().optional(),
});

/**
 * /organizer/claim (COLLECTOR_COMPLETION Slice 2). Three ways in:
 *   ?event=<id>   "Are you the organizer?" on an imported listing: choose the site address and
 *                 the proof (a tag, a .well-known file, a DNS record, or for a calendar feed a
 *                 code in its description), then see the token with copy buttons and Check now.
 *   ?feed=true    connect a calendar you run: a feed claim on its link, connected at once (it
 *                 starts listing when the verify job finds the code in it).
 *   ?connect=<id> add a calendar to a verified claim (same site or domain).
 * The database checks every rule again: account age, 5 claims a day, the host, the denylist.
 */
export const Route = createFileRoute("/_app/organizer_/claim")({
  validateSearch: searchSchema,
  component: ClaimPage,
});

function ClaimPage() {
  const search = Route.useSearch();
  const [claimId, setClaimId] = useState<string | null>(null);
  return (
    <>
      <TopBar title={search.connect ? "Connect a calendar" : "Claim your listings"} back />
      <main className="flex flex-col gap-5 pt-2 pb-8 safe-px">
        {claimId ? (
          <Started claimId={claimId} />
        ) : search.connect ? (
          <ConnectToClaim claimId={search.connect} />
        ) : search.event && !search.feed ? (
          <FromEvent eventId={search.event} onStarted={setClaimId} />
        ) : (
          <FeedClaim onStarted={setClaimId} />
        )}
      </main>
    </>
  );
}

/** After a claim starts: its card from my_organizer_claims, with the proof and Check now. */
function Started({ claimId }: { claimId: string }) {
  const claims = useQuery(myClaimsQuery());
  const claim = claims.data?.find((c) => c.claim_id === claimId);
  if (claims.isPending) return <ListSkeleton rows={1} rowClassName="h-56" />;
  if (!claim) {
    return (
      <EmptyState
        icon={CircleAlert}
        title="Couldn't load the claim"
        body="Open your organizer page to see it."
        action={
          <Link to="/organizer" className={buttonVariants({ variant: "secondary" })}>
            Organizer page
          </Link>
        }
      />
    );
  }
  return (
    <>
      <p className="text-[15px] text-text-2">
        Put the proof in place, then tap Check now. You can leave and come back: the claim waits on
        your organizer page for 7 days.
      </p>
      <ClaimCard claim={claim} />
      <Link
        to="/organizer"
        className={buttonVariants({ variant: "ghost", className: "self-start" })}
      >
        All your claims
      </Link>
    </>
  );
}

function FromEvent({ eventId, onStarted }: { eventId: string; onStarted: (id: string) => void }) {
  const target = useQuery(claimTargetQuery(eventId));
  if (target.isPending) return <ListSkeleton rows={2} rowClassName="h-24" />;
  if (target.isError) {
    return (
      <EmptyState
        icon={CircleAlert}
        title="Can't claim this one"
        body={organizerErrorMessage(target.error)}
        action={
          <Link to="/organizer" className={buttonVariants({ variant: "secondary" })}>
            Organizer page
          </Link>
        }
      />
    );
  }
  const t = target.data;
  if (t.mine && t.source_id) {
    return (
      <EmptyState
        icon={BadgeCheck}
        title="You already run this source"
        body={`${t.source_name} is verified as yours.`}
        action={
          <Link
            to="/organizer/sources/$id"
            params={{ id: t.source_id }}
            className={buttonVariants({ variant: "secondary" })}
          >
            Manage it
          </Link>
        }
      />
    );
  }
  if (t.claimed) {
    return (
      <EmptyState
        icon={CircleAlert}
        title="Already claimed"
        body="Someone else proved they run this source. If that's wrong, use Request removal on the listing or email us, and a moderator takes a look."
      />
    );
  }
  return <ClaimForm eventId={eventId} target={t} onStarted={onStarted} />;
}

function ClaimForm({
  eventId,
  target,
  onStarted,
}: {
  eventId: string;
  target: ClaimTarget;
  onStarted: (id: string) => void;
}) {
  const queryClient = useQueryClient();
  const hosts = sortHosts(target.hosts);
  const methods = CLAIM_METHODS.filter((m) =>
    m === "feed" ? target.feed_proof : hosts.length > 0,
  );
  const [host, setHost] = useState(hosts[0] ?? "");
  const [method, setMethod] = useState<ClaimMethod>(methods[0] ?? "meta");
  const start = useMutation({
    mutationFn: () =>
      startClaim(method === "feed" ? { eventId, host: null, method } : { eventId, host, method }),
    onSuccess: (c) => {
      void queryClient.invalidateQueries({ queryKey: organizerKeys.claims });
      onStarted(c.claim_id);
    },
  });

  if (methods.length === 0) {
    return (
      <EmptyState
        icon={CircleAlert}
        title="Can't claim this one here"
        body="This listing comes from a shared calendar site. Connect your own calendar instead, from your organizer page."
        action={
          <Link to="/organizer" className={buttonVariants({ variant: "secondary" })}>
            Organizer page
          </Link>
        }
      />
    );
  }

  return (
    <form
      className="flex flex-col gap-5"
      onSubmit={(e) => {
        e.preventDefault();
        start.mutate();
      }}
    >
      <p className="text-[15px] text-text-2">
        <strong className="text-text">{target.source_name}</strong>: prove you run it and your
        listings say they&apos;re from the organizer. Nothing changes for people who already saw
        them, and they still link to your page.
      </p>

      {method !== "feed" && hosts.length > 1 ? (
        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1 text-[14px] font-semibold">Your site&apos;s address</legend>
          {hosts.map((h) => (
            <label key={h} className="flex min-h-11 items-center gap-3 text-[15px]">
              <input
                type="radio"
                name="host"
                value={h}
                checked={host === h}
                onChange={() => setHost(h)}
                className="size-4 shrink-0"
              />
              <span className="min-w-0 break-all">{h}</span>
            </label>
          ))}
        </fieldset>
      ) : null}

      <fieldset className="flex flex-col gap-2">
        <legend className="mb-1 text-[14px] font-semibold">How you&apos;ll prove it</legend>
        {methods.map((m) => {
          const info = claimMethodInfo(m);
          return (
            <label
              key={m}
              className={cn(
                "flex items-start gap-3 rounded-tile border p-3",
                method === m ? "border-text" : "border-border",
              )}
            >
              <input
                type="radio"
                name="method"
                value={m}
                checked={method === m}
                onChange={() => setMethod(m)}
                className="mt-1 size-4 shrink-0"
              />
              <span className="flex min-w-0 flex-col">
                <span className="text-[15px] font-semibold">{info.label}</span>
                <span className="text-[13px] text-text-2">{info.summary}</span>
              </span>
            </label>
          );
        })}
      </fieldset>

      <FormError>{start.isError ? organizerErrorMessage(start.error) : null}</FormError>
      <Button type="submit" block loading={start.isPending} disabled={method !== "feed" && !host}>
        Get my code
      </Button>
    </form>
  );
}

/** A calendar link plus, when the account has no saved home, the device's coarse location. */
function useConnect(onDone: (sourceId: string, claimId: string) => void) {
  const [needPoint, setNeedPoint] = useState(false);
  const connect = useMutation({
    mutationFn: async (v: { url: string; claimId: string; usePoint: boolean }) =>
      connectFeed(v.url, v.claimId, v.usePoint ? await coarsePosition() : null),
    onSuccess: (r, v) => onDone(r.source_id, v.claimId),
    onError: (err) => {
      if (organizerErrorCode(err) === "region_required") setNeedPoint(true);
    },
  });
  const message =
    connect.error instanceof Error && connect.error.message === "no_location"
      ? "We couldn't get your location. Set your area in the app first, then try again."
      : connect.isError && organizerErrorCode(connect.error) !== "region_required"
        ? organizerErrorMessage(connect.error)
        : null;
  return { connect, needPoint, message };
}

function FeedClaim({ onStarted }: { onStarted: (id: string) => void }) {
  const queryClient = useQueryClient();
  const [url, setUrl] = useState("");
  const [fieldError, setFieldError] = useState<string | null>(null);
  const [pending, setPending] = useState<{ claimId: string; url: string } | null>(null);
  const done = (_sourceId: string, claimId: string) => {
    void queryClient.invalidateQueries({ queryKey: organizerKeys.all });
    onStarted(claimId);
  };
  const { connect, needPoint, message } = useConnect(done);
  const start = useMutation({
    mutationFn: (feedUrl: string) =>
      startClaim({ eventId: null, host: null, method: "feed", feedUrl }),
    onSuccess: (c, feedUrl) => {
      setPending({ claimId: c.claim_id, url: feedUrl });
      connect.mutate({ url: feedUrl, claimId: c.claim_id, usePoint: false });
    },
  });

  const onSubmit = (e: FormEvent) => {
    e.preventDefault();
    const checked = checkFeedUrl(url);
    if (!checked.ok) {
      setFieldError(checked.error);
      return;
    }
    setFieldError(null);
    start.mutate(checked.url);
  };

  return (
    <form className="flex flex-col gap-4" onSubmit={onSubmit} noValidate>
      <p className="text-[15px] text-text-2">
        Run a public calendar (Google Calendar, Outlook, your website&apos;s .ics feed)? Paste its
        public link. We give you a short code to put in the calendar&apos;s description; once we see
        it, your events show up near the people around you, linked back to you.
      </p>
      <Field
        label="Public calendar link"
        type="url"
        inputMode="url"
        autoComplete="url"
        autoCapitalize="none"
        spellCheck={false}
        placeholder="https:// or webcal://"
        maxLength={500}
        value={url}
        onChange={(e) => {
          setUrl(e.target.value);
          if (fieldError) setFieldError(null);
        }}
        error={fieldError ?? undefined}
        disabled={Boolean(pending)}
        hint="The iCal or .ics address, often under Share or Integrate calendar."
      />
      {needPoint && pending ? (
        <div className="flex flex-col gap-2 rounded-tile bg-surface-2 p-3">
          <p className="text-[14px]">
            Where do these events happen? We use your device&apos;s rough location (about 10 km)
            once, to list them for people nearby.
          </p>
          <Button
            type="button"
            variant="secondary"
            loading={connect.isPending}
            onClick={() =>
              connect.mutate({ url: pending.url, claimId: pending.claimId, usePoint: true })
            }
          >
            Use my rough location
          </Button>
        </div>
      ) : null}
      <FormError>{start.isError ? organizerErrorMessage(start.error) : message}</FormError>
      {pending ? null : (
        <Button
          type="submit"
          block
          loading={start.isPending || connect.isPending}
          disabled={!url.trim()}
        >
          Get my code
        </Button>
      )}
    </form>
  );
}

function ConnectToClaim({ claimId }: { claimId: string }) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [url, setUrl] = useState("");
  const [fieldError, setFieldError] = useState<string | null>(null);
  const { connect, needPoint, message } = useConnect((sourceId) => {
    void queryClient.invalidateQueries({ queryKey: organizerKeys.all });
    void navigate({ to: "/organizer/sources/$id", params: { id: sourceId }, replace: true });
  });
  const [checkedUrl, setCheckedUrl] = useState<string | null>(null);

  return (
    <form
      className="flex flex-col gap-4"
      noValidate
      onSubmit={(e) => {
        e.preventDefault();
        const checked = checkFeedUrl(url);
        if (!checked.ok) {
          setFieldError(checked.error);
          return;
        }
        setFieldError(null);
        setCheckedUrl(checked.url);
        connect.mutate({ url: checked.url, claimId, usePoint: false });
      }}
    >
      <p className="text-[15px] text-text-2">
        Add a calendar feed from the site you verified. We read it every night and keep your events
        up to date, removing the ones you delete.
      </p>
      <Field
        label="Calendar feed link"
        type="url"
        inputMode="url"
        autoCapitalize="none"
        spellCheck={false}
        placeholder="https://"
        maxLength={500}
        value={url}
        onChange={(e) => {
          setUrl(e.target.value);
          if (fieldError) setFieldError(null);
        }}
        error={fieldError ?? undefined}
        hint="An .ics feed on your verified site or domain."
      />
      {needPoint && checkedUrl ? (
        <Button
          type="button"
          variant="secondary"
          loading={connect.isPending}
          onClick={() => connect.mutate({ url: checkedUrl, claimId, usePoint: true })}
        >
          Use my rough location for its area
        </Button>
      ) : null}
      <FormError>{message}</FormError>
      <Button type="submit" block loading={connect.isPending} disabled={!url.trim()}>
        Connect
      </Button>
    </form>
  );
}
