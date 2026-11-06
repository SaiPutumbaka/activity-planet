import {
  CHAT_IMAGE_BUCKET,
  CHAT_IMAGE_JPEG_QUALITY,
  CHAT_IMAGE_MAX_BYTES,
  chatImagePath,
  fitWithin,
} from "@ap/core/messaging";

import { AvatarError, checkSourceFile, decodeImageFile } from "./avatar";
import { supabase } from "./supabase";

/**
 * Photos in chats (D-043, design section 10; migration 71). Shown only while
 * conversation_info.images_enabled is true. The browser decodes the picked photo, scales it to
 * at most 1600 px on the long side and re-encodes a JPEG (quality 0.85; the canvas drops the
 * metadata, location included), stepping the quality down if it is still over the bucket's
 * 2 MiB. The upload goes to the private chat-images bucket at <uid>/<conversation>/<uuid>.jpg;
 * send_message then takes the path and others see the photo only after image-guard's checks.
 */

export { AvatarError as ChatImageError };

export async function prepareChatImage(file: File): Promise<Blob> {
  checkSourceFile(file);
  let image;
  try {
    image = await decodeImageFile(file);
  } catch (err) {
    throw err instanceof AvatarError ? err : new AvatarError("unreadable");
  }
  const w0 = "naturalWidth" in image ? image.naturalWidth : image.width;
  const h0 = "naturalHeight" in image ? image.naturalHeight : image.height;
  const { width, height } = fitWithin(w0, h0);
  if (!width || !height) throw new AvatarError("unreadable");

  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new AvatarError("encode_failed");
  ctx.fillStyle = "#ffffff";
  ctx.fillRect(0, 0, width, height);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(image, 0, 0, width, height);
  if ("close" in image) image.close();

  for (const quality of [CHAT_IMAGE_JPEG_QUALITY, 0.75, 0.6]) {
    const blob = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, "image/jpeg", quality),
    );
    if (!blob) throw new AvatarError("encode_failed");
    if (blob.size <= CHAT_IMAGE_MAX_BYTES) return blob;
  }
  throw new AvatarError("too_large");
}

/** Uploads a prepared photo for one conversation. Resolves with the object path. */
export async function uploadChatImage(
  userId: string,
  conversationId: string,
  blob: Blob,
): Promise<string> {
  const path = chatImagePath(userId, conversationId, crypto.randomUUID());
  const { error } = await supabase.storage.from(CHAT_IMAGE_BUCKET).upload(path, blob, {
    contentType: "image/jpeg",
    upsert: false,
  });
  if (error) throw error;
  return path;
}

/** Deletes an uploaded photo that was never sent (the storage policy allows only that). */
export async function discardChatImage(path: string): Promise<void> {
  await supabase.storage.from(CHAT_IMAGE_BUCKET).remove([path]);
}

/** Copy for a photo that could not be prepared. */
export function chatImageErrorMessage(err: unknown): string {
  if (err instanceof AvatarError) {
    if (err.code === "not_an_image") return "That file isn't a photo.";
    if (err.code === "too_large") return "That photo is too large. Try another.";
    return "That photo couldn't be read. Try another.";
  }
  return "";
}
