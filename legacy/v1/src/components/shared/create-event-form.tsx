"use client";

import { useState, useTransition } from "react";
import { zodResolver } from "@hookform/resolvers/zod";
import { Loader2, MapPinCheck } from "lucide-react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";

import { createEventAction } from "@/actions/events";
import { HubPicker } from "@/components/shared/hub-picker";
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
import {
  createEventSchema,
  type CreateEventInput,
} from "@/lib/validation/event";

export function CreateEventForm() {
  const [isPending, startTransition] = useTransition();
  const [coords, setCoords] = useState<Coordinates | null>(null);

  const form = useForm<CreateEventInput>({
    resolver: zodResolver(createEventSchema),
    defaultValues: {
      title: "",
      description: "",
      category: undefined,
      location: "",
      eventTimestamp: "",
    },
  });

  function handleLocated(next: Coordinates, place: string | null) {
    setCoords(next);
    if (place && !form.getValues("location")) {
      form.setValue("location", place, { shouldValidate: true });
    }
    toast.success("Location pinned — it'll show on the hub map.");
  }

  function onSubmit(values: CreateEventInput) {
    startTransition(async () => {
      // datetime-local strings carry no timezone; convert in the browser,
      // where the user's local timezone is known, before sending.
      const result = await createEventAction({
        ...values,
        eventTimestamp: new Date(values.eventTimestamp).toISOString(),
        latitude: coords?.latitude,
        longitude: coords?.longitude,
      });
      // Success redirects on the server and never returns.
      if (result.status === "error") {
        toast.error(result.message);
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
          name="title"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Title</FormLabel>
              <FormControl>
                <Input
                  placeholder="Pickup basketball at the rec"
                  {...field}
                />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />
        <FormField
          control={form.control}
          name="category"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Hub</FormLabel>
              <FormControl>
                <HubPicker
                  mode="single"
                  value={field.value}
                  onChange={field.onChange}
                />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />
        <FormField
          control={form.control}
          name="eventTimestamp"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Date &amp; time</FormLabel>
              <FormControl>
                <Input type="datetime-local" {...field} />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />
        <FormField
          control={form.control}
          name="location"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Location</FormLabel>
              <div className="flex gap-2">
                <FormControl>
                  <Input placeholder="Student Rec Center, Court 2" {...field} />
                </FormControl>
                <UseMyLocationButton onLocated={handleLocated} label="Pin here" />
              </div>
              <FormDescription>
                {coords ? (
                  <span className="flex items-center gap-1 text-primary">
                    <MapPinCheck className="h-3.5 w-3.5" aria-hidden />
                    Pinned — this event will show on the hub map.
                  </span>
                ) : (
                  "Pin your current location so this event shows up on the hub map."
                )}
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />
        <FormField
          control={form.control}
          name="description"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Description</FormLabel>
              <FormControl>
                <Textarea
                  rows={4}
                  placeholder="What should people know? Skill level, what to bring, where to meet…"
                  {...field}
                />
              </FormControl>
              <FormDescription>Optional, up to 2,000 characters.</FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />
        <Button type="submit" className="w-full" disabled={isPending}>
          {isPending ? (
            <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
          ) : null}
          Post event
        </Button>
      </form>
    </Form>
  );
}
