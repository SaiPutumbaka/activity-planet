"use client";

import { useState, useTransition } from "react";
import { zodResolver } from "@hookform/resolvers/zod";
import { ArrowLeft, Loader2 } from "lucide-react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";

import { completeOnboardingAction } from "@/actions/onboarding";
import { HubPicker } from "@/components/shared/hub-picker";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
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
import { MAX_HUBS } from "@/lib/validation/profile";
import {
  onboardingSchema,
  type OnboardingInput,
} from "@/lib/validation/onboarding";

export function OnboardingFlow() {
  const [step, setStep] = useState<1 | 2>(1);
  const [isPending, startTransition] = useTransition();

  const form = useForm<OnboardingInput>({
    resolver: zodResolver(onboardingSchema),
    defaultValues: {
      username: "",
      fullName: "",
      organization: "",
      selectedHobbies: [],
    },
  });

  const selectedHobbies = form.watch("selectedHobbies");

  async function goToStep2() {
    const valid = await form.trigger(["username", "fullName", "organization"]);
    if (valid) {
      setStep(2);
    }
  }

  function onSubmit(values: OnboardingInput) {
    startTransition(async () => {
      const result = await completeOnboardingAction(values);
      // Success redirects on the server and never returns.
      if (result.status === "error") {
        toast.error(result.message);
      }
    });
  }

  return (
    <Card className="w-full max-w-lg">
      <CardHeader className="text-center">
        <p className="text-sm font-medium text-muted-foreground">
          Step {step} of 2
        </p>
        <CardTitle className="text-2xl">
          {step === 1 ? "Set up your profile" : "Pick your hubs"}
        </CardTitle>
        <CardDescription>
          {step === 1
            ? "Choose a username and, optionally, your name and organization."
            : `Hubs personalize your feed. Pick up to ${MAX_HUBS} you're into.`}
        </CardDescription>
      </CardHeader>
      <CardContent>
        <Form {...form}>
          <form
            onSubmit={form.handleSubmit(onSubmit)}
            className="space-y-6"
            noValidate
          >
            {step === 1 ? (
              <>
                <FormField
                  control={form.control}
                  name="username"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Username</FormLabel>
                      <FormControl>
                        <Input
                          autoComplete="username"
                          placeholder="e.g. sai_plays_pool"
                          {...field}
                        />
                      </FormControl>
                      <FormDescription>
                        3–24 characters. Letters, numbers, and underscores.
                      </FormDescription>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                <FormField
                  control={form.control}
                  name="fullName"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Name</FormLabel>
                      <FormControl>
                        <Input
                          autoComplete="name"
                          placeholder="e.g. Sai Putumbaka"
                          {...field}
                        />
                      </FormControl>
                      <FormDescription>
                        Optional — shown above your username on your profile.
                      </FormDescription>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                <FormField
                  control={form.control}
                  name="organization"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Organization</FormLabel>
                      <FormControl>
                        <Input
                          placeholder="Georgia State University"
                          {...field}
                        />
                      </FormControl>
                      <FormDescription>
                        Optional — your college, company, or community.
                      </FormDescription>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                <Button type="button" className="w-full" onClick={goToStep2}>
                  Continue
                </Button>
              </>
            ) : (
              <>
                <FormField
                  control={form.control}
                  name="selectedHobbies"
                  render={() => (
                    <FormItem>
                      <FormControl>
                        <HubPicker
                          mode="multi"
                          value={selectedHobbies}
                          onChange={(next) =>
                            form.setValue("selectedHobbies", next, {
                              shouldValidate: true,
                            })
                          }
                          max={MAX_HUBS}
                        />
                      </FormControl>
                      <FormMessage className="pt-2 text-center" />
                    </FormItem>
                  )}
                />
                <div className="flex gap-3">
                  <Button
                    type="button"
                    variant="outline"
                    onClick={() => setStep(1)}
                    disabled={isPending}
                  >
                    <ArrowLeft className="h-4 w-4" aria-hidden />
                    Back
                  </Button>
                  <Button type="submit" className="flex-1" disabled={isPending}>
                    {isPending ? (
                      <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
                    ) : null}
                    Finish &amp; explore
                  </Button>
                </div>
              </>
            )}
          </form>
        </Form>
      </CardContent>
    </Card>
  );
}
