import { useRef, type ChangeEvent } from "react";
import { Camera, Trash } from "lucide-react";

import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { FormError } from "@/components/ui/field";

/**
 * Big avatar, a hidden file input and the three actions. The parent owns the file work
 * (resize, upload, remove) and tells this component which state it is in.
 */
export function PhotoPicker({
  name,
  currentUrl,
  previewUrl,
  preparing,
  saving,
  removing,
  error,
  onPick,
  onSave,
  onDiscard,
  onRemove,
}: {
  name: string;
  currentUrl: string | null;
  /** Object URL of the resized photo waiting to be saved, or null. */
  previewUrl: string | null;
  preparing: boolean;
  saving: boolean;
  removing: boolean;
  error: string | null;
  onPick: (file: File) => void;
  onSave: () => void;
  onDiscard: () => void;
  onRemove: () => void;
}) {
  const inputRef = useRef<HTMLInputElement>(null);
  const busy = preparing || saving || removing;
  const shown = previewUrl ?? currentUrl;

  function onChange(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    // Reset so picking the same file again fires onChange.
    event.target.value = "";
    if (file) onPick(file);
  }

  return (
    <div className="flex flex-col items-center gap-5">
      {/* key: Avatar remembers a broken image until it remounts. */}
      <Avatar key={shown ?? "none"} src={shown} name={name} size={144} />
      <p className="max-w-[36ch] text-center text-[13px] text-text-3">
        JPG, PNG, WebP or HEIC up to 25 MB. We crop it square and resize it to 512 px before it
        leaves your phone.
      </p>
      <input
        ref={inputRef}
        type="file"
        accept="image/*"
        className="sr-only"
        tabIndex={-1}
        aria-hidden="true"
        onChange={onChange}
        disabled={busy}
      />
      <FormError>{error}</FormError>

      {previewUrl ? (
        <div className="flex w-full flex-col gap-2">
          <Button size="lg" block loading={saving} onClick={onSave} disabled={removing}>
            Save photo
          </Button>
          <Button variant="secondary" size="lg" block onClick={onDiscard} disabled={busy}>
            Choose another
          </Button>
        </div>
      ) : (
        <div className="flex w-full flex-col gap-2">
          <Button
            variant={currentUrl ? "secondary" : "primary"}
            size="lg"
            block
            loading={preparing}
            disabled={saving || removing}
            leading={<Camera className="size-5" aria-hidden="true" />}
            onClick={() => inputRef.current?.click()}
          >
            {currentUrl ? "Change photo" : "Choose a photo"}
          </Button>
          {currentUrl ? (
            <Button
              variant="ghost"
              size="lg"
              block
              className="text-danger hover:bg-danger-tint"
              loading={removing}
              disabled={preparing || saving}
              leading={<Trash className="size-5" aria-hidden="true" />}
              onClick={onRemove}
            >
              Remove photo
            </Button>
          ) : null}
        </div>
      )}
    </div>
  );
}
