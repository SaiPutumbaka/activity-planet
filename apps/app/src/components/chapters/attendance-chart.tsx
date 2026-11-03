import {
  barPercent,
  chartMax,
  formatPercent,
  formatWeekLabel,
  labelStep,
  returningRate,
  type DashboardWeek,
} from "@/lib/attendance";
import { cn } from "@/lib/cn";

/**
 * Weekly attendance as CSS bars (no chart library): one column per week, the returning
 * attendees at the base in the accent and first-timers above in neutral grey, with a 2 px
 * surface gap between them and a 4 px rounded top. A second row of bars shows the returning
 * rate. Both plots are hidden from assistive tech; AttendanceTable is the accessible version
 * and the dashboard offers it under "Show as a table".
 */
export function AttendanceChart({ weeks }: { weeks: DashboardWeek[] }) {
  const max = chartMax(weeks);
  const step = labelStep(weeks.length);

  return (
    <div className="flex flex-col gap-5">
      <figure className="flex flex-col gap-2">
        <figcaption className="flex flex-wrap items-center justify-between gap-2">
          <span className="text-[15px] font-semibold">People who came, by week</span>
          <span className="flex items-center gap-3 text-[13px] text-text-2">
            <LegendSwatch className="bg-primary" label="Returning" />
            <LegendSwatch className="bg-info-dot" label="First time" />
          </span>
        </figcaption>
        <div aria-hidden="true" className="flex flex-col gap-1">
          <div className="relative flex h-40 items-end gap-0.5 border-b border-border">
            <span className="absolute top-0 left-0 text-[11px] text-text-3 tabular">{max}</span>
            {weeks.map((w) => {
              const firstTime = Math.max(0, w.distinctAttendees - w.returningAttendees);
              const tip = `Week of ${formatWeekLabel(w.weekStart)}: ${w.distinctAttendees} came, ${w.returningAttendees} returning`;
              return (
                <div
                  key={w.weekStart}
                  title={tip}
                  className="group flex h-full min-w-0 flex-1 flex-col justify-end hover:bg-surface-2"
                >
                  <div
                    className={cn(
                      "w-full rounded-t-[4px] bg-info-dot",
                      w.returningAttendees > 0 && firstTime > 0 && "mb-0.5",
                    )}
                    style={{ height: `${barPercent(firstTime, max)}%` }}
                  />
                  <div
                    className={cn("w-full bg-primary", firstTime === 0 && "rounded-t-[4px]")}
                    style={{ height: `${barPercent(w.returningAttendees, max)}%` }}
                  />
                </div>
              );
            })}
          </div>
          <WeekAxis weeks={weeks} step={step} />
        </div>
      </figure>

      <figure className="flex flex-col gap-2">
        <figcaption className="text-[15px] font-semibold">Returning rate, by week</figcaption>
        <div aria-hidden="true" className="flex flex-col gap-1">
          <div className="relative flex h-20 items-end gap-0.5 border-b border-border">
            <span className="absolute top-0 left-0 text-[11px] text-text-3 tabular">100%</span>
            {weeks.map((w) => {
              const rate = returningRate(w);
              return (
                <div
                  key={w.weekStart}
                  title={`Week of ${formatWeekLabel(w.weekStart)}: ${formatPercent(rate)} returning`}
                  className="flex h-full min-w-0 flex-1 flex-col justify-end hover:bg-surface-2"
                >
                  <div
                    className="w-full rounded-t-[4px] bg-primary"
                    style={{ height: `${rate === null ? 0 : rate * 100}%` }}
                  />
                </div>
              );
            })}
          </div>
          <WeekAxis weeks={weeks} step={step} />
        </div>
      </figure>
    </div>
  );
}

function LegendSwatch({ className, label }: { className: string; label: string }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <span aria-hidden="true" className={cn("size-2.5 rounded-[2px]", className)} />
      {label}
    </span>
  );
}

function WeekAxis({ weeks, step }: { weeks: DashboardWeek[]; step: number }) {
  return (
    <div className="flex gap-0.5">
      {weeks.map((w, i) => (
        <span
          key={w.weekStart}
          className="min-w-0 flex-1 overflow-visible text-[11px] whitespace-nowrap text-text-3 tabular"
        >
          {i % step === 0 ? formatWeekLabel(w.weekStart) : ""}
        </span>
      ))}
    </div>
  );
}

/** The same numbers as a table: the accessible alternative to the bars. */
export function AttendanceTable({ weeks }: { weeks: DashboardWeek[] }) {
  return (
    <div className="-mx-4 overflow-x-auto px-4">
      <table className="w-full min-w-[480px] border-collapse text-left text-[14px] tabular">
        <caption className="sr-only">Attendance by week, oldest first</caption>
        <thead>
          <tr className="border-b border-border text-[12px] text-text-2">
            <th scope="col" className="py-2 pr-3 font-semibold">
              Week of
            </th>
            <th scope="col" className="py-2 pr-3 text-right font-semibold">
              Plans
            </th>
            <th scope="col" className="py-2 pr-3 text-right font-semibold">
              Going
            </th>
            <th scope="col" className="py-2 pr-3 text-right font-semibold">
              Checked in
            </th>
            <th scope="col" className="py-2 pr-3 text-right font-semibold">
              Said they went
            </th>
            <th scope="col" className="py-2 pr-3 text-right font-semibold">
              Came
            </th>
            <th scope="col" className="py-2 pr-3 text-right font-semibold">
              Returning
            </th>
            <th scope="col" className="py-2 text-right font-semibold">
              Rate
            </th>
          </tr>
        </thead>
        <tbody>
          {weeks.map((w) => (
            <tr key={w.weekStart} className="border-b border-border last:border-0">
              <th scope="row" className="py-2 pr-3 font-medium">
                {formatWeekLabel(w.weekStart)}
              </th>
              <td className="py-2 pr-3 text-right">{w.eventsHeld}</td>
              <td className="py-2 pr-3 text-right">{w.going}</td>
              <td className="py-2 pr-3 text-right">{w.checkedIn}</td>
              <td className="py-2 pr-3 text-right">{w.selfReported}</td>
              <td className="py-2 pr-3 text-right">{w.distinctAttendees}</td>
              <td className="py-2 pr-3 text-right">{w.returningAttendees}</td>
              <td className="py-2 text-right">{formatPercent(returningRate(w))}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
