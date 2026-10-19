import { useEffect, useRef, useState } from "react";
import { Link, createFileRoute, useNavigate } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { toast } from "sonner";
import { passwordSchema } from "@ap/core/validation";

import { Button } from "@/components/ui/button";
import { Field, FormError } from "@/components/ui/field";
import { Spinner } from "@/components/ui/spinner";
import { authErrorMessage } from "@/lib/auth";
import { completeAuthLink } from "@/lib/auth-links";
import { supabase } from "@/lib/supabase";

const searchSchema = z.object({
  token_hash: z.string().optional(),
  type: z.string().optional(),
  code: z.string().optional(),
  error: z.string().optional(),
  error_code: z.string().optional(),
  error_description: z.string().optional(),
});

const formSchema = z
  .object({ password: passwordSchema, confirmPassword: z.string() })
  .refine((v) => v.password === v.confirmPassword, {
    message: "Passwords don't match.",
    path: ["confirmPassword"],
  });
type Values = z.infer<typeof formSchema>;

/** Lands the password-reset email, then lets the person choose a new password. */
export const Route = createFileRoute("/auth/reset")({
  validateSearch: searchSchema,
  component: ResetPage,
});

type Stage = "verifying" | "ready" | "invalid";

function ResetPage() {
  const search = Route.useSearch();
  const navigate = useNavigate();
  const [stage, setStage] = useState<Stage>("verifying");
  const [message, setMessage] = useState<string | null>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const started = useRef(false);
  const form = useForm<Values>({
    resolver: zodResolver(formSchema),
    defaultValues: { password: "", confirmPassword: "" },
  });

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    const hasLink = Boolean(search.token_hash || search.code || search.error);
    (hasLink ? completeAuthLink(search) : supabase.auth.getSession().then((r) => r.data.session))
      .then((session) => {
        if (session) setStage("ready");
        else {
          setMessage("This page needs the link from your reset email.");
          setStage("invalid");
        }
      })
      .catch((err: unknown) => {
        setMessage(authErrorMessage(err));
        setStage("invalid");
      });
  }, [search]);

  async function onSubmit({ password }: Values) {
    setFormError(null);
    const { error } = await supabase.auth.updateUser({ password });
    if (error) {
      setFormError(authErrorMessage(error));
      return;
    }
    toast.success("Password updated.");
    await navigate({ to: "/", replace: true });
  }

  if (stage === "verifying") {
    return (
      <div className="flex flex-col items-center gap-3 pt-10 text-text-2">
        <Spinner className="size-7" label="Checking your link" />
        <p>Checking your link…</p>
      </div>
    );
  }

  if (stage === "invalid") {
    return (
      <div className="flex flex-col items-center gap-4 pt-6 text-center">
        <h1 className="text-[26px] font-extrabold tracking-[-0.025em]">That link didn't work</h1>
        <p className="max-w-[34ch] text-text-2">{message}</p>
        <Link to="/auth/forgot">
          <Button variant="secondary">Request a new link</Button>
        </Link>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-[28px] font-extrabold tracking-[-0.025em]">Choose a new password</h1>
        <p className="mt-1 text-text-2">
          At least 8 characters, and not one you've used here before.
        </p>
      </div>
      <form onSubmit={form.handleSubmit(onSubmit)} className="flex flex-col gap-4" noValidate>
        <Field
          label="New password"
          type="password"
          autoComplete="new-password"
          error={form.formState.errors.password?.message}
          {...form.register("password")}
        />
        <Field
          label="Confirm new password"
          type="password"
          autoComplete="new-password"
          error={form.formState.errors.confirmPassword?.message}
          {...form.register("confirmPassword")}
        />
        <FormError>{formError}</FormError>
        <Button type="submit" size="lg" block loading={form.formState.isSubmitting}>
          Update password
        </Button>
      </form>
    </div>
  );
}
