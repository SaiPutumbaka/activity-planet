import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Lock, MapPin, Search } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Field, inputClassName } from "@/components/ui/field";
import { SegmentedControl } from "@/components/ui/segmented";
import { Spinner } from "@/components/ui/spinner";
import { Switch } from "@/components/ui/switch";
import { cn } from "@/lib/cn";
import { eventErrorMessage } from "@/lib/events";
import { useDebouncedValue } from "@/lib/use-debounced-value";
import {
  formatVenueAddress,
  geoapifyKey,
  geoapifyQuery,
  upsertVenue,
  venueSearchQuery,
  type GeoSuggestion,
  type VenueSearchResult,
} from "@/lib/venues";

/**
 * Where a plan happens: find a public place by name, add one (hand-typed, or picked from
 * Geoapify when the key is set), or just describe the spot. Holds the five location fields of
 * the event form as one value.
 */
export interface VenueValue {
  locationMode: "venue" | "text";
  venueId: string | null;
  venueName: string;
  venueIsPublic: boolean;
  locationText: string;
}

type Tab = "search" | "add" | "text";

const TABS: readonly { value: Tab; label: string }[] = [
  { value: "search", label: "Find a place" },
  { value: "add", label: "Add a place" },
  { value: "text", label: "Describe" },
];

export function VenuePicker({
  value,
  onChange,
  error,
  disabled,
}: {
  value: VenueValue;
  onChange: (next: VenueValue) => void;
  error?: string;
  disabled?: boolean;
}) {
  const [tab, setTab] = useState<Tab>(value.locationMode === "text" ? "text" : "search");

  function pickTab(next: Tab) {
    setTab(next);
    onChange({ ...value, locationMode: next === "text" ? "text" : "venue" });
  }

  function selectVenue(v: { id: string; name: string; is_public: boolean }) {
    onChange({
      ...value,
      locationMode: "venue",
      venueId: v.id,
      venueName: v.name,
      venueIsPublic: v.is_public,
    });
    setTab("search");
  }

  return (
    <div className="flex flex-col gap-3">
      <SegmentedControl value={tab} onChange={pickTab} options={TABS} label="Where" />

      {tab === "search" ? (
        value.venueId ? (
          <SelectedVenue
            name={value.venueName}
            isPublic={value.venueIsPublic}
            disabled={disabled}
            onChange={() => onChange({ ...value, venueId: null, venueName: "" })}
          />
        ) : (
          <VenueSearch
            onPick={selectVenue}
            onAddInstead={() => pickTab("add")}
            disabled={disabled}
          />
        )
      ) : tab === "add" ? (
        <AddPlaceForm onSaved={selectVenue} disabled={disabled} />
      ) : (
        <Field
          label="Where to meet"
          value={value.locationText}
          onChange={(e) =>
            onChange({ ...value, locationMode: "text", locationText: e.target.value })
          }
          placeholder="Hurt Park, by the fountain"
          hint="A spot people can find without an address."
          maxLength={200}
          autoComplete="off"
          disabled={disabled}
          error={error}
        />
      )}

      {error && tab !== "text" ? (
        <p role="alert" className="text-[13px] font-medium text-danger">
          {error}
        </p>
      ) : null}
    </div>
  );
}

function SelectedVenue({
  name,
  isPublic,
  disabled,
  onChange,
}: {
  name: string;
  isPublic: boolean;
  disabled?: boolean;
  onChange: () => void;
}) {
  return (
    <div className="flex items-center gap-3 rounded-input border border-border bg-surface-2 px-4 py-3">
      <MapPin className="size-5 shrink-0 text-text-2" aria-hidden="true" />
      <div className="min-w-0 flex-1">
        <p className="truncate text-[15px] font-semibold">{name}</p>
        <p className="flex items-center gap-1 text-[13px] text-text-2">
          {isPublic ? (
            "Public place"
          ) : (
            <>
              <Lock className="size-3.5" aria-hidden="true" />
              Private address, shared after you approve
            </>
          )}
        </p>
      </div>
      <Button variant="ghost" size="sm" onClick={onChange} disabled={disabled}>
        Change
      </Button>
    </div>
  );
}

function VenueSearch({
  onPick,
  onAddInstead,
  disabled,
}: {
  onPick: (v: VenueSearchResult) => void;
  onAddInstead: () => void;
  disabled?: boolean;
}) {
  const [text, setText] = useState("");
  const debounced = useDebouncedValue(text, 300);
  const results = useQuery(venueSearchQuery(debounced));
  const searching = debounced.trim().length >= 2;

  return (
    <div className="flex flex-col gap-2">
      <div className="relative">
        <Search
          className="pointer-events-none absolute inset-y-0 left-4 my-auto size-5 text-text-3"
          aria-hidden="true"
        />
        <input
          type="search"
          className={cn(inputClassName, "pl-11")}
          placeholder="Search places by name"
          value={text}
          onChange={(e) => setText(e.target.value)}
          aria-label="Search places"
          autoComplete="off"
          disabled={disabled}
        />
      </div>
      {!searching ? (
        <p className="text-[13px] text-text-2">
          Parks, courts, cafés and campus buildings other hosts have used.
        </p>
      ) : results.isPending ? (
        <div className="flex items-center gap-2 py-2 text-[13px] text-text-3">
          <Spinner className="size-4" /> Searching
        </div>
      ) : results.isError ? (
        <p role="alert" className="text-[13px] font-medium text-danger">
          Couldn't search places. Check your connection and try again.
        </p>
      ) : results.data.length === 0 ? (
        <p className="text-[13px] text-text-2">
          No place called “{debounced.trim()}” yet.{" "}
          <button
            type="button"
            onClick={onAddInstead}
            className="font-semibold text-primary-text underline-offset-2 hover:underline"
          >
            Add it
          </button>
          .
        </p>
      ) : (
        <ul className="divide-y divide-border overflow-hidden rounded-input border border-border">
          {results.data.map((v) => (
            <li key={v.id}>
              <button
                type="button"
                onClick={() => onPick(v)}
                disabled={disabled}
                className="flex min-h-11 w-full items-center gap-3 px-4 py-2.5 text-left hover:bg-surface-2"
              >
                <MapPin className="size-5 shrink-0 text-text-3" aria-hidden="true" />
                <span className="min-w-0">
                  <span className="block truncate text-[15px] font-semibold">{v.name}</span>
                  <span className="block truncate text-[13px] text-text-2">
                    {formatVenueAddress(v) || "No address on file"}
                  </span>
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function AddPlaceForm({
  onSaved,
  disabled,
}: {
  onSaved: (v: { id: string; name: string; is_public: boolean }) => void;
  disabled?: boolean;
}) {
  const [name, setName] = useState("");
  const [address1, setAddress1] = useState("");
  const [city, setCity] = useState("Atlanta");
  const [state, setState] = useState("GA");
  const [postal, setPostal] = useState("");
  const [isPublic, setIsPublic] = useState(false);
  const [picked, setPicked] = useState<GeoSuggestion | null>(null);
  const [nameError, setNameError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const debounced = useDebouncedValue(address1, 400);
  const suggestions = useQuery(geoapifyQuery(picked ? "" : debounced));

  function applySuggestion(s: GeoSuggestion) {
    setPicked(s);
    setAddress1(s.address_line1);
    setCity(s.city);
    setState(s.state);
    setPostal(s.postal_code);
    setIsPublic(true);
    if (!name.trim()) setName(s.name);
  }

  async function save() {
    const trimmed = name.trim();
    if (!trimmed) {
      setNameError("Give the place a name.");
      return;
    }
    setNameError(null);
    setSaving(true);
    try {
      const venue = await upsertVenue({
        name: trimmed,
        address_line1: address1.trim(),
        city: city.trim(),
        state: state.trim(),
        postal_code: postal.trim(),
        country: picked?.country ?? "US",
        ...(picked ? { lat: picked.lat, lng: picked.lng, place_id: picked.place_id } : {}),
        is_public: isPublic,
      });
      toast.success(`${venue.name} saved.`);
      onSaved(venue);
    } catch (err) {
      toast.error(eventErrorMessage(err));
    } finally {
      setSaving(false);
    }
  }

  const busy = disabled || saving;

  return (
    <div className="flex flex-col gap-4 rounded-input border border-border p-4">
      <Field
        label="Place name"
        value={name}
        onChange={(e) => {
          setName(e.target.value);
          setNameError(null);
        }}
        placeholder="Piedmont Park, Classroom South 200"
        maxLength={120}
        autoComplete="off"
        disabled={busy}
        error={nameError ?? undefined}
      />
      <div className="flex flex-col gap-1.5">
        <Field
          label="Address line 1"
          value={address1}
          onChange={(e) => {
            setAddress1(e.target.value);
            setPicked(null);
          }}
          placeholder="25 Park Pl NE"
          maxLength={200}
          autoComplete="street-address"
          disabled={busy}
          hint={geoapifyKey ? "Start typing and pick a match to place it on the map." : undefined}
        />
        {geoapifyKey && !picked && suggestions.data && suggestions.data.length > 0 ? (
          <ul className="divide-y divide-border overflow-hidden rounded-input border border-border">
            {suggestions.data.map((s) => (
              <li key={s.place_id}>
                <button
                  type="button"
                  onClick={() => applySuggestion(s)}
                  disabled={busy}
                  className="flex min-h-11 w-full items-center gap-3 px-4 py-2 text-left text-[14px] hover:bg-surface-2"
                >
                  <MapPin className="size-4 shrink-0 text-text-3" aria-hidden="true" />
                  <span className="truncate">{s.label}</span>
                </button>
              </li>
            ))}
          </ul>
        ) : null}
      </div>
      <div className="grid grid-cols-[1fr_72px] gap-3">
        <Field
          label="City"
          value={city}
          onChange={(e) => setCity(e.target.value)}
          maxLength={80}
          autoComplete="address-level2"
          disabled={busy}
        />
        <Field
          label="State"
          value={state}
          onChange={(e) => setState(e.target.value.toUpperCase())}
          maxLength={2}
          autoCapitalize="characters"
          autoComplete="address-level1"
          disabled={busy}
        />
      </div>
      <Field
        label="Postal code"
        value={postal}
        onChange={(e) => setPostal(e.target.value)}
        inputMode="numeric"
        maxLength={20}
        autoComplete="postal-code"
        disabled={busy}
        className="max-w-[160px]"
      />
      <Switch
        label="Public place"
        hint="On for a park, café or campus building. Off keeps a home address private: it goes only to people you approve."
        checked={isPublic}
        onCheckedChange={setIsPublic}
        disabled={busy}
      />
      <Button variant="secondary" onClick={save} loading={saving} disabled={disabled}>
        Save place
      </Button>
    </div>
  );
}
