import { describe, expect, it } from "vitest";
import { clientIp, hostsOf, verifyTurnstile } from "../turnstile";

const answer = (body: unknown) => () => Promise.resolve(new Response(JSON.stringify(body)));
const env = { secret: "s", vercelEnv: "production", hostnames: ["activityplanet.app"] };

describe("verifyTurnstile", () => {
  it("fails closed in production without the secret", async () => {
    expect(await verifyTurnstile("t", null, { ...env, secret: undefined })).toBe("not_configured");
    expect(
      await verifyTurnstile("t", null, { ...env, secret: undefined, vercelEnv: "preview" }),
    ).toBe("ok");
  });

  it("checks the hostname of a good answer", async () => {
    expect(
      await verifyTurnstile(
        "t",
        null,
        env,
        answer({ success: true, hostname: "activityplanet.app" }),
      ),
    ).toBe("ok");
    expect(
      await verifyTurnstile("t", null, env, answer({ success: true, hostname: "evil.example" })),
    ).toBe("wrong_host");
    expect(await verifyTurnstile("t", null, env, answer({ success: false }))).toBe("failed");
  });

  it("refuses a missing token and a network error", async () => {
    expect(await verifyTurnstile("", null, env)).toBe("missing_token");
    expect(await verifyTurnstile("t", null, env, () => Promise.reject(new Error("down")))).toBe(
      "failed",
    );
  });
});

describe("helpers", () => {
  it("hostsOf reads origins and bare hosts", () => {
    expect(hostsOf("https://activityplanet.app/", "www.activityplanet.app, bad url", null)).toEqual(
      ["activityplanet.app", "www.activityplanet.app"],
    );
  });

  it("clientIp takes the first hop", () => {
    expect(clientIp(new Headers({ "x-forwarded-for": "1.2.3.4, 5.6.7.8" }))).toBe("1.2.3.4");
    expect(clientIp(new Headers())).toBeNull();
  });
});
