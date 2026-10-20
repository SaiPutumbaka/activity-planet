import { queryOptions, type QueryClient } from "@tanstack/react-query";
import type { Database } from "@ap/core/types";

import { supabase } from "./supabase";

export type Profile = Database["public"]["Tables"]["profiles"]["Row"];
export type Hub = Database["public"]["Tables"]["hubs"]["Row"];
export type HubCategory = Database["public"]["Tables"]["hub_categories"]["Row"];
export type Campus = Database["public"]["Tables"]["org_campuses"]["Row"];

export const profileQuery = (userId: string) =>
  queryOptions({
    queryKey: ["profile", userId] as const,
    queryFn: async (): Promise<Profile> => {
      const { data, error } = await supabase.from("profiles").select("*").eq("id", userId).single();
      if (error) throw error;
      return data;
    },
    staleTime: 60_000,
  });

export function getProfile(queryClient: QueryClient, userId: string): Promise<Profile> {
  return queryClient.ensureQueryData(profileQuery(userId));
}

/** Every active hub with its category, for the onboarding picker and the Hubs tab. One request, ~60 KB. */
export const hubCatalogQuery = queryOptions({
  queryKey: ["hubs", "catalog"] as const,
  queryFn: async () => {
    const [cats, hubs] = await Promise.all([
      supabase
        .from("hub_categories")
        .select("slug,name,color_key,sort_order,is_sensitive,scope,min_age")
        .order("sort_order"),
      supabase
        .from("hubs")
        .select("id,slug,name,category_slug,emoji,aliases,scope,min_age,is_featured")
        .eq("is_active", true)
        .order("name"),
    ]);
    if (cats.error) throw cats.error;
    if (hubs.error) throw hubs.error;
    return { categories: cats.data, hubs: hubs.data };
  },
  staleTime: 10 * 60_000,
});

export type CatalogHub = Awaited<
  ReturnType<NonNullable<typeof hubCatalogQuery.queryFn>>
>["hubs"][number];
export type CatalogCategory = Awaited<
  ReturnType<NonNullable<typeof hubCatalogQuery.queryFn>>
>["categories"][number];

export const campusesQuery = queryOptions({
  queryKey: ["campuses"] as const,
  queryFn: async () => {
    const { data, error } = await supabase
      .from("org_campuses")
      .select("id,slug,name,org_id,timezone,organizations(name,slug)")
      .order("name");
    if (error) throw error;
    // The main campus leads the list; the rest stay alphabetical.
    const MAIN = new Set(["atlanta"]);
    return [...data].sort((a, b) => Number(MAIN.has(b.slug)) - Number(MAIN.has(a.slug)));
  },
  staleTime: 10 * 60_000,
});

/** The hubs the signed-in person belongs to. */
export const myHubsQuery = (userId: string) =>
  queryOptions({
    queryKey: ["my-hubs", userId] as const,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("hub_members")
        .select("hub_id,notify,joined_at,hubs(id,slug,name,emoji,category_slug)")
        .eq("user_id", userId)
        .order("joined_at");
      if (error) throw error;
      return data;
    },
    staleTime: 60_000,
  });
