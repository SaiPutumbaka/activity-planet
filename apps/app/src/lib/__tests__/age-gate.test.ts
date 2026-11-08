import { describe, expect, it, vi } from "vitest";

const rpc = vi.fn();
const invoke = vi.fn();
const signOut = vi.fn();
vi.mock("../supabase", () => ({
  supabase: { rpc, functions: { invoke }, auth: { signOut } },
}));

const { AGE_BLOCK_KEY, AGE_BLOCK_MS, ageBlocked, closeUnderageAccount, rememberAgeBlock } =
  await import("../age-gate");

function memory(): Storage {
  const m = new Map<string, string>();
  return {
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => void m.set(k, v),
    removeItem: (k: string) => void m.delete(k),
    clear: () => m.clear(),
    key: () => null,
    length: 0,
  };
}

describe("age gate", () => {
  it("remembers a block as an expiry time only, for one day", () => {
    const s = memory();
    const now = 1_800_000_000_000;
    expect(ageBlocked(s, now)).toBe(false);
    rememberAgeBlock(s, now);
    expect(ageBlocked(s, now)).toBe(true);
    expect(s.getItem(AGE_BLOCK_KEY)).toBe(String(now + AGE_BLOCK_MS));
    expect(ageBlocked(s, now + AGE_BLOCK_MS - 1)).toBe(true);
    expect(ageBlocked(s, now + AGE_BLOCK_MS)).toBe(false);
    expect(s.getItem(AGE_BLOCK_KEY)).toBeNull();
  });

  it("clears the old permanent flag and tampered values", () => {
    const now = 1_800_000_000_000;
    for (const v of ["1", "garbage", String(now + 10 * AGE_BLOCK_MS)]) {
      const s = memory();
      s.setItem(AGE_BLOCK_KEY, v);
      expect(ageBlocked(s, now)).toBe(false);
      expect(s.getItem(AGE_BLOCK_KEY)).toBeNull();
    }
  });

  it("survives storage that throws", () => {
    const broken = {
      getItem: () => {
        throw new Error("denied");
      },
    };
    expect(ageBlocked(broken)).toBe(false);
  });

  it("closes the account through the deletion path, then signs out", async () => {
    vi.stubGlobal("localStorage", memory());
    rpc.mockResolvedValue({ error: null });
    invoke.mockResolvedValue({ error: null });
    signOut.mockResolvedValue({ error: null });
    expect(await closeUnderageAccount()).toBe(true);
    expect(rpc).toHaveBeenCalledWith("request_account_deletion", { p_reason: "under_18" });
    expect(invoke).toHaveBeenCalledWith("delete-account", { method: "POST" });
    expect(signOut).toHaveBeenCalled();
    expect(ageBlocked()).toBe(true);
    vi.unstubAllGlobals();
  });
});
