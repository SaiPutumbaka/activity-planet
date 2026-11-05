import type { ReactNode } from "react";

/**
 * A titled row of recommendation cards. Cards scroll sideways inside the row (snap, no visible
 * scrollbar) and the page itself never does.
 */
export function RecRow({
  id,
  title,
  subtitle,
  children,
  layout = "scroll",
  trailing,
}: {
  id: string;
  title: string;
  subtitle?: string;
  children: ReactNode;
  layout?: "scroll" | "list";
  trailing?: ReactNode;
}) {
  return (
    <section className="flex min-w-0 flex-col gap-3" aria-labelledby={id} data-testid={id}>
      <div className="flex items-end justify-between gap-3">
        <div className="min-w-0">
          <h3 id={id} className="text-[17px] font-bold tracking-[-0.01em]">
            {title}
          </h3>
          {subtitle ? <p className="text-[13px] text-text-2">{subtitle}</p> : null}
        </div>
        {trailing}
      </div>
      {layout === "scroll" ? (
        <ul className="no-scrollbar -mx-4 flex snap-x snap-mandatory scroll-px-4 gap-3 overflow-x-auto px-4 pb-1">
          {children}
        </ul>
      ) : (
        <ul className="flex flex-col gap-2">{children}</ul>
      )}
    </section>
  );
}

/** One card slot in a scrolling RecRow. */
export function RecSlot({ children }: { children: ReactNode }) {
  return <li className="flex w-[15.5rem] shrink-0 snap-start">{children}</li>;
}
