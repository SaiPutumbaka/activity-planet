import type { Metadata } from "next";

import { LoginForm } from "@/components/shared/login-form";

export const metadata: Metadata = {
  title: "Log in",
};

interface LoginPageProps {
  searchParams: Promise<{ next?: string; error?: string }>;
}

export default async function LoginPage({ searchParams }: LoginPageProps) {
  const { next, error } = await searchParams;

  return (
    <>
      {error ? (
        <p
          role="alert"
          className="w-full max-w-sm rounded-md border border-destructive/50 bg-destructive/10 px-4 py-3 text-sm text-destructive"
        >
          {error}
        </p>
      ) : null}
      <LoginForm nextPath={next} />
    </>
  );
}
