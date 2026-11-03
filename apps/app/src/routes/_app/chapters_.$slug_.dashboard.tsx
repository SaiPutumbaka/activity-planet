import { useState } from "react";
import { Link, createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { BarChart3, CalendarX, CircleAlert, Lock } from "lucide-react";

import { AttendanceChart, AttendanceTable } from "@/components/chapters/attendance-chart";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { SegmentedControl } from "@/components/ui/segmented";
import { Skeleton } from "@/components/ui/skeleton";
import {
  DASHBOARD_WEEK_OPTIONS,
  attendanceErrorMessage,
  chapterDashboardQuery,
  formatPercent,
  formatWeekLabel,
  isForbidden,
  returningRate,
  type ChapterDashboard,
  type DashboardWeeks,
} from "@/lib/attendance";
import { chapterBySlugQuery, type ChapterDetail } from "@/lib/chapters";

/**
 * A chapter's attendance dashboard (PLAN.md 4.5): for its captains, organizers and moderators
 * (chapter_dashboard raises forbidden for anyone else). Counts only, never names: plans held,
 * people who came (checked in or said they went), and how many of them had been before.
 * `chapters_.$slug_.dashboard.tsx` makes /chapters/:slug/dashboard a sibling of the chapter page.
 */
export const Route = createFileRoute("/_app/chapters_/$slug_/dashboard")({
  loader: ({ context: { queryClient }, params }) => {
    void queryClient.prefetchQuery(chapterBySlugQuery(params.slug));
  },
  component: DashboardPage,
});

function DashboardPage() {
  const { slug } = Route.useParams();
  const chapter = useQuery(chapterBySlugQuery(slug));

  return (
    <>
      <TopBar title="Dashboard" back />
      <main className="flex flex-col gap-6 pt-2 pb-8 safe-px">
        {chapter.isPending ? (
          <DashboardSkeleton />
        ) : chapter.isError ? (
          <EmptyState
            icon={CircleAlert}
            title="Couldn't load this chapter"
            body="Check your connection and try again."
            action={
              <Button variant="secondary" onClick={() => void chapter.refetch()}>
                Try again
              </Button>
            }
          />
        ) : !chapter.data ? (
          <EmptyState
            icon={CalendarX}
            title="No chapter here"
            body="That chapter doesn't exist, or it isn't active anymore."
          />
        ) : (
          <Dashboard chapter={chapter.data} />
        )}
      </main>
    </>
  );
}

const WEEK_OPTIONS = DASHBOARD_WEEK_OPTIONS.map((w) => ({
  value: String(w) as `${DashboardWeeks}`,
  label: `${w} weeks`,
}));

function Dashboard({ chapter }: { chapter: ChapterDetail }) {
  const [weeks, setWeeks] = useState<DashboardWeeks>(12);
  const dash = useQuery(chapterDashboardQuery(chapter.id, weeks));

  if (dash.isError) {
    return isForbidden(dash.error) ? (
      <EmptyState
        icon={Lock}
        title="For the chapter's captains"
        body="Captains and organizers of this chapter can see its attendance here."
        action={
          <Link
            to="/chapters/$slug"
            params={{ slug: chapter.slug }}
            className={buttonVariants({ variant: "secondary" })}
          >
            Back to the chapter
          </Link>
        }
      />
    ) : (
      <EmptyState
        icon={CircleAlert}
        title="Couldn't load the numbers"
        body={attendanceErrorMessage(dash.error)}
        action={
          <Button variant="secondary" onClick={() => void dash.refetch()}>
            Try again
          </Button>
        }
      />
    );
  }

  return (
    <>
      <section className="flex flex-col gap-3">
        <h2 className="text-[24px] leading-tight font-extrabold tracking-[-0.02em] text-balance">
          {chapter.name}
        </h2>
        <SegmentedControl
          label="Time range"
          value={String(weeks) as `${DashboardWeeks}`}
          onChange={(v) => setWeeks(Number(v) as DashboardWeeks)}
          options={WEEK_OPTIONS}
        />
      </section>
      {dash.isPending || !dash.data ? (
        dash.isPending ? (
          <DashboardSkeleton />
        ) : (
          <EmptyState icon={BarChart3} title="No numbers yet" body="Try again in a bit." />
        )
      ) : (
        <DashboardBody data={dash.data} />
      )}
    </>
  );
}

function DashboardBody({ data }: { data: ChapterDashboard }) {
  const t = data.totals;
  const range =
    data.from && data.to ? `${formatWeekLabel(data.from)} to ${formatWeekLabel(data.to)}` : null;

  return (
    <>
      <section aria-label="Totals" className="grid grid-cols-2 gap-2">
        <Stat label="Plans held" value={String(t.eventsHeld)} />
        <Stat label="People who came" value={String(t.distinctAttendees)} />
        <Stat
          label="Came back"
          value={formatPercent(returningRate(t))}
          detail={`${t.returningAttendees} of ${t.distinctAttendees}`}
        />
        <Stat label="Members" value={String(data.membersCount)} />
      </section>
      <p className="-mt-3 text-[13px] text-text-2">
        {range ? `${range}. ` : ""}Weeks start Monday, Eastern time. "Came" counts check-ins and
        people who said they went; "came back" means they'd been to an earlier plan of this chapter.
      </p>

      {t.eventsHeld === 0 ? (
        <EmptyState
          icon={BarChart3}
          title="No plans have ended yet"
          body="Once this chapter's plans happen, attendance shows up here week by week."
        />
      ) : (
        <>
          <AttendanceChart weeks={data.byWeek} />
          <details className="group rounded-card border border-border">
            <summary className="flex min-h-11 cursor-pointer items-center px-4 text-[15px] font-semibold">
              Show as a table
            </summary>
            <div className="px-4 pb-3">
              <AttendanceTable weeks={data.byWeek} />
            </div>
          </details>
        </>
      )}
    </>
  );
}

function Stat({ label, value, detail }: { label: string; value: string; detail?: string }) {
  return (
    <div className="flex flex-col gap-0.5 rounded-card border border-border p-3">
      <span className="text-[13px] text-text-2">{label}</span>
      <span className="text-[26px] leading-tight font-extrabold tracking-[-0.02em] tabular">
        {value}
      </span>
      {detail ? <span className="text-[12px] text-text-3 tabular">{detail}</span> : null}
    </div>
  );
}

function DashboardSkeleton() {
  return (
    <div className="flex flex-col gap-4" aria-busy="true">
      <div className="grid grid-cols-2 gap-2">
        <Skeleton className="h-20 rounded-card" />
        <Skeleton className="h-20 rounded-card" />
        <Skeleton className="h-20 rounded-card" />
        <Skeleton className="h-20 rounded-card" />
      </div>
      <Skeleton className="h-48 rounded-card" />
    </div>
  );
}
