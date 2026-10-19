import { useState } from "react";
import { Link, createFileRoute, redirect, useNavigate } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { emailSchema, loginSchema, type LoginInput } from "@ap/core/validation";

import { OAuthButtons } from "@/components/auth/oauth-buttons";
import { Button } from "@/components/ui/button";
import { Field, FormError } from "@/components/ui/field";
import { authErrorMessage, authRedirect, getSession } from "@/lib/auth";
import { internalTo } from "@/lib/navigation";
import { supabase } from "@/lib/supabase";

const searchSchema = z.object({ next: z.string().optional() });

export const Route = createFileRoute("/auth/sign-in")({
  validateSearch: searchSchema,
  beforeLoad: async ({ context: { queryClient }, search }) => {
    if (await getSession(queryClient))
      throw redirect({ to: internalTo(search.next), replace: true });
  },
  component: SignInPage,
});

function SignInPage() {
  const { next } = Route.useSearch();
  const navigate = useNavigate();
  const [formError, setFormError] = useState<string | null>(null);
  const [sendingLink, setSendingLink] = useState(false);
  const form = useForm<LoginInput>({
    resolver: zodResolver(loginSchema),
    defaultValues: { email: "", password: "" },
  });

  async function onSubmit(values: LoginInput) {
    setFormError(null);
    const { error } = await supabase.auth.signInWithPassword(values);
    if (error) {
      setFormError(authErrorMessage(error));
      return;
    }
    await navigate({ to: internalTo(next), replace: true });
  }

  async function sendMagicLink() {
    setFormError(null);
    const parsed = emailSchema.safeParse(form.getValues("email"));
    if (!parsed.success) {
      form.setError("email", { message: "Enter your email first and we'll send you a link." });
      return;
    }
    setSendingLink(true);
    const { error } = await supabase.auth.signInWithOtp({
      email: parsed.data,
      options: { emailRedirectTo: authRedirect.confirm() },
    });
    setSendingLink(false);
    if (error) {
      setFormError(authErrorMessage(error));
      return;
    }
    await navigate({
      to: "/auth/check-email",
      search: { email: parsed.data, kind: "magic", next },
    });
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-[28px] font-extrabold tracking-[-0.025em]">Welcome back</h1>
        <p className="mt-1 text-text-2">Sign in to see what your hubs are doing this week.</p>
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
          autoComplete="current-password"
          error={form.formState.errors.password?.message}
          {...form.register("password")}
        />
        <FormError>{formError}</FormError>
        <Button type="submit" size="lg" block loading={form.formState.isSubmitting}>
          Sign in
        </Button>
        <div className="flex items-center justify-between text-[14px] font-semibold">
          <Link to="/auth/forgot" className="text-primary-text">
            Forgot password?
          </Link>
          <button
            type="button"
            onClick={sendMagicLink}
            disabled={sendingLink}
            className="text-primary-text disabled:opacity-50"
          >
            {sendingLink ? "Sending…" : "Email me a link instead"}
          </button>
        </div>
      </form>

      <p className="text-center text-[15px] text-text-2">
        New here?{" "}
        <Link to="/auth/sign-up" search={{ next }} className="font-semibold text-primary-text">
          Create an account
        </Link>
      </p>
    </div>
  );
}
