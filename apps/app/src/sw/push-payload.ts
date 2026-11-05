/**
 * What the service worker accepts from a push (send-notifications templates.ts render().push).
 * Pure, so it is unit-tested and shared by the worker without DOM or WebWorker types.
 */
export interface PushView {
  title: string;
  body: string;
  url: string;
  tag: string | undefined;
}

/** An in-app path only ("/events/…"); anything else (other origins, "//host") goes to the inbox. */
export function safeAppPath(value: unknown): string {
  if (typeof value !== "string") return "/inbox";
  if (!/^\/(?!\/)[A-Za-z0-9\-._~/?=&%]*$/.test(value) || value.length > 300) return "/inbox";
  return value;
}

function text(v: unknown, max: number): string {
  return typeof v === "string" ? v.trim().slice(0, max) : "";
}

export function parsePushPayload(raw: unknown): PushView {
  const r =
    raw && typeof raw === "object" && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  const tag = text(r.tag, 64);
  return {
    title: text(r.title, 120) || "Activity Planet",
    body: text(r.body, 180),
    url: safeAppPath(r.url),
    tag: tag || undefined,
  };
}
