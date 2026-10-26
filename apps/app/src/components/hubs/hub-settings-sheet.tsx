import { Link } from "@tanstack/react-router";

import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { Sheet } from "@/components/ui/sheet";
import { Switch } from "@/components/ui/switch";

import type { MembershipHub } from "./use-hub-membership";

/** The "…" sheet for a joined hub: notifications on/off, open the hub, leave it. */
export function HubSettingsSheet({
  hub,
  notify,
  open,
  onClose,
  onNotifyChange,
  onLeave,
}: {
  hub: MembershipHub | null;
  notify: boolean;
  open: boolean;
  onClose: () => void;
  onNotifyChange: (notify: boolean) => void;
  onLeave: () => void;
}) {
  return (
    <Sheet
      open={open && hub !== null}
      onClose={onClose}
      title={hub?.name}
      footer={
        hub ? (
          <>
            <Link
              to="/hubs/$slug"
              params={{ slug: hub.slug }}
              onClick={onClose}
              className={buttonVariants({ variant: "secondary", size: "lg", block: true })}
            >
              Open hub
            </Link>
            <Button variant="danger" size="lg" block onClick={onLeave}>
              Leave {hub.name}
            </Button>
          </>
        ) : null
      }
    >
      {hub ? (
        <div className="pt-1">
          <Switch
            label="Notifications"
            hint="New plans and chapter news from this hub"
            checked={notify}
            onCheckedChange={onNotifyChange}
          />
        </div>
      ) : null}
    </Sheet>
  );
}
