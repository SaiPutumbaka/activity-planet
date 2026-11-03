import { Button } from "@/components/ui/button";
import type { AccountSwitch } from "@/lib/auth-links";

/** The interstitial itself; pages show it while useAccountSwitchPrompt has a pending ask. */
export function AccountSwitchPrompt({
  accounts,
  onAnswer,
}: {
  accounts: AccountSwitch;
  onAnswer: (accept: boolean) => void;
}) {
  const incoming = accounts.incomingEmail ?? "another account";
  const current = accounts.currentEmail ?? "another account";
  return (
    <div className="flex flex-col gap-5 pt-6" role="alertdialog" aria-labelledby="switch-title">
      <div className="flex flex-col gap-2">
        <h1 id="switch-title" className="text-[26px] font-extrabold tracking-[-0.025em]">
          Switch accounts?
        </h1>
        <p className="text-text-2">
          This link signs in to{" "}
          <span className="font-semibold text-text break-all">{incoming}</span>. You're signed in
          here as <span className="font-semibold text-text break-all">{current}</span>.
        </p>
        <p className="text-text-2">
          Only continue if you asked for this link. If someone sent it to you, cancel and stay where
          you are.
        </p>
      </div>
      <div className="flex flex-col gap-2">
        <Button size="lg" block onClick={() => onAnswer(true)}>
          Continue
        </Button>
        <Button size="lg" block variant="secondary" onClick={() => onAnswer(false)}>
          Cancel
        </Button>
      </div>
    </div>
  );
}
