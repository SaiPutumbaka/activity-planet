import { useId, useState } from "react";
import { Link } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Field, FormError } from "@/components/ui/field";
import { Sheet } from "@/components/ui/sheet";
import { FieldTextArea } from "@/components/ui/textarea";
import { existingHubSlug, hubErrorMessage, requestHub } from "@/lib/hubs";

const NAME_RULE = "Hub names are 2 to 60 characters.";

const schema = z.object({
  name: z.string().trim().min(2, NAME_RULE).max(60, NAME_RULE),
  note: z.string().trim().max(280, "Keep the note under 280 characters."),
});
type Values = z.infer<typeof schema>;

/**
 * "Request a hub": name plus an optional note, through request_hub. The same limits the database
 * enforces are checked here first; a name that already exists comes back with a link to that hub.
 */
export function RequestHubSheet({
  open,
  onClose,
  hubNameBySlug,
}: {
  open: boolean;
  onClose: () => void;
  /** Looks a slug up in the loaded catalog, for the "That hub exists" link. */
  hubNameBySlug: (slug: string) => string | undefined;
}) {
  const formId = useId();
  const [formError, setFormError] = useState<string | null>(null);
  const [existing, setExisting] = useState<{ slug: string; name: string } | null>(null);
  const form = useForm<Values>({
    resolver: zodResolver(schema),
    defaultValues: { name: "", note: "" },
  });

  function close() {
    form.reset();
    setFormError(null);
    setExisting(null);
    onClose();
  }

  async function onSubmit(values: Values) {
    setFormError(null);
    setExisting(null);
    try {
      await requestHub(values.name, values.note);
    } catch (err) {
      const slug = existingHubSlug(err);
      if (slug) setExisting({ slug, name: hubNameBySlug(slug) ?? slug });
      else setFormError(hubErrorMessage(err));
      return;
    }
    toast.success(`Thanks. We'll look at “${values.name}” within a few days.`);
    close();
  }

  return (
    <Sheet
      open={open}
      onClose={close}
      title="Request a hub"
      footer={
        <Button type="submit" form={formId} size="lg" block loading={form.formState.isSubmitting}>
          Send request
        </Button>
      }
    >
      <form
        id={formId}
        onSubmit={form.handleSubmit(onSubmit)}
        className="flex flex-col gap-4 pt-1"
        noValidate
      >
        <p className="text-[14px] text-text-2">
          Can't find your thing? Name it and we'll add it. Up to three requests can be open at once.
        </p>
        <Field
          label="Hub name"
          placeholder="e.g. Disc Golf"
          maxLength={60}
          autoComplete="off"
          autoCapitalize="words"
          error={form.formState.errors.name?.message}
          {...form.register("name")}
        />
        <FieldTextArea
          label="Why it belongs here (optional)"
          rows={3}
          maxLength={280}
          className="[&_textarea]:min-h-[88px]"
          error={form.formState.errors.note?.message}
          {...form.register("note")}
        />
        {existing ? (
          <div role="alert" className="rounded-input bg-surface-2 px-4 py-3 text-[14px]">
            <p className="font-medium">That hub already exists.</p>
            <Link
              to="/hubs/$slug"
              params={{ slug: existing.slug }}
              onClick={close}
              className="mt-1 inline-block font-semibold text-primary-text underline-offset-2 hover:underline"
            >
              Open {existing.name}
            </Link>
          </div>
        ) : (
          <FormError>{formError}</FormError>
        )}
      </form>
    </Sheet>
  );
}
