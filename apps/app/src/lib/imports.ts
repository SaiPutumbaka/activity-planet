import { queryOptions } from "@tanstack/react-query";

import { supabase } from "./supabase";

/**
 * Labels for imported listings (D-037): imported_event_labels() returns, for imported events the
 * viewer can read, the source's attribution, its chip (PIN: "Georgia State student org event"),
 * the hosting organization, whether the source says the event is open to the public, whether
 * the map point is an approximation, and the organization the source belongs to (shown as the
 * D-022 not-affiliated line). The importer tables themselves are not readable by clients.
 *
 *   useQuery(importLabelsQuery(ids))   // Map<eventId, ImportLabel>
 */
export interface ImportLabel {
  event_id: string;
  source_slug: string;
  source_kind: string;
  source_name: string;
  attribution: string;
  homepage_url: string | null;
  item_label: string | null;
  host_org: string | null;
  open_to_public: boolean | null;
  approximate_location: boolean;
  affiliated_org_name: string | null;
}

export const importLabelsQuery = (eventIds: readonly string[]) => {
  const ids = [...new Set(eventIds)].sort();
  return queryOptions({
    queryKey: ["imports", "labels", ids] as const,
    queryFn: async (): Promise<Map<string, ImportLabel>> => {
      if (ids.length === 0) return new Map();
      const { data, error } = await supabase.rpc("imported_event_labels", { p_event_ids: ids });
      if (error) throw error;
      return new Map(data.map((l) => [l.event_id, l]));
    },
    enabled: ids.length > 0,
    staleTime: 5 * 60_000,
  });
};

/** This listing's page in the app, for the removal email. */
export function appEventUrl(id: string): string {
  return `${window.location.origin}/events/${id}`;
}
