import { Search, X } from "lucide-react";

import { inputClassName } from "@/components/ui/field";
import { cn } from "@/lib/cn";

/**
 * The search field that sticks under the TopBar on the Hubs tab. 16 px text so iOS does not zoom;
 * the native WebKit clear button is hidden in favour of a 44 px one.
 */
export function HubSearch({
  value,
  onChange,
  total,
}: {
  value: string;
  onChange: (value: string) => void;
  /** How many hubs there are, for the placeholder. */
  total: number;
}) {
  return (
    <div className="sticky top-[calc(56px+env(safe-area-inset-top,0px))] z-10 -mx-4 bg-surface px-4 pt-1 pb-3">
      <div className="relative">
        <Search
          className="pointer-events-none absolute inset-y-0 left-4 my-auto size-5 text-text-3"
          aria-hidden="true"
        />
        <input
          type="search"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          className={cn(
            inputClassName,
            "pr-12 pl-11 [&::-webkit-search-cancel-button]:appearance-none",
          )}
          placeholder={total > 0 ? `Search ${total} hubs` : "Search hubs"}
          aria-label="Search hubs"
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="none"
          spellCheck={false}
          enterKeyHint="search"
        />
        {value ? (
          <button
            type="button"
            onClick={() => onChange("")}
            aria-label="Clear search"
            className="absolute inset-y-0 right-0.5 my-auto flex size-11 items-center justify-center rounded-full text-text-2 hover:bg-surface-2"
          >
            <X className="size-5" aria-hidden="true" />
          </button>
        ) : null}
      </div>
    </div>
  );
}
