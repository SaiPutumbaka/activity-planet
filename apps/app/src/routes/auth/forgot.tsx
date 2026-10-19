import { useState } from "react";
import { Link, createFileRoute, useNavigate } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { emailSchema } from "@ap/core/validation";

import { Button } from "@/components/ui/button";
import { Field, FormError } from "@/components/ui/field";
import { authErrorMessage, authRedirect } from "@/lib/auth";
import { supabase } from "@/lib/supabase";

const schema = z.object({ email: emailSchema });
type Values = z.infer<typeof schema>;

export const Route = createFileRoute("/auth/forgot")({
  component: ForgotPage,
});

function ForgotPage() {
  const navigate = useNavigate();
  const [formError, setFormError] = useState<string | null>(null);
  const form = useForm<Values>({ resolver: zodResolver(schema), defaultValues: { email: "" } });

  async function onSubmit({ email }: Values) {
    setFormError(null);
    const { error } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: authRedirect.reset(),
    });
    if (error) {
      setFormError(authErrorMessage(error));
      return;
    }
    await navigate({ to: "/auth/check-email", search: { email, kind: "reset" } });
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-[28px] font-extrabold tracking-[-0.025em]">Reset your password</h1>
        <p className="mt-1 text-text-2">We'll email you a link that lets you choose a new one.</p>
      </div>
      <form onSubmit={form.handleSubmit(onSubmit)} className="flex flex-col gap-4" noValidate>
        <Field
          label="Email"
          type="email"
          autoComplete="email"
          inputMode="email"
          autoCapitalize="none"
          error={form.formState.errors.email?.message}
          {...form.register("email")}
        />
        <FormError>{formError}</FormError>
        <Button type="submit" size="lg" block loading={form.formState.isSubmitting}>
          Send reset link
        </Button>
      </form>
      <p className="text-center text-[15px] text-text-2">
        <Link to="/auth/sign-in" className="font-semibold text-primary-text">
          Back to sign in
        </Link>
      </p>
    </div>
  );
}
