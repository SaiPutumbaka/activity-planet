// Subject and disclaimer for the verification emails (L4 of the launch audit): built from the
// organization's name, never a fixed campus (D-022, D-040).

/** The subject names the organization (D-040: never a fixed campus); control characters stripped. */
export function subjectFor(orgName: string): string {
  // deno-lint-ignore no-control-regex
  const name = orgName
    .replace(/[\u0000-\u001f\u007f]+/g, " ")
    .trim()
    .slice(0, 80);
  return name ? `Your ${name} email verification code` : "Your email verification code";
}

/** The disclaimer names the organization the address belongs to (D-022, D-040). */
export function disclaimerFor(orgName: string): string {
  const name = orgName.trim();
  return name ? `Activity Planet · Not affiliated with or endorsed by ${name}.` : "Activity Planet";
}
