import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { MapPin } from "lucide-react";

import { HubJoinToggle } from "@/components/shared/hub-join-toggle";
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { distanceMiles, formatDistance } from "@/lib/geo";
import { hubToSlug } from "@/lib/hub-slug";
import { HUB_EMOJI } from "@/lib/hubs";
import { createClient } from "@/lib/supabase/server";
import { HUBS, isHub, type Hub } from "@/types/database";

export const metadata: Metadata = {
  title: "Discover",
};

export default async function DiscoverPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("selected_hobbies, latitude, longitude")
    .eq("id", user.id)
    .maybeSingle();

  if (!profile) {
    redirect("/onboarding");
  }

  const myHubs = new Set(profile.selected_hobbies.filter(isHub));
  const viewerLocation =
    profile.latitude !== null && profile.longitude !== null
      ? { latitude: profile.latitude, longitude: profile.longitude }
      : null;

  const [{ data: peopleRows }, hubCountEntries] = await Promise.all([
    supabase
      .from("profiles")
      .select(
        "id, username, organization, bio, avatar_url, selected_hobbies, latitude, longitude",
      )
      .neq("id", user.id)
      .order("created_at", { ascending: false })
      .limit(30),
    Promise.all(
      HUBS.map(async (hub) => {
        const { count } = await supabase
          .from("profiles")
          .select("id", { count: "exact", head: true })
          .contains("selected_hobbies", [hub]);
        return [hub, count ?? 0] as const;
      }),
    ),
  ]);

  const hubMemberCounts = new Map<Hub, number>(hubCountEntries);

  const people = (peopleRows ?? [])
    .map((person) => ({
      ...person,
      distance:
        viewerLocation &&
        person.latitude !== null &&
        person.longitude !== null
          ? distanceMiles(viewerLocation, {
              latitude: person.latitude,
              longitude: person.longitude,
            })
          : null,
      sharedHubs: person.selected_hobbies.filter((hub) => myHubs.has(hub as Hub)),
    }))
    .sort((a, b) => {
      if (a.distance !== null && b.distance !== null) {
        return a.distance - b.distance;
      }
      if (a.distance !== null) {
        return -1;
      }
      if (b.distance !== null) {
        return 1;
      }
      return 0;
    });

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Discover</h1>
        <p className="text-sm text-muted-foreground">
          Find people and hubs around you.
        </p>
      </div>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold">Hubs to explore</h2>
        <div className="grid gap-3 sm:grid-cols-2">
          {HUBS.map((hub) => (
            <Card key={hub}>
              <CardContent className="flex items-center justify-between gap-3 p-4">
                <Link
                  href={`/hubs/${hubToSlug(hub)}`}
                  className="flex min-w-0 items-center gap-3"
                >
                  <span className="text-2xl" aria-hidden>
                    {HUB_EMOJI[hub]}
                  </span>
                  <div className="min-w-0">
                    <p className="truncate font-medium">{hub}</p>
                    <p className="text-xs text-muted-foreground">
                      {hubMemberCounts.get(hub) ?? 0} member
                      {hubMemberCounts.get(hub) === 1 ? "" : "s"}
                    </p>
                  </div>
                </Link>
                <HubJoinToggle hub={hub} initialIsMember={myHubs.has(hub)} />
              </CardContent>
            </Card>
          ))}
        </div>
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold">People near you</h2>
        {people.length === 0 ? (
          <div className="rounded-xl border border-dashed px-6 py-12 text-center text-sm text-muted-foreground">
            No one else has joined yet — invite your friends!
          </div>
        ) : (
          <div className="space-y-3">
            {people.map((person) => (
              <Card key={person.id}>
                <CardContent className="flex items-start gap-3 p-4">
                  <Avatar className="h-11 w-11 shrink-0">
                    {person.avatar_url ? (
                      <AvatarImage src={person.avatar_url} alt="" />
                    ) : null}
                    <AvatarFallback className="text-sm font-semibold uppercase">
                      {person.username.slice(0, 2)}
                    </AvatarFallback>
                  </Avatar>
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-x-2 gap-y-0.5">
                      <p className="truncate font-medium">@{person.username}</p>
                      {person.distance !== null ? (
                        <span className="flex items-center gap-1 text-xs text-muted-foreground">
                          <MapPin className="h-3 w-3" aria-hidden />
                          {formatDistance(person.distance)}
                        </span>
                      ) : null}
                    </div>
                    {person.organization ? (
                      <p className="truncate text-xs text-muted-foreground">
                        {person.organization}
                      </p>
                    ) : null}
                    {person.bio ? (
                      <p className="mt-1 line-clamp-2 text-sm text-muted-foreground">
                        {person.bio}
                      </p>
                    ) : null}
                    {person.selected_hobbies.length > 0 ? (
                      <div className="mt-2 flex flex-wrap gap-1.5">
                        {person.selected_hobbies.slice(0, 5).map((hub) => (
                          <Badge
                            key={hub}
                            variant={
                              person.sharedHubs.includes(hub)
                                ? "default"
                                : "secondary"
                            }
                            className="gap-1 text-[11px]"
                          >
                            <span aria-hidden>
                              {isHub(hub) ? HUB_EMOJI[hub] : "📌"}
                            </span>
                            {hub}
                          </Badge>
                        ))}
                      </div>
                    ) : null}
                  </div>
                </CardContent>
              </Card>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
