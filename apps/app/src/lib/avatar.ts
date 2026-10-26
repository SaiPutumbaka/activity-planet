import { supabase } from "./supabase";

/**
 * Profile photos (PLAN.md 4.1). The browser does the work: the picked image is decoded,
 * cover-cropped to a 512 x 512 square and re-encoded as JPEG at quality 0.85 (well under 200
 * KB), then uploaded to the public `avatars` bucket at <uid>/<timestamp>.jpg. The storage
 * policies only let a user write inside their own folder; profiles.avatar_url is a direct
 * column update (migration 1 grants it).
 */

export const AVATAR_BUCKET = "avatars";
export const AVATAR_SIZE = 512;
export const AVATAR_JPEG_QUALITY = 0.85;
/** The source file the person picks. Phones produce 3 to 12 MB HEIC/JPEG files. */
export const MAX_SOURCE_BYTES = 25 * 1024 * 1024;
/** The bucket's limit from migration 8; a resized avatar never comes close. */
export const MAX_UPLOAD_BYTES = 2 * 1024 * 1024;

export class AvatarError extends Error {
  constructor(public readonly code: "not_an_image" | "too_large" | "unreadable" | "encode_failed") {
    super(code);
    this.name = "AvatarError";
  }
}

const IMAGE_EXTENSION = /\.(jpe?g|png|webp|gif|heic|heif|avif|bmp|tiff?)$/i;

/** Type check before any decoding. Some browsers report an empty type for HEIC. */
export function checkSourceFile(file: File): void {
  const looksLikeImage = file.type
    ? file.type.startsWith("image/")
    : IMAGE_EXTENSION.test(file.name);
  if (!looksLikeImage) throw new AvatarError("not_an_image");
  if (file.size > MAX_SOURCE_BYTES) throw new AvatarError("too_large");
}

type Drawable = ImageBitmap | HTMLImageElement;

async function decode(file: File): Promise<Drawable> {
  // createImageBitmap honours EXIF orientation ("from-image" is the default where supported).
  if (typeof createImageBitmap === "function") {
    try {
      return await createImageBitmap(file, { imageOrientation: "from-image" });
    } catch {
      /* fall through to the <img> path (older Safari, unusual formats) */
    }
  }
  const url = URL.createObjectURL(file);
  try {
    return await new Promise<HTMLImageElement>((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = () => reject(new AvatarError("unreadable"));
      img.src = url;
    });
  } finally {
    // Revoke after the draw; the element keeps the decoded bitmap.
    setTimeout(() => URL.revokeObjectURL(url), 0);
  }
}

/**
 * Decodes, cover-crops to a centered square and encodes a 512 x 512 JPEG. Throws
 * AvatarError for anything the person can fix by picking another file.
 */
export async function prepareAvatar(file: File): Promise<Blob> {
  checkSourceFile(file);
  let image: Drawable;
  try {
    image = await decode(file);
  } catch (err) {
    throw err instanceof AvatarError ? err : new AvatarError("unreadable");
  }
  const width = "naturalWidth" in image ? image.naturalWidth : image.width;
  const height = "naturalHeight" in image ? image.naturalHeight : image.height;
  if (!width || !height) throw new AvatarError("unreadable");

  const side = Math.min(width, height);
  const sx = Math.floor((width - side) / 2);
  const sy = Math.floor((height - side) / 2);

  const canvas = document.createElement("canvas");
  canvas.width = AVATAR_SIZE;
  canvas.height = AVATAR_SIZE;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new AvatarError("encode_failed");
  // JPEG has no alpha: transparent PNG corners become white, not black.
  ctx.fillStyle = "#ffffff";
  ctx.fillRect(0, 0, AVATAR_SIZE, AVATAR_SIZE);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(image, sx, sy, side, side, 0, 0, AVATAR_SIZE, AVATAR_SIZE);
  if ("close" in image) image.close();

  const blob = await new Promise<Blob | null>((resolve) =>
    canvas.toBlob(resolve, "image/jpeg", AVATAR_JPEG_QUALITY),
  );
  if (!blob) throw new AvatarError("encode_failed");
  if (blob.size > MAX_UPLOAD_BYTES) throw new AvatarError("too_large");
  return blob;
}

/** The object path inside the bucket when `url` is one of this user's own avatars, else null. */
export function ownAvatarPath(url: string | null | undefined, userId: string): string | null {
  if (!url) return null;
  const marker = `/storage/v1/object/public/${AVATAR_BUCKET}/`;
  const at = url.indexOf(marker);
  if (at === -1) return null;
  let path = url.slice(at + marker.length);
  const query = path.indexOf("?");
  if (query !== -1) path = path.slice(0, query);
  try {
    path = decodeURIComponent(path);
  } catch {
    return null;
  }
  return path.startsWith(`${userId}/`) ? path : null;
}

/**
 * Uploads the prepared JPEG, points the profile at it, then removes the previous object when
 * it was ours. Resolves with the new public URL. The order matters: the profile never points
 * at a missing file, and a failed delete only leaves an orphan the next upload or account
 * deletion cleans up.
 */
export async function uploadAvatar(
  userId: string,
  blob: Blob,
  previousUrl: string | null | undefined,
): Promise<string> {
  const path = `${userId}/${Date.now()}.jpg`;
  const { error: uploadError } = await supabase.storage.from(AVATAR_BUCKET).upload(path, blob, {
    contentType: "image/jpeg",
    cacheControl: "31536000",
    upsert: false,
  });
  if (uploadError) throw uploadError;

  const { data } = supabase.storage.from(AVATAR_BUCKET).getPublicUrl(path);
  const publicUrl = data.publicUrl;

  const { error: profileError } = await supabase
    .from("profiles")
    .update({ avatar_url: publicUrl })
    .eq("id", userId);
  if (profileError) {
    // Don't leave the orphan behind when the profile could not be updated.
    await supabase.storage.from(AVATAR_BUCKET).remove([path]);
    throw profileError;
  }

  const previous = ownAvatarPath(previousUrl, userId);
  if (previous && previous !== path) {
    await supabase.storage.from(AVATAR_BUCKET).remove([previous]);
  }
  return publicUrl;
}

/** Clears profiles.avatar_url, then deletes the object when it was ours. */
export async function removeAvatar(
  userId: string,
  currentUrl: string | null | undefined,
): Promise<void> {
  const { error } = await supabase.from("profiles").update({ avatar_url: null }).eq("id", userId);
  if (error) throw error;
  const path = ownAvatarPath(currentUrl, userId);
  if (path) await supabase.storage.from(AVATAR_BUCKET).remove([path]);
}

/** Sentences for AvatarError codes and the Storage API's messages. */
export function avatarErrorMessage(err: unknown): string {
  if (err instanceof AvatarError) {
    switch (err.code) {
      case "not_an_image":
        return "Pick a photo: a JPG, PNG, WebP or HEIC file.";
      case "too_large":
        return "That file is too big. Pick a photo under 25 MB.";
      case "unreadable":
        return "We couldn't read that image. Try a JPG or PNG.";
      case "encode_failed":
        return "Your browser couldn't resize that photo. Try another one.";
    }
  }
  const message =
    typeof err === "object" && err && "message" in err && typeof err.message === "string"
      ? err.message
      : String(err ?? "");
  const lower = message.toLowerCase();
  if (lower.includes("row-level security") || lower.includes("unauthorized")) {
    return "Your session ended. Sign in again.";
  }
  if (lower.includes("maximum allowed size") || lower.includes("too large")) {
    return "That photo is too big to upload. Try another one.";
  }
  if (lower.includes("mime type")) return "Only JPG, PNG and WebP photos can be uploaded.";
  if (lower.includes("already exists")) return "Try again; that file name was just taken.";
  if (lower.includes("failed to fetch") || lower.includes("network")) {
    return "Check your connection and try again.";
  }
  return message || "Something went wrong. Try again.";
}
