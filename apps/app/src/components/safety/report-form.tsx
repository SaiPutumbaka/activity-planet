import { useId, useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { FormError } from "@/components/ui/field";
import { Sheet } from "@/components/ui/sheet";
import { FieldTextArea } from "@/components/ui/textarea";
import {
  BOOKING_REPORT_REASONS,
  REPORT_REASONS,
  REPORT_REASON_LABELS,
  reportContent,
  reportSentText,
  reportTitle,
  safetyErrorMessage,
  type ReportKind,
  type ReportReason,
} from "@/lib/safety";
import { SITE_URL } from "@/lib/site";

const NOTE_MAX = 1000;

/**
 * The report form for a profile, plan, chapter or hub (report_content). A reason is required,
 * a note is optional. Reports are private; the server decides everything else (one open report
 * per person per item, own items, the daily limit, auto-hide).
 */
export function ReportForm({
  kind,
  targetId,
  onDone,
  onCancel,
}: {
  kind: ReportKind;
  targetId: string;
  onDone: () => void;
  onCancel: () => void;
}) {
  const queryClient = useQueryClient();
  const name = useId();
  const [reason, setReason] = useState<ReportReason | null>(null);
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);

  const send = useMutation({
    mutationFn: () => reportContent(kind, targetId, reason!, note),
    onSuccess: (r) => {
      // Only this report's own hide is ever reported back; refresh in case it was one.
      if (r.hidden) void queryClient.invalidateQueries();
      toast.success(reportSentText(r));
      onDone();
    },
    onError: (err) => setError(safetyErrorMessage(err)),
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
      <fieldset className="flex flex-col gap-1" disabled={send.isPending}>
        <legend className="pb-1.5 text-[14px] font-semibold">What's wrong?</legend>
        {(kind === "booking"
          ? [...BOOKING_REPORT_REASONS, ...REPORT_REASONS]
          : [...REPORT_REASONS]
        ).map((r) => (
          <label key={r} className="flex min-h-11 items-center gap-3 text-[15px]">
            <input
              type="radio"
              name={name}
              value={r}
              className="size-5 shrink-0 accent-primary"
              checked={reason === r}
              onChange={() => setReason(r)}
            />
            {REPORT_REASON_LABELS[r]}
          </label>
        ))}
      </fieldset>
      {reason === "ncii" ? (
        <p className="rounded-input bg-surface-2 px-4 py-3 text-[14px]">
          You can also ask us to remove the image everywhere, even without an account:{" "}
          <a
            href={`${SITE_URL}/safety/intimate-images`}
            target="_blank"
            rel="noreferrer"
            className="font-semibold text-link underline-offset-2 hover:underline"
          >
            image removal request
          </a>
          .
        </p>
      ) : null}
      {reason === "child_safety" || reason === "violence" ? (
        <p className="rounded-input bg-surface-2 px-4 py-3 text-[14px]">
          If someone is in danger right now, call your local emergency number first.
        </p>
      ) : null}
      <FieldTextArea
        label="Details (optional)"
        rows={3}
        maxLength={NOTE_MAX}
        value={note}
        onChange={(e) => setNote(e.target.value)}
        disabled={send.isPending}
      />
      <p className="text-[12px] text-text-3">
        Reports are private. No one is told who reported them. A moderator reviews every report.
      </p>
      <div className="grid grid-cols-2 gap-2">
        <Button variant="secondary" onClick={onCancel} disabled={send.isPending}>
          Cancel
        </Button>
        <Button type="submit" variant="danger" loading={send.isPending} disabled={!reason}>
          Send report
        </Button>
      </div>
    </form>
  );
}

/** A sheet holding the report form, for pages that report the thing they show. */
export function ReportSheet({
  open,
  onClose,
  kind,
  targetId,
  name,
}: {
  open: boolean;
  onClose: () => void;
  kind: ReportKind;
  targetId: string;
  /** The person's first name, for a profile report title. */
  name?: string | null;
}) {
  return (
    <Sheet open={open} onClose={onClose} title={reportTitle(kind, name)}>
      <ReportForm kind={kind} targetId={targetId} onDone={onClose} onCancel={onClose} />
    </Sheet>
  );
}
