import { useState, type FormEvent } from "react";
import { Link, createFileRoute } from "@tanstack/react-router";
import { useMutation } from "@tanstack/react-query";
import { CalendarCheck } from "lucide-react";

import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { Field, FormError } from "@/components/ui/field";
import {
  checkSuggestion,
  suggestCalendar,
  suggestionErrorMessage,
  type SuggestResult,
} from "@/lib/calendar-suggestions";

/**
 * "Suggest a calendar" at /suggest-calendar (D-042 slice 7). One field: the link to a public
 * events page or calendar feed near you. The server checks it again (D-040 rules, denylist),
 * allows five a day and keeps the link without your name. A moderator looks at it first, then
 * the collector checks it politely and lists its events only after two separate days of valid
 * events. Linked from the "Also happening" shelf, the empty feed and the You tab.
 */
export const Route = createFileRoute("/_app/suggest-calendar")({
  component: SuggestCalendarPage,
});

function SuggestCalendarPage() {
  const [url, setUrl] = useState("");
  const [fieldError, setFieldError] = useState<string | null>(null);
  const [done, setDone] = useState<SuggestResult | null>(null);

  const send = useMutation({
    mutationFn: (value: string) => suggestCalendar(value),
    onSuccess: (r) => {
      setDone(r);
      setUrl("");
    },
  });

  const onSubmit = (e: FormEvent) => {
    e.preventDefault();
    const { check, error } = checkSuggestion(url);
    setFieldError(error);
    if (!check.ok) return;
    send.mutate(check.url);
  };

  return (
    <>
      <TopBar title="Suggest a calendar" back />
      <main className="flex flex-col gap-5 pt-2 pb-8 safe-px">
        {done ? (
          <section
            className="flex flex-col items-start gap-3 rounded-card border border-border bg-surface-2 px-4 py-4"
            role="status"
          >
            <CalendarCheck className="size-6 text-primary" aria-hidden="true" />
            <p className="text-[15px] font-semibold">
              {done.status === "already_known"
                ? "We already know this one. Thanks for pointing to it."
                : "Thanks. We'll take a look."}
            </p>
            <p className="text-[14px] text-text-2">
              {done.status === "already_known"
                ? "Its events show up once it passes our checks."
                : "Someone reviews it first. Then we check the calendar on two different days, and its public events show up near you if it lists any."}
            </p>
            <div className="flex flex-wrap gap-2">
              <Button
                variant="secondary"
                onClick={() => {
                  setDone(null);
                  send.reset();
                }}
              >
                Suggest another
              </Button>
              <Link to="/" className={buttonVariants({ variant: "ghost" })}>
                Back to the feed
              </Link>
            </div>
          </section>
        ) : (
          <form className="flex flex-col gap-4" onSubmit={onSubmit} noValidate>
            <p className="text-[15px] text-text-2">
              Know a public events calendar near you, from a library, museum, park, club or venue?
              Paste its link and we'll check whether we can list its events.
            </p>
            <Field
              label="Calendar link"
              type="url"
              inputMode="url"
              autoComplete="url"
              autoCapitalize="none"
              spellCheck={false}
              placeholder="https://"
              maxLength={500}
              value={url}
              onChange={(e) => {
                setUrl(e.target.value);
                if (fieldError) setFieldError(null);
              }}
              error={fieldError ?? undefined}
              hint="The events page, or a calendar feed (.ics or RSS). Public pages only."
            />
            <FormError>{send.isError ? suggestionErrorMessage(send.error) : null}</FormError>
            <Button type="submit" block loading={send.isPending} disabled={!url.trim()}>
              Send suggestion
            </Button>
            <ul className="flex list-disc flex-col gap-1 pl-5 text-[13px] text-text-2">
              <li>We keep only the link, not who sent it.</li>
              <li>
                We read only what the site allows (robots.txt), link every event back to it, and
                remove a source on request.
              </li>
              <li>
                Sites that forbid automated collection, like Facebook, Instagram, Meetup or
                Eventbrite, can't be listed.
              </li>
            </ul>
          </form>
        )}
      </main>
    </>
  );
}
