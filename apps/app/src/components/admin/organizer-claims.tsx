import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleAlert, Inbox } from "lucide-react";
import { toast } from "sonner";
import { claimMethodInfo, failureText } from "@ap/core/organizer";

import { ListSkeleton } from "@/components/hubs/hub-states";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import { FieldTextArea } from "@/components/ui/textarea";
import { adminErrorMessage, adminKeys, formatWhen } from "@/lib/admin";
import {
  modOrganizerClaimsQuery,
  reviewOrganizerClaim,
  type ModOrganizerClaim,
} from "@/lib/collector-admin";

const STATUS: Record<ModOrganizerClaim["status"], string> = {
  pending: "Waiting for proof",
  verified: "Verified",
  failed: "Failed",
  revoked: "Revoked",
};

/**
 * The Organizers tab of /admin/claims (collector Slice 2; mod_organizer_claims and
 * mod_organizer_claim_review): claims are verified automatically, so this is a look after the
 * fact. "Looks right" takes a verified claim out of the queue; Revoke withdraws it (its connected
 * calendars stop, the source loses its owner). A moderator's own claim is someone else's call.
 */
export function OrganizerClaims({ closed }: { closed: boolean }) {
  const claims = useQuery(modOrganizerClaimsQuery(closed));
  if (claims.isPending) return <ListSkeleton rows={3} rowClassName="h-32" />;
  if (claims.isError) {
    return (
      <EmptyState
        icon={CircleAlert}
        title="Couldn't load claims"
        body={adminErrorMessage(claims.error)}
        action={
          <Button variant="secondary" onClick={() => void claims.refetch()}>
            Try again
          </Button>
        }
      />
    );
  }
  if (claims.data.length === 0) {
    return (
      <EmptyState
        icon={Inbox}
        title="Nothing here"
        body="Organizer claims show up here as people start them."
      />
    );
  }
  return (
    <ul className="flex flex-col gap-3">
      {claims.data.map((c) => (
        <li key={c.id}>
          <OrganizerClaimCard claim={c} />
        </li>
      ))}
    </ul>
  );
}

function OrganizerClaimCard({ claim }: { claim: ModOrganizerClaim }) {
  const queryClient = useQueryClient();
  const [note, setNote] = useState("");
  const review = useMutation({
    mutationFn: (action: "ok" | "revoke") => reviewOrganizerClaim(claim.id, action, note),
    onSuccess: (_, action) => {
      setNote("");
      void queryClient.invalidateQueries({ queryKey: adminKeys.all });
      toast.success(action === "ok" ? "Marked as looked at." : "Claim revoked.");
    },
    onError: (err) => toast.error(adminErrorMessage(err)),
  });
  const live = claim.status === "pending" || claim.status === "verified";
  const failure = claim.status === "verified" ? null : failureText(claim.failure);

  return (
    <article className="flex flex-col gap-3 rounded-card border border-border p-4">
      <header className="min-w-0">
        <p className="text-[13px] text-text-2">
          {STATUS[claim.status]} · {claimMethodInfo(claim.method).label} ·{" "}
          {formatWhen(claim.created_at)}
          {claim.status === "verified" && !claim.reviewed_at ? " · not reviewed" : ""}
        </p>
        <h2 className="text-[17px] font-bold break-words">{claim.source?.name ?? claim.host}</h2>
      </header>
      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[14px]">
        <dt className="text-text-2">Person</dt>
        <dd className="min-w-0 break-words">
          {claim.user ? (
            <Link
              to="/admin/users"
              search={{ user: claim.user.id }}
              className="font-semibold text-link underline-offset-2 hover:underline"
            >
              {claim.user.first_name} @{claim.user.handle}
            </Link>
          ) : (
            "Unknown"
          )}
        </dd>
        <dt className="text-text-2">Site</dt>
        <dd className="min-w-0 break-all">{claim.host}</dd>
        {claim.feed_url ? (
          <>
            <dt className="text-text-2">Calendar</dt>
            <dd className="min-w-0 break-all">{claim.feed_url}</dd>
          </>
        ) : null}
        {claim.source ? (
          <>
            <dt className="text-text-2">Source page</dt>
            <dd className="min-w-0 break-all">{claim.source.url}</dd>
          </>
        ) : null}
        <dt className="text-text-2">Checks</dt>
        <dd className="tabular">
          {claim.attempts}
          {claim.connected > 0
            ? ` · ${claim.connected} connected ${claim.connected === 1 ? "calendar" : "calendars"}`
            : ""}
        </dd>
      </dl>
      {failure ? <p className="text-[14px] text-text-2">{failure}</p> : null}

      {!live ? null : !claim.can_act ? (
        <p className="text-[14px] text-text-2">Your own claim. Another moderator reviews it.</p>
      ) : (
        <>
          <FieldTextArea
            label="Note for the log (optional)"
            rows={2}
            maxLength={400}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            disabled={review.isPending}
          />
          <div className="flex flex-wrap justify-end gap-2">
            <Button
              size="sm"
              variant="danger"
              loading={review.isPending && review.variables === "revoke"}
              disabled={review.isPending}
              onClick={() => review.mutate("revoke")}
            >
              Revoke
            </Button>
            {claim.status === "verified" && !claim.reviewed_at ? (
              <Button
                size="sm"
                loading={review.isPending && review.variables === "ok"}
                disabled={review.isPending}
                onClick={() => review.mutate("ok")}
              >
                Looks right
              </Button>
            ) : null}
          </div>
        </>
      )}
    </article>
  );
}
