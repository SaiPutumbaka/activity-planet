import type { ChatMessage, ConversationInfo } from "./schemas";

/**
 * Chat images (D-043, design section 10; migration 71). Off unless the project has the
 * classifier keys and meta.chat_images is on (conversation_info.images_enabled). The app
 * resizes and re-encodes the picked photo, uploads it to the private chat-images bucket at
 * <uid>/<conversation>/<uuid>.jpg and sends the path; the photo is shown to others only after
 * image-guard's pHash check and the classifier both pass.
 */

export const CHAT_IMAGE_BUCKET = "chat-images";
/** Longest side after the resize, in pixels. */
export const CHAT_IMAGE_MAX_SIDE = 1600;
export const CHAT_IMAGE_JPEG_QUALITY = 0.85;
/** The bucket's limit (migration 58). */
export const CHAT_IMAGE_MAX_BYTES = 2 * 1024 * 1024;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** The object path send_message accepts: <uid>/<conversation>/<uuid>.jpg (all lowercase). */
export function chatImagePath(userId: string, conversationId: string, imageId: string): string {
  const parts = [userId, conversationId, imageId].map((p) => p.toLowerCase());
  if (!parts.every((p) => UUID.test(p))) throw new Error("image_invalid");
  return `${parts[0]}/${parts[1]}/${parts[2]}.jpg`;
}

/** Whether the composer offers a photo: images on, the caller may post, not a message request. */
export function canAttachImages(
  info: Pick<ConversationInfo, "images_enabled" | "can_post" | "request">,
): boolean {
  return info.images_enabled && info.can_post === null && info.request !== "sent";
}

/** Width and height scaled to fit within `max` on the long side (never enlarged). */
export function fitWithin(width: number, height: number, max = CHAT_IMAGE_MAX_SIDE) {
  if (!(width > 0) || !(height > 0)) return { width: 0, height: 0 };
  const scale = Math.min(1, max / Math.max(width, height));
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  };
}

/**
 * The label on an image bubble instead of the photo, or null to show it. Others only ever
 * receive visible photos; the sender sees their own with the state of its checks.
 */
export function imageLabel(m: Pick<ChatMessage, "kind" | "image">): string | null {
  if (m.kind !== "image") return null;
  switch (m.image?.state ?? null) {
    case "visible":
      return null;
    case "pending":
    case "classifying":
    case "queued":
      return "Photo is being checked";
    case "blocked":
      return "This photo can't be shared";
    case "removed":
      return "Photo removed";
    default:
      return "Photo";
  }
}

/** Whether the bubble may load the photo: visible, or the sender's own while it is checked. */
export function imageLoadable(m: Pick<ChatMessage, "kind" | "image" | "mine">): boolean {
  if (m.kind !== "image" || !m.image?.path) return false;
  const s = m.image.state;
  return s === "visible" || (m.mine && (s === "pending" || s === "classifying" || s === "queued"));
}

/** The states in which the sender's photo is still being checked. */
const CHECKING = new Set(["pending", "classifying", "queued"]);

/** How often an open conversation re-reads the sender's photos that are still being checked. */
export const CHECKING_REFRESH_MS = 10_000;

/**
 * The seqs of the viewer's own photos still being checked, oldest first (at most `max`). The
 * open conversation re-reads these rows on a timer, so the "being checked" label clears even
 * when the msg_update signal was missed or the channel is down (the poll fallback only reads
 * newer messages).
 */
export function checkingImageSeqs(
  messages: readonly Pick<ChatMessage, "kind" | "image" | "mine" | "seq">[],
  max = 5,
): number[] {
  return messages
    .filter((m) => m.mine && m.kind === "image" && CHECKING.has(m.image?.state ?? ""))
    .map((m) => m.seq)
    .sort((a, b) => a - b)
    .slice(0, Math.max(0, max));
}
