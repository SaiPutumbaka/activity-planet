import { assertEquals } from "jsr:@std/assert@1.0.19";
import { runBatch, undeliverableAddress, type WorkerDeps } from "./worker.ts";

const links = { appUrl: "https://app.example.com", siteUrl: "https://example.com" };

function row(id: string, over: Record<string, unknown> = {}) {
  return {
    id,
    kind: "event_reminder_day",
    event_id: null,
    payload: { title: "Run" },
    actor_name: null,
    hub: null,
    chapter: null,
    email: { to: `${id}@members.activityplanet.app`, unsubscribe_token: `${id}.sig` },
    push: [
      { device_id: `d-${id}`, endpoint: "https://fcm.googleapis.com/x", p256dh: "k", auth: "a" },
    ],
    ...over,
  };
}

function fake(claimed: unknown[], over: Partial<WorkerDeps> = {}) {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const deps: WorkerDeps = {
    rpc: (name, args) => {
      calls.push({ name, args });
      return Promise.resolve(name === "claim_pending_notifications" ? claimed : 1);
    },
    sendEmails: null,
    sendPush: null,
    links,
    ...over,
  };
  return { deps, calls };
}

Deno.test("without RESEND_API_KEY and VAPID keys everything ends skipped, never sent", async () => {
  const { deps, calls } = fake([row("1"), row("2")]);
  const s = await runBatch(deps);
  assertEquals(s.email, { sent: 0, skipped: 2, failed: 0, retry: 0 });
  assertEquals(s.push, { sent: 0, skipped: 2, failed: 0, retry: 0 });
  const done = calls.find((c) => c.name === "complete_notification_delivery")!;
  const results = done.args.p_results as { email: string; push: string }[];
  assertEquals(
    results.map((r) => [r.email, r.push]),
    [
      ["skipped", "skipped"],
      ["skipped", "skipped"],
    ],
  );
});

Deno.test("nothing claimed: no completion call", async () => {
  const { deps, calls } = fake([]);
  await runBatch(deps);
  assertEquals(
    calls.map((c) => c.name),
    ["claim_pending_notifications"],
  );
});

Deno.test("one email result per row: one refusal fails only its row, a 5xx retries", async () => {
  let calls_ = 0;
  const { deps, calls } = fake([row("1"), row("2", { push: null }), row("3", { push: null })], {
    sendEmails: (m) => {
      calls_++;
      assertEquals(
        m.map((x) => x.id),
        ["1", "2", "3"],
      );
      return Promise.resolve(["sent", "failed", "retry"]);
    },
  });
  const s = await runBatch(deps);
  assertEquals(calls_, 1);
  assertEquals(s.email, { sent: 1, skipped: 0, failed: 1, retry: 1 });
  const results = calls.at(-1)!.args.p_results as { id: string; email: string }[];
  assertEquals(
    results.map((r) => r.email),
    ["sent", "failed", "retry"],
  );
});

Deno.test("a thrown or short email answer retries the rows it did not cover", async () => {
  const { deps, calls } = fake([row("1", { push: null }), row("2", { push: null })], {
    sendEmails: () => Promise.resolve(["sent"]),
  });
  await runBatch(deps);
  const results = calls.at(-1)!.args.p_results as { id: string; email: string }[];
  assertEquals(
    results.map((r) => r.email),
    ["sent", "retry"],
  );
});

Deno.test("push: 410 revokes, one good device makes it sent, all transient retries", async () => {
  const statuses: Record<string, number> = { a: 201, b: 410, c: 503, d: 404 };
  const { deps, calls } = fake(
    [
      row("1", {
        email: null,
        push: [
          { device_id: "a", endpoint: "https://fcm.googleapis.com/a", p256dh: "k", auth: "x" },
          { device_id: "b", endpoint: "https://fcm.googleapis.com/b", p256dh: "k", auth: "x" },
        ],
      }),
      row("2", {
        email: null,
        push: [
          { device_id: "c", endpoint: "https://fcm.googleapis.com/c", p256dh: "k", auth: "x" },
        ],
      }),
      row("3", {
        email: null,
        push: [
          { device_id: "d", endpoint: "https://fcm.googleapis.com/d", p256dh: "k", auth: "x" },
        ],
      }),
    ],
    { sendPush: (m) => Promise.resolve(statuses[m.endpoint.slice(-1)]) },
  );
  const s = await runBatch(deps);
  assertEquals(s.push, { sent: 1, skipped: 1, failed: 0, retry: 1 });
  const done = calls.at(-1)!.args;
  assertEquals(
    (done.p_results as { push: string }[]).map((r) => r.push),
    ["sent", "retry", "skipped"],
  );
  assertEquals(done.p_devices, { ok: ["a"], gone: ["b", "d"], failed: [] });
});

Deno.test("the push payload carries the copy, an in-app path and the row id", async () => {
  let seen: unknown = null;
  const { deps } = fake(
    [row("1", { email: null, event_id: "11111111-2222-4333-8444-555555555555" })],
    {
      sendPush: (m) => {
        seen = m.payload;
        return Promise.resolve(201);
      },
    },
  );
  await runBatch(deps);
  assertEquals(seen, {
    title: "Coming up: Run",
    body: "",
    url: "/events/11111111-2222-4333-8444-555555555555",
    tag: "event_reminder_day:11111111-2222-4333-8444-555555555555",
    nid: "1",
  });
});

Deno.test("reserved domains are skipped, never handed to Resend", async () => {
  const sent: string[] = [];
  const { deps, calls } = fake(
    [
      row("1", { email: { to: "qa-e2e-a@example.com", unsubscribe_token: "1.sig" }, push: null }),
      row("2", { email: { to: "someone@mail.test", unsubscribe_token: "2.sig" }, push: null }),
      row("3", { email: { to: "delivered@resend.dev", unsubscribe_token: "3.sig" }, push: null }),
    ],
    {
      sendEmails: (ms) => {
        sent.push(...ms.map((m) => m.id));
        return Promise.resolve(ms.map(() => "sent" as const));
      },
    },
  );
  const s = await runBatch(deps);
  assertEquals(sent, ["3"]);
  assertEquals(s.email, { sent: 1, skipped: 2, failed: 0, retry: 0 });
  const done = calls.find((c) => c.name === "complete_notification_delivery")!;
  const results = done.args.p_results as { id: string; email: string; error?: string }[];
  assertEquals(
    results.map((r) => [r.id, r.email, r.error ?? null]),
    [
      ["1", "skipped", "reserved_domain"],
      ["2", "skipped", "reserved_domain"],
      ["3", "sent", null],
    ],
  );
});

Deno.test("undeliverableAddress", () => {
  for (const a of [
    "a@example.com",
    "a@sub.example.org",
    "a@x.test",
    "a@x.invalid",
    "a@localhost",
    "a@",
  ]) {
    assertEquals(undeliverableAddress(a), true, a);
  }
  for (const a of [
    "a@gmail.com",
    "delivered@resend.dev",
    "a@example-mail.com",
    "a@myexample.com",
  ]) {
    assertEquals(undeliverableAddress(a), false, a);
  }
});
