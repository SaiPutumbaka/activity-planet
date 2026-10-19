"use client";

import { useMemo, useState } from "react";
import { Search, X } from "lucide-react";
import { toast } from "sonner";

import { Input } from "@/components/ui/input";
import { HUB_CATALOG } from "@/lib/hub-catalog";
import { cn } from "@/lib/utils";
import type { Hub } from "@/types/database";

type HubPickerProps =
  | {
      mode: "multi";
      value: Hub[];
      onChange: (value: Hub[]) => void;
      max: number;
      className?: string;
    }
  | {
      mode: "single";
      value: Hub | undefined;
      onChange: (value: Hub) => void;
      className?: string;
    };

function ChipButton({
  hub,
  emoji,
  isSelected,
  onClick,
}: {
  hub: Hub;
  emoji: string;
  isSelected: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      aria-pressed={isSelected}
      onClick={onClick}
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-sm font-medium transition-colors",
        "hover:bg-accent hover:text-accent-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
        isSelected
          ? "border-primary bg-primary/10 text-primary"
          : "border-border text-foreground",
      )}
    >
      <span aria-hidden>{emoji}</span>
      {hub}
    </button>
  );
}

/**
 * Searchable, categorized picker over the full hub catalog (500+ entries) —
 * a flat grid stopped being usable once the catalog grew past the original
 * 8 hubs. Used in single mode (create-event's category field) and multi
 * mode (onboarding, profile hub management).
 */
export function HubPicker(props: HubPickerProps) {
  const { mode, value, onChange, className } = props;
  const [query, setQuery] = useState("");

  const normalizedQuery = query.trim().toLowerCase();
  const filteredCatalog = useMemo(() => {
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

  function isSelected(hub: Hub): boolean {
    return mode === "multi" ? value.includes(hub) : value === hub;
  }

  function handleToggle(hub: Hub) {
    if (mode === "single") {
      onChange(hub);
      return;
    }

    const current = value;
    if (current.includes(hub)) {
      onChange(current.filter((h) => h !== hub));
      return;
    }
    if (current.length >= props.max) {
      toast.error(`You can pick up to ${props.max} hubs — remove one first.`);
      return;
    }
    onChange([...current, hub]);
  }

  return (
    <div className={cn("space-y-3", className)}>
      {mode === "multi" && value.length > 0 ? (
        <div className="flex flex-wrap gap-1.5 rounded-lg border bg-muted/40 p-2">
          {value.map((hub) => (
            <span
              key={hub}
              className="inline-flex items-center gap-1 rounded-full bg-primary px-2.5 py-1 text-xs font-medium text-primary-foreground"
            >
              {hub}
              <button
                type="button"
                onClick={() => onChange(value.filter((h) => h !== hub))}
                aria-label={`Remove ${hub}`}
                className="rounded-full hover:opacity-75"
              >
                <X className="h-3 w-3" aria-hidden />
              </button>
            </span>
          ))}
        </div>
      ) : null}

      <div className="relative">
        <Search
          className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
          aria-hidden
        />
        <Input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Search sports, games, hobbies…"
          className="pl-9"
        />
      </div>

      <div className="max-h-72 space-y-4 overflow-y-auto rounded-lg border p-3">
        {filteredCatalog.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted-foreground">
            No hobbies match “{query}”.
          </p>
        ) : (
          filteredCatalog.map((group) => (
            <div key={group.category}>
              <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                {group.category}
              </p>
              <div className="flex flex-wrap gap-2">
                {group.hubs.map((entry) => (
                  <ChipButton
                    key={entry.name}
                    hub={entry.name}
                    emoji={entry.emoji}
                    isSelected={isSelected(entry.name)}
                    onClick={() => handleToggle(entry.name)}
                  />
                ))}
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
