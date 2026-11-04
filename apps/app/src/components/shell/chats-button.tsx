import { Link } from "@tanstack/react-router";
import { MessageCircle } from "lucide-react";

import { buttonVariants } from "@/components/ui/button-variants";
import { cn } from "@/lib/cn";

/** Chats, beside the inbox bell, while Map holds its tab-bar slot (until messaging ships). */
export function ChatsButton() {
  return (
    <Link
      to="/chats"
      aria-label="Chats"
      className={cn(buttonVariants({ variant: "secondary", size: "icon-sm" }), "rounded-full")}
    >
      <MessageCircle className="size-5" aria-hidden="true" />
    </Link>
  );
}
