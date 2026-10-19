/**
 * Database types. Placeholder matching the v1 schema's public tables at the column level we
 * touch today; replaced by `supabase gen types typescript` output once schema v2 lands
 * (see docs/PLAN.md section 5). Do not hand-edit after generation is wired up.
 */
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

export interface Database {
  public: {
    Tables: {
      profiles: {
        Row: {
          id: string;
          username: string;
          full_name: string;
          bio: string;
          avatar_url: string | null;
          created_at: string;
        };
        Insert: {
          id: string;
          username: string;
          full_name?: string;
          bio?: string;
          avatar_url?: string | null;
        };
        Update: {
          username?: string;
          full_name?: string;
          bio?: string;
          avatar_url?: string | null;
        };
        Relationships: [];
      };
    };
    Views: Record<string, never>;
    Functions: Record<string, never>;
    Enums: Record<string, never>;
    CompositeTypes: Record<string, never>;
  };
}
