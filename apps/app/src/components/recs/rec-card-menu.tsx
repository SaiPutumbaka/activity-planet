import { useState } from "react";
import { EllipsisVertical, EyeOff, Info } from "lucide-react";
import { whyLines, whyNote, type Reason } from "@ap/core/recs";

import { Sheet } from "@/components/ui/sheet";
import { useDismissRec, type RecSubjectKind } from "@/lib/recs";

export type WhyKind = Parameters<typeof whyNote>[0];

/**
 * The "..." on a recommended card: "Not interested" (removes it from every row at once, with
 * Undo) and "Why am I seeing this?" (the chips in words). It sits above the card's own link.
 */
export function RecCardMenu({
  kind,
  id,
  name,
  reasons,
  why,
  className,
}: {
  kind: RecSubjectKind;
  id: string;
  /** What the card is, for the button's accessible name. */
  name: string;
  reasons: readonly Reason[];
  why: WhyKind;
  className?: string;
}) {
  const [open, setOpen] = useState(false);
  const [view, setView] = useState<"menu" | "why">("menu");
  const dismiss = useDismissRec();
  const close = () => {
    setOpen(false);
    setView("menu");
  };
  return (
    <>
      <button
        type="button"
        aria-label={`More about ${name}`}
        aria-haspopup="dialog"
        onClick={() => setOpen(true)}
        className={
          className ??
          "relative z-[2] inline-flex size-9 shrink-0 items-center justify-center rounded-full bg-surface/90 text-text-2 hover:bg-surface-2 hover:text-text"
        }
      >
        <EllipsisVertical className="size-5" aria-hidden="true" />
      </button>
      <Sheet open={open} onClose={close} title={view === "why" ? "Why am I seeing this?" : name}>
        {view === "menu" ? (
          <div className="flex flex-col">
            <button
              type="button"
              className="flex min-h-12 items-center gap-3 rounded-input px-1 text-left text-[15px] font-medium hover:bg-surface-2"
              onClick={() => {
                close();
                dismiss.mutate({ kind, id });
              }}
            >
              <EyeOff className="size-5 text-text-2" aria-hidden="true" />
              Not interested
            </button>
            <button
              type="button"
              className="flex min-h-12 items-center gap-3 rounded-input px-1 text-left text-[15px] font-medium hover:bg-surface-2"
              onClick={() => setView("why")}
            >
              <Info className="size-5 text-text-2" aria-hidden="true" />
              Why am I seeing this?
            </button>
          </div>
        ) : (
          <div className="flex flex-col gap-3 pb-2">
            <ul className="flex list-disc flex-col gap-1.5 pl-5 text-[15px]">
              {whyLines(reasons).map((line) => (
                <li key={line}>{line}</li>
              ))}
            </ul>
            <p className="text-[13px] text-text-2">{whyNote(why)}</p>
          </div>
        )}
      </Sheet>
    </>
  );
}
