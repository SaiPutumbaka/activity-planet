import { assertEquals } from "jsr:@std/assert@1";
import { disclaimerFor, subjectFor } from "./copy.ts";

Deno.test("the subject and disclaimer name the organization", () => {
  assertEquals(
    subjectFor("University of Calgary"),
    "Your University of Calgary email verification code",
  );
  assertEquals(
    disclaimerFor("University of Calgary"),
    "Activity Planet · Not affiliated with or endorsed by University of Calgary.",
  );
});

Deno.test("no organization name falls back to neutral copy", () => {
  assertEquals(subjectFor("  "), "Your email verification code");
  assertEquals(disclaimerFor(""), "Activity Planet");
});

Deno.test("control characters never reach the subject", () => {
  assertEquals(subjectFor("Acme\r\nBcc: x@y.z"), "Your Acme Bcc: x@y.z email verification code");
});
