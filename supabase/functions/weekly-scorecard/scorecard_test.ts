// weekly-scorecard tests (fake RPCs and sender; no network, no key).
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import {
  type Counts,
  flatten,
  render,
  runScorecard,
  type ScorecardEmail,
  validWeek,
} from "./scorecard.ts";

const fixture = JSON.parse(
  await Deno.readTextFile(new URL("./fixtures/week.json", import.meta.url)),
) as Counts;

function fakeDb(state: {
  status: string | null;
  previous_counts: Counts | null;
  budget?: boolean;
}) {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const runs = new Map<string, { status: string }>();
  if (state.status) runs.set("2026-11-02", { status: state.status });
  const rpc = (name: string, args: Record<string, unknown>) => {
    calls.push({ name, args });
    if (name === "scorecard_run_state") {
      return Promise.resolve({
        week_start: (args.p_week_start as string | null) ?? "2026-11-02",
        status: runs.get("2026-11-02")?.status ?? null,
        previous_counts: state.previous_counts,
      });
    }
    if (name === "scorecard_week") return Promise.resolve(fixture);
    if (name === "email_budget_take") return Promise.resolve(state.budget ?? true);
    if (name === "scorecard_record") {
      const week = (args.p_week_start as string | null) ?? "2026-11-02";
      if (runs.get(week)?.status !== "sent") runs.set(week, { status: args.p_status as string });
      return Promise.resolve({ week_start: week, status: runs.get(week)?.status });
    }
    return Promise.reject(new Error(`unexpected ${name}`));
  };
  return { rpc, calls, runs };
}

Deno.test(
  "the key gate: without RESEND_API_KEY or SCORECARD_TO, skipped_no_key and nothing else",
  async () => {
    for (const [key, to] of [
      ["", "me@example.com"],
      ["re_test", ""],
      ["", ""],
    ]) {
      const db = fakeDb({ status: null, previous_counts: null });
      const sent: ScorecardEmail[] = [];
      const res = await runScorecard(
        {
          rpc: db.rpc,
          resendKey: key,
          to,
          send: (m) => (sent.push(m), Promise.resolve("sent")),
          adminUrl: "https://a.example/admin",
        },
        null,
      );
      assertEquals(res.status, "skipped_no_key");
      assertEquals(
        db.calls.map((c) => c.name),
        ["scorecard_record"],
      );
      assertEquals(db.calls[0].args.p_status, "skipped_no_key");
      assertEquals(db.calls[0].args.p_counts, {});
      assertEquals(sent.length, 0);
    }
  },
);

Deno.test("the template from the fixture: numbers, labels and the admin link, no names", () => {
  const { subject, text, html } = render("2026-11-02", fixture, null, {
    adminUrl: "https://a.example/admin",
  });
  assertEquals(subject, "Activity Planet weekly scorecard, week of 2026-11-02");
  assert(text.includes("people / signups: 12"));
  assert(text.includes("coaching / gmv minor / usd: 4000"));
  assert(text.includes("launch gate / chapters live / target: 5"));
  assert(text.includes("Admin panel: https://a.example/admin"));
  assert(!text.includes("week start"));
  assert(html.startsWith("<h1>Activity Planet weekly scorecard"));
  assert(html.includes('<a href="https://a.example/admin">Admin panel</a>'));
  assertEquals(flatten(fixture, null).length, 34);
});

Deno.test("deltas against last week's stored counts", () => {
  const prev = structuredClone(fixture) as Counts;
  (prev.people as Counts).signups = 10;
  (prev.plans as Counts).second_attendance_rate = 0.2;
  delete (prev.messages as Counts).sent;
  const rows = flatten(fixture, prev);
  const get = (p: string) => rows.find((r) => r.path.join(".") === p)!;
  assertEquals(get("people.signups").delta, 2);
  assertEquals(get("plans.second_attendance_rate").delta, 0.05);
  assertEquals(get("messages.sent").delta, null);
  assertEquals(get("people.wau").delta, 0);
  const { text } = render("2026-11-02", fixture, prev, { adminUrl: "https://a.example/admin" });
  assert(text.includes("people / signups: 12 (+2)"));
  assert(text.includes("people / wau: 40 (no change)"));
  assert(text.includes("messages / sent: 120\n"));
});

Deno.test("sent once; the second call for the same week sends nothing", async () => {
  const db = fakeDb({ status: null, previous_counts: null });
  const sent: ScorecardEmail[] = [];
  const deps = {
    rpc: db.rpc,
    resendKey: "re_test",
    to: "me@example.com",
    send: (m: ScorecardEmail) => (sent.push(m), Promise.resolve("sent" as const)),
    adminUrl: "https://a.example/admin",
  };
  const first = await runScorecard(deps, "2026-11-02");
  assertEquals(first.status, "sent");
  assertEquals(sent.length, 1);
  assertEquals(sent[0].id, "scorecard-2026-11-02");
  assertEquals(sent[0].to, "me@example.com");
  const second = await runScorecard(deps, "2026-11-02");
  assertEquals(second.status, "already_sent");
  assertEquals(sent.length, 1);
  assertEquals(db.runs.get("2026-11-02")?.status, "sent");
});

Deno.test("a refused email is recorded as failed with a code", async () => {
  const db = fakeDb({ status: null, previous_counts: null });
  const res = await runScorecard(
    {
      rpc: db.rpc,
      resendKey: "re_test",
      to: "me@example.com",
      send: () => Promise.resolve("retry"),
      adminUrl: "https://a.example/admin",
    },
    null,
  );
  assertEquals(res.status, "failed");
  const rec = db.calls.find((c) => c.name === "scorecard_record")!;
  assertEquals([rec.args.p_status, rec.args.p_error], ["failed", "resend_retry"]);
});

Deno.test("past the account-wide email budget nothing is sent and the run is failed", async () => {
  const db = fakeDb({ status: null, previous_counts: null, budget: false });
  const sent: ScorecardEmail[] = [];
  const res = await runScorecard(
    {
      rpc: db.rpc,
      resendKey: "re_test",
      to: "me@example.com",
      send: (m: ScorecardEmail) => (sent.push(m), Promise.resolve("sent" as const)),
      adminUrl: "https://a.example/admin",
    },
    null,
  );
  assertEquals(res.status, "failed");
  assertEquals(sent.length, 0);
  const rec = db.calls.find((c) => c.name === "scorecard_record")!;
  assertEquals([rec.args.p_status, rec.args.p_error], ["failed", "email_budget"]);
});

Deno.test("validWeek", () => {
  assertEquals(validWeek("2026-11-02"), "2026-11-02");
  assertEquals(validWeek("2026-11-02'; drop"), null);
  assertEquals(validWeek(7), null);
});
