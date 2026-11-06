import { describe, expect, it, vi } from "vitest";

import { createMessagingApi } from "../api";
import {
  CHAT_IMAGE_MAX_SIDE,
  canAttachImages,
  chatImagePath,
  fitWithin,
  imageLabel,
  imageLoadable,
} from "../images";

const uid = "6f1c1c1e-5b8e-4a3e-9d0a-3d1f2b4c5a6e";
const conv = "0b7c1a2e-3d4f-4a5b-8c6d-7e8f9a0b1c2d";
const img = "1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9";

describe("chatImagePath", () => {
  it("builds the path send_message and the storage policy accept", () => {
    expect(chatImagePath(uid, conv, img)).toBe(`${uid}/${conv}/${img}.jpg`);
    expect(chatImagePath(uid.toUpperCase(), conv, img)).toBe(`${uid}/${conv}/${img}.jpg`);
  });
  it("refuses anything that is not three ids", () => {
    expect(() => chatImagePath(uid, "../x", img)).toThrow("image_invalid");
    expect(() => chatImagePath("", conv, img)).toThrow();
  });
});

describe("canAttachImages", () => {
  const base = { images_enabled: true, can_post: null, request: null } as const;
  it("is hidden while chat images are off", () => {
    expect(canAttachImages({ ...base, images_enabled: false })).toBe(false);
  });
  it("needs posting rights and no outgoing request", () => {
    expect(canAttachImages(base)).toBe(true);
    expect(canAttachImages({ ...base, can_post: "account_too_new" })).toBe(false);
    expect(canAttachImages({ ...base, request: "sent" })).toBe(false);
    expect(canAttachImages({ ...base, request: "received" })).toBe(true);
  });
});

describe("fitWithin", () => {
  it("scales the long side down and never enlarges", () => {
    expect(fitWithin(4000, 3000)).toEqual({ width: CHAT_IMAGE_MAX_SIDE, height: 1200 });
    expect(fitWithin(3000, 4000)).toEqual({ width: 1200, height: CHAT_IMAGE_MAX_SIDE });
    expect(fitWithin(800, 600)).toEqual({ width: 800, height: 600 });
    expect(fitWithin(0, 600)).toEqual({ width: 0, height: 0 });
  });
});

describe("image states", () => {
  const msg = (state: string | null, mine = false) => ({
    kind: "image" as const,
    image: { state, path: `${uid}/${conv}/${img}.jpg` },
    mine,
  });
  it("labels every state that is not shown", () => {
    expect(imageLabel(msg("visible"))).toBeNull();
    expect(imageLabel(msg("pending"))).toBe("Photo is being checked");
    expect(imageLabel(msg("classifying"))).toBe("Photo is being checked");
    expect(imageLabel(msg("queued"))).toBe("Photo is being checked");
    expect(imageLabel(msg("blocked"))).toBe("This photo can't be shared");
    expect(imageLabel(msg("removed"))).toBe("Photo removed");
    expect(imageLabel({ kind: "text", image: null })).toBeNull();
  });
  it("loads a photo when visible, or for its sender while it is checked", () => {
    expect(imageLoadable(msg("visible"))).toBe(true);
    expect(imageLoadable(msg("classifying"))).toBe(false);
    expect(imageLoadable(msg("classifying", true))).toBe(true);
    expect(imageLoadable(msg("blocked", true))).toBe(false);
    expect(
      imageLoadable({ kind: "image", image: { state: "visible", path: null }, mine: false }),
    ).toBe(false);
  });
});

describe("send with a photo", () => {
  it("passes p_image_path only when there is one", async () => {
    const rpc = vi.fn().mockResolvedValue({
      data: { id: img, seq: 3, created_at: "2026-11-06T10:00:00Z", duplicate: false },
      error: null,
    });
    const api = createMessagingApi({ rpc } as never);
    await api.send(conv, img, "", `${uid}/${conv}/${img}.jpg`);
    expect(rpc).toHaveBeenLastCalledWith("send_message", {
      p_conversation: conv,
      p_client_id: img,
      p_body: "",
      p_image_path: `${uid}/${conv}/${img}.jpg`,
    });
    await api.send(conv, img, "hi");
    expect(rpc).toHaveBeenLastCalledWith("send_message", {
      p_conversation: conv,
      p_client_id: img,
      p_body: "hi",
    });
  });
});
