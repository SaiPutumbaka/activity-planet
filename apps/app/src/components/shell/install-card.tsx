import { useEffect, useState } from "react";
import { Share, SquarePlus, X } from "lucide-react";
import { AppIcon } from "@ap/ui/brand";

import { Button } from "@/components/ui/button";
import { Sheet } from "@/components/ui/sheet";
import { cn } from "@/lib/cn";
import {
  installAfterRsvpPending,
  markInstallAfterRsvpShown,
  useInstallPrompt,
} from "@/lib/install";

/**
 * "Add to your home screen" (RECS_DESIGN 9.1). On Chromium the button replays the captured
 * install prompt; on iPhone and iPad it opens the Share, then Add to Home Screen steps. Never
 * shown once installed. "Not now" hides it for 30 days, except in You and the push settings
 * (`persistent`), where it is a setting rather than a nudge.
 *
 *   <InstallCard placement="onboarding" />   // the finish step
 *   <InstallCard placement="rsvp" />         // the event page, once, after the first RSVP
 *   <InstallCard placement="you" persistent />
 */
export function InstallCard({
  placement,
  persistent = false,
  className,
}: {
  placement: "onboarding" | "you" | "rsvp" | "push";
  persistent?: boolean;
  className?: string;
}) {
  const install = useInstallPrompt();
  const [steps, setSteps] = useState(false);
  // The after-RSVP card shows once: the first time it can show, it claims the turn and stays
  // for this visit.
  const [claimed, setClaimed] = useState(false);
  const pending = placement === "rsvp" && installAfterRsvpPending();
  const eligible = install.available && (persistent || !install.dismissed);
  const visible = eligible && (placement !== "rsvp" || pending || claimed);

  if (pending && eligible && !claimed) setClaimed(true);
  useEffect(() => {
    if (claimed) markInstallAfterRsvpShown();
  }, [claimed]);

  if (!visible) return null;

  const body = install.ios
    ? "Open it like an app, and turn on notifications on iPhone and iPad."
    : "Open it like an app, straight from your home screen.";

  return (
    <section
      data-testid="install-card"
      data-placement={placement}
      aria-labelledby={`install-${placement}`}
      className={cn(
        "relative flex items-start gap-3 rounded-card border border-border bg-surface-2 p-4",
        className,
      )}
    >
      <AppIcon size={40} />
      <div className="flex min-w-0 flex-1 flex-col gap-2">
        <div>
          <h3 id={`install-${placement}`} className="text-[15px] font-bold">
            Add Activity Planet to your home screen
          </h3>
          <p className="text-[13px] text-text-2">{body}</p>
        </div>
        <div className="flex flex-wrap gap-2">
          {install.canPrompt ? (
            <Button size="sm" variant="secondary" onClick={() => void install.prompt()}>
              Install
            </Button>
          ) : (
            <Button size="sm" variant="secondary" onClick={() => setSteps(true)}>
              Show me how
            </Button>
          )}
        </div>
      </div>
      {persistent ? null : (
        <button
          type="button"
          aria-label="Not now"
          onClick={install.dismiss}
          className="-mt-1 -mr-1 inline-flex size-9 shrink-0 items-center justify-center rounded-full text-text-2 hover:bg-surface-3 hover:text-text"
        >
          <X className="size-5" aria-hidden="true" />
        </button>
      )}
      <Sheet open={steps} onClose={() => setSteps(false)} title="Add to Home Screen">
        <ol className="flex flex-col gap-3 pb-2 text-[15px]">
          <li className="flex items-center gap-3">
            <Share className="size-5 shrink-0 text-text-2" aria-hidden="true" />
            <span>
              Tap <span className="font-semibold">Share</span> in your browser&apos;s toolbar.
            </span>
          </li>
          <li className="flex items-center gap-3">
            <SquarePlus className="size-5 shrink-0 text-text-2" aria-hidden="true" />
            <span>
              Then tap <span className="font-semibold">Add to Home Screen</span>.
            </span>
          </li>
          <li className="text-[13px] text-text-2">
            Open Activity Planet from its new icon. On iPhone and iPad, that is also where you can
            turn on notifications.
          </li>
        </ol>
      </Sheet>
    </section>
  );
}
