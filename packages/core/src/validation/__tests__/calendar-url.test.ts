import { describe, expect, it } from "vitest";

import { checkCalendarUrl } from "../calendar-url";

// The same cases as supabase/tests/source_discovery.sql section 2 (source_url_check), except the
// denylist, which only the database applies.
describe("checkCalendarUrl", () => {
  it.each([
    ["http://Www.Aptest-Lib.org/events#top", "https://www.aptest-lib.org/events", "aptest-lib.org"],
    [
      "webcal://cal.aptest-city.gov/feed.ics?c=1",
      "https://cal.aptest-city.gov/feed.ics?c=1",
      "cal.aptest-city.gov",
    ],
    ["  https://aptest-x.org  ", "https://aptest-x.org/", "aptest-x.org"],
    ["https://aptest-x.org:443?y=1", "https://aptest-x.org/?y=1", "aptest-x.org"],
    [
      "https://kalender.aptest-verein.de/termine",
      "https://kalender.aptest-verein.de/termine",
      "kalender.aptest-verein.de",
    ],
  ])("accepts %s", (input, url, host) => {
    expect(checkCalendarUrl(input)).toEqual({ ok: true, url, host });
  });

  it.each([
    ["", "url_invalid"],
    ["not a url", "url_invalid"],
    ["aptest-x.org/events", "url_invalid"],
    ["ftp://aptest-x.org/", "url_not_https"],
    ["mailto:events@aptest-x.org", "url_not_https"],
    ["https://me:pw@aptest-x.org/", "url_has_credentials"],
    ["https://aptest-x.org:8443/", "url_port"],
    ["https://10.1.2.3/", "url_private_host"],
    ["https://[::1]/", "url_private_host"],
    ["https://localhost/", "url_private_host"],
    ["https://intranet/", "url_private_host"],
    ["https://printer.local/", "url_private_host"],
    ["https://svc.internal/", "url_private_host"],
    ["https://bad_host.org/", "url_invalid"],
    [`https://aptest-${"x".repeat(500)}.org/`, "url_too_long"],
  ])("refuses %s", (input, error) => {
    expect(checkCalendarUrl(input)).toEqual({ ok: false, error });
  });
});
