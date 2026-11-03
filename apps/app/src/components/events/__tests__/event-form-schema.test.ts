import { describe, expect, it } from "vitest";

import {
  defaultEventFormValues,
  eventFormSchema,
  postAsArgs,
  toCreateEventArgs,
  toCreateEventSeriesArgs,
  type EventArgsContext,
  type EventFormValues,
} from "../event-form-schema";

const TZ = "America/New_York";
const NOW = new Date("2026-11-03T15:00:00Z");
const ctx: EventArgsContext = { campusId: null, forceIs21: false, timeZone: TZ };

function values(overrides: Partial<EventFormValues> = {}): EventFormValues {
  return {
    ...defaultEventFormValues({ hubId: "hub-1", timeZone: TZ, now: NOW }),
    title: "Pickup basketball",
    locationMode: "text",
    locationText: "The Rec",
    ...overrides,
  };
}

describe("post as", () => {
  it("posts as the viewer by default", () => {
    expect(postAsArgs({ postAs: "" })).toEqual({ kind: "member" });
    const args = toCreateEventArgs(values(), ctx);
    expect(args.kind).toBe("member");
    expect(args).not.toHaveProperty("chapter_id");
  });

  it("posts as a chapter when one is chosen", () => {
    const args = toCreateEventArgs(values({ postAs: "ch-1" }), ctx);
    expect(args.kind).toBe("chapter");
    expect(args.chapter_id).toBe("ch-1");
    expect(args.hub_id).toBe("hub-1");
  });

  it("prefills the chapter and repeat from the defaults", () => {
    const v = defaultEventFormValues({
      hubId: "hub-1",
      chapterId: "ch-1",
      repeatWeekly: true,
      timeZone: TZ,
      now: NOW,
    });
    expect(v.postAs).toBe("ch-1");
    expect(v.repeatWeekly).toBe(true);
    expect(v.startsOn).toBe("2026-11-03");
    expect(v.endsOn).toBe("");
  });
});

describe("weekly series", () => {
  it("runs for a number of weeks when there is no last date", () => {
    const args = toCreateEventSeriesArgs(
      values({ repeatWeekly: true, postAs: "ch-1", weekday: "2", startTime: "18:30", weeks: "6" }),
      ctx,
    );
    expect(args).toMatchObject({
      kind: "chapter",
      chapter_id: "ch-1",
      weekday: 2,
      start_time: "18:30",
      starts_on: "2026-11-03",
      max_occurrences: 6,
    });
    expect(args).not.toHaveProperty("ends_on");
    expect(args).not.toHaveProperty("starts_at");
  });

  it("uses the date range when a last date is given", () => {
    const args = toCreateEventSeriesArgs(
      values({ repeatWeekly: true, startsOn: "2027-01-12", endsOn: "2027-04-27" }),
      ctx,
    );
    expect(args.starts_on).toBe("2027-01-12");
    expect(args.ends_on).toBe("2027-04-27");
    expect(args).not.toHaveProperty("max_occurrences");
    expect(args.kind).toBe("member");
  });

  it("refuses a last date before the first", () => {
    const parsed = eventFormSchema.safeParse(
      values({ repeatWeekly: true, startsOn: "2027-02-01", endsOn: "2027-01-01" }),
    );
    expect(parsed.success).toBe(false);
    expect(parsed.error?.issues.map((i) => i.path[0])).toContain("endsOn");
  });

  it("refuses a range longer than a year of weeks", () => {
    const parsed = eventFormSchema.safeParse(
      values({ repeatWeekly: true, startsOn: "2027-01-01", endsOn: "2028-06-01" }),
    );
    expect(parsed.success).toBe(false);
  });

  it("ignores the week count when a last date bounds the series", () => {
    const parsed = eventFormSchema.safeParse(
      values({ repeatWeekly: true, startsOn: "2027-01-12", endsOn: "2027-03-01", weeks: "" }),
    );
    expect(parsed.success).toBe(true);
  });
});
