// Test helpers for the Stripe functions (imported by *_test.ts only): a mocked fetch that records
// every request and answers from a script, and a recorded fake RPC. No network.
import { createStripe, type FetchLike, type Rpc, RpcError, type Stripe } from "./stripe.ts";

export interface Recorded {
  method: string;
  url: string;
  headers: Record<string, string>;
  form: URLSearchParams;
}

export function mockStripe(
  answer: (req: Recorded) => { status?: number; body: Record<string, unknown> },
): { stripe: Stripe; calls: Recorded[] } {
  const calls: Recorded[] = [];
  const fetchImpl: FetchLike = (url, init) => {
    const headers = (init.headers ?? {}) as Record<string, string>;
    const rec: Recorded = {
      method: String(init.method),
      url,
      headers,
      form: new URLSearchParams(typeof init.body === "string" ? init.body : new URL(url).search),
    };
    calls.push(rec);
    const a = answer(rec);
    return Promise.resolve(new Response(JSON.stringify(a.body), { status: a.status ?? 200 }));
  };
  return { stripe: createStripe("sk_test_mock", fetchImpl), calls };
}

export function mockRpc(
  answers: Record<string, unknown | ((args: Record<string, unknown>) => unknown)>,
): { rpc: Rpc; calls: { name: string; args: Record<string, unknown> }[] } {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const rpc: Rpc = (name, args) => {
    calls.push({ name, args });
    const a = answers[name];
    if (a instanceof RpcError) return Promise.reject(a);
    return Promise.resolve(
      typeof a === "function" ? (a as (x: Record<string, unknown>) => unknown)(args) : (a ?? null),
    );
  };
  return { rpc, calls };
}
