import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Check, LocateFixed, MapPin, Search } from "lucide-react";
import { formatKmRough } from "@ap/core/locale";
import {
  normalizePlaceText,
  placeMatchScore,
  searchStarterCities,
  starterCityLabel,
} from "@ap/core/places";

import { Button } from "@/components/ui/button";
import { inputClassName } from "@/components/ui/field";
import { Spinner } from "@/components/ui/spinner";
import { cn } from "@/lib/cn";
import {
  areasQuery,
  citySearchQuery,
  hasCitySearch,
  isIos,
  requestRoughPosition,
  useLocationDenied,
  type Area,
  type HomeChoice,
} from "@/lib/location";
import { DISTANCE_UNIT } from "@/lib/units";
import { useDebouncedValue } from "@/lib/use-debounced-value";

import { LocationHowToSheet } from "./location-how-to";

/** A named area as a choice: a neighborhood carries its city ("Midtown, Atlanta"). */
function areaChoice(a: Area, all: readonly Area[]): HomeChoice {
  const parent = a.parent_id ? all.find((p) => p.id === a.parent_id) : undefined;
  return {
    kind: "area",
    key: `area:${a.id}`,
    areaId: a.id,
    label: parent ? `${a.name}, ${parent.name}` : a.name,
  };
}

/**
 * Pick a home anywhere (D-040): "Use my location" (asked only on this tap, rounded to about 1 km)
 * or a search for a city or neighborhood. With VITE_GEOAPIFY_KEY the search is Geoapify's city
 * autocomplete; without it, a starter list of major world cities. Named areas from the areas table
 * (seeded neighborhoods) match too. Picking calls `onPick`; saving is the caller's job.
 */
export function HomePicker({
  selectedKey,
  onPick,
  busy = false,
  locateLabel = "Use my location",
  autoFocus = false,
}: {
  selectedKey: string | null;
  onPick: (choice: HomeChoice) => void;
  busy?: boolean;
  locateLabel?: string;
  autoFocus?: boolean;
}) {
  const areas = useQuery(areasQuery);
  const denied = useLocationDenied();
  const [query, setQuery] = useState("");
  const [locating, setLocating] = useState(false);
  const [locateMessage, setLocateMessage] = useState<string | null>(null);
  const [howToOpen, setHowToOpen] = useState(false);

  const debounced = useDebouncedValue(query, 300);
  const remote = useQuery(citySearchQuery(debounced));

  const results = useMemo<HomeChoice[]>(() => {
    const q = query.trim();
    if (!q) return [];
    const allAreas = areas.data ?? [];
    const areaMatches = allAreas
      .map((a) => ({ a, score: placeMatchScore(q, [a.name]) }))
      .filter((x) => x.score > 0)
      .sort((x, y) => y.score - x.score)
      .slice(0, 4)
      .map((x) => areaChoice(x.a, allAreas));
    const areaNames = new Set(
      areaMatches.map((c) => normalizePlaceText((c.label ?? "").split(",")[0] ?? "")),
    );

    const useRemote = hasCitySearch && remote.isSuccess && debounced.trim() === q && q.length >= 3;
    const cities: HomeChoice[] = useRemote
      ? remote.data
          .filter((p) => !areaNames.has(normalizePlaceText(p.name)))
          .map((p) => ({
            kind: "point",
            key: `geo:${p.id}`,
            lat: p.lat,
            lng: p.lng,
            label: p.label,
          }))
      : searchStarterCities(q).map((c) => ({
          kind: "point",
          key: `city:${c.id}`,
          lat: c.lat,
          lng: c.lng,
          label: starterCityLabel(c),
        }));
    return [...areaMatches, ...cities].slice(0, 10);
  }, [query, debounced, areas.data, remote.isSuccess, remote.data]);

  const searching =
    hasCitySearch && query.trim().length >= 3 && (debounced !== query || remote.isFetching);

  async function onLocate() {
    setLocating(true);
    setLocateMessage(null);
    try {
      const { result, point } = await requestRoughPosition();
      if (result === "granted" && point) {
        onPick({ kind: "point", key: "device", lat: point.lat, lng: point.lng, label: null });
      } else if (result === "denied") {
        setLocateMessage(
          "Location is turned off for this site. Search for your city instead, or allow location in your browser settings.",
        );
        if (isIos()) setHowToOpen(true);
      } else {
        setLocateMessage("Couldn't find your location. Search for your city instead.");
      }
    } finally {
      setLocating(false);
    }
  }

  return (
    <div className="flex flex-col gap-3">
      <Button
        variant={selectedKey === "device" ? "secondary" : "outline"}
        block
        loading={locating}
        disabled={busy}
        onClick={() => void onLocate()}
        aria-pressed={selectedKey === "device"}
      >
        {selectedKey === "device" ? (
          <Check className="size-5" aria-hidden="true" />
        ) : (
          <LocateFixed className="size-5" aria-hidden="true" />
        )}
        {selectedKey === "device" ? "Using your current location" : locateLabel}
      </Button>
      <p className="text-[13px] text-text-2" role={locateMessage ? "status" : undefined}>
        {locateMessage ??
          (denied
            ? "Location is turned off for this site. Search for your city below."
            : `We keep only a rough spot (about ${formatKmRough(1, DISTANCE_UNIT)}). It's never shown on your profile.`)}
      </p>

      <div className="relative">
        <Search
          className="pointer-events-none absolute inset-y-0 left-4 my-auto size-5 text-text-3"
          aria-hidden="true"
        />
        <input
          type="search"
          className={cn(inputClassName, "pl-11")}
          placeholder="Search for your city or neighborhood"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search for your city or neighborhood"
          autoComplete="address-level2"
          autoCapitalize="words"
          autoCorrect="off"
          spellCheck={false}
          maxLength={80}
          autoFocus={autoFocus}
          disabled={busy}
        />
        {searching ? (
          <Spinner className="absolute inset-y-0 right-4 my-auto size-4 text-text-3" />
        ) : null}
      </div>

      {query.trim() ? (
        results.length > 0 ? (
          <div role="radiogroup" aria-label="Places" className="flex flex-col gap-2">
            {results.map((c) => (
              <PlaceRow
                key={c.key}
                label={c.label ?? ""}
                checked={c.key === selectedKey}
                disabled={busy}
                onSelect={() => onPick(c)}
              />
            ))}
          </div>
        ) : searching ? null : (
          <p className="text-[14px] text-text-2">
            {hasCitySearch
              ? `No city matches “${query.trim()}”. Check the spelling, or use your location.`
              : `“${query.trim()}” isn't on our list yet. Try the nearest big city, or use your location.`}
          </p>
        )
      ) : null}
      <LocationHowToSheet open={howToOpen} onClose={() => setHowToOpen(false)} />
    </div>
  );
}

function PlaceRow({
  label,
  checked,
  disabled,
  onSelect,
}: {
  label: string;
  checked: boolean;
  disabled: boolean;
  onSelect: () => void;
}) {
  const [first, ...rest] = label.split(", ");
  return (
    <button
      type="button"
      role="radio"
      aria-checked={checked}
      disabled={disabled}
      onClick={onSelect}
      className={cn(
        "flex items-center gap-3 rounded-input border px-4 py-3 text-left transition-colors disabled:opacity-60",
        checked ? "border-primary bg-primary-tint" : "border-border bg-surface hover:bg-surface-2",
      )}
    >
      <MapPin className="size-5 shrink-0 text-text-3" aria-hidden="true" />
      <span className="min-w-0 flex-1">
        <span className="block truncate text-[15px] font-semibold">{first}</span>
        {rest.length > 0 ? (
          <span className="block truncate text-[13px] text-text-2">{rest.join(", ")}</span>
        ) : null}
      </span>
      {checked ? <Check className="size-5 shrink-0 text-primary-text" aria-hidden="true" /> : null}
    </button>
  );
}
