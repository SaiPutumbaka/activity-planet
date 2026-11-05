import { beforeEach, describe, expect, it, vi } from "vitest";

const rpc = vi.fn();
vi.mock("../supabase", () => ({ supabase: { rpc: (...args: unknown[]) => rpc(...args) } }));

import { PRESENCE_INTERVAL_MS, presenceDue, resetPresence, touchPresence } from "@/lib/presence";

describe("presence", () => {
  beforeEach(() => {
    rpc.mockReset();
    rpc.mockResolvedValue({ data: null, error: null });
    resetPresence();
  });

  it("is due on the first call and again after the interval", () => {
    expect(presenceDue(1000, 0)).toBe(true);
    expect(presenceDue(1000 + PRESENCE_INTERVAL_MS - 1, 1000)).toBe(false);
    expect(presenceDue(1000 + PRESENCE_INTERVAL_MS, 1000)).toBe(true);
  });

  it("calls touch_last_seen at most once per interval", () => {
    touchPresence(1_000_000);
    touchPresence(1_000_000 + 60_000);
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(rpc).toHaveBeenCalledWith("touch_last_seen");
    touchPresence(1_000_000 + PRESENCE_INTERVAL_MS);
    expect(rpc).toHaveBeenCalledTimes(2);
  });

  it("tries again on the next visit after a failure", async () => {
    rpc.mockResolvedValueOnce({ data: null, error: { message: "offline" } });
    touchPresence(5_000_000);
    await Promise.resolve();
    await Promise.resolve();
    touchPresence(5_000_000 + 1000);
    expect(rpc).toHaveBeenCalledTimes(2);
  });
});
