import { describe, expect, it } from "vitest";

import {
  MESSAGE_MAX,
  bodyProblem,
  cleanBody,
  foldText,
  hasLink,
  linkShortened,
  matchText,
  splitLinks,
} from "../text";

// The same strings supabase/tests/messaging.sql sends through send_message (section 6 there).
describe("link rules mirror the server (messaging.sql fixtures)", () => {
  it("finds a www. link and a scheme link", () => {
    expect(hasLink("see www.example.com")).toBe(true);
    expect(hasLink("tickets at https://example.org/tickets")).toBe(true);
  });

  it("does not count an email address or a phone number", () => {
    expect(hasLink("mail me at sam@example.com or call 404.555.0100")).toBe(false);
  });

  it("refuses shorteners", () => {
    expect(linkShortened("look: bit.ly/abc123")).toBe(true);
    expect(linkShortened("tickets at https://example.org/tickets")).toBe(false);
  });

  it("finds a bare label.tld and leaves ordinary words alone", () => {
    expect(hasLink("meet at climbgym.com tonight")).toBe(true);
    expect(hasLink("Check example.de")).toBe(true);
    expect(hasLink("damn that was a hell of a hike")).toBe(false);
    expect(hasLink("e.g. bring water")).toBe(false);
  });
});

describe("normalization", () => {
  it("lower-cases, drops zero-width characters and collapses spaces", () => {
    expect(matchText("Hi​  THERE\n\tyou")).toBe("hi there you");
  });

  it("folds leetspeak, look-alikes and stretched letters like chat_fold", () => {
    expect(foldText("you f4gggg0t")).toBe("you faggot");
    expect(foldText("$3nd nud3$")).toBe("send nudes");
    // Cyrillic о and е look like Latin letters.
    expect(foldText("hеllо")).toBe("hello");
  });

  it("cleans control characters and trims like send_message", () => {
    expect(cleanBody("  hi\u0007 there \n")).toBe("hi there");
    expect(cleanBody("line one\nline two")).toBe("line one\nline two");
  });
});

describe("bodyProblem", () => {
  it("says empty, too long and link problems before sending", () => {
    expect(bodyProblem("   ", { linksAllowed: true })).toBe("empty");
    expect(bodyProblem("x".repeat(MESSAGE_MAX + 1), { linksAllowed: true })).toBe("too_long");
    expect(bodyProblem("x".repeat(MESSAGE_MAX), { linksAllowed: true })).toBeNull();
    expect(bodyProblem("see www.example.com", { linksAllowed: false })).toBe("link_not_allowed");
    expect(bodyProblem("see www.example.com", { linksAllowed: true })).toBeNull();
    expect(bodyProblem("look: bit.ly/abc123", { linksAllowed: true })).toBe("link_not_allowed");
  });
});

describe("splitLinks", () => {
  it("splits text and links, adding https and leaving trailing punctuation out", () => {
    expect(splitLinks("Tickets: example.org/t, see you.")).toEqual([
      { text: "Tickets: ", href: null },
      { text: "example.org/t", href: "https://example.org/t" },
      { text: ", see you.", href: null },
    ]);
  });

  it("keeps a scheme and skips email addresses", () => {
    expect(splitLinks("https://a.com.")).toEqual([
      { text: "https://a.com", href: "https://a.com" },
      { text: ".", href: null },
    ]);
    expect(splitLinks("sam@example.com")).toEqual([{ text: "sam@example.com", href: null }]);
  });
});
