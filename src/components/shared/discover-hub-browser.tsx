"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { Search } from "lucide-react";

import { HubJoinToggle } from "@/components/shared/hub-join-toggle";
import { Input } from "@/components/ui/input";
import { HUB_CATALOG } from "@/lib/hub-catalog";
import { hubToSlug } from "@/lib/hub-slug";
import type { Hub } from "@/types/database";

interface DiscoverHubBrowserProps {
  counts: Record<string, number>;
  myHubs: Hub[];
}

/**
 * Browse the full hub catalog (100+ entries) grouped by category with a
 * search filter — a flat grid of every hub stopped being usable once the
 * catalog grew past the original 8.
 */
export function DiscoverHubBrowser({ counts, myHubs }: DiscoverHubBrowserProps) {
  const [query, setQuery] = useState("");
  const memberSet = useMemo(() => new Set(myHubs), [myHubs]);
  const normalizedQuery = query.trim().toLowerCase();

  const groups = useMemo(() => {
    if (!normalizedQuery) {
      return HUB_CATALOG;
    }
    return HUB_CATALOG.map((group) => ({
      category: group.category,
      hubs: group.hubs.filter((entry) =>
        entry.name.toLowerCase().includes(normalizedQuery),
      ),
    })).filter((group) => group.hubs.length > 0);
  }, [normalizedQuery]);

  return (
    <div className="space-y-4">
      <div className="relative">
        <Search
          className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
          aria-hidden
        />
        <Input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Search hubs…"
          className="pl-9"
        />
      </div>

      {groups.length === 0 ? (
        <p className="py-6 text-center text-sm text-muted-foreground">
          No hubs match “{query}”.
        </p>
      ) : (
        <div className="space-y-5">
          {groups.map((group) => (
            <div key={group.category}>
              <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                {group.category}
              </p>
              <div className="space-y-1.5">
                {group.hubs.map((entry) => {
                  const count = counts[entry.name] ?? 0;
                  return (
                    <div
                      key={entry.name}
                      className="flex items-center justify-between gap-3 rounded-lg border px-3 py-2"
                    >
                      <Link
                        href={`/hubs/${hubToSlug(entry.name)}`}
                        className="flex min-w-0 flex-1 items-center gap-2.5"
                      >
                        <span aria-hidden>{entry.emoji}</span>
                        <span className="truncate text-sm font-medium">
                          {entry.name}
                        </span>
                        <span className="shrink-0 text-xs text-muted-foreground">
                          {count} member{count === 1 ? "" : "s"}
                        </span>
                      </Link>
                      <HubJoinToggle
                        hub={entry.name}
                        initialIsMember={memberSet.has(entry.name)}
                        size="sm"
                      />
                    </div>
                  );
                })}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
