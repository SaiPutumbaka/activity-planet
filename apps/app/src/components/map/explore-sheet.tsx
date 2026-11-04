import { useMemo, useState } from "react";
import { Search } from "lucide-react";

import { inputClassName } from "@/components/ui/field";
import { Sheet } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/cn";
import { categoryTone, hubMatches, normalizeSearch } from "@/lib/hubs";
import type { CatalogCategory, CatalogHub } from "@/lib/profile";

const MAX_RESULTS = 40;

/**
 * "+ Explore" (§9): preview any hub on the map without joining it. Signed-out visitors use the
 * same sheet to pick hubs, since the map has no joined hubs to default to for them.
 */
export function ExploreSheet({
  open,
  onClose,
  hubs,
  categories,
  loading,
  onPick,
}: {
  open: boolean;
  onClose: () => void;
  hubs: readonly CatalogHub[];
  categories: readonly CatalogCategory[];
  loading: boolean;
  onPick: (hub: CatalogHub) => void;
}) {
  const [q, setQ] = useState("");
  const cats = useMemo(() => new Map(categories.map((c) => [c.slug, c] as const)), [categories]);
  const results = useMemo(() => {
    const needle = normalizeSearch(q);
    const list = needle
      ? hubs.filter((h) => hubMatches(h, cats.get(h.category_slug)?.name ?? "", needle))
      : hubs.filter((h) => h.is_featured).concat(hubs.filter((h) => !h.is_featured));
    return list.slice(0, MAX_RESULTS);
  }, [hubs, q, cats]);

  return (
    <Sheet open={open} onClose={onClose} title="See a hub on the map">
      <div className="sticky top-0 z-10 bg-surface pb-3">
        <div className="relative">
          <Search
            className="pointer-events-none absolute inset-y-0 left-4 my-auto size-5 text-text-3"
            aria-hidden="true"
          />
          <input
            type="search"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            className={cn(inputClassName, "pl-11")}
            placeholder="Basketball, anime, chess..."
            aria-label="Search hubs"
            autoComplete="off"
            enterKeyHint="search"
          />
        </div>
      </div>
      {loading ? (
        <div className="flex flex-col gap-2">
          <Skeleton className="h-12 w-full" />
          <Skeleton className="h-12 w-full" />
        </div>
      ) : results.length === 0 ? (
        <p className="py-6 text-center text-text-2">No hub matches that.</p>
      ) : (
        <ul className="flex flex-col">
          {results.map((h) => (
            <li key={h.id}>
              <button
                type="button"
                onClick={() => onPick(h)}
                className="flex min-h-12 w-full items-center gap-3 rounded-tile px-1 text-left hover:bg-surface-2"
              >
                <span
                  aria-hidden="true"
                  className={cn(
                    "flex size-9 items-center justify-center rounded-full text-[17px]",
                    categoryTone(cats.get(h.category_slug)?.color_key),
                  )}
                >
                  {h.emoji}
                </span>
                <span className="min-w-0 flex-1 truncate font-semibold">{h.name}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </Sheet>
  );
}
