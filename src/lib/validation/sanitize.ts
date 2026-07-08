/**
 * Strips ASCII control characters, keeping tab (9), newline (10), and
 * carriage return (13), which are legitimate in multi-line text. Combined
 * with React's output escaping and Supabase's parameterized queries, this is
 * the input-sanitization layer for free-text fields across the app.
 */
function isControlChar(codePoint: number): boolean {
  if (codePoint === 9 || codePoint === 10 || codePoint === 13) {
    return false;
  }
  return codePoint < 32 || codePoint === 127;
}

export function stripControlChars(value: string): string {
  let result = "";
  for (const char of value) {
    if (!isControlChar(char.codePointAt(0) ?? 0)) {
      result += char;
    }
  }
  return result;
}
