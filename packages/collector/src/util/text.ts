// Text helpers shared by every lane. Same rules as supabase/functions/import-feed/adapters.ts
// (entities decode, tags go, whitespace collapses) so items look alike whatever the source.

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  rsquo: "’",
  lsquo: "‘",
  rdquo: "”",
  ldquo: "“",
  ndash: "–",
  mdash: "—",
  hellip: "…",
  middot: "·",
  bull: "•",
  eacute: "é",
  copy: "©",
  reg: "®",
  trade: "™",
};

export function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (match, code: string) => {
    if (code[0] === "#") {
      const n =
        code[1] === "x" || code[1] === "X"
          ? parseInt(code.slice(2), 16)
          : parseInt(code.slice(1), 10);
      return Number.isFinite(n) && n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : match;
    }
    return NAMED_ENTITIES[code.toLowerCase()] ?? match;
  });
}

/**
 * Drops <script> and <style> elements in one forward pass. An element with no closing tag runs
 * to the end of the text, as a browser reads it. Linear in the input, whatever it holds.
 */
function dropScriptsAndStyles(html: string): string {
  const open = /<(script|style)\b/gi;
  let out = "";
  let pos = 0;
  for (;;) {
    open.lastIndex = pos;
    const m = open.exec(html);
    if (!m) break;
    out += html.slice(pos, m.index) + " ";
    const close = new RegExp(`</${m[1]}\\s*>`, "gi");
    close.lastIndex = m.index + m[0].length;
    const c = close.exec(html);
    if (!c) return out;
    pos = c.index + c[0].length;
  }
  return out + html.slice(pos);
}

/** Tags go; [^<>] keeps the scan linear even when a "<" never closes. */
function stripTags(text: string): string {
  return text
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|h[1-6]|tr)\s*>/gi, "\n")
    .replace(/<[^<>]*>/g, " ");
}

/**
 * HTML to plain text: block ends become line breaks, tags go, entities decode, spaces collapse.
 * Decoding can reveal markup that was escaped ("&lt;img onerror=...&gt;"), so decode and strip
 * repeat until the text stops changing, and no "<" or ">" survives.
 */
export function htmlToText(html: string): string {
  let text = stripTags(dropScriptsAndStyles(html.replace(/\r\n?/g, "\n")));
  for (let i = 0; i < 4; i++) {
    const next = stripTags(decodeEntities(text));
    if (next === text) break;
    text = next;
  }
  return noAngles(text)
    .replace(/[ \t\u00a0]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** "<" and ">" as look-alike angle quotes, so no item text can carry markup. */
function noAngles(text: string): string {
  return text.replace(/</g, "\u2039").replace(/>/g, "\u203a");
}

/** Decoded text; escaped HTML inside is decoded first, then stripped. No markup survives. */
export function plain(value: string | null | undefined): string {
  if (!value) return "";
  const decoded = decodeEntities(value);
  return /<[a-z!/][^<>]*>/i.test(decoded)
    ? htmlToText(decoded)
    : noAngles(decoded).replace(/\s+/g, " ").trim();
}

/** One line: every run of whitespace becomes a single space. */
export function oneLine(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

/**
 * A verbatim prefix of at most max characters, cut at a word boundary where one is close,
 * ending with an ellipsis when cut.
 */
export function excerpt(text: string, max: number): string {
  if (max <= 0) return "";
  const clean = text.trim();
  if (clean.length <= max) return clean;
  const cut = clean.slice(0, max - 1);
  const space = cut.lastIndexOf(" ");
  return `${(space > max * 0.6 ? cut.slice(0, space) : cut).trimEnd()}…`;
}

/** import_clip(): at most max characters, the last one an ellipsis when cut. */
export function clip(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max - 1).trimEnd()}…`;
}

export function str(value: unknown): string | null {
  if (typeof value === "string") {
    const t = value.trim();
    return t === "" ? null : t;
  }
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return null;
}

export function num(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "") {
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

/** A value at a dotted path ("venue.location.lat") in a JSON object. */
export function pick(obj: unknown, path: string): unknown {
  let cur: unknown = obj;
  for (const part of path.split(".")) {
    if (!cur || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[part];
  }
  return cur;
}
