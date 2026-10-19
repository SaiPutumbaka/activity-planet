import { useState } from "react";
import { Link, createFileRoute, redirect, useNavigate } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { signupSchema, type SignupInput } from "@ap/core/validation";

import { OAuthButtons } from "@/components/auth/oauth-buttons";
import { Button } from "@/components/ui/button";
import { Field, FormError } from "@/components/ui/field";
import { authErrorMessage, authRedirect, getSession } from "@/lib/auth";
import { internalTo } from "@/lib/navigation";
import { supabase } from "@/lib/supabase";

const searchSchema = z.object({ next: z.string().optional() });
const siteUrl =
  (import.meta.env.VITE_SITE_URL as string | undefined) ?? "https://activityplanet.app";

export const Route = createFileRoute("/auth/sign-up")({
  validateSearch: searchSchema,
  beforeLoad: async ({ context: { queryClient }, search }) => {
    if (await getSession(queryClient))
      throw redirect({ to: internalTo(search.next), replace: true });
  },
  component: SignUpPage,
});

function SignUpPage() {
  const { next } = Route.useSearch();
  const navigate = useNavigate();
  const [formError, setFormError] = useState<string | null>(null);
  const form = useForm<SignupInput>({
    resolver: zodResolver(signupSchema),
    defaultValues: { email: "", password: "", confirmPassword: "" },
  });

  async function onSubmit(values: SignupInput) {
    setFormError(null);
    const { data, error } = await supabase.auth.signUp({
      email: values.email,
      password: values.password,
      options: { emailRedirectTo: authRedirect.confirm() },
    });
    if (error) {
      setFormError(authErrorMessage(error));
      return;
    }
    // With email confirmation on there is no session yet; the link in the email finishes sign-up.
    // Supabase returns a placeholder user for an address that already exists, so the next screen
    // stays neutral about which case this is.
    if (data.session) {
      await navigate({ to: "/onboarding", replace: true });
      return;
    }
    await navigate({
      to: "/auth/check-email",
      search: { email: values.email, kind: "signup", next },
    });
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-[28px] font-extrabold tracking-[-0.025em]">Create your account</h1>
        <p className="mt-1 text-text-2">
          Any email works. A .edu address unlocks your campus space later.
        </p>
      </div>

      <OAuthButtons next={next} />

      <form onSubmit={form.handleSubmit(onSubmit)} className="flex flex-col gap-4" noValidate>
        <Field
          label="Email"
          type="email"
          autoComplete="email"
          inputMode="email"
          autoCapitalize="none"
          placeholder="you@student.gsu.edu"
          error={form.formState.errors.email?.message}
          {...form.register("email")}
        />
        <Field
          label="Password"
          type="password"
          autoComplete="new-password"
          hint="At least 8 characters."
          error={form.formState.errors.password?.message}
          {...form.register("password")}
        />
        <Field
          label="Confirm password"
          type="password"
          autoComplete="new-password"
          error={form.formState.errors.confirmPassword?.message}
          {...form.register("confirmPassword")}
        />
        <FormError>{formError}</FormError>
        <Button type="submit" size="lg" block loading={form.formState.isSubmitting}>
          Continue
        </Button>
        <p className="text-center text-[12px] leading-relaxed text-text-3">
          By continuing you agree to the{" "}
          <a href={`${siteUrl}/terms`} className="underline underline-offset-2">
            Terms
          </a>{" "}
          and{" "}
          <a href={`${siteUrl}/privacy`} className="underline underline-offset-2">
            Privacy Policy
          </a>
          .
        </p>
      </form>

      <p className="text-center text-[15px] text-text-2">
        Already have an account?{" "}
        <Link to="/auth/sign-in" search={{ next }} className="font-semibold text-primary-text">
          Sign in
        </Link>
      </p>
    </div>
  );
}
