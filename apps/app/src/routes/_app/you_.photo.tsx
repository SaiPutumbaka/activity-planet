import { useEffect, useState } from "react";
import { createFileRoute, getRouteApi, useNavigate, useRouter } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { TopBar } from "@/components/shell/top-bar";
import { PhotoPicker } from "@/components/you/photo-picker";
import { avatarErrorMessage, prepareAvatar, removeAvatar, uploadAvatar } from "@/lib/avatar";
import { profileQuery } from "@/lib/profile";

const appRoute = getRouteApi("/_app");

/**
 * Profile photo. A sibling of the You tab at /you/photo (file name `you_.photo.tsx`, like
 * `you_.delete.tsx`), so it renders with its own TopBar instead of inside the tab.
 */
export const Route = createFileRoute("/_app/you_/photo")({
  component: PhotoPage,
});

interface Selection {
  blob: Blob;
  url: string;
}

function PhotoPage() {
  const { session, profile: contextProfile } = appRoute.useRouteContext();
  const userId = session.user.id;
  const queryClient = useQueryClient();
  const router = useRouter();
  const navigate = useNavigate();

  // The route context is a snapshot from beforeLoad; the query is what mutations update.
  const profileResult = useQuery(profileQuery(userId));
  const profile = profileResult.data ?? contextProfile;
  const currentUrl = profile.avatar_url;

  const [selection, setSelection] = useState<Selection | null>(null);
  const [preparing, setPreparing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Object URLs are freed when replaced or when the page goes away.
  useEffect(() => {
    if (!selection) return;
    const { url } = selection;
    return () => URL.revokeObjectURL(url);
  }, [selection]);

  async function refreshProfile(avatarUrl: string | null) {
    queryClient.setQueryData(profileQuery(userId).queryKey, (old) =>
      old ? { ...old, avatar_url: avatarUrl } : old,
    );
    await queryClient.invalidateQueries({ queryKey: ["profile"] });
    // Re-runs the _app guard so its context carries the new URL too.
    await router.invalidate();
  }

  const upload = useMutation({
    mutationFn: (blob: Blob) => uploadAvatar(userId, blob, currentUrl),
    onSuccess: async (url) => {
      setSelection(null);
      await refreshProfile(url);
      toast.success("Photo saved.");
      await navigate({ to: "/you" });
    },
    onError: (err) => setError(avatarErrorMessage(err)),
  });

  const remove = useMutation({
    mutationFn: () => removeAvatar(userId, currentUrl),
    onSuccess: async () => {
      await refreshProfile(null);
      toast.success("Photo removed.");
      await navigate({ to: "/you" });
    },
    onError: (err) => setError(avatarErrorMessage(err)),
  });

  async function onPick(file: File) {
    setError(null);
    setPreparing(true);
    try {
      const blob = await prepareAvatar(file);
      setSelection({ blob, url: URL.createObjectURL(blob) });
    } catch (err) {
      setError(avatarErrorMessage(err));
    } finally {
      setPreparing(false);
    }
  }

  return (
    <>
      <TopBar title={currentUrl ? "Change photo" : "Add a photo"} back />
      <main className="flex flex-col gap-6 pb-8 safe-px">
        <section className="flex flex-col gap-2 pt-2">
          <h2 className="text-[22px] font-extrabold tracking-[-0.02em]">
            {currentUrl ? "Your photo" : "Put a face to the name"}
          </h2>
          <p className="text-text-2">
            Your photo shows on events you join and in chats, so people can find you at the door. A
            clear shot of your face works best.
          </p>
        </section>

        <PhotoPicker
          name={profile.first_name}
          currentUrl={currentUrl}
          previewUrl={selection?.url ?? null}
          preparing={preparing}
          saving={upload.isPending}
          removing={remove.isPending}
          error={error}
          onPick={onPick}
          onSave={() => {
            if (!selection) return;
            setError(null);
            upload.mutate(selection.blob);
          }}
          onDiscard={() => {
            setSelection(null);
            setError(null);
          }}
          onRemove={() => {
            setError(null);
            remove.mutate();
          }}
        />
      </main>
    </>
  );
}
