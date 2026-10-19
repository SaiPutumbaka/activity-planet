import { safeInternalPath } from "@ap/core/validation";

/**
 * Turns a `next` search param into something `navigate({ to })` accepts. The router's `to` type
 * is the union of known routes; a user-supplied path can't be proven to be one at compile time,
 * so this is the single place where that cast lives, after the open-redirect check.
 */
export function internalTo(next: string | null | undefined, fallback = "/"): "/" {
  return safeInternalPath(next, fallback) as "/";
}
