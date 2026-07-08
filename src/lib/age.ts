/**
 * Age in whole years from an ISO date string (YYYY-MM-DD). Not stored in the
 * database on purpose — deriving it from birthday avoids a value that goes
 * stale the moment a year passes.
 */
export function calculateAge(birthday: string): number | null {
  const parsed = new Date(birthday);
  if (Number.isNaN(parsed.getTime())) {
    return null;
  }

  const today = new Date();
  let age = today.getFullYear() - parsed.getFullYear();
  const monthDiff = today.getMonth() - parsed.getMonth();
  if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < parsed.getDate())) {
    age -= 1;
  }
  return age;
}
