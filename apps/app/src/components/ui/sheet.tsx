import { useEffect, useId, useRef, type MouseEvent, type ReactNode } from "react";
import { X } from "lucide-react";

import { cn } from "@/lib/cn";

/**
 * Bottom sheet on phones, centred modal from 640 px up. A native <dialog> opened with showModal()
 * gives the top layer, the focus trap, Escape and focus return for free; `closedby="any"` closes
 * on a backdrop tap (with a click fallback for browsers without it). The page under it cannot
 * scroll through the backdrop (overscroll containment, the modern way; no body overflow hacks).
 * Children mount only while open, so a form inside starts fresh each time.
 *
 *   <Sheet open={open} onClose={() => setOpen(false)} title="Cancel this event?"
 *     footer={<Button variant="danger" block>Cancel event</Button>}>
 *     <p>Everyone going gets a message.</p>
 *   </Sheet>
 */
export interface SheetProps {
  open: boolean;
  onClose: () => void;
  title?: string;
  children: ReactNode;
  footer?: ReactNode;
  /** Extra classes for the scrolling body. */
  className?: string;
}

const supportsClosedBy =
  typeof HTMLDialogElement !== "undefined" && "closedBy" in HTMLDialogElement.prototype;

export function Sheet({ open, onClose, title, children, footer, className }: SheetProps) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useId();

  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    else if (!open && dialog.open) dialog.close();
  }, [open]);

  // Escape and light dismiss end in the native close event; mirror it into React state. Our own
  // dialog.close() above fires it too, but by then `open` is already false.
  function onNativeClose() {
    if (open) onClose();
  }

  // Light-dismiss fallback where closedby is not implemented: a click whose target is the dialog
  // itself and whose point lies outside its box landed on the backdrop.
  function onClick(event: MouseEvent<HTMLDialogElement>) {
    const dialog = ref.current;
    if (supportsClosedBy || !dialog || event.target !== dialog) return;
    const r = dialog.getBoundingClientRect();
    const inside =
      r.top <= event.clientY &&
      event.clientY <= r.bottom &&
      r.left <= event.clientX &&
      event.clientX <= r.right;
    if (!inside) dialog.close();
  }

  const bottomPad = "pb-[calc(16px+env(safe-area-inset-bottom,0px))]";

  return (
    <dialog
      ref={ref}
      role="dialog"
      aria-modal="true"
      aria-labelledby={title ? titleId : undefined}
      closedby="any"
      onClose={onNativeClose}
      onClick={onClick}
      className={cn(
        // Reset the UA box: pinned to the bottom edge on phones, centred from sm up.
        "fixed inset-x-0 top-auto bottom-0 m-0 max-h-[88dvh] w-full max-w-none flex-col overflow-hidden overscroll-contain rounded-t-card border-0 bg-surface p-0 text-text shadow-[var(--shadow-lift)] outline-none open:flex",
        "sm:inset-0 sm:m-auto sm:max-h-[80dvh] sm:w-[calc(100%-32px)] sm:max-w-md sm:rounded-card",
        "backdrop:overflow-hidden backdrop:overscroll-contain backdrop:bg-scrim",
        // Entry only: slide up on phones, a short fade from sm. Exit is instant.
        "translate-y-0 opacity-100 transition-[translate,opacity] duration-200 ease-out-quart starting:open:translate-y-full sm:starting:open:translate-y-2 sm:starting:open:opacity-0",
      )}
    >
      {open ? (
        <>
          <div
            aria-hidden="true"
            className="mx-auto mt-2 h-1 w-9 rounded-full bg-border-strong sm:hidden"
          />
          <div className="flex items-center gap-3 pr-2 pl-4 pt-2 pb-1 sm:pt-3">
            {title ? (
              <h2 id={titleId} className="min-w-0 flex-1 truncate text-[17px] font-bold">
                {title}
              </h2>
            ) : (
              <span className="flex-1" />
            )}
            <button
              type="button"
              onClick={onClose}
              aria-label="Close"
              className="flex size-11 shrink-0 items-center justify-center rounded-full text-text-2 hover:bg-surface-2"
            >
              <X className="size-5" aria-hidden="true" />
            </button>
          </div>
          <div
            className={cn(
              "min-h-0 flex-1 overflow-y-auto overscroll-contain px-4 pb-4",
              !footer && bottomPad,
              className,
            )}
          >
            {children}
          </div>
          {footer ? (
            <div className={cn("flex flex-col gap-3 border-t border-border px-4 pt-3", bottomPad)}>
              {footer}
            </div>
          ) : null}
        </>
      ) : null}
    </dialog>
  );
}
