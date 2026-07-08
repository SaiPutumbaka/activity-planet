"use client";

import { useState, useTransition } from "react";
import { zodResolver } from "@hookform/resolvers/zod";
import { Loader2 } from "lucide-react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";
import { z } from "zod";

import { updateProfileAction } from "@/actions/profile";
import { UseMyLocationButton } from "@/components/shared/use-my-location-button";
import { Button } from "@/components/ui/button";
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
import { Textarea } from "@/components/ui/textarea";
import type { Coordinates } from "@/lib/geo";
import { organizationSchema, usernameSchema } from "@/lib/validation/profile";

const formSchema = z.object({
  username: usernameSchema,
  organization: organizationSchema,
  bio: z.string().trim().max(280, "Bio must be at most 280 characters."),
  birthday: z.string(),
  locationText: z
    .string()
    .trim()
    .max(120, "Location must be at most 120 characters."),
});

type FormValues = z.infer<typeof formSchema>;

interface ProfileDetailsFormProps {
  initial: {
    username: string;
    organization: string;
    bio: string;
    birthday: string | null;
    locationText: string;
    latitude: number | null;
    longitude: number | null;
  };
}

export function ProfileDetailsForm({ initial }: ProfileDetailsFormProps) {
  const [isPending, startTransition] = useTransition();
  const [coords, setCoords] = useState<Coordinates | null>(
    initial.latitude !== null && initial.longitude !== null
      ? { latitude: initial.latitude, longitude: initial.longitude }
      : null,
  );

  const form = useForm<FormValues>({
    resolver: zodResolver(formSchema),
    defaultValues: {
      username: initial.username,
      organization: initial.organization,
      bio: initial.bio,
      birthday: initial.birthday ?? "",
      locationText: initial.locationText,
    },
  });

  function handleLocated(next: Coordinates, place: string | null) {
    setCoords(next);
    if (place) {
      form.setValue("locationText", place, { shouldValidate: true });
    }
    toast.success("Location captured.");
  }

  function onSubmit(values: FormValues) {
    startTransition(async () => {
      const result = await updateProfileAction({
        ...values,
        latitude: coords?.latitude ?? null,
        longitude: coords?.longitude ?? null,
      });
      if (result.status === "error") {
        toast.error(result.message);
      } else {
        toast.success("Profile updated.");
      }
    });
  }

  return (
    <Form {...form}>
      <form
        onSubmit={form.handleSubmit(onSubmit)}
        className="space-y-5"
        noValidate
      >
        <FormField
          control={form.control}
          name="username"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Username</FormLabel>
              <FormControl>
                <Input autoComplete="username" {...field} />
              </FormControl>
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
                <Input placeholder="Georgia State University" {...field} />
              </FormControl>
              <FormDescription>
                Optional — your college, company, or community.
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />
        <FormField
          control={form.control}
          name="bio"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Bio</FormLabel>
              <FormControl>
                <Textarea rows={3} placeholder="A little about you…" {...field} />
              </FormControl>
              <FormDescription>Up to 280 characters.</FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />
        <FormField
          control={form.control}
          name="birthday"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Birthday</FormLabel>
              <FormControl>
                <Input type="date" {...field} />
              </FormControl>
              <FormDescription>
                Only used to show your age on your profile.
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />
        <FormField
          control={form.control}
          name="locationText"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Location</FormLabel>
              <div className="flex gap-2">
                <FormControl>
                  <Input placeholder="Atlanta, GA" {...field} />
                </FormControl>
                <UseMyLocationButton onLocated={handleLocated} label="Use current" />
              </div>
              <FormDescription>
                Powers events near you — never shown as an exact address.
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />
        <Button type="submit" className="w-full" disabled={isPending}>
          {isPending ? (
            <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
          ) : null}
          Save changes
        </Button>
      </form>
    </Form>
  );
}
