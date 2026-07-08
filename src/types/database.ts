/**
 * Hand-authored database types matching supabase/migrations/*.sql.
 * If the schema changes, update both files together (or switch to
 * `supabase gen types typescript` once the CLI is part of the workflow).
 */

export const HUBS = [
  "College Campus Life",
  "Basketball",
  "Pickleball",
  "Anime",
  "TV Shows",
  "Movies",
  "Ping Pong",
  "Pool",
] as const;

export type Hub = (typeof HUBS)[number];

export function isHub(value: string): value is Hub {
  return (HUBS as readonly string[]).includes(value);
}

// These are `type` aliases, not `interface`s, on purpose: interfaces lack
// implicit index signatures, so they fail supabase-js's
// `Row extends Record<string, unknown>` constraint and every query would
// silently type as `never`.
export type ProfileRow = {
  id: string;
  email: string;
  username: string;
  organization: string;
  bio: string;
  selected_hobbies: string[];
  avatar_url: string | null;
  birthday: string | null;
  location_text: string;
  latitude: number | null;
  longitude: number | null;
  created_at: string;
};

export type EventRow = {
  id: string;
  creator_id: string;
  title: string;
  description: string;
  category: string;
  location: string;
  latitude: number | null;
  longitude: number | null;
  event_timestamp: string;
  created_at: string;
};

export type RsvpRow = {
  event_id: string;
  user_id: string;
  created_at: string;
};

export type HubMessageRow = {
  id: string;
  hub: string;
  sender_id: string;
  body: string;
  created_at: string;
};

export type Database = {
  public: {
    Tables: {
      profiles: {
        Row: ProfileRow;
        Insert: {
          id: string;
          email: string;
          username: string;
          organization?: string;
          bio?: string;
          selected_hobbies?: string[];
          avatar_url?: string | null;
          birthday?: string | null;
          location_text?: string;
          latitude?: number | null;
          longitude?: number | null;
          created_at?: string;
        };
        Update: {
          username?: string;
          organization?: string;
          bio?: string;
          selected_hobbies?: string[];
          avatar_url?: string | null;
          birthday?: string | null;
          location_text?: string;
          latitude?: number | null;
          longitude?: number | null;
        };
        Relationships: [];
      };
      events: {
        Row: EventRow;
        Insert: {
          id?: string;
          creator_id: string;
          title: string;
          description?: string;
          category: string;
          location: string;
          latitude?: number | null;
          longitude?: number | null;
          event_timestamp: string;
          created_at?: string;
        };
        Update: {
          title?: string;
          description?: string;
          category?: string;
          location?: string;
          latitude?: number | null;
          longitude?: number | null;
          event_timestamp?: string;
        };
        Relationships: [
          {
            foreignKeyName: "events_creator_id_fkey";
            columns: ["creator_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      rsvps: {
        Row: RsvpRow;
        Insert: {
          event_id: string;
          user_id: string;
          created_at?: string;
        };
        // RLS has no update policy for rsvps; kept as an object type because
        // supabase-js requires it structurally.
        Update: {
          event_id?: string;
          user_id?: string;
          created_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "rsvps_event_id_fkey";
            columns: ["event_id"];
            isOneToOne: false;
            referencedRelation: "events";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "rsvps_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      hub_messages: {
        Row: HubMessageRow;
        Insert: {
          id?: string;
          hub: string;
          sender_id: string;
          body: string;
          created_at?: string;
        };
        // No update policy: messages are permanent once posted.
        Update: {
          hub?: string;
          sender_id?: string;
          body?: string;
          created_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "hub_messages_sender_id_fkey";
            columns: ["sender_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
    };
    Views: Record<string, never>;
    Functions: Record<string, never>;
    Enums: Record<string, never>;
    CompositeTypes: Record<string, never>;
  };
};
