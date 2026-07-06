"use client";

import { useState, useTransition } from "react";
import { zodResolver } from "@hookform/resolvers/zod";
import { ArrowLeft, Loader2 } from "lucide-react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";

import { completeOnboardingAction } from "@/actions/onboarding";
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
import { HUB_EMOJI } from "@/lib/hubs";
import { cn } from "@/lib/utils";
import {
  onboardingSchema,
  type OnboardingInput,
} from "@/lib/validation/onboarding";
import { HUBS, type Hub } from "@/types/database";

export function OnboardingFlow() {
  const [step, setStep] = useState<1 | 2>(1);
  const [isPending, startTransition] = useTransition();

  const form = useForm<OnboardingInput>({
    resolver: zodResolver(onboardingSchema),
    defaultValues: {
      username: "",
      organization: "",
      selectedHobbies: [],
    },
  });

  const selectedHobbies = form.watch("selectedHobbies");

  async function goToStep2() {
    const valid = await form.trigger(["username", "organization"]);
    if (valid) {
      setStep(2);
    }
  }

  function toggleHub(hub: Hub) {
    const current = form.getValues("selectedHobbies");
    form.setValue(
      "selectedHobbies",
      current.includes(hub)
        ? current.filter((h) => h !== hub)
        : [...current, hub],
      { shouldValidate: true },
    );
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
            ? "Choose a username and, optionally, your school or organization."
            : "Hubs personalize your feed. Pick everything you're into."}
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
                      <div
                        role="group"
                        aria-label="Choose your hubs"
                        className="grid grid-cols-2 gap-3 sm:grid-cols-4"
                      >
                        {HUBS.map((hub) => {
                          const isSelected = selectedHobbies.includes(hub);
                          return (
                            <button
                              key={hub}
                              type="button"
                              aria-pressed={isSelected}
                              onClick={() => toggleHub(hub)}
                              className={cn(
                                "flex flex-col items-center gap-2 rounded-xl border-2 p-4 text-center text-sm font-medium transition-colors",
                                "hover:bg-accent hover:text-accent-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                                isSelected
                                  ? "border-primary bg-primary/10 text-primary"
                                  : "border-border text-foreground",
                              )}
                            >
                              <span className="text-3xl" aria-hidden>
                                {HUB_EMOJI[hub]}
                              </span>
                              {hub}
                            </button>
                          );
                        })}
                      </div>
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
