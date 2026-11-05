import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Ellipsis, ExternalLink, ImageOff, RotateCw } from "lucide-react";
import { removedLabel, splitLinks, timeLabel, type ChatMessage } from "@ap/core/messaging";

import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Sheet } from "@/components/ui/sheet";
import { cn } from "@/lib/cn";
import { chatImageUrlQuery } from "@/lib/messaging";

/** Message text with plain links that open through a "Leaving Activity Planet" step. */
export function MessageText({ text }: { text: string }) {
  const [href, setHref] = useState<string | null>(null);
  const parts = splitLinks(text);
  return (
    <>
      {parts.map((p, i) =>
        p.href ? (
          <a
            key={i}
            href={p.href}
            rel="noopener noreferrer nofollow ugc"
            target="_blank"
            className="font-semibold underline underline-offset-2"
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              setHref(p.href);
            }}
          >
            {p.text}
          </a>
        ) : (
          <span key={i}>{p.text}</span>
        ),
      )}
      <Sheet
        open={href !== null}
        onClose={() => setHref(null)}
        title="Leaving Activity Planet"
        footer={
          <div className="grid grid-cols-2 gap-2">
            <Button variant="secondary" size="lg" onClick={() => setHref(null)}>
              Stay
            </Button>
            <a
              href={href ?? undefined}
              target="_blank"
              rel="noopener noreferrer nofollow ugc"
              onClick={() => setHref(null)}
              className="inline-flex h-13 items-center justify-center gap-2 rounded-control bg-primary px-[22px] text-[17px] font-semibold text-on-primary"
            >
              <ExternalLink className="size-4" aria-hidden="true" />
              Open link
            </a>
          </div>
        }
      >
        <p className="pt-1 text-[15px] text-text-2">
          This link goes to another site. We don&apos;t check where links lead, so only open it if
          you trust the person who sent it.
        </p>
        <p className="mt-3 break-all rounded-input bg-surface-2 px-3 py-2 text-[14px]">{href}</p>
      </Sheet>
    </>
  );
}

function ChatImage({ path, checking }: { path: string | null; checking: boolean }) {
  const url = useQuery({ ...chatImageUrlQuery(path ?? ""), enabled: Boolean(path) && !checking });
  if (!path || checking || !url.data) {
    return (
      <span className="flex h-40 w-56 max-w-full flex-col items-center justify-center gap-2 rounded-input bg-surface-3 text-[13px] text-text-2">
        <ImageOff className="size-5" aria-hidden="true" />
        {checking ? "Photo is being checked" : "Photo"}
      </span>
    );
  }
  return (
    <img
      src={url.data}
      alt="Photo"
      className="max-h-72 w-auto max-w-full rounded-input object-cover"
      loading="lazy"
    />
  );
}

export interface BubbleProps {
  message: ChatMessage;
  /** Show the author's name and photo (groups and rooms, first of a run). */
  showAuthor: boolean;
  onOpenActions?: () => void;
}

/** One message. Its time line opens the actions (delete your own, report someone else's). */
export function MessageBubble({ message: m, showAuthor, onOpenActions }: BubbleProps) {
  const removed = removedLabel(m);
  const name = m.author?.first_name ?? "Deleted user";
  const checking = m.kind === "image" && m.image?.state !== "visible";
  return (
    <div className={cn("flex w-full gap-2", m.mine ? "justify-end" : "justify-start")}>
      {!m.mine ? (
        <span className="w-8 shrink-0">
          {showAuthor ? <Avatar src={m.author?.avatar_url} name={name} size={32} /> : null}
        </span>
      ) : null}
      <div
        className={cn("flex min-w-0 max-w-[78%] flex-col", m.mine ? "items-end" : "items-start")}
      >
        {showAuthor && !m.mine ? (
          <span className="px-3 pb-0.5 text-[12px] font-semibold text-text-2">{name}</span>
        ) : null}
        <div
          className={cn(
            "min-w-0 max-w-full rounded-[20px] px-3.5 py-2 text-left text-[15px] leading-[1.35] whitespace-pre-wrap [overflow-wrap:anywhere]",
            removed
              ? "border border-border bg-surface italic text-text-2"
              : m.mine
                ? "bg-primary text-on-primary"
                : "bg-surface-2 text-text",
          )}
        >
          {removed ? (
            removed
          ) : m.kind === "image" ? (
            <span className="flex flex-col gap-1.5">
              <ChatImage path={m.image?.path ?? null} checking={checking} />
              {m.body ? <MessageText text={m.body} /> : null}
            </span>
          ) : (
            <MessageText text={m.body} />
          )}
        </div>
        {onOpenActions ? (
          <button
            type="button"
            onClick={onOpenActions}
            aria-haspopup="dialog"
            aria-label={`Options for the message from ${m.mine ? "you" : name} at ${timeLabel(m.created_at)}`}
            className="inline-flex min-h-8 items-center gap-1 rounded-full px-3 text-[11px] text-text-3 tabular hover:bg-surface-2"
          >
            {timeLabel(m.created_at)}
            <Ellipsis className="size-3.5" aria-hidden="true" />
          </button>
        ) : (
          <span className="px-3 pt-0.5 text-[11px] text-text-3 tabular">
            {timeLabel(m.created_at)}
          </span>
        )}
      </div>
    </div>
  );
}

/** A bubble the server has not stored yet: "Sending" or "Not sent, tap to retry". */
export function PendingBubble({
  body,
  failed,
  onRetry,
}: {
  body: string;
  failed: boolean;
  onRetry: () => void;
}) {
  return (
    <div className="flex w-full justify-end">
      <div className="flex min-w-0 max-w-[78%] flex-col items-end">
        <span
          className={cn(
            "min-w-0 max-w-full rounded-[20px] px-3.5 py-2 text-[15px] leading-[1.35] whitespace-pre-wrap [overflow-wrap:anywhere]",
            failed
              ? "border border-danger bg-danger-tint text-text"
              : "bg-primary/70 text-on-primary",
          )}
        >
          {body}
        </span>
        {failed ? (
          <button
            type="button"
            onClick={onRetry}
            className="inline-flex min-h-8 items-center gap-1 px-3 text-[12px] font-semibold text-danger"
          >
            <RotateCw className="size-3.5" aria-hidden="true" />
            Not sent. Tap to retry
          </button>
        ) : (
          <span className="px-3 pt-0.5 text-[11px] text-text-3" aria-live="polite">
            Sending…
          </span>
        )}
      </div>
    </div>
  );
}
