import { useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Chip } from "@/components/ui/chip";
import { Field, FormError } from "@/components/ui/field";
import { FieldSelect } from "@/components/ui/select";
import { SegmentedControl } from "@/components/ui/segmented";
import { Sheet } from "@/components/ui/sheet";
import { PLACE_KIND_OPTIONS, formatDistance, mapKeys, type ChipHub, type LngLat } from "@/lib/map";
import {
  addPlace,
  duplicateCandidates,
  placeErrorCode,
  placeErrorMessage,
  type DuplicateCandidate,
} from "@/lib/place-contributions";

/**
 * Add a place (§9 "Add place", §7 rules 1, 2 and 9): name and kind, up to three of the viewer's
 * hubs (none picked: the server picks hubs that show this kind), "Only me" by default or
 * "Everyone (reviewed first)" behind the confirmation, then the duplicate check. A public place
 * waits for a moderator and shows to its creator as a dashed pin.
 */
export function AddPlaceSheet({
  open,
  point,
  hubs,
  onClose,
  onAdded,
  onOpenPlace,
}: {
  open: boolean;
  point: LngLat | null;
  /** The viewer's joined hubs that take member places (not sensitive, not events only). */
  hubs: readonly ChipHub[];
  onClose: () => void;
  onAdded: (id: string) => void;
  onOpenPlace: (id: string) => void;
}) {
  return (
    <Sheet open={open && point !== null} onClose={onClose} title="Add a place">
      {point ? (
        <AddPlaceForm point={point} hubs={hubs} onAdded={onAdded} onOpenPlace={onOpenPlace} />
      ) : null}
    </Sheet>
  );
}

type Visibility = "private" | "public";

function AddPlaceForm({
  point,
  hubs,
  onAdded,
  onOpenPlace,
}: {
  point: LngLat;
  hubs: readonly ChipHub[];
  onAdded: (id: string) => void;
  onOpenPlace: (id: string) => void;
}) {
  const queryClient = useQueryClient();
  const [name, setName] = useState("");
  const [kind, setKind] = useState("");
  const [picked, setPicked] = useState<string[]>([]);
  const [visibility, setVisibility] = useState<Visibility>("private");
  const [confirmed, setConfirmed] = useState(false);
  const [website, setWebsite] = useState("");
  const [hours, setHours] = useState("");
  const [dups, setDups] = useState<DuplicateCandidate[]>([]);
  const [error, setError] = useState<string | null>(null);

  const add = useMutation({
    mutationFn: (allowDuplicate: boolean) =>
      addPlace({
        name,
        kind,
        lat: point.lat,
        lng: point.lng,
        hubIds: picked.length ? picked : undefined,
        isPublic: visibility === "public",
        confirmPublic: confirmed,
        website,
        hours,
        allowDuplicate,
      }),
    onSuccess: (r) => {
      void queryClient.invalidateQueries({ queryKey: mapKeys.all });
      toast.success(
        r.status === "pending"
          ? "Added. A moderator reviews it before anyone else sees it."
          : r.isPublic
            ? "Added to the map."
            : "Added. Only you can see it.",
      );
      onAdded(r.id);
    },
    onError: (err) => {
      const candidates = duplicateCandidates(err);
      if (candidates.length) {
        setDups(candidates);
        setError(null);
        return;
      }
      setError(placeErrorMessage(err));
      if (
        placeErrorCode(err) === "near_your_home" ||
        placeErrorCode(err) === "near_private_venue"
      ) {
        setVisibility("private");
        setConfirmed(false);
      }
    },
  });

  const trimmed = name.trim();
  const publicReady = visibility === "private" || confirmed;
  const canSubmit = trimmed.length >= 2 && kind !== "" && publicReady && !add.isPending;

  function toggleHub(id: string) {
    setPicked((prev) =>
      prev.includes(id) ? prev.filter((h) => h !== id) : prev.length < 3 ? [...prev, id] : prev,
    );
  }

  if (dups.length) {
    return (
      <div className="flex flex-col gap-4 pt-1">
        <p className="text-[15px]">
          {dups.length === 1 ? "There's a place like this" : "There are places like this"} right
          here. Is yours one of them?
        </p>
        <ul className="flex flex-col gap-1">
          {dups.map((d) => (
            <li key={d.id}>
              <button
                type="button"
                onClick={() => onOpenPlace(d.id)}
                className="flex min-h-12 w-full items-center justify-between gap-3 rounded-tile px-2 text-left hover:bg-surface-2"
              >
                <span className="min-w-0 truncate font-semibold">{d.name}</span>
                <span className="shrink-0 text-[13px] text-text-2">
                  {d.mine ? "Yours · " : ""}
                  {formatDistance(d.distanceM)}
                </span>
              </button>
            </li>
          ))}
        </ul>
        <div className="grid grid-cols-2 gap-2">
          <Button variant="secondary" onClick={() => setDups([])} disabled={add.isPending}>
            Back
          </Button>
          <Button loading={add.isPending} onClick={() => add.mutate(true)}>
            Mine is different
          </Button>
        </div>
      </div>
    );
  }

  return (
    <form
      className="flex flex-col gap-4 pt-1"
      onSubmit={(e) => {
        e.preventDefault();
        if (canSubmit) add.mutate(false);
      }}
    >
      <p className="text-[13px] text-text-2">
        The pin goes where the crosshair was. You can fix it later with a correction.
      </p>
      <FormError>{error}</FormError>
      <Field
        label="Name"
        value={name}
        maxLength={120}
        autoComplete="off"
        onChange={(e) => setName(e.target.value)}
        hint="What people call it, like “Riverside courts”."
        required
      />
      <FieldSelect label="Kind" value={kind} onChange={(e) => setKind(e.target.value)} required>
        <option value="" disabled>
          Pick one
        </option>
        {PLACE_KIND_OPTIONS.map((k) => (
          <option key={k.value} value={k.value}>
            {k.label}
          </option>
        ))}
      </FieldSelect>

      {hubs.length ? (
        <fieldset className="flex flex-col gap-1.5">
          <legend className="pb-1.5 text-[14px] font-semibold">Hubs (up to 3)</legend>
          <div className="flex flex-wrap gap-1.5">
            {hubs.map((h) => (
              <Chip
                key={h.id}
                selected={picked.includes(h.id)}
                leading={h.emoji}
                onClick={() => toggleHub(h.id)}
                disabled={!picked.includes(h.id) && picked.length >= 3}
              >
                {h.name}
              </Chip>
            ))}
          </div>
          <p className="text-[13px] text-text-2">
            {picked.length ? "" : "Leave these and we'll pick your hubs that fit this kind."}
          </p>
        </fieldset>
      ) : null}

      <div className="flex flex-col gap-1.5">
        <p className="text-[14px] font-semibold" id="add-place-visibility">
          Who can see it
        </p>
        <SegmentedControl
          label="Who can see it"
          value={visibility}
          onChange={(v) => {
            setVisibility(v);
            if (v === "private") setConfirmed(false);
          }}
          options={[
            { value: "private", label: "Only me" },
            { value: "public", label: "Everyone (reviewed first)" },
          ]}
        />
        {visibility === "public" ? (
          <label className="flex items-start gap-3 rounded-tile bg-surface-2 p-3 text-[14px]">
            <input
              type="checkbox"
              className="mt-0.5 size-5 shrink-0 accent-primary"
              checked={confirmed}
              onChange={(e) => setConfirmed(e.target.checked)}
            />
            <span>
              This is a public place, not a home or private residence. A moderator checks it before
              anyone else sees it.
            </span>
          </label>
        ) : (
          <p className="text-[13px] text-text-2">A pin only you can see. Change it any time.</p>
        )}
      </div>

      <Field
        label="Website (optional)"
        type="url"
        inputMode="url"
        value={website}
        maxLength={500}
        placeholder="https://"
        onChange={(e) => setWebsite(e.target.value)}
      />
      <Field
        label="Hours (optional)"
        value={hours}
        maxLength={255}
        placeholder="Mo-Fr 07:00-21:00"
        onChange={(e) => setHours(e.target.value)}
      />
      <Button type="submit" block loading={add.isPending} disabled={!canSubmit}>
        Add place
      </Button>
    </form>
  );
}
