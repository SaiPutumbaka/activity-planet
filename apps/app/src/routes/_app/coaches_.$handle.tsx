import { useState } from "react";
import { Link, createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { BadgeCheck, CircleAlert, Ellipsis, MessageCircle } from "lucide-react";
import { toast } from "sonner";
import {
  coachingErrorMessage,
  formatPrice,
  fromPriceLabel,
  listingShapeLabel,
  ratingLabel,
  type Coach,
  type Review,
  type ReviewCursor,
} from "@ap/core/coaching";

import { useOpenChat } from "@/components/chats/use-open-chat";
import { Note, SectionTitle, Stars } from "@/components/coaching/parts";
import { PersonSheet } from "@/components/safety/person-sheet";
import { ReportSheet } from "@/components/safety/report-form";
import { TopBar } from "@/components/shell/top-bar";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { Skeleton } from "@/components/ui/skeleton";
import { FieldTextArea } from "@/components/ui/textarea";
import { coaching, coachQuery, coachingKeys } from "@/lib/coaching";
import { type ReportKind } from "@/lib/safety";

const appRoute = getRouteApi("/_app");

/**
 * A coach's public page (design section 15): photos, headline, "Self-reported" credentials, the
 * area and how they coach, hubs, listings with prices, reviews with the coach's reply, Message,
 * Report and Block. Never a coordinate or a distance; the service area is the coach's own label.
 */
export const Route = createFileRoute("/_app/coaches_/$handle")({
  loader: ({ context: { queryClient }, params }) => {
    void queryClient.prefetchQuery(coachQuery(params.handle));
  },
  component: CoachPage,
});

function CoachPage() {
  const { handle } = Route.useParams();
  const coach = useQuery(coachQuery(handle));
  return (
    <>
      <TopBar title={coach.data?.first_name ?? "Coach"} back />
      <main className="flex flex-col gap-6 pb-8 safe-px">
        {coach.isPending ? (
          <div className="flex flex-col gap-3 pt-2" aria-busy="true">
            <Skeleton className="h-20" />
            <Skeleton className="h-32" />
          </div>
        ) : coach.isError ? (
          <EmptyState
            icon={CircleAlert}
            title="This coach isn't available"
            body={coachingErrorMessage(coach.error)}
            action={
              <Link to="/coaches" className={buttonVariants({ variant: "secondary" })}>
                Find a coach
              </Link>
            }
          />
        ) : (
          <CoachContent coach={coach.data} />
        )}
      </main>
    </>
  );
}

function CoachContent({ coach }: { coach: Coach }) {
  const { session } = appRoute.useRouteContext();
  const [personOpen, setPersonOpen] = useState(false);
  const [report, setReport] = useState<{ kind: ReportKind; id: string } | null>(null);
  const openChat = useOpenChat();
  const from = fromPriceLabel(coach.from_prices);
  const how = [coach.in_person ? "In person" : null, coach.online ? "Online" : null]
    .filter(Boolean)
    .join(" and ");

  return (
    <>
      {coach.own && coach.status !== "active" ? (
        <Note>
          Only you can see this page until you publish it.{" "}
          <Link to="/coach" className="font-semibold text-link underline-offset-2 hover:underline">
            Coach home
          </Link>
        </Note>
      ) : null}

      <section className="flex items-center gap-4 pt-2">
        <Avatar src={coach.avatar_url} name={coach.first_name} size={72} />
        <div className="min-w-0">
          <p className="truncate text-[20px] font-extrabold tracking-tight">{coach.first_name}</p>
          <p className="text-[15px] text-text-2">{coach.headline}</p>
          <p className="text-[13px] text-text-3">
            {ratingLabel(coach.rating_avg, coach.rating_count)}
            {coach.completed_count > 0 ? ` · ${coach.completed_count} sessions` : ""}
            {from ? ` · ${from}` : ""}
          </p>
        </div>
      </section>

      {coach.photos.length > 0 ? (
        <ul className="-mx-4 flex gap-2 overflow-x-auto px-4" aria-label="Photos">
          {coach.photos.map((url) => (
            <li key={url} className="shrink-0">
              <img
                src={url}
                alt=""
                loading="lazy"
                className="size-32 rounded-card border border-border object-cover"
              />
            </li>
          ))}
        </ul>
      ) : null}

      {!coach.own ? (
        <div className="flex gap-2">
          <Button
            variant="secondary"
            leading={<MessageCircle className="size-4" aria-hidden="true" />}
            loading={openChat.isPending}
            onClick={() => openChat.mutate({ kind: "dm", userId: coach.user_id })}
          >
            Message
          </Button>
          <Button
            variant="ghost"
            size="icon"
            aria-label={`More about ${coach.first_name}`}
            aria-haspopup="dialog"
            onClick={() => setPersonOpen(true)}
          >
            <Ellipsis className="size-5" aria-hidden="true" />
          </Button>
        </div>
      ) : (
        <Link to="/coach/profile" className={buttonVariants({ variant: "secondary" })}>
          Edit coach profile
        </Link>
      )}

      <section className="flex flex-col gap-2">
        <SectionTitle>About</SectionTitle>
        <p className="text-[15px] text-text-2">
          {how}
          {coach.in_person && coach.area_label ? ` · ${coach.area_label}` : ""}
        </p>
        {coach.about ? <p className="whitespace-pre-line text-[15px]">{coach.about}</p> : null}
        {coach.hubs.length > 0 ? (
          <ul className="flex flex-wrap gap-2" aria-label="Hubs">
            {coach.hubs.map((h) => (
              <li key={h.id}>
                <Link
                  to="/hubs/$slug"
                  params={{ slug: h.slug }}
                  className="inline-flex h-9 items-center gap-1.5 rounded-control border border-border px-3 text-[14px] font-semibold hover:bg-surface-2"
                >
                  {h.emoji ? <span aria-hidden="true">{h.emoji}</span> : null}
                  {h.name}
                </Link>
              </li>
            ))}
          </ul>
        ) : null}
      </section>

      {coach.credentials.length > 0 ? (
        <section className="flex flex-col gap-2">
          <SectionTitle>Credentials</SectionTitle>
          <ul className="flex flex-col gap-1.5">
            {coach.credentials.map((c, i) => (
              <li key={i} className="flex items-start gap-2 text-[15px]">
                <BadgeCheck className="mt-0.5 size-4 shrink-0 text-text-3" aria-hidden="true" />
                <span className="min-w-0">
                  {c.title}
                  {c.issuer ? `, ${c.issuer}` : ""}
                  {c.year ? ` (${c.year})` : ""}{" "}
                  <span className="text-[12px] font-semibold text-text-3">Self-reported</span>
                </span>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <section className="flex flex-col gap-2">
        <SectionTitle>Sessions</SectionTitle>
        {coach.listings.length === 0 ? (
          <p className="text-[15px] text-text-2">No sessions to book right now.</p>
        ) : (
          <ul className="flex flex-col gap-3">
            {coach.listings.map((l) => (
              <li key={l.id} className="flex flex-col gap-2 rounded-card border border-border p-4">
                <div className="flex items-start justify-between gap-3">
                  <p className="min-w-0 text-[16px] font-bold">{l.title}</p>
                  <p className="shrink-0 text-[16px] font-bold">
                    {formatPrice(l.price_minor, l.currency)}
                  </p>
                </div>
                <p className="text-[13px] text-text-2">
                  {listingShapeLabel(l)}
                  {l.min_age === 21 ? " · 21+" : ""}
                </p>
                {l.description ? (
                  <p className="whitespace-pre-line text-[14px] text-text-2">{l.description}</p>
                ) : null}
                <div className="flex flex-wrap items-center gap-2">
                  {!coach.own ? (
                    <Link
                      to="/coaches/$handle/book/$listing"
                      params={{ handle: coach.handle, listing: l.id }}
                      className={buttonVariants({ size: "sm" })}
                    >
                      Request a time
                    </Link>
                  ) : (
                    <Link
                      to="/coach/listings/$id"
                      params={{ id: l.id }}
                      className={buttonVariants({ variant: "secondary", size: "sm" })}
                    >
                      Edit
                    </Link>
                  )}
                  {!coach.own ? (
                    <Button
                      variant="ghost"
                      size="sm"
                      className="text-text-2"
                      aria-haspopup="dialog"
                      onClick={() => setReport({ kind: "coach_listing", id: l.id })}
                    >
                      Report
                    </Button>
                  ) : null}
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      <Reviews coach={coach} onReport={(kind, id) => setReport({ kind, id })} />

      <PersonSheet
        person={
          personOpen
            ? {
                user_id: coach.user_id,
                first_name: coach.first_name,
                handle: coach.handle,
                avatar_url: coach.avatar_url,
              }
            : null
        }
        viewerId={session.user.id}
        onClose={() => setPersonOpen(false)}
      />
      <ReportSheet
        open={report !== null}
        onClose={() => setReport(null)}
        kind={report?.kind ?? "coach_listing"}
        targetId={report?.id ?? ""}
      />
    </>
  );
}

function Reviews({
  coach,
  onReport,
}: {
  coach: Coach;
  onReport: (kind: ReportKind, id: string) => void;
}) {
  const more = useInfiniteQuery({
    queryKey: [...coachingKeys.coach(coach.handle), "reviews"],
    queryFn: ({ pageParam }) => coaching.reviews(coach.user_id, pageParam),
    initialPageParam: coach.reviews.next as ReviewCursor | null,
    getNextPageParam: (last) => last.next,
    enabled: false,
  });
  const extra = more.data?.pages.flatMap((p) => p.items) ?? [];
  const items = [...coach.reviews.items, ...extra];
  const hasMore = more.data ? more.hasNextPage : coach.reviews.next !== null;

  return (
    <section className="flex flex-col gap-2" aria-labelledby="coach-reviews">
      <SectionTitle id="coach-reviews">
        Reviews {coach.rating_count > 0 ? `(${coach.rating_count})` : ""}
      </SectionTitle>
      {items.length === 0 ? (
        <p className="text-[15px] text-text-2">No reviews yet.</p>
      ) : (
        <ul className="flex flex-col gap-4">
          {items.map((r) => (
            <ReviewItem key={r.booking_id} review={r} coach={coach} onReport={onReport} />
          ))}
        </ul>
      )}
      {hasMore ? (
        <Button
          variant="secondary"
          loading={more.isFetching}
          onClick={() => void (more.data ? more.fetchNextPage() : more.refetch())}
        >
          More reviews
        </Button>
      ) : null}
    </section>
  );
}

function ReviewItem({
  review,
  coach,
  onReport,
}: {
  review: Review;
  coach: Coach;
  onReport: (kind: ReportKind, id: string) => void;
}) {
  const queryClient = useQueryClient();
  const [replying, setReplying] = useState(false);
  const [text, setText] = useState(review.reply ?? "");
  const reply = useMutation({
    mutationFn: () => coaching.replyToReview(review.booking_id, text.trim()),
    onSuccess: () => {
      toast.success("Reply posted.");
      setReplying(false);
      void queryClient.invalidateQueries({ queryKey: coachingKeys.coach(coach.handle) });
    },
    onError: (err) => toast.error(coachingErrorMessage(err)),
  });

  return (
    <li className="flex flex-col gap-1.5">
      <div className="flex items-center gap-2">
        <Avatar
          src={review.author?.avatar_url}
          name={review.author?.first_name ?? "Member"}
          size={28}
        />
        <span className="text-[14px] font-semibold">{review.author?.first_name ?? "Member"}</span>
        <Stars value={review.rating} />
      </div>
      {review.moderation_state ? (
        <p className="text-[12px] font-semibold text-text-3">Hidden by moderators</p>
      ) : null}
      {review.body ? <p className="whitespace-pre-line text-[15px]">{review.body}</p> : null}
      {review.reply ? (
        <div className="ml-4 border-l-2 border-border pl-3">
          <p className="text-[13px] font-semibold">{coach.first_name} replied</p>
          <p className="whitespace-pre-line text-[14px] text-text-2">{review.reply}</p>
        </div>
      ) : null}
      <div className="flex flex-wrap gap-1">
        {coach.own ? (
          <Button variant="ghost" size="sm" onClick={() => setReplying((v) => !v)}>
            {review.reply ? "Edit reply" : "Reply"}
          </Button>
        ) : null}
        {!review.mine && !coach.own ? (
          <Button
            variant="ghost"
            size="sm"
            className="text-text-2"
            aria-haspopup="dialog"
            onClick={() => onReport("coach_review", review.booking_id)}
          >
            Report review
          </Button>
        ) : null}
        {review.reply && !coach.own ? (
          <Button
            variant="ghost"
            size="sm"
            className="text-text-2"
            aria-haspopup="dialog"
            onClick={() => onReport("coach_review_reply", review.booking_id)}
          >
            Report reply
          </Button>
        ) : null}
      </div>
      {replying ? (
        <form
          className="flex flex-col gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            if (text.trim()) reply.mutate();
          }}
        >
          <FieldTextArea
            label="Your reply"
            rows={3}
            maxLength={1000}
            value={text}
            onChange={(e) => setText(e.target.value)}
            hint="One reply, editable for 7 days. No links."
          />
          <Button type="submit" size="sm" className="self-start" loading={reply.isPending}>
            Post reply
          </Button>
        </form>
      ) : null}
    </li>
  );
}
