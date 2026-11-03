import { useState, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { GraduationCap, MapPin } from "lucide-react";
import { toast } from "sonner";

import { StateChip } from "@/components/events/event-state-chip";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { Field, FormError } from "@/components/ui/field";
import { FieldSelect } from "@/components/ui/select";
import { Sheet } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import { FieldTextArea } from "@/components/ui/textarea";
import {
  chapterErrorMessage,
  chapterKeys,
  claimFormErrors,
  claimStatusView,
  emptyClaimForm,
  fieldForClaimError,
  myChapterClaimsQuery,
  submitChapterClaim,
  toClaimArgs,
  withdrawChapterClaim,
  type ClaimFormField,
  type ClaimFormValues,
  type MyClaim,
} from "@/lib/chapters";
import { cn } from "@/lib/cn";
import { areasQuery } from "@/lib/location";
import { membershipQuery } from "@/lib/verification";

/** The chapter being claimed, when it already exists (its place is then fixed). */
export interface ClaimTarget {
  id: string;
  name: string;
  org_id: string | null;
  campus_id: string | null;
  area_id: string | null;
}

/**
 * Ask to run a chapter of a hub (submit_chapter_claim): for a school organization (needs a
 * verified school email; the org and campus come from it) or a neighborhood group (pick an
 * area). A moderator reviews every claim before any role is granted. The viewer's claims for
 * this hub sit on top with their status, and a pending one can be withdrawn.
 */
export function ClaimChapterSheet({
  open,
  onClose,
  userId,
  hub,
  chapter,
}: {
  open: boolean;
  onClose: () => void;
  userId: string;
  hub: { id: string; name: string };
  chapter?: ClaimTarget | null;
}) {
  return (
    <Sheet
      open={open}
      onClose={onClose}
      title={chapter ? `Run ${chapter.name}` : `Start a ${hub.name} chapter`}
    >
      <ClaimBody userId={userId} hub={hub} chapter={chapter ?? null} onDone={onClose} />
    </Sheet>
  );
}

function ClaimBody({
  userId,
  hub,
  chapter,
  onDone,
}: {
  userId: string;
  hub: { id: string; name: string };
  chapter: ClaimTarget | null;
  onDone: () => void;
}) {
  const queryClient = useQueryClient();
  const claims = useQuery(myChapterClaimsQuery(userId));
  const membership = useQuery(membershipQuery(userId));
  const areas = useQuery(areasQuery);

  const fixedKind = chapter ? (chapter.org_id ? "org" : "area") : null;
  const [values, setValues] = useState<ClaimFormValues>(() => emptyClaimForm(fixedKind ?? "area"));
  const [errors, setErrors] = useState<Partial<Record<ClaimFormField, string>>>({});
  const [formError, setFormError] = useState<string | null>(null);
  const kind = fixedKind ?? values.kind;

  const set = <K extends ClaimFormField>(key: K, value: ClaimFormValues[K]) => {
    setValues((v) => ({ ...v, [key]: value }));
    setErrors((e) => ({ ...e, [key]: undefined }));
  };

  const mine = (claims.data ?? []).filter((c) => c.hub_id === hub.id);
  const pendingHere = chapter
    ? mine.some((c) => c.status === "pending" && c.chapter_id === chapter.id)
    : false;

  // An organization claim takes its organization and campus from the verified membership.
  const member = membership.data ?? null;
  const memberFitsChapter =
    !chapter?.org_id ||
    (member?.org_id === chapter.org_id &&
      (!chapter.campus_id || !member.campus_id || member.campus_id === chapter.campus_id));
  const orgBlocked = kind === "org" && (!member || !memberFitsChapter);
  const orgName = member ? (member.org_campuses?.name ?? member.organizations?.name ?? "") : "";

  const invalidate = () => {
    void queryClient.invalidateQueries({ queryKey: chapterKeys.claims(userId) });
  };

  const submit = useMutation({
    mutationFn: () =>
      submitChapterClaim(
        toClaimArgs(
          { ...values, kind },
          {
            hubId: hub.id,
            chapterId: chapter?.id ?? null,
            orgId: member?.org_id ?? null,
            campusId: member?.campus_id ?? null,
          },
        ),
      ),
    onSuccess: () => {
      invalidate();
      toast.success("Claim sent. A moderator reviews it, usually within two days.");
      onDone();
    },
    onError: (err) => {
      const field = fieldForClaimError(err);
      const message = chapterErrorMessage(err);
      if (field) setErrors((e) => ({ ...e, [field]: message }));
      else setFormError(message);
    },
  });

  const withdraw = useMutation({
    mutationFn: (claimId: string) => withdrawChapterClaim(claimId),
    onSuccess: () => {
      invalidate();
      toast("Claim withdrawn.");
    },
    onError: (err) => toast.error(chapterErrorMessage(err)),
  });

  function onSubmit() {
    setFormError(null);
    const next: Partial<Record<ClaimFormField, string>> =
      claimFormErrors({ ...values, kind }) ?? {};
    if (!chapter && !values.proposedName.trim()) next.proposedName = "Give the chapter a name.";
    if (Object.values(next).some(Boolean)) {
      setErrors(next);
      return;
    }
    submit.mutate();
  }

  const loading = claims.isPending || membership.isPending;

  return (
    <div className="flex flex-col gap-5 pt-1 pb-2">
      <p className="text-[15px] text-text-2">
        A chapter is {hub.name} for one group or one neighborhood, with its own plans and captains.
        Tell us who you are and a moderator reviews it before anything goes live.
      </p>

      {claims.isError ? (
        <FormError>Couldn't load your claims. Check your connection.</FormError>
      ) : mine.length > 0 ? (
        <ClaimList
          claims={mine}
          withdrawing={withdraw.isPending ? (withdraw.variables ?? null) : null}
          onWithdraw={(id) => withdraw.mutate(id)}
        />
      ) : null}

      {loading ? (
        <div className="flex flex-col gap-3" aria-busy="true">
          <Skeleton className="h-16" />
          <Skeleton className="h-12" />
          <Skeleton className="h-12" />
        </div>
      ) : pendingHere ? null : (
        <div className="flex flex-col gap-4">
          {fixedKind ? null : (
            <fieldset className="flex flex-col gap-2">
              <legend className="mb-2 text-[14px] font-semibold">Who runs it</legend>
              <KindOption
                selected={kind === "org"}
                onSelect={() => set("kind", "org")}
                icon={<GraduationCap className="size-5" aria-hidden="true" />}
                title="A school organization"
                body="A club or student org you're an officer of. Needs a verified school email."
              />
              <KindOption
                selected={kind === "area"}
                onSelect={() => set("kind", "area")}
                icon={<MapPin className="size-5" aria-hidden="true" />}
                title="A neighborhood group"
                body="You bring people together in one part of town. Anyone can join it."
              />
            </fieldset>
          )}

          {kind === "org" && orgBlocked ? (
            <div className="flex flex-col gap-3 rounded-card border border-border p-4">
              <p className="text-[15px]">
                {member
                  ? "This chapter belongs to another organization. Verify a school email there to claim it."
                  : "Verify your school email first, so we know which organization you're with."}
              </p>
              <Link to="/you/verify" className={buttonVariants({ variant: "secondary" })}>
                Verify a school email
              </Link>
            </div>
          ) : (
            <>
              {kind === "org" && orgName ? (
                <p className="text-[14px] text-text-2">
                  For <span className="font-semibold text-text">{orgName}</span>, from your verified
                  school email.
                </p>
              ) : null}
              {kind === "area" && !chapter ? (
                <FieldSelect
                  label="Neighborhood"
                  value={values.areaId}
                  onChange={(e) => set("areaId", e.target.value)}
                  error={errors.areaId}
                  disabled={areas.isPending}
                >
                  <option value="">{areas.isPending ? "Loading…" : "Pick one"}</option>
                  {(areas.data ?? []).map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.name}
                    </option>
                  ))}
                </FieldSelect>
              ) : null}
              {chapter ? null : (
                <Field
                  label="Chapter name"
                  placeholder={
                    kind === "org" ? `${hub.name} Club` : `${hub.name} in Old Fourth Ward`
                  }
                  maxLength={100}
                  autoComplete="off"
                  value={values.proposedName}
                  onChange={(e) => set("proposedName", e.target.value)}
                  error={errors.proposedName}
                />
              )}
              {kind === "org" ? (
                <>
                  <Field
                    label="Registered organization name (optional)"
                    placeholder="As it appears on your school's listing"
                    maxLength={120}
                    autoComplete="off"
                    value={values.rsoName}
                    onChange={(e) => set("rsoName", e.target.value)}
                    error={errors.rsoName}
                  />
                  <Field
                    label="Link to its listing (optional)"
                    type="url"
                    inputMode="url"
                    placeholder="https://"
                    autoCapitalize="none"
                    autoComplete="off"
                    maxLength={500}
                    value={values.pinUrl}
                    onChange={(e) => set("pinUrl", e.target.value)}
                    error={errors.pinUrl}
                  />
                  <Field
                    label="Your role (optional)"
                    placeholder="President, events chair"
                    maxLength={80}
                    autoComplete="off"
                    value={values.officerRole}
                    onChange={(e) => set("officerRole", e.target.value)}
                    error={errors.officerRole}
                  />
                </>
              ) : null}
              <div className="grid grid-cols-2 gap-3">
                <Field
                  label="Reference (optional)"
                  placeholder="Their name"
                  maxLength={80}
                  autoComplete="off"
                  value={values.referenceName}
                  onChange={(e) => set("referenceName", e.target.value)}
                  error={errors.referenceName}
                />
                <Field
                  label="How to reach them"
                  placeholder="Email or phone"
                  maxLength={200}
                  autoComplete="off"
                  value={values.referenceContact}
                  onChange={(e) => set("referenceContact", e.target.value)}
                  error={errors.referenceContact}
                />
              </div>
              <FieldTextArea
                label="What would you run? (optional)"
                placeholder="Weekly pickup on Tuesdays, a monthly beginner night."
                rows={3}
                maxLength={1000}
                value={values.motivation}
                onChange={(e) => set("motivation", e.target.value)}
                error={errors.motivation}
              />
              <div className="flex flex-col gap-1">
                <Switch
                  label="I agree to the captain guidelines"
                  hint="Host safely, keep plans accurate, and follow the community guidelines."
                  checked={values.agreed}
                  onCheckedChange={(on) => set("agreed", on)}
                />
                {errors.agreed ? (
                  <p role="alert" className="text-[13px] font-medium text-danger">
                    {errors.agreed}
                  </p>
                ) : null}
              </div>
              <FormError>{formError}</FormError>
              <Button size="lg" block loading={submit.isPending} onClick={onSubmit}>
                Send claim
              </Button>
            </>
          )}
        </div>
      )}
    </div>
  );
}

function KindOption({
  selected,
  onSelect,
  icon,
  title,
  body,
}: {
  selected: boolean;
  onSelect: () => void;
  icon: ReactNode;
  title: string;
  body: string;
}) {
  return (
    <button
      type="button"
      role="radio"
      aria-checked={selected}
      onClick={onSelect}
      className={cn(
        "flex min-h-14 items-start gap-3 rounded-card border p-3 text-left transition-colors",
        selected ? "border-text bg-surface-2" : "border-border hover:bg-surface-2",
      )}
    >
      <span className="mt-0.5 text-text-2">{icon}</span>
      <span className="min-w-0">
        <span className="block text-[15px] font-semibold">{title}</span>
        <span className="block text-[13px] text-text-2">{body}</span>
      </span>
    </button>
  );
}

function ClaimList({
  claims,
  withdrawing,
  onWithdraw,
}: {
  claims: MyClaim[];
  withdrawing: string | null;
  onWithdraw: (id: string) => void;
}) {
  return (
    <section className="flex flex-col gap-2" aria-label="Your claims">
      <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">Your claims</h3>
      <ul className="divide-y divide-border rounded-card border border-border">
        {claims.map((c) => {
          const view = claimStatusView(c.status);
          return (
            <li key={c.id} className="flex flex-col gap-2 px-4 py-3">
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <p className="truncate text-[15px] font-semibold">{c.proposed_name}</p>
                  {c.place_label ? (
                    <p className="truncate text-[13px] text-text-2">{c.place_label}</p>
                  ) : null}
                </div>
                <StateChip tone={view.tone}>{view.label}</StateChip>
              </div>
              {c.review_note ? <p className="text-[14px] text-text-2">{c.review_note}</p> : null}
              {c.status === "approved" && c.chapter_slug ? (
                <Link
                  to="/chapters/$slug"
                  params={{ slug: c.chapter_slug }}
                  className={cn(buttonVariants({ variant: "secondary", size: "sm" }), "self-start")}
                >
                  Open the chapter
                </Link>
              ) : null}
              {c.status === "pending" ? (
                <Button
                  variant="ghost"
                  size="sm"
                  className="self-start"
                  loading={withdrawing === c.id}
                  onClick={() => onWithdraw(c.id)}
                >
                  Withdraw
                </Button>
              ) : null}
            </li>
          );
        })}
      </ul>
    </section>
  );
}
