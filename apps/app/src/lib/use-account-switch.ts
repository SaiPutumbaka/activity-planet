import { useCallback, useRef, useState } from "react";

import type { AccountSwitch, ConfirmSwitch } from "./auth-links";

/**
 * The "switch account?" step for email links (login CSRF / session swap). completeAuthLink
 * calls `confirm` only when the link belongs to a different account than the one signed in
 * here; the page renders AccountSwitchPrompt (components/auth/account-switch.tsx) instead of
 * its spinner while it waits for an answer.
 */
export function useAccountSwitchPrompt(): {
  confirm: ConfirmSwitch;
  pending: AccountSwitch | null;
  answer: (accept: boolean) => void;
} {
  const [pending, setPending] = useState<AccountSwitch | null>(null);
  const resolver = useRef<((accept: boolean) => void) | null>(null);

  const confirm = useCallback<ConfirmSwitch>(
    (accounts) =>
      new Promise<boolean>((resolve) => {
        resolver.current = resolve;
        setPending(accounts);
      }),
    [],
  );

  const answer = useCallback((accept: boolean) => {
    const resolve = resolver.current;
    resolver.current = null;
    setPending(null);
    resolve?.(accept);
  }, []);

  return { confirm, pending, answer };
}
