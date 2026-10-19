import type { Metadata } from "next";

import { CreateEventForm } from "@/components/shared/create-event-form";

export const metadata: Metadata = {
  title: "Create event",
};

export default function CreateEventPage() {
  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Create an event</h1>
        <p className="text-sm text-muted-foreground">
          Post an activity and let your campus join in.
        </p>
      </div>
      <CreateEventForm />
    </div>
  );
}
