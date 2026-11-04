/**
 * "Suggest a calendar" (D-042 slice 7): the D-040 URL rules the database applies in
 * source_url_check (migration 46), mirrored so the form can say what is wrong before it sends.
 * The denylist is checked on the server only (its rows live in the database). The rules:
 * https only (http:// and webcal:// read as https://, as the collector fetches over TLS), at
 * most 500 characters, no spaces, no user name or password, port 443 only, a public DNS name
 * (no IP literal, no localhost, .local, .internal and the like); the fragment is dropped.
 *
 *   checkCalendarUrl("webcal://city.example.gov/cal.ics")
 *     -> { ok: true, url: "https://city.example.gov/cal.ics", host: "city.example.gov" }
 */

export type CalendarUrlError =
  | "url_invalid"
  | "url_too_long"
  | "url_not_https"
  | "url_has_credentials"
  | "url_port"
  | "url_private_host";

export type CalendarUrlCheck =
  { ok: true; url: string; host: string } | { ok: false; error: CalendarUrlError };

export const CALENDAR_URL_MAX = 500;

const HOST = /^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$/;
const PRIVATE_TLDS = new Set([
  "local",
  "localhost",
  "localdomain",
  "internal",
  "intranet",
  "lan",
  "home",
  "corp",
  "private",
  "arpa",
  "test",
  "example",
  "invalid",
  "onion",
  "alt",
]);

export function checkCalendarUrl(input: string): CalendarUrlCheck {
  let s = input.trim();
  if (!s) return { ok: false, error: "url_invalid" };
  if (s.length > CALENDAR_URL_MAX) return { ok: false, error: "url_too_long" };
  // eslint-disable-next-line no-control-regex
  if (/[\s\u0000-\u001f\u007f]/.test(s)) return { ok: false, error: "url_invalid" };
  s = s.replace(/^(webcals?|https?):\/\//i, "https://");
  if (!/^https:\/\//.test(s)) {
    return { ok: false, error: /^[a-z][a-z0-9+.-]*:/i.test(s) ? "url_not_https" : "url_invalid" };
  }
  const m = /^https:\/\/([^/?#]*)(.*)$/.exec(s);
  const authority = m?.[1] ?? "";
  let rest = (m?.[2] ?? "").replace(/#.*$/, "");
  if (authority.includes("@")) return { ok: false, error: "url_has_credentials" };
  if (authority.startsWith("[")) return { ok: false, error: "url_private_host" };
  let host = authority.toLowerCase();
  const colon = host.lastIndexOf(":");
  if (colon >= 0) {
    const port = host.slice(colon + 1);
    host = host.slice(0, colon);
    if (port !== "" && port !== "443") return { ok: false, error: "url_port" };
  }
  host = host.replace(/\.+$/, "");
  if (/^[0-9.]+$/.test(host) || host.startsWith("0x"))
    return { ok: false, error: "url_private_host" };
  if (host.length > 253 || !HOST.test(host))
    return { ok: false, error: host.includes(".") ? "url_invalid" : "url_private_host" };
  const tld = host.slice(host.lastIndexOf(".") + 1);
  if (PRIVATE_TLDS.has(tld) || /(^|\.)(localhost|example\.(com|net|org))$/.test(host))
    return { ok: false, error: "url_private_host" };
  if (rest === "" || rest.startsWith("?")) rest = `/${rest}`;
  return { ok: true, url: `https://${host}${rest}`, host: host.replace(/^www\./, "") };
}
