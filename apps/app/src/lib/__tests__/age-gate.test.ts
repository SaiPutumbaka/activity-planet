import { describe, expect, it, vi } from "vitest";

const rpc = vi.fn();
const invoke = vi.fn();
const signOut = vi.fn();
vi.mock("../supabase", () => ({
  supabase: { rpc, functions: { invoke }, auth: { signOut } },
}));

const { AGE_BLOCK_KEY, ageBlocked, closeUnderageAccount, rememberAgeBlock } =
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
  it("remembers a block as a flag only", () => {
    const s = memory();
    expect(ageBlocked(s)).toBe(false);
    rememberAgeBlock(s);
    expect(ageBlocked(s)).toBe(true);
    expect(s.getItem(AGE_BLOCK_KEY)).toBe("1");
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
