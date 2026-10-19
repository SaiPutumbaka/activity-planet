import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Check, Search, X } from "lucide-react";
import {
  birthDateSchema,
  firstNameSchema,
  handleSchema,
  meetsMinimumAge,
} from "@ap/core/validation";

import { Button } from "@/components/ui/button";
import { Chip } from "@/components/ui/chip";
import { Field, FormError, inputClassName } from "@/components/ui/field";
import { Spinner } from "@/components/ui/spinner";
import { cn } from "@/lib/cn";
import { campusesQuery, hubCatalogQuery, type CatalogHub } from "@/lib/profile";
import { supabase } from "@/lib/supabase";
import { useDebouncedValue } from "@/lib/use-debounced-value";

export const MAX_HUBS = 25;

/* ------------------------------------------------------------------ */
/* 1. Birthday                                                          */
/* ------------------------------------------------------------------ */

function todayIso(): string {
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

/**
 * The neutral age screen (D-018). It never mentions a minimum age before the date is entered,
 * so nobody is coached into a false date. Under-18 answers are not sent to the server.
 */
export function BirthdayStep({
  initial,
  onContinue,
  onUnderage,
}: {
  initial: string;
  onContinue: (birthDate: string) => void;
  onUnderage: () => void;
}) {
  const [value, setValue] = useState(initial);
  const [error, setError] = useState<string | null>(null);

  function submit() {
    const parsed = birthDateSchema.safeParse(value);
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? "Enter your birthday.");
      return;
    }
    if (!meetsMinimumAge(parsed.data)) {
      onUnderage();
      return;
    }
    onContinue(parsed.data);
  }

  return (
    <StepFrame
      title="When's your birthday?"
      body="We use it to show you the right events and keep the community safe. It stays private."
      footer={
        <Button size="lg" block onClick={submit}>
          Continue
        </Button>
      }
    >
      <Field
        label="Birthday"
        type="date"
        value={value}
        min="1900-01-01"
        max={todayIso()}
        autoComplete="bday"
        onChange={(e) => {
          setValue(e.target.value);
          setError(null);
        }}
        error={error ?? undefined}
      />
    </StepFrame>
  );
}

export function UnderageScreen({
  onSignOut,
  signingOut,
}: {
  onSignOut: () => void;
  signingOut: boolean;
}) {
  return (
    <StepFrame
      title="Thanks for checking out Activity Planet"
      body="Right now it's for people 18 and over. We didn't save anything from this screen. We'll let you know when that changes."
      footer={
        <Button variant="secondary" size="lg" block loading={signingOut} onClick={onSignOut}>
          Sign out
        </Button>
      }
    />
  );
}

/* ------------------------------------------------------------------ */
/* 2. About you                                                         */
/* ------------------------------------------------------------------ */

export function AboutStep({
  initialFirstName,
  initialHandle,
  onContinue,
}: {
  initialFirstName: string;
  initialHandle: string;
  onContinue: (values: { firstName: string; handle: string }) => void;
}) {
  const [firstName, setFirstName] = useState(initialFirstName);
  const [handle, setHandle] = useState(initialHandle);
  const [nameError, setNameError] = useState<string | null>(null);
  const [submitError, setSubmitError] = useState<string | null>(null);

  // Validation is derived during render; only the availability round trip is asynchronous.
  const trimmed = handle.trim();
  const parsed = useMemo(() => (trimmed ? handleSchema.safeParse(trimmed) : null), [trimmed]);
  const validationError =
    parsed && !parsed.success
      ? (parsed.error.issues[0]?.message ?? "That handle won't work.")
      : null;
  const candidate = parsed?.success ? parsed.data : null;
  const debounced = useDebouncedValue(candidate, 400);

  const availability = useQuery({
    queryKey: ["handle-available", debounced] as const,
    queryFn: async () => {
      if (!debounced) return null;
      const { data, error } = await supabase.rpc("handle_available", { p_handle: debounced });
      if (error) throw error;
      return data;
    },
    enabled: debounced !== null,
    staleTime: 30_000,
  });

  const checking = candidate !== null && (debounced !== candidate || availability.isFetching);
  const available = !checking && candidate !== null && availability.data === true;
  const taken = !checking && candidate !== null && availability.data === false;
  const handleError = submitError ?? validationError ?? (taken ? "That handle is taken." : null);

  function submit() {
    const name = firstNameSchema.safeParse(firstName);
    if (!name.success) {
      setNameError(name.error.issues[0]?.message ?? "Enter your first name.");
      return;
    }
    if (!candidate) {
      setSubmitError(trimmed ? validationError : "Pick a handle.");
      return;
    }
    if (taken) return;
    onContinue({ firstName: name.data, handle: candidate });
  }

  const suffix = checking ? (
    <Spinner className="size-4 text-text-3" />
  ) : available ? (
    <Check className="size-5 text-going" aria-label="Available" />
  ) : handleError ? (
    <X className="size-5 text-danger" aria-hidden="true" />
  ) : null;

  return (
    <StepFrame
      title="What should people call you?"
      body="Your first name shows on events you join. Your handle is how friends find you."
      footer={
        <Button size="lg" block onClick={submit} disabled={checking}>
          Continue
        </Button>
      }
    >
      <Field
        label="First name"
        autoComplete="given-name"
        autoCapitalize="words"
        maxLength={40}
        value={firstName}
        onChange={(e) => {
          setFirstName(e.target.value);
          setNameError(null);
        }}
        error={nameError ?? undefined}
      />
      <Field
        label="Handle"
        prefix="@"
        suffix={suffix}
        autoComplete="username"
        autoCapitalize="none"
        autoCorrect="off"
        spellCheck={false}
        maxLength={24}
        value={handle}
        onChange={(e) => {
          setHandle(e.target.value.replace(/\s+/g, ""));
          setSubmitError(null);
        }}
        hint={available ? "Available." : "Letters, numbers and underscores. 3 to 24 characters."}
        error={handleError ?? undefined}
      />
    </StepFrame>
  );
}

/* ------------------------------------------------------------------ */
/* 3. Hubs                                                              */
/* ------------------------------------------------------------------ */

export function HubsStep({
  age,
  initialSelected,
  onContinue,
}: {
  age: number;
  initialSelected: string[];
  onContinue: (hubIds: string[]) => void;
}) {
  const catalog = useQuery(hubCatalogQuery);
  const [selected, setSelected] = useState<Set<string>>(() => new Set(initialSelected));
  const [query, setQuery] = useState("");

  const sections = useMemo(() => {
    if (!catalog.data) return [];
    const q = query.trim().toLowerCase();
    const visible = catalog.data.hubs.filter((h) => h.scope !== "campus" && h.min_age <= age);
    const matches = (h: CatalogHub) =>
      !q || h.name.toLowerCase().includes(q) || h.aliases.some((a) => a.toLowerCase().includes(q));
    const byCategory = new Map<string, CatalogHub[]>();
    for (const h of visible) {
      if (!matches(h)) continue;
      const list = byCategory.get(h.category_slug) ?? [];
      list.push(h);
      byCategory.set(h.category_slug, list);
    }
    return catalog.data.categories
      .filter((c) => c.scope !== "campus" && c.min_age <= age && byCategory.has(c.slug))
      .map((c) => ({ category: c, hubs: byCategory.get(c.slug) ?? [] }));
  }, [catalog.data, query, age]);

  function toggle(id: string) {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else if (next.size < MAX_HUBS) next.add(id);
      return next;
    });
  }

  const count = selected.size;

  return (
    <StepFrame
      title="What are you into?"
      body="Pick everything that fits. Hubs are where plans, people and chats live."
      footer={
        <Button size="lg" block onClick={() => onContinue([...selected])} disabled={count === 0}>
          {count === 0
            ? "Pick at least one"
            : `Continue with ${count} ${count === 1 ? "hub" : "hubs"}`}
        </Button>
      }
    >
      <div className="sticky top-0 z-10 -mx-4 bg-surface px-4 pb-2">
        <div className="relative">
          <Search
            className="pointer-events-none absolute inset-y-0 left-4 my-auto size-5 text-text-3"
            aria-hidden="true"
          />
          <input
            type="search"
            className={cn(inputClassName, "pl-11")}
            placeholder="Search 600+ hubs"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            aria-label="Search hubs"
          />
        </div>
        <p className="mt-2 text-[13px] text-text-3 tabular">
          {count} of {MAX_HUBS} picked
        </p>
      </div>

      {catalog.isPending ? (
        <div className="flex justify-center py-10 text-text-3">
          <Spinner className="size-6" label="Loading hubs" />
        </div>
      ) : catalog.isError ? (
        <FormError>Couldn't load hubs. Check your connection and try again.</FormError>
      ) : sections.length === 0 ? (
        <p className="py-8 text-center text-text-2">
          No hub matches “{query}”. You can request one from the Hubs tab after setup.
        </p>
      ) : (
        <div className="flex flex-col gap-6">
          {sections.map(({ category, hubs }) => (
            <section key={category.slug}>
              <h3 className="mb-2 text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
                {category.name}
              </h3>
              <div className="flex flex-wrap gap-2">
                {hubs.map((h) => (
                  <Chip
                    key={h.id}
                    selected={selected.has(h.id)}
                    leading={h.emoji}
                    onClick={() => toggle(h.id)}
                  >
                    {h.name}
                  </Chip>
                ))}
              </div>
            </section>
          ))}
        </div>
      )}
    </StepFrame>
  );
}

/* ------------------------------------------------------------------ */
/* 4. Campus                                                            */
/* ------------------------------------------------------------------ */

export function CampusStep({
  initialCampusId,
  submitting,
  error,
  onFinish,
}: {
  initialCampusId: string | null;
  submitting: boolean;
  error: string | null;
  onFinish: (campusId: string | null) => void;
}) {
  const campuses = useQuery(campusesQuery);
  const [campusId, setCampusId] = useState<string | null>(initialCampusId);
  const [none, setNone] = useState<boolean>(false);

  const orgName = campuses.data?.[0]?.organizations?.name ?? "Georgia State University";
  const canFinish = none || campusId !== null;

  return (
    <StepFrame
      title={`Are you at ${orgName}?`}
      body="Pick your campus and we'll show what's happening there first. Verifying a .edu email later unlocks the campus-only space."
      footer={
        <>
          <FormError>{error}</FormError>
          <Button
            size="lg"
            block
            loading={submitting}
            disabled={!canFinish}
            onClick={() => onFinish(none ? null : campusId)}
          >
            Finish
          </Button>
        </>
      }
    >
      {campuses.isPending ? (
        <div className="flex justify-center py-10 text-text-3">
          <Spinner className="size-6" label="Loading campuses" />
        </div>
      ) : (
        <div role="radiogroup" aria-label="Campus" className="flex flex-col gap-2">
          {(campuses.data ?? []).map((c) => (
            <OptionRow
              key={c.id}
              checked={!none && campusId === c.id}
              onSelect={() => {
                setNone(false);
                setCampusId(c.id);
              }}
              label={c.name}
            />
          ))}
          <OptionRow
            checked={none}
            onSelect={() => {
              setNone(true);
              setCampusId(null);
            }}
            label="I'm not a student here"
            hint="You still get every hub and every public event."
          />
        </div>
      )}
    </StepFrame>
  );
}

function OptionRow({
  checked,
  onSelect,
  label,
  hint,
}: {
  checked: boolean;
  onSelect: () => void;
  label: string;
  hint?: string;
}) {
  return (
    <button
      type="button"
      role="radio"
      aria-checked={checked}
      onClick={onSelect}
      className={cn(
        "flex items-center justify-between gap-3 rounded-input border px-4 py-3 text-left transition-colors",
        checked ? "border-primary bg-primary-tint" : "border-border bg-surface hover:bg-surface-2",
      )}
    >
      <span>
        <span className="block text-[15px] font-semibold">{label}</span>
        {hint ? <span className="block text-[13px] text-text-2">{hint}</span> : null}
      </span>
      <span
        className={cn(
          "flex size-5 shrink-0 items-center justify-center rounded-full border-2",
          checked ? "border-primary bg-primary text-on-primary" : "border-border-strong",
        )}
        aria-hidden="true"
      >
        {checked ? <Check className="size-3.5" strokeWidth={3} /> : null}
      </span>
    </button>
  );
}

/* ------------------------------------------------------------------ */
/* Frame                                                                */
/* ------------------------------------------------------------------ */

export function StepFrame({
  title,
  body,
  children,
  footer,
}: {
  title: string;
  body?: string;
  children?: React.ReactNode;
  footer?: React.ReactNode;
}) {
  return (
    <div className="flex flex-1 flex-col">
      <div className="pb-5">
        <h1 className="text-[28px] font-extrabold tracking-[-0.025em] text-balance">{title}</h1>
        {body ? <p className="mt-1 text-text-2">{body}</p> : null}
      </div>
      <div className="flex flex-1 flex-col gap-4 pb-28">{children}</div>
      {footer ? (
        <div className="fixed inset-x-0 bottom-0 z-20 border-t border-border bg-surface/95 backdrop-blur safe-pb">
          <div className="mx-auto flex max-w-lg flex-col gap-3 px-4 py-3">{footer}</div>
        </div>
      ) : null}
    </div>
  );
}
