/**
 * Text rules for chat messages, mirroring migration 58 (design section 8) so the composer can
 * warn before sending. The server is authoritative: these only give instant feedback.
 *
 *   matchText(s)      private.chat_match_text: NFKC, lower case, no zero-width, single spaces
 *   foldText(s)       private.chat_fold: look-alikes and leetspeak folded, long runs cut to two
 *   hasLink(s)        private.chat_has_link (migration 59): a scheme, www. or a bare label.tld
 *   linkShortened(s)  private.chat_link_shortened against LINK_DENYLIST
 *   cleanBody(s)      send_message's control-character strip and trim
 */

/** Longest message after cleanup (messages_body_length, send_message's body_length). */
export const MESSAGE_MAX = 2000;

/** Link shorteners refused in every message (private.chat_link_denylist, migration 58). */
export const LINK_DENYLIST: readonly string[] = [
  "bit.ly",
  "tinyurl.com",
  "t.co",
  "goo.gl",
  "is.gd",
  "cutt.ly",
  "rb.gy",
  "ow.ly",
  "buff.ly",
  "tiny.cc",
  "shorturl.at",
  "t.ly",
  "v.gd",
  "rebrand.ly",
  "bl.ink",
  "s.id",
  "lnkd.in",
  "qrco.de",
  "shorte.st",
  "adf.ly",
  "linktr.ee",
];

// U+200B to U+200D, U+2060, U+FEFF and the soft hyphen U+00AD, as in chat_match_text.
const ZERO_WIDTH = /[​-‍⁠﻿­]/g;

export function matchText(text: string | null | undefined): string {
  return (text ?? "").normalize("NFKC").toLowerCase().replace(ZERO_WIDTH, "").replace(/\s+/g, " ");
}

// translate(..., '01345@$аеорсхі', 'oieasasaeopcxi'): digits, symbols and Cyrillic look-alikes.
const FOLD_FROM = "01345@$аеорсхі";
const FOLD_TO = "oieasasaeopcxi";

export function foldText(text: string | null | undefined): string {
  let out = "";
  for (const ch of matchText(text)) {
    const i = FOLD_FROM.indexOf(ch);
    out += i >= 0 ? FOLD_TO[i] : ch;
  }
  return out.replace(/(.)\1{2,}/g, "$1$1");
}

// Migration 59: www. counts after anything but a letter, digit, "@" or "_" (so "-www." and
// ".www." are links, as the renderer below would show them).
const LINK_RE =
  /(https?:\/\/|(^|[^a-z0-9@_])www\.|(^|[^a-z0-9@._-])([a-z0-9-]+\.)+(com|net|org|app|xyz|info|biz|link|site|online|[a-z]{2})([^a-z0-9-]|$))/;

/** A link by the server's rule. Email addresses and phone numbers are not links. */
export function hasLink(text: string | null | undefined): boolean {
  return LINK_RE.test(matchText(text));
}

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Whether the text names a link shortener (refused everywhere). */
export function linkShortened(text: string | null | undefined): boolean {
  const t = matchText(text);
  return LINK_DENYLIST.some((d) =>
    new RegExp(`(^|[^a-z0-9.-])${escapeRe(d)}([^a-z0-9.-]|$)`).test(t),
  );
}

/** send_message's cleanup: control characters out (tab and newline stay), then trimmed. */
export function cleanBody(text: string): string {
  // eslint-disable-next-line no-control-regex
  return text.replace(/[\u0001-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "").trim();
}

export type BodyProblem = "empty" | "too_long" | "link_not_allowed" | null;

/**
 * What the composer can say before sending: empty, too long, or a link where links are refused
 * (a message request, an account under a day, or any shortener). Null means try the server.
 */
export function bodyProblem(text: string, opts: { linksAllowed: boolean }): BodyProblem {
  const body = cleanBody(text);
  if (body.length === 0) return "empty";
  if (body.length > MESSAGE_MAX) return "too_long";
  if (linkShortened(body)) return "link_not_allowed";
  if (!opts.linksAllowed && hasLink(body)) return "link_not_allowed";
  return null;
}

export interface TextPart {
  text: string;
  href: string | null;
}

const RENDER_LINK_RE =
  /\b((?:https?:\/\/|www\.)[^\s<>"]+|[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|net|org|io|co|app|me|ly|gg|xyz|info|biz|tv|link|site|online)(?![a-z0-9-])(?:\/[^\s<>"]*)?)/gi;

/**
 * Splits a message into plain text and links for rendering (no previews, never fetched). Links
 * get an https:// scheme when they have none; trailing punctuation stays outside the link.
 *
 * Only a message the server's rule (hasLink) calls a link gets any link at all, so the bubble
 * never makes something tappable that got past the request and new-account link checks.
 */
export function splitLinks(text: string): TextPart[] {
  if (!hasLink(text)) return [{ text, href: null }];
  const parts: TextPart[] = [];
  let last = 0;
  for (const m of text.matchAll(RENDER_LINK_RE)) {
    let raw = m[0];
    const start = m.index ?? 0;
    // An email address is not a link: skip a match right after "@".
    if (start > 0 && text[start - 1] === "@") continue;
    const trail = /[.,!?;:)\]]+$/.exec(raw);
    if (trail) raw = raw.slice(0, raw.length - trail[0].length);
    if (!raw) continue;
    if (start > last) parts.push({ text: text.slice(last, start), href: null });
    const href = /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
    parts.push({ text: raw, href });
    last = start + raw.length;
  }
  if (last < text.length) parts.push({ text: text.slice(last), href: null });
  return parts.length > 0 ? parts : [{ text, href: null }];
}
