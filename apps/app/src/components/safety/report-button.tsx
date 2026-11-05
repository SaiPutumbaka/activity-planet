import { useState } from "react";
import { Flag } from "lucide-react";

import { Button } from "@/components/ui/button";
import { reportTitle, type ReportKind } from "@/lib/safety";

import { ReportSheet } from "./report-form";

/**
 * A quiet "Report this plan" (chapter, hub) button at the foot of a page, with its sheet.
 *
 *   <ReportButton kind="event" targetId={event.id} />
 */
export function ReportButton({ kind, targetId }: { kind: ReportKind; targetId: string }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <Button
        variant="ghost"
        size="sm"
        className="self-start text-text-2"
        aria-haspopup="dialog"
        leading={<Flag className="size-4" aria-hidden="true" />}
        onClick={() => setOpen(true)}
      >
        {reportTitle(kind)}
      </Button>
      <ReportSheet open={open} onClose={() => setOpen(false)} kind={kind} targetId={targetId} />
    </>
  );
}
