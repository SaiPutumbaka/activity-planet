"use client";

import { useRef, useState, useTransition } from "react";
import { Camera, Loader2 } from "lucide-react";
import { toast } from "sonner";

import { updateAvatarAction } from "@/actions/profile";
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { createClient } from "@/lib/supabase/client";

const MAX_FILE_BYTES = 5 * 1024 * 1024;
const EXTENSION_BY_TYPE: Record<string, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/webp": "webp",
  "image/gif": "gif",
};

function randomFileId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

interface AvatarUploaderProps {
  userId: string;
  username: string;
  avatarUrl: string | null;
}

export function AvatarUploader({
  userId,
  username,
  avatarUrl,
}: AvatarUploaderProps) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [preview, setPreview] = useState<string | null>(avatarUrl);
  const [isUploading, setIsUploading] = useState(false);
  const [, startTransition] = useTransition();

  function handlePick() {
    inputRef.current?.click();
  }

  async function handleFileChange(
    event: React.ChangeEvent<HTMLInputElement>,
  ) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) {
      return;
    }

    const extension = EXTENSION_BY_TYPE[file.type];
    if (!extension) {
      toast.error("Please choose a PNG, JPEG, WEBP, or GIF image.");
      return;
    }
    if (file.size > MAX_FILE_BYTES) {
      toast.error("Images must be 5MB or smaller.");
      return;
    }

    setIsUploading(true);
    const supabase = createClient();
    const path = `${userId}/${randomFileId()}.${extension}`;

    const { error: uploadError } = await supabase.storage
      .from("avatars")
      .upload(path, file, { cacheControl: "3600", upsert: false });

    if (uploadError) {
      toast.error("Could not upload your photo. Please try again.");
      setIsUploading(false);
      return;
    }

    const {
      data: { publicUrl },
    } = supabase.storage.from("avatars").getPublicUrl(path);
    setPreview(publicUrl);

    startTransition(async () => {
      const result = await updateAvatarAction({ avatarUrl: publicUrl });
      if (result.status === "error") {
        toast.error(result.message);
      } else {
        toast.success("Profile photo updated.");
      }
      setIsUploading(false);
    });
  }

  return (
    <div className="flex items-center gap-4">
      <Avatar className="h-20 w-20">
        {preview ? <AvatarImage src={preview} alt="" /> : null}
        <AvatarFallback className="text-2xl font-semibold uppercase">
          {username.slice(0, 2)}
        </AvatarFallback>
      </Avatar>
      <div>
        <Button
          type="button"
          variant="outline"
          onClick={handlePick}
          disabled={isUploading}
        >
          {isUploading ? (
            <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
          ) : (
            <Camera className="h-4 w-4" aria-hidden />
          )}
          Change photo
        </Button>
        <p className="mt-1.5 text-xs text-muted-foreground">
          PNG, JPEG, WEBP, or GIF. Up to 5MB.
        </p>
      </div>
      <input
        ref={inputRef}
        type="file"
        accept="image/png,image/jpeg,image/webp,image/gif"
        className="hidden"
        onChange={handleFileChange}
      />
    </div>
  );
}
