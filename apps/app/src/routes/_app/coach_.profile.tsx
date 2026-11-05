import { useMemo, useRef, useState } from "react";
import { createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ImagePlus, LocateFixed, Trash, X } from "lucide-react";
import { toast } from "sonner";
import {
  coachingErrorCode,
  coachingErrorMessage,
  type Coach,
  type CredentialInput,
} from "@ap/core/coaching";

import { Note, SectionTitle } from "@/components/coaching/parts";
import { GuidelinesSheet } from "@/components/events/guidelines-sheet";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { Field, FormError } from "@/components/ui/field";
import { FieldSelect } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import { FieldTextArea } from "@/components/ui/textarea";
import {
  avatarErrorMessage,
  prepareAvatar,
  removeCoachPhoto,
  uploadCoachPhoto,
} from "@/lib/avatar";
import {
  coachTermsUrl,
  coaching,
  coachQuery,
  coachingConfigQuery,
  coachingKeys,
  myCoachStatusQuery,
  zoneOptions,
} from "@/lib/coaching";
import { viewerZone } from "@/lib/datetime";
import { acceptGuidelines } from "@/lib/events";
import { useFeedOrigin, type DevicePoint } from "@/lib/location";
import { hubCatalogQuery } from "@/lib/profile";
import { SITE_URL } from "@/lib/site";

const appRoute = getRouteApi("/_app");

/**
 * Become a coach / edit the coach profile (design sections 2, 3.2 and 15): headline, about, time
 * zone, in person (a point rounded by the server and a radius, never shown) and/or online, the
 * public area label, self-reported credentials, photos, hubs and the Coach Terms. The server
 * checks everything again (section 2's rules answer by code).
 */
export const Route = createFileRoute("/_app/coach_/profile")({
  component: CoachProfilePage,
});

function CoachProfilePage() {
  const { session, profile } = appRoute.useRouteContext();
  const status = useQuery(myCoachStatusQuery(session.user.id));
  const coach = useQuery({ ...coachQuery(profile.handle), enabled: status.data != null });
  const loading = status.isPending || (status.data != null && coach.isPending);
  return (
    <>
      <TopBar title={status.data ? "Coach profile" : "Become a coach"} back />
      <main className="flex flex-col gap-6 pb-8 safe-px">
        {loading ? (
          <Skeleton className="mt-2 h-60" />
        ) : (
          <ProfileForm
            userId={session.user.id}
            existing={status.data ? (coach.data ?? null) : null}
          />
        )}
      </main>
    </>
  );
}

const RADII = [5, 10, 25, 50];

function ProfileForm({ userId, existing }: { userId: string; existing: Coach | null }) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const config = useQuery(coachingConfigQuery);
  const catalog = useQuery(hubCatalogQuery);
  const origin = useFeedOrigin(userId);
  const [headline, setHeadline] = useState(existing?.headline ?? "");
  const [about, setAbout] = useState(existing?.about ?? "");
  const [timezone, setTimezone] = useState(existing?.timezone ?? viewerZone());
  const [inPerson, setInPerson] = useState(existing?.in_person ?? true);
  const [online, setOnline] = useState(existing?.online ?? false);
  const [radius, setRadius] = useState(existing?.service_radius_km ?? 10);
  const [areaLabel, setAreaLabel] = useState(existing?.area_label ?? "");
  // A new coach starts from the saved home point; an existing one keeps their saved area.
  const [pointSource, setPointSource] = useState<"home" | "device" | null>(
    existing ? null : "home",
  );
  const point: DevicePoint | null =
    pointSource === "device" ? origin.point : pointSource === "home" ? origin.homePoint : null;
  const [credentials, setCredentials] = useState<CredentialInput[]>(
    existing?.credentials.map((c) => ({ title: c.title, issuer: c.issuer, year: c.year })) ?? [],
  );
  const [hubIds, setHubIds] = useState<string[]>(existing?.hubs.map((h) => h.id) ?? []);
  const [photos, setPhotos] = useState<string[]>(existing?.photos ?? []);
  const [uploading, setUploading] = useState(false);
  const [terms, setTerms] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [gated, setGated] = useState(false);
  const [accepting, setAccepting] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);
  const hadPoint = Boolean(existing?.in_person);
  const termsCurrent = existing?.terms_current === true;

  const zones = useMemo(() => zoneOptions(timezone, viewerZone()), [timezone]);
  const hubs = useMemo(() => {
    const sensitive = new Set(
      (catalog.data?.categories ?? []).filter((c) => c.is_sensitive).map((c) => c.slug),
    );
    return (catalog.data?.hubs ?? []).filter((h) => !sensitive.has(h.category_slug));
  }, [catalog.data]);
  const hubName = (id: string) => {
    const h = hubs.find((x) => x.id === id);
    return h ? `${h.emoji ? `${h.emoji} ` : ""}${h.name}` : "Hub";
  };

  async function locateDevice() {
    const r = await origin.locate();
    if (r !== "granted") {
      toast.error("We couldn't get this device's location. Use your home location instead.");
    }
  }

  async function onPhoto(file: File) {
    setUploading(true);
    try {
      const blob = await prepareAvatar(file);
      const url = await uploadCoachPhoto(userId, blob);
      setPhotos((p) => [...p, url].slice(0, 6));
    } catch (err) {
      toast.error(avatarErrorMessage(err));
    } finally {
      setUploading(false);
    }
  }

  async function save() {
    setError(null);
    if (inPerson && !point && !hadPoint) {
      setError("Pick where you coach in person: your home location or this device's location.");
      return;
    }
    if (!termsCurrent && !terms) {
      setError("Accept the Coach Terms to continue.");
      return;
    }
    setSaving(true);
    try {
      await coaching.upsertProfile({
        headline: headline.trim(),
        about: about.trim(),
        timezone,
        in_person: inPerson,
        online,
        area_label: areaLabel.trim(),
        ...(inPerson ? { radius_km: radius } : {}),
        ...(inPerson && point ? { lat: point.lat, lng: point.lng } : {}),
      });
      await coaching.setCredentials(credentials.filter((c) => c.title.trim()));
      await coaching.setHubs(hubIds);
      await coaching.setPhotos(photos);
      for (const old of existing?.photos ?? []) {
        if (!photos.includes(old)) await removeCoachPhoto(userId, old).catch(() => undefined);
      }
      if (!termsCurrent && terms && config.data)
        await coaching.acceptTerms(config.data.coach_terms_version);
      void queryClient.invalidateQueries({ queryKey: coachingKeys.all });
      toast.success(existing ? "Saved." : "Coach profile created. Add a listing next.");
      await navigate({ to: "/coach" });
    } catch (err) {
      if (coachingErrorCode(err) === "guidelines_required") setGated(true);
      else setError(coachingErrorMessage(err));
    } finally {
      setSaving(false);
    }
  }

  async function acceptAndRetry() {
    setAccepting(true);
    try {
      await acceptGuidelines();
      void queryClient.invalidateQueries({ queryKey: ["profile"] });
      setGated(false);
      await save();
    } catch (err) {
      toast.error(coachingErrorMessage(err));
    } finally {
      setAccepting(false);
    }
  }

  return (
    <form
      className="flex flex-col gap-6 pt-2"
      onSubmit={(e) => {
        e.preventDefault();
        void save();
      }}
    >
      <section className="flex flex-col gap-4">
        <Field
          label="Headline"
          maxLength={80}
          placeholder="Tennis coach for all levels"
          value={headline}
          onChange={(e) => setHeadline(e.target.value)}
          hint="3 to 80 characters. Shown in search."
        />
        <FieldTextArea
          label="About"
          rows={5}
          maxLength={2000}
          value={about}
          onChange={(e) => setAbout(e.target.value)}
          hint="How you coach and who it's for."
        />
        <FieldSelect
          label="Your time zone"
          value={timezone}
          onChange={(e) => setTimezone(e.target.value)}
          hint={
            existing && existing.timezone !== timezone
              ? "Your weekly times stay the same wall-clock times, so future open times move."
              : "Your weekly availability is in this zone."
          }
        >
          {zones.map((z) => (
            <option key={z} value={z}>
              {z.replace(/_/g, " ")}
            </option>
          ))}
        </FieldSelect>
      </section>

      <section className="flex flex-col gap-3">
        <SectionTitle>How you coach</SectionTitle>
        <Switch label="In person" checked={inPerson} onCheckedChange={setInPerson} />
        <Switch
          label="Online"
          hint="One-on-one video sessions"
          checked={online}
          onCheckedChange={setOnline}
        />
        {inPerson ? (
          <div className="flex flex-col gap-3 rounded-card border border-border p-4">
            <p className="text-[14px] text-text-2">
              Where you coach. The point is rounded to about 1 km and never shown; people see your
              area label and a distance band.
            </p>
            <div className="flex flex-wrap gap-2">
              <Button
                variant={pointSource === "home" ? "secondary" : "outline"}
                size="sm"
                disabled={!origin.homePoint}
                onClick={() => {
                  setPointSource("home");
                }}
              >
                My home location
              </Button>
              <Button
                variant={pointSource === "device" ? "secondary" : "outline"}
                size="sm"
                leading={<LocateFixed className="size-4" aria-hidden="true" />}
                loading={origin.locating}
                onClick={() => {
                  setPointSource("device");
                  void locateDevice();
                }}
              >
                This device
              </Button>
            </div>
            <p className="text-[13px] text-text-3">
              {point
                ? pointSource === "device"
                  ? "Using this device's location."
                  : "Using your home location."
                : hadPoint
                  ? "Keeping the area you saved."
                  : "No area picked yet."}
            </p>
            <FieldSelect
              label="How far you travel"
              value={String(radius)}
              onChange={(e) => setRadius(Number(e.target.value))}
            >
              {RADII.map((r) => (
                <option key={r} value={r}>
                  {r} km
                </option>
              ))}
            </FieldSelect>
            <Field
              label="Area name (public)"
              maxLength={80}
              placeholder="Neighbourhood, city"
              value={areaLabel}
              onChange={(e) => setAreaLabel(e.target.value)}
            />
          </div>
        ) : null}
      </section>

      <section className="flex flex-col gap-3">
        <SectionTitle>Credentials (optional)</SectionTitle>
        <p className="text-[13px] text-text-2">Shown as self-reported. Up to 10.</p>
        {credentials.map((c, i) => (
          <div key={i} className="grid grid-cols-[1fr_auto] items-end gap-2">
            <div className="grid gap-2 min-[400px]:grid-cols-[2fr_2fr_1fr]">
              <Field
                label="Title"
                maxLength={80}
                value={c.title}
                onChange={(e) =>
                  setCredentials((l) =>
                    l.map((x, j) => (j === i ? { ...x, title: e.target.value } : x)),
                  )
                }
              />
              <Field
                label="Issuer"
                maxLength={80}
                value={c.issuer}
                onChange={(e) =>
                  setCredentials((l) =>
                    l.map((x, j) => (j === i ? { ...x, issuer: e.target.value } : x)),
                  )
                }
              />
              <Field
                label="Year"
                inputMode="numeric"
                maxLength={4}
                value={c.year ? String(c.year) : ""}
                onChange={(e) =>
                  setCredentials((l) =>
                    l.map((x, j) =>
                      j === i
                        ? {
                            ...x,
                            year: /^\d{4}$/.test(e.target.value) ? Number(e.target.value) : null,
                          }
                        : x,
                    ),
                  )
                }
              />
            </div>
            <Button
              variant="ghost"
              size="icon"
              aria-label="Remove credential"
              onClick={() => setCredentials((l) => l.filter((_x, j) => j !== i))}
            >
              <Trash className="size-4" aria-hidden="true" />
            </Button>
          </div>
        ))}
        {credentials.length < 10 ? (
          <Button
            variant="secondary"
            size="sm"
            className="self-start"
            onClick={() => setCredentials((l) => [...l, { title: "", issuer: "", year: null }])}
          >
            Add a credential
          </Button>
        ) : null}
      </section>

      <section className="flex flex-col gap-3">
        <SectionTitle>Hubs (optional)</SectionTitle>
        <FieldSelect
          label="Add a hub"
          value=""
          onChange={(e) => {
            const v = e.target.value;
            if (v && !hubIds.includes(v)) setHubIds((l) => [...l, v].slice(0, 10));
          }}
          hint="Up to 10. People find you on these hubs' pages."
        >
          <option value="">Pick a hub</option>
          {hubs
            .filter((h) => !hubIds.includes(h.id))
            .map((h) => (
              <option key={h.id} value={h.id}>
                {h.emoji ? `${h.emoji} ` : ""}
                {h.name}
              </option>
            ))}
        </FieldSelect>
        {hubIds.length > 0 ? (
          <ul className="flex flex-wrap gap-2">
            {hubIds.map((id) => (
              <li key={id}>
                <button
                  type="button"
                  onClick={() => setHubIds((l) => l.filter((x) => x !== id))}
                  className="inline-flex h-9 items-center gap-1.5 rounded-control bg-primary-tint px-3 text-[14px] font-semibold text-primary-text"
                  aria-label={`Remove ${hubName(id)}`}
                >
                  {hubName(id)}
                  <X className="size-4" aria-hidden="true" />
                </button>
              </li>
            ))}
          </ul>
        ) : null}
      </section>

      <section className="flex flex-col gap-3">
        <SectionTitle>Photos (optional)</SectionTitle>
        <ul className="grid grid-cols-3 gap-2">
          {photos.map((url) => (
            <li key={url} className="relative">
              <img
                src={url}
                alt=""
                className="aspect-square w-full rounded-card border border-border object-cover"
              />
              <button
                type="button"
                aria-label="Remove photo"
                onClick={() => setPhotos((p) => p.filter((x) => x !== url))}
                className="absolute top-1 right-1 flex size-9 items-center justify-center rounded-full bg-surface/90"
              >
                <X className="size-4" aria-hidden="true" />
              </button>
            </li>
          ))}
        </ul>
        <input
          ref={fileRef}
          type="file"
          accept="image/*"
          className="hidden"
          onChange={(e) => {
            const f = e.target.files?.[0];
            if (f) void onPhoto(f);
            e.target.value = "";
          }}
        />
        {photos.length < 6 ? (
          <Button
            variant="secondary"
            size="sm"
            className="self-start"
            leading={<ImagePlus className="size-4" aria-hidden="true" />}
            loading={uploading}
            onClick={() => fileRef.current?.click()}
          >
            Add a photo
          </Button>
        ) : null}
      </section>

      {!termsCurrent ? (
        <label className="flex items-start gap-3 text-[14px]">
          <input
            type="checkbox"
            className="mt-0.5 size-5 shrink-0 accent-primary"
            checked={terms}
            onChange={(e) => setTerms(e.target.checked)}
          />
          <span>
            I&apos;m 18 or older, I&apos;m legally allowed to do paid work where I coach, and I
            agree to the{" "}
            <a
              href={coachTermsUrl(SITE_URL)}
              target="_blank"
              rel="noreferrer"
              className="font-semibold text-link underline-offset-2 hover:underline"
            >
              Coach Terms
            </a>
            .
          </span>
        </label>
      ) : (
        <Note>You accepted the current Coach Terms.</Note>
      )}

      <FormError>{error}</FormError>
      <Button type="submit" size="lg" block loading={saving}>
        {existing ? "Save" : "Create coach profile"}
      </Button>
      <GuidelinesSheet
        open={gated}
        onClose={() => setGated(false)}
        onAccept={() => void acceptAndRetry()}
        accepting={accepting}
      />
    </form>
  );
}
