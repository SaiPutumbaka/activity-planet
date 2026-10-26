import { Button } from "@/components/ui/button";
import { Sheet } from "@/components/ui/sheet";

const siteUrl =
  (import.meta.env.VITE_SITE_URL as string | undefined) ?? "https://activityplanet.app";

const RULES = [
  { title: "Be real", body: "Your name, your face, your plans. No fake accounts." },
  { title: "Show up, or cancel early", body: "A spot you hold is a spot someone else wanted." },
  {
    title: "Respect the host and the space",
    body: "Their rules, their room. Leave it as you found it.",
  },
  { title: "No harassment", body: "No threats, slurs or unwanted contact. Report it and we act." },
  { title: "18+ only", body: "Everyone here is an adult. Some plans are 21+." },
] as const;

/**
 * Shown once, at the first RSVP (set_rsvp raises guidelines_required). Accepting calls
 * accept_guidelines() and the RSVP goes through; closing leaves the RSVP unsent.
 */
export function GuidelinesSheet({
  open,
  onClose,
  onAccept,
  accepting,
}: {
  open: boolean;
  onClose: () => void;
  onAccept: () => void;
  accepting: boolean;
}) {
  return (
    <Sheet
      open={open}
      onClose={onClose}
      title="Community guidelines"
      footer={
        <>
          <Button size="lg" block loading={accepting} onClick={onAccept}>
            I agree
          </Button>
          <Button variant="ghost" block onClick={onClose} disabled={accepting}>
            Not now
          </Button>
        </>
      }
    >
      <p className="text-[15px] text-text-2">
        Five rules before your first plan. They keep the people you meet here real and safe.
      </p>
      <ol className="mt-4 flex flex-col gap-3">
        {RULES.map((rule, i) => (
          <li key={rule.title} className="flex gap-3">
            <span className="flex size-7 shrink-0 items-center justify-center rounded-full bg-surface-2 text-[13px] font-bold text-text-2 tabular">
              {i + 1}
            </span>
            <span>
              <span className="block text-[15px] font-semibold">{rule.title}</span>
              <span className="block text-[14px] text-text-2">{rule.body}</span>
            </span>
          </li>
        ))}
      </ol>
      <p className="mt-4 text-[13px] text-text-3">
        The full text is at{" "}
        <a
          href={`${siteUrl}/guidelines`}
          target="_blank"
          rel="noreferrer"
          className="font-medium text-text-2 underline underline-offset-2"
        >
          {siteUrl.replace(/^https?:\/\//, "")}/guidelines
        </a>
        .
      </p>
    </Sheet>
  );
}
