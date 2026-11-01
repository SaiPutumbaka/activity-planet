import { toast } from "sonner";

import { SITE_URL } from "@/lib/site";

/** The site's public share page for a plan: works logged out, with an OG image and calendar links. */
export function eventShareUrl(id: string): string {
  return `${SITE_URL}/e/${id}`;
}

/**
 * The native share sheet where there is one (iPhone, Android, installed web app), else the link
 * copied to the clipboard. Closing the sheet is not an error and says nothing.
 */
export async function shareLink({ url, title }: { url: string; title?: string }): Promise<void> {
  if (typeof navigator.share === "function") {
    const data: ShareData = title ? { title, url } : { url };
    if (!navigator.canShare || navigator.canShare(data)) {
      try {
        await navigator.share(data);
        return;
      } catch (err) {
        if (err instanceof DOMException && err.name === "AbortError") return;
        // NotAllowedError (no user gesture left) and friends: fall through to copying.
      }
    }
  }
  try {
    await navigator.clipboard.writeText(url);
    toast.success("Link copied.");
  } catch {
    toast.error(`Couldn't copy. The link is ${url}`);
  }
}
