import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ArrowLeft } from "lucide-react";

import { AvatarUploader } from "@/components/shared/avatar-uploader";
import { HubManager } from "@/components/shared/hub-manager";
import { ProfileDetailsForm } from "@/components/shared/profile-details-form";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { createClient } from "@/lib/supabase/server";
import type { Hub } from "@/types/database";

export const metadata: Metadata = {
  title: "Edit profile",
};

export default async function EditProfilePage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select(
      "username, full_name, organization, bio, birthday, location_text, latitude, longitude, avatar_url, selected_hobbies",
    )
    .eq("id", user.id)
    .maybeSingle();

  if (!profile) {
    redirect("/onboarding");
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-3">
        <Button asChild variant="ghost" size="icon">
          <Link href="/profile" aria-label="Back to profile">
            <ArrowLeft className="h-4 w-4" />
          </Link>
        </Button>
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Edit profile</h1>
          <p className="text-sm text-muted-foreground">
            Make it yours — photo, details, and the hubs you&apos;re part of.
          </p>
        </div>
      </div>

      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base">Photo</CardTitle>
        </CardHeader>
        <CardContent>
          <AvatarUploader
            userId={user.id}
            username={profile.username}
            avatarUrl={profile.avatar_url}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base">Personal details</CardTitle>
        </CardHeader>
        <CardContent>
          <ProfileDetailsForm
            initial={{
              fullName: profile.full_name,
              username: profile.username,
              organization: profile.organization,
              bio: profile.bio,
              birthday: profile.birthday,
              locationText: profile.location_text,
              latitude: profile.latitude,
              longitude: profile.longitude,
            }}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base">Your hubs</CardTitle>
        </CardHeader>
        <CardContent>
          <HubManager initialHubs={profile.selected_hobbies as Hub[]} />
        </CardContent>
      </Card>
    </div>
  );
}
