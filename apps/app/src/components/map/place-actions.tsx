import { useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Eye, EyeOff, Flag, PencilLine, Trash2 } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Field, FormError } from "@/components/ui/field";
import { FieldSelect } from "@/components/ui/select";
import { FieldTextArea } from "@/components/ui/textarea";
import { PLACE_KIND_OPTIONS, mapKeys, type PlaceDetail } from "@/lib/map";
import {
  REPORT_REASONS,
  deleteMyPlace,
  factsOf,
  ownPinActions,
  placeChanges,
  placeErrorMessage,
  reportPlace,
  setMyPlaceVisibility,
  suggestPlaceEdit,
  type PlaceFacts,
  type ReportReason,
} from "@/lib/place-contributions";

export type PlaceMode = "view" | "correct" | "report" | "publish";

/**
 * The row under a place card (§9): "Suggest a correction" and "Report" for everyone signed in,
 * and for the creator's own unreviewed pin Edit, "Make public" / "Make private" and Delete.
 * A reviewed public place is a shared fact: even its creator corrects or reports it.
 */
export function PlaceActionRow({
  detail,
  onMode,
  onDeleted,
}: {
  detail: PlaceDetail;
  onMode: (m: PlaceMode) => void;
  onDeleted: () => void;
}) {
  const queryClient = useQueryClient();
  const own = ownPinActions(detail);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: mapKeys.all });
  };
  const makePrivate = useMutation({
    mutationFn: () => setMyPlaceVisibility(detail.id, false, false),
    onSuccess: () => {
      refresh();
      toast.success("Request withdrawn. Only you can see it now.");
    },
    onError: (err) => toast.error(placeErrorMessage(err)),
  });
  const remove = useMutation({
    mutationFn: () => deleteMyPlace(detail.id),
    onSuccess: () => {
      refresh();
      toast.success("Place deleted.");
      onDeleted();
    },
    onError: (err) => toast.error(placeErrorMessage(err)),
  });

  if (own.edit) {
    return (
      <div className="flex flex-col gap-2">
        <div className="flex flex-wrap gap-2">
          <Button
            variant="secondary"
            size="sm"
            leading={<PencilLine className="size-4" aria-hidden="true" />}
            onClick={() => onMode("correct")}
          >
            Edit
          </Button>
          {own.makePublic ? (
            <Button
              variant="secondary"
              size="sm"
              leading={<Eye className="size-4" aria-hidden="true" />}
              onClick={() => onMode("publish")}
            >
              Share with everyone
            </Button>
          ) : null}
          {own.makePrivate ? (
            <Button
              variant="secondary"
              size="sm"
              loading={makePrivate.isPending}
              leading={<EyeOff className="size-4" aria-hidden="true" />}
              onClick={() => makePrivate.mutate()}
            >
              Keep it private
            </Button>
          ) : null}
          <Button
            variant="danger"
            size="sm"
            leading={<Trash2 className="size-4" aria-hidden="true" />}
            onClick={() => setConfirmDelete(true)}
          >
            Delete
          </Button>
        </div>
        {confirmDelete ? (
          <div className="flex flex-wrap items-center gap-2 rounded-tile bg-surface-2 p-3 text-[14px]">
            <span className="min-w-0 flex-1">Delete this place for good?</span>
            <Button size="sm" variant="secondary" onClick={() => setConfirmDelete(false)}>
              Keep
            </Button>
            <Button
              size="sm"
              variant="danger"
              loading={remove.isPending}
              onClick={() => remove.mutate()}
            >
              Delete
            </Button>
          </div>
        ) : null}
      </div>
    );
  }

  return (
    <div className="flex flex-wrap gap-2">
      {detail.source !== "venue" ? (
        <Button
          variant="ghost"
          size="sm"
          leading={<PencilLine className="size-4" aria-hidden="true" />}
          onClick={() => onMode("correct")}
        >
          Suggest a correction
        </Button>
      ) : null}
      {detail.mine ? null : (
        <Button
          variant="ghost"
          size="sm"
          leading={<Flag className="size-4" aria-hidden="true" />}
          onClick={() => onMode("report")}
        >
          Report
        </Button>
      )}
    </div>
  );
}

/** Suggest a correction, or (own unreviewed pin) edit it directly; only changed fields are sent. */
export function CorrectionForm({ detail, onDone }: { detail: PlaceDetail; onDone: () => void }) {
  const queryClient = useQueryClient();
  const before = factsOf(detail);
  const [facts, setFacts] = useState<PlaceFacts>(before);
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const own = ownPinActions(detail).edit;
  const changes = placeChanges(before, facts);
  const changed = Object.keys(changes).length > 0;

  const save = useMutation({
    mutationFn: () => suggestPlaceEdit(detail.id, changes, note),
    onSuccess: (r) => {
      void queryClient.invalidateQueries({ queryKey: mapKeys.all });
      toast.success(r.applied ? "Saved." : "Thanks. A moderator checks it before it shows.");
      onDone();
    },
    onError: (err) => setError(placeErrorMessage(err)),
  });
  const set = <K extends keyof PlaceFacts>(k: K, v: PlaceFacts[K]) =>
    setFacts((f) => ({ ...f, [k]: v }));

  return (
    <form
      className="flex flex-col gap-4 pt-1"
      onSubmit={(e) => {
        e.preventDefault();
        if (changed) save.mutate();
      }}
    >
      <p className="text-[14px] text-text-2">
        {own
          ? "Your changes save right away."
          : "Change what's wrong. A moderator checks it before it shows on the map."}
      </p>
      <FormError>{error}</FormError>
      <Field
        label="Name"
        value={facts.name}
        maxLength={120}
        onChange={(e) => set("name", e.target.value)}
      />
      <FieldSelect label="Kind" value={facts.kind} onChange={(e) => set("kind", e.target.value)}>
        {PLACE_KIND_OPTIONS.some((k) => k.value === facts.kind) ? null : (
          <option value={facts.kind}>{detail.kindLabel}</option>
        )}
        {PLACE_KIND_OPTIONS.map((k) => (
          <option key={k.value} value={k.value}>
            {k.label}
          </option>
        ))}
      </FieldSelect>
      {detail.private ? null : (
        <Field
          label="Address"
          value={facts.address}
          maxLength={200}
          onChange={(e) => set("address", e.target.value)}
        />
      )}
      <Field
        label="Hours"
        value={facts.hours}
        maxLength={255}
        onChange={(e) => set("hours", e.target.value)}
      />
      <Field
        label="Website"
        type="url"
        inputMode="url"
        value={facts.website}
        maxLength={500}
        placeholder="https://"
        onChange={(e) => set("website", e.target.value)}
      />
      <label className="flex items-center gap-3 text-[15px]">
        <input
          type="checkbox"
          className="size-5 shrink-0 accent-primary"
          checked={facts.closed}
          onChange={(e) => set("closed", e.target.checked)}
        />
        It's closed for good
      </label>
      {own ? null : (
        <FieldTextArea
          label="Anything a moderator should know? (optional)"
          rows={2}
          maxLength={500}
          value={note}
          onChange={(e) => setNote(e.target.value)}
        />
      )}
      <p className="text-[12px] text-text-3">
        Is the pin in the wrong spot? Report it as “The pin is in the wrong spot” and say where.
      </p>
      <div className="grid grid-cols-2 gap-2">
        <Button variant="secondary" onClick={onDone} disabled={save.isPending}>
          Cancel
        </Button>
        <Button type="submit" loading={save.isPending} disabled={!changed}>
          {own ? "Save" : "Send"}
        </Button>
      </div>
    </form>
  );
}

export function ReportForm({ detail, onDone }: { detail: PlaceDetail; onDone: () => void }) {
  const queryClient = useQueryClient();
  const [reason, setReason] = useState<ReportReason | null>(null);
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const send = useMutation({
    mutationFn: () => reportPlace(detail.id, reason!, note),
    onSuccess: (r) => {
      void queryClient.invalidateQueries({ queryKey: mapKeys.all });
      toast.success(
        r.already
          ? "You already reported this place. A moderator is on it."
          : r.hidden
            ? "Thanks. It's hidden until a moderator looks at it."
            : "Thanks. A moderator will look at it.",
      );
      onDone();
    },
    onError: (err) => setError(placeErrorMessage(err)),
  });
  return (
    <form
      className="flex flex-col gap-4 pt-1"
      onSubmit={(e) => {
        e.preventDefault();
        if (reason) send.mutate();
      }}
    >
      <FormError>{error}</FormError>
      <fieldset className="flex flex-col gap-1">
        <legend className="pb-1.5 text-[14px] font-semibold">What's wrong?</legend>
        {REPORT_REASONS.map((r) => (
          <label key={r.value} className="flex min-h-11 items-center gap-3 text-[15px]">
            <input
              type="radio"
              name="report-reason"
              className="size-5 shrink-0 accent-primary"
              checked={reason === r.value}
              onChange={() => setReason(r.value)}
            />
            {r.label}
          </label>
        ))}
      </fieldset>
      <FieldTextArea
        label="Details (optional)"
        rows={2}
        maxLength={500}
        value={note}
        onChange={(e) => setNote(e.target.value)}
      />
      <p className="text-[12px] text-text-3">
        Reports are private. The place's creator never sees who reported it.
      </p>
      <div className="grid grid-cols-2 gap-2">
        <Button variant="secondary" onClick={onDone} disabled={send.isPending}>
          Cancel
        </Button>
        <Button type="submit" loading={send.isPending} disabled={!reason}>
          Report
        </Button>
      </div>
    </form>
  );
}

/** "Share with everyone" for the creator's private pin: the §7 rule 1 confirmation. */
export function PublishForm({ detail, onDone }: { detail: PlaceDetail; onDone: () => void }) {
  const queryClient = useQueryClient();
  const [confirmed, setConfirmed] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const publish = useMutation({
    mutationFn: () => setMyPlaceVisibility(detail.id, true, confirmed),
    onSuccess: (r) => {
      void queryClient.invalidateQueries({ queryKey: mapKeys.all });
      toast.success(
        r.status === "pending"
          ? "Sent for review. Everyone sees it once a moderator approves it."
          : "It's on the map for everyone.",
      );
      onDone();
    },
    onError: (err) => setError(placeErrorMessage(err)),
  });
  return (
    <div className="flex flex-col gap-4 pt-1">
      <FormError>{error}</FormError>
      <label className="flex items-start gap-3 rounded-tile bg-surface-2 p-3 text-[14px]">
        <input
          type="checkbox"
          className="mt-0.5 size-5 shrink-0 accent-primary"
          checked={confirmed}
          onChange={(e) => setConfirmed(e.target.checked)}
        />
        <span>
          This is a public place, not a home or private residence. A moderator checks it before
          anyone else sees it.
        </span>
      </label>
      <div className="grid grid-cols-2 gap-2">
        <Button variant="secondary" onClick={onDone} disabled={publish.isPending}>
          Cancel
        </Button>
        <Button loading={publish.isPending} disabled={!confirmed} onClick={() => publish.mutate()}>
          Send for review
        </Button>
      </div>
    </div>
  );
}
