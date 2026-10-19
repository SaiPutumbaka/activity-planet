import type { LucideIcon } from "lucide-react";

export function ComingSoon({
  icon: Icon,
  title,
  body,
}: {
  icon: LucideIcon;
  title: string;
  body: string;
}) {
  return (
    <main className="flex flex-col items-center gap-3 px-8 pt-20 text-center">
      <div className="flex size-16 items-center justify-center rounded-full bg-surface-2 text-text-2">
        <Icon className="size-7" aria-hidden="true" />
      </div>
      <h2 className="text-[20px] font-bold tracking-tight">{title}</h2>
      <p className="max-w-[32ch] text-[15px] text-text-2">{body}</p>
    </main>
  );
}
