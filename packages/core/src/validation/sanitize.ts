/**
 * Strip ASCII control characters except tab, newline and carriage return, then trim.
 * Applied to every free-text field before validation so stored text never carries
 * invisible characters that break rendering or search.
 */
export function stripControlChars(value: string): string {
  // eslint-disable-next-line no-control-regex
  return value.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "").trim();
}
