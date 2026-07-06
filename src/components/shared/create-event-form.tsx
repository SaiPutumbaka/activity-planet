"use client";

import { useTransition } from "react";
import { zodResolver } from "@hookform/resolvers/zod";
import { Loader2 } from "lucide-react";
import { useForm } from "react-hook-form";
import { toast } from "sonner";

import { createEventAction } from "@/actions/events";
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { HUB_EMOJI } from "@/lib/hubs";
import {
  createEventSchema,
  type CreateEventInput,
} from "@/lib/validation/event";
import { HUBS } from "@/types/database";

export function CreateEventForm() {
  const [isPending, startTransition] = useTransition();

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

  function onSubmit(values: CreateEventInput) {
    startTransition(async () => {
      // datetime-local strings carry no timezone; convert in the browser,
      // where the user's local timezone is known, before sending.
      const result = await createEventAction({
        ...values,
        eventTimestamp: new Date(values.eventTimestamp).toISOString(),
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
              <Select onValueChange={field.onChange} value={field.value}>
                <FormControl>
                  <SelectTrigger>
                    <SelectValue placeholder="Pick a hub" />
                  </SelectTrigger>
                </FormControl>
                <SelectContent>
                  {HUBS.map((hub) => (
                    <SelectItem key={hub} value={hub}>
                      {HUB_EMOJI[hub]} {hub}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
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
              <FormControl>
                <Input
                  placeholder="Student Rec Center, Court 2"
                  {...field}
                />
              </FormControl>
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
