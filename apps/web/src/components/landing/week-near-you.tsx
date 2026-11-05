"use client";

import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent } from "react";
import { LANDING_FALLBACK_CITY, landingPoint, parseWeekCards, type WeekCard } from "@ap/core/recs";
import { STARTER_CITIES, searchStarterCities, type StarterCity } from "@ap/core/places";

import { WeekCardView } from "./week-card";

const CITY_KEY = "ap-landing-city";

type Origin =
  | { kind: "default" }
  | { kind: "city"; city: StarterCity }
  | { kind: "device"; lat: number; lng: number };

function cityLabel(c: StarterCity): string {
  return [c.name, c.region && c.region !== c.name ? c.region : null, c.country]
    .filter(Boolean)
    .join(", ");
}

function readSavedCity(): StarterCity | null {
  try {
    const id = localStorage.getItem(CITY_KEY);
    return id ? (STARTER_CITIES.find((c) => c.id === id) ?? null) : null;
  } catch {
    return null;
  }
}

function saveCity(id: string | null) {
  try {
    if (id) localStorage.setItem(CITY_KEY, id);
    else localStorage.removeItem(CITY_KEY);
  } catch {
    /* no memory in this browser: the pick lasts for this visit */
  }
}

/**
 * The client island of "This week near you". It starts from the server's Atlanta cards and swaps
 * them, without a reload, for a picked city (a combobox over the starter cities, remembered by
 * id) or for the visitor's own area after they tap "Use my location". The browser rounds that
 * point to 0.1 degree (about 11 km) before asking, and it is never stored. No IP lookup.
 */
export function WeekNearYou({
  initialCards,
  appUrl,
}: {
  initialCards: WeekCard[] | null;
  appUrl: string;
}) {
  const [origin, setOrigin] = useState<Origin>({ kind: "default" });
  const [cards, setCards] = useState<WeekCard[] | null>(initialCards);
  const [loading, setLoading] = useState(false);
  const [locating, setLocating] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const request = useRef(0);

  async function load(next: Origin) {
    setOrigin(next);
    setNote(null);
    const id = ++request.current;
    const point =
      next.kind === "city"
        ? landingPoint(next.city.lat, next.city.lng)
        : next.kind === "device"
          ? landingPoint(next.lat, next.lng)
          : null;
    if (!point && initialCards) {
      setCards(initialCards);
      return;
    }
    setLoading(true);
    try {
      const res = await fetch(point ? `/api/week?lat=${point.lat}&lng=${point.lng}` : "/api/week");
      if (!res.ok) throw new Error(String(res.status));
      const body: unknown = await res.json();
      if (id !== request.current) return;
      const raw = body && typeof body === "object" && "cards" in body ? body.cards : null;
      setCards(parseWeekCards(raw));
    } catch {
      if (id !== request.current) return;
      setCards(null);
    } finally {
      if (id === request.current) setLoading(false);
    }
  }

  // A city picked on an earlier visit. Read after mount so the server render stays Atlanta.
  useEffect(() => {
    const saved = readSavedCity();
    if (!saved) return;
    const t = window.setTimeout(() => void load({ kind: "city", city: saved }), 0);
    return () => window.clearTimeout(t);
    // Only once, on mount.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function pickCity(city: StarterCity | null) {
    saveCity(city?.id ?? null);
    void load(city ? { kind: "city", city } : { kind: "default" });
  }

  function locateMe() {
    if (!("geolocation" in navigator)) {
      setNote("This browser can't share a location. Pick your city instead.");
      return;
    }
    setLocating(true);
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        setLocating(false);
        const p = landingPoint(pos.coords.latitude, pos.coords.longitude);
        if (p) void load({ kind: "device", lat: p.lat, lng: p.lng });
      },
      (err) => {
        setLocating(false);
        setNote(
          err.code === err.PERMISSION_DENIED
            ? "Location is off for this site. Pick your city instead."
            : "Couldn't find your location. Pick your city instead.",
        );
      },
      { enableHighAccuracy: false, maximumAge: 10 * 60_000, timeout: 15_000 },
    );
  }

  const place =
    origin.kind === "city"
      ? origin.city.name
      : origin.kind === "device"
        ? "you"
        : LANDING_FALLBACK_CITY;
  const status =
    origin.kind === "default"
      ? `Showing plans around ${LANDING_FALLBACK_CITY}. Pick your city to see yours.`
      : origin.kind === "device"
        ? "Showing plans near you."
        : `Showing plans around ${origin.city.name}.`;

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-end">
        <CityCombobox selected={origin.kind === "city" ? origin.city : null} onPick={pickCity} />
        <button
          type="button"
          onClick={locateMe}
          disabled={locating}
          className="inline-flex h-11 shrink-0 items-center justify-center gap-2 rounded-control border border-border-strong bg-surface px-4 text-[15px] font-semibold text-text hover:bg-surface-2 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-link disabled:opacity-60"
        >
          <LocateIcon />
          {locating ? "Finding you…" : "Use my location"}
        </button>
      </div>
      <p className="text-[14px] text-text-2" role="status" aria-live="polite">
        {loading ? "Loading plans…" : (note ?? status)}
      </p>

      {cards === null ? (
        <p className="rounded-card border border-border bg-surface-2 p-4 text-[15px] text-text-2">
          Couldn&apos;t load this week&apos;s plans right now. Try again in a moment, or{" "}
          <a href={appUrl} className="font-semibold text-link underline underline-offset-2">
            open the app
          </a>
          .
        </p>
      ) : cards.length === 0 ? (
        <div className="flex flex-col items-start gap-3 rounded-card border border-border bg-surface-2 p-5">
          <p className="text-[16px] font-semibold text-text">
            Nothing posted near {place} this week yet. Be the first: post a plan in the app.
          </p>
          <a
            href={`${appUrl.replace(/\/$/, "")}/post`}
            className="inline-flex h-11 items-center rounded-control bg-primary px-5 text-[15px] font-semibold text-on-primary"
          >
            Post a plan
          </a>
        </div>
      ) : (
        <ul
          className={`grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3 ${loading ? "opacity-60" : ""}`}
          aria-label="Plans this week"
          aria-busy={loading}
        >
          {cards.map((c) => (
            <WeekCardView key={c.id} card={c} />
          ))}
        </ul>
      )}
    </div>
  );
}

function LocateIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="18"
      height="18"
      aria-hidden="true"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
    >
      <circle cx="12" cy="12" r="7" />
      <circle cx="12" cy="12" r="2.5" fill="currentColor" />
      <path d="M12 2v3M12 19v3M2 12h3M19 12h3" />
    </svg>
  );
}

/**
 * A labelled combobox over the starter cities (WAI-ARIA combobox with a listbox popup): type to
 * filter, arrows to move, Enter to pick, Escape to close. "Atlanta" is always offered as the
 * default area.
 */
function CityCombobox({
  selected,
  onPick,
}: {
  selected: StarterCity | null;
  onPick: (city: StarterCity | null) => void;
}) {
  const id = useId();
  const [text, setText] = useState("");
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);

  const options = useMemo(() => {
    const q = text.trim();
    const found = q ? searchStarterCities(q, STARTER_CITIES, 8) : STARTER_CITIES.slice(0, 8);
    const atlanta = !q || LANDING_FALLBACK_CITY.toLowerCase().startsWith(q.toLowerCase());
    return [...(atlanta ? [null] : []), ...found] as (StarterCity | null)[];
  }, [text]);

  function choose(city: StarterCity | null) {
    setText("");
    setOpen(false);
    onPick(city);
  }

  function onKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setOpen(true);
      setActive((a) => Math.min(a + 1, options.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setActive((a) => Math.max(a - 1, 0));
    } else if (e.key === "Enter" && open && options.length > 0) {
      e.preventDefault();
      choose(options[Math.min(active, options.length - 1)] ?? null);
    } else if (e.key === "Escape") {
      setOpen(false);
    }
  }

  const listId = `${id}-list`;
  const optionId = (i: number) => `${id}-opt-${i}`;
  return (
    <div className="relative min-w-0 flex-1">
      <label htmlFor={`${id}-input`} className="mb-1.5 block text-[14px] font-semibold text-text">
        Your city
      </label>
      <input
        id={`${id}-input`}
        type="text"
        role="combobox"
        aria-expanded={open}
        aria-controls={listId}
        aria-autocomplete="list"
        aria-activedescendant={open && options.length > 0 ? optionId(active) : undefined}
        autoComplete="off"
        placeholder={selected ? cityLabel(selected) : `${LANDING_FALLBACK_CITY} (pick yours)`}
        value={text}
        onChange={(e) => {
          setText(e.target.value);
          setActive(0);
          setOpen(true);
        }}
        onFocus={() => setOpen(true)}
        onBlur={() => setTimeout(() => setOpen(false), 120)}
        onKeyDown={onKeyDown}
        className="h-11 w-full rounded-input border border-border-strong bg-surface px-3.5 text-[16px] text-text placeholder:text-text-2 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-link"
      />
      {open ? (
        <ul
          id={listId}
          role="listbox"
          aria-label="Cities"
          className="absolute inset-x-0 top-full z-20 mt-1 max-h-72 overflow-y-auto rounded-input border border-border bg-surface py-1 shadow-[var(--shadow-lift)]"
        >
          {options.length === 0 ? (
            <li className="px-3.5 py-2.5 text-[14px] text-text-2" role="presentation">
              No match yet. Try a bigger city nearby, or use your location.
            </li>
          ) : (
            options.map((c, i) => (
              <li
                key={c?.id ?? "default"}
                id={optionId(i)}
                role="option"
                aria-selected={i === active}
                onMouseDown={(e) => {
                  e.preventDefault();
                  choose(c);
                }}
                onMouseEnter={() => setActive(i)}
                className={`cursor-pointer px-3.5 py-2.5 text-[15px] ${i === active ? "bg-surface-2" : ""}`}
              >
                {c ? cityLabel(c) : `${LANDING_FALLBACK_CITY}, Georgia, United States`}
              </li>
            ))
          )}
        </ul>
      ) : null}
    </div>
  );
}
