"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { zodResolver } from "@hookform/resolvers/zod";
import { Loader2, MailCheck } from "lucide-react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";

import { signUpAction } from "@/actions/auth";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/components/ui/form";
import { Input } from "@/components/ui/input";
import { signupSchema, type SignupInput } from "@/lib/validation/auth";

export function SignupForm() {
  const [isPending, startTransition] = useTransition();
  const [confirmationSent, setConfirmationSent] = useState(false);

  const form = useForm<SignupInput>({
    resolver: zodResolver(signupSchema),
    defaultValues: { email: "", password: "", confirmPassword: "" },
  });

  function onSubmit(values: SignupInput) {
    startTransition(async () => {
      const result = await signUpAction(values);
      // Instant-session signups redirect on the server and never return.
      if (result.status === "error") {
        toast.error(result.message);
        return;
      }
      setConfirmationSent(true);
    });
  }

  if (confirmationSent) {
    return (
      <Card className="w-full max-w-sm text-center">
        <CardHeader>
          <MailCheck
            className="mx-auto h-10 w-10 text-primary"
            aria-hidden
          />
          <CardTitle className="text-2xl">Check your email</CardTitle>
          <CardDescription>
            We sent a confirmation link to{" "}
            <span className="font-medium text-foreground">
              {form.getValues("email")}
            </span>
            . Click it to activate your account, then come back and log in.
          </CardDescription>
        </CardHeader>
        <CardFooter className="justify-center">
          <Button variant="outline" asChild>
            <Link href="/login">Back to login</Link>
          </Button>
        </CardFooter>
      </Card>
    );
  }

  return (
    <Card className="w-full max-w-sm">
      <CardHeader className="text-center">
        <CardTitle className="text-2xl">Create your account</CardTitle>
        <CardDescription>
          Join the beta and start turning shared interests into real plans.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <Form {...form}>
          <form
            onSubmit={form.handleSubmit(onSubmit)}
            className="space-y-4"
            noValidate
          >
            <FormField
              control={form.control}
              name="email"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Email</FormLabel>
                  <FormControl>
                    <Input
                      type="email"
                      autoComplete="email"
                      placeholder="you@university.edu"
                      {...field}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />
            <FormField
              control={form.control}
              name="password"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Password</FormLabel>
                  <FormControl>
                    <Input
                      type="password"
                      autoComplete="new-password"
                      placeholder="••••••••"
                      {...field}
                    />
                  </FormControl>
                  <FormDescription>At least 8 characters.</FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />
            <FormField
              control={form.control}
              name="confirmPassword"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Confirm password</FormLabel>
                  <FormControl>
                    <Input
                      type="password"
                      autoComplete="new-password"
                      placeholder="••••••••"
                      {...field}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />
            <Button type="submit" className="w-full" disabled={isPending}>
              {isPending ? (
                <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
              ) : null}
              Sign up
            </Button>
          </form>
        </Form>
      </CardContent>
      <CardFooter className="justify-center text-sm text-muted-foreground">
        <p>
          Already have an account?{" "}
          <Link
            href="/login"
            className="font-medium text-primary underline-offset-4 hover:underline"
          >
            Log in
          </Link>
        </p>
      </CardFooter>
    </Card>
  );
}
