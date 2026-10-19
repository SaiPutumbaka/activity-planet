/**
 * Database types, generated from the staging project with the Supabase management API after
 * migrations 1 to 3 (schema_version 2.3). Regenerate after every migration; do not hand-edit.
 */
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

export type Database = {
  __InternalSupabase: {
    PostgrestVersion: "14.18";
  };
  public: {
    Tables: {
      account_deletions: {
        Row: {
          apple_token_revoked_at: string | null;
          completed_at: string | null;
          email_hash: string;
          processors_notified: Json;
          reason: string | null;
          requested_at: string;
          retain_evidence_until: string | null;
          user_id: string;
        };
        Insert: {
          apple_token_revoked_at?: string | null;
          completed_at?: string | null;
          email_hash: string;
          processors_notified?: Json;
          reason?: string | null;
          requested_at?: string;
          retain_evidence_until?: string | null;
          user_id: string;
        };
        Update: {
          apple_token_revoked_at?: string | null;
          completed_at?: string | null;
          email_hash?: string;
          processors_notified?: Json;
          reason?: string | null;
          requested_at?: string;
          retain_evidence_until?: string | null;
          user_id?: string;
        };
        Relationships: [];
      };
      auth_provider_secrets: {
        Row: {
          created_at: string;
          provider: string;
          secret: string;
          updated_at: string;
          user_id: string;
        };
        Insert: {
          created_at?: string;
          provider: string;
          secret: string;
          updated_at?: string;
          user_id: string;
        };
        Update: {
          created_at?: string;
          provider?: string;
          secret?: string;
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "auth_provider_secrets_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      chapter_members: {
        Row: {
          chapter_id: string;
          joined_at: string;
          notify: boolean;
          role: Database["public"]["Enums"]["chapter_role"];
          user_id: string;
        };
        Insert: {
          chapter_id: string;
          joined_at?: string;
          notify?: boolean;
          role?: Database["public"]["Enums"]["chapter_role"];
          user_id: string;
        };
        Update: {
          chapter_id?: string;
          joined_at?: string;
          notify?: boolean;
          role?: Database["public"]["Enums"]["chapter_role"];
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "chapter_members_chapter_id_fkey";
            columns: ["chapter_id"];
            isOneToOne: false;
            referencedRelation: "hub_chapters";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "chapter_members_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      email_verification_codes: {
        Row: {
          attempts: number;
          code_hmac: string;
          consumed_at: string | null;
          created_at: string;
          email: string;
          expires_at: string;
          id: string;
          last_sent_at: string;
          org_id: string | null;
          send_count: number;
          user_id: string;
        };
        Insert: {
          attempts?: number;
          code_hmac: string;
          consumed_at?: string | null;
          created_at?: string;
          email: string;
          expires_at: string;
          id?: string;
          last_sent_at?: string;
          org_id?: string | null;
          send_count?: number;
          user_id: string;
        };
        Update: {
          attempts?: number;
          code_hmac?: string;
          consumed_at?: string | null;
          created_at?: string;
          email?: string;
          expires_at?: string;
          id?: string;
          last_sent_at?: string;
          org_id?: string | null;
          send_count?: number;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "email_verification_codes_org_id_fkey";
            columns: ["org_id"];
            isOneToOne: false;
            referencedRelation: "organizations";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "email_verification_codes_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      handle_history: {
        Row: { handle: string; id: string; released_at: string; user_id: string };
        Insert: { handle: string; id?: string; released_at?: string; user_id: string };
        Update: { handle?: string; id?: string; released_at?: string; user_id?: string };
        Relationships: [
          {
            foreignKeyName: "handle_history_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      hub_categories: {
        Row: {
          color_key: string;
          is_sensitive: boolean;
          min_age: number;
          name: string;
          scope: string;
          slug: string;
          sort_order: number;
        };
        Insert: {
          color_key: string;
          is_sensitive?: boolean;
          min_age?: number;
          name: string;
          scope?: string;
          slug: string;
          sort_order?: number;
        };
        Update: {
          color_key?: string;
          is_sensitive?: boolean;
          min_age?: number;
          name?: string;
          scope?: string;
          slug?: string;
          sort_order?: number;
        };
        Relationships: [];
      };
      hub_chapters: {
        Row: {
          campus_id: string | null;
          cover_url: string | null;
          created_at: string;
          created_by: string | null;
          description: string;
          hub_id: string;
          id: string;
          is_active: boolean;
          name: string;
          org_id: string;
          slug: string;
          updated_at: string;
        };
        Insert: {
          campus_id?: string | null;
          cover_url?: string | null;
          created_at?: string;
          created_by?: string | null;
          description?: string;
          hub_id: string;
          id?: string;
          is_active?: boolean;
          name: string;
          org_id: string;
          slug: string;
          updated_at?: string;
        };
        Update: {
          campus_id?: string | null;
          cover_url?: string | null;
          created_at?: string;
          created_by?: string | null;
          description?: string;
          hub_id?: string;
          id?: string;
          is_active?: boolean;
          name?: string;
          org_id?: string;
          slug?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "hub_chapters_campus_id_fkey";
            columns: ["campus_id"];
            isOneToOne: false;
            referencedRelation: "org_campuses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "hub_chapters_created_by_fkey";
            columns: ["created_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "hub_chapters_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "hub_chapters_org_id_fkey";
            columns: ["org_id"];
            isOneToOne: false;
            referencedRelation: "organizations";
            referencedColumns: ["id"];
          },
        ];
      };
      hub_members: {
        Row: { hub_id: string; joined_at: string; notify: boolean; user_id: string };
        Insert: { hub_id: string; joined_at?: string; notify?: boolean; user_id: string };
        Update: { hub_id?: string; joined_at?: string; notify?: boolean; user_id?: string };
        Relationships: [
          {
            foreignKeyName: "hub_members_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "hub_members_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      hub_requests: {
        Row: {
          created_at: string;
          hub_id: string | null;
          id: string;
          name: string;
          note: string;
          reviewed_at: string | null;
          reviewed_by: string | null;
          status: string;
          user_id: string | null;
        };
        Insert: {
          created_at?: string;
          hub_id?: string | null;
          id?: string;
          name: string;
          note?: string;
          reviewed_at?: string | null;
          reviewed_by?: string | null;
          status?: string;
          user_id?: string | null;
        };
        Update: {
          created_at?: string;
          hub_id?: string | null;
          id?: string;
          name?: string;
          note?: string;
          reviewed_at?: string | null;
          reviewed_by?: string | null;
          status?: string;
          user_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "hub_requests_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "hub_requests_reviewed_by_fkey";
            columns: ["reviewed_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "hub_requests_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      hub_stats: {
        Row: {
          active_members_30d: number;
          activity_score: number;
          campus_id: string | null;
          chapter_count: number;
          computed_at: string;
          events_next_7d: number;
          hub_id: string;
          id: string;
          member_count: number;
        };
        Insert: {
          active_members_30d?: number;
          activity_score?: number;
          campus_id?: string | null;
          chapter_count?: number;
          computed_at?: string;
          events_next_7d?: number;
          hub_id: string;
          id?: string;
          member_count?: number;
        };
        Update: {
          active_members_30d?: number;
          activity_score?: number;
          campus_id?: string | null;
          chapter_count?: number;
          computed_at?: string;
          events_next_7d?: number;
          hub_id?: string;
          id?: string;
          member_count?: number;
        };
        Relationships: [
          {
            foreignKeyName: "hub_stats_campus_id_fkey";
            columns: ["campus_id"];
            isOneToOne: false;
            referencedRelation: "org_campuses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "hub_stats_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
        ];
      };
      hubs: {
        Row: {
          aliases: string[];
          category_slug: string;
          cover_url: string | null;
          created_at: string;
          created_by: string | null;
          description: string;
          emoji: string;
          id: string;
          is_active: boolean;
          is_featured: boolean;
          min_age: number;
          name: string;
          scope: string;
          search_text: string | null;
          slug: string;
          updated_at: string;
        };
        Insert: {
          aliases?: string[];
          category_slug: string;
          cover_url?: string | null;
          created_at?: string;
          created_by?: string | null;
          description?: string;
          emoji?: string;
          id?: string;
          is_active?: boolean;
          is_featured?: boolean;
          min_age?: number;
          name: string;
          scope?: string;
          search_text?: string | null;
          slug: string;
          updated_at?: string;
        };
        Update: {
          aliases?: string[];
          category_slug?: string;
          cover_url?: string | null;
          created_at?: string;
          created_by?: string | null;
          description?: string;
          emoji?: string;
          id?: string;
          is_active?: boolean;
          is_featured?: boolean;
          min_age?: number;
          name?: string;
          scope?: string;
          search_text?: string | null;
          slug?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "hubs_category_slug_fkey";
            columns: ["category_slug"];
            isOneToOne: false;
            referencedRelation: "hub_categories";
            referencedColumns: ["slug"];
          },
          {
            foreignKeyName: "hubs_created_by_fkey";
            columns: ["created_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      meta: {
        Row: { key: string; updated_at: string; value: string };
        Insert: { key: string; updated_at?: string; value: string };
        Update: { key?: string; updated_at?: string; value?: string };
        Relationships: [];
      };
      notification_prefs: {
        Row: {
          checkin_prompts: boolean;
          email_enabled: boolean;
          event_reminders: boolean;
          event_updates: boolean;
          hub_activity: boolean;
          messages: boolean;
          push_enabled: boolean;
          quiet_end: string | null;
          quiet_start: string | null;
          timezone: string;
          unsubscribed_all_at: string | null;
          updated_at: string;
          user_id: string;
          weekly_digest: boolean;
        };
        Insert: {
          checkin_prompts?: boolean;
          email_enabled?: boolean;
          event_reminders?: boolean;
          event_updates?: boolean;
          hub_activity?: boolean;
          messages?: boolean;
          push_enabled?: boolean;
          quiet_end?: string | null;
          quiet_start?: string | null;
          timezone?: string;
          unsubscribed_all_at?: string | null;
          updated_at?: string;
          user_id: string;
          weekly_digest?: boolean;
        };
        Update: {
          checkin_prompts?: boolean;
          email_enabled?: boolean;
          event_reminders?: boolean;
          event_updates?: boolean;
          hub_activity?: boolean;
          messages?: boolean;
          push_enabled?: boolean;
          quiet_end?: string | null;
          quiet_start?: string | null;
          timezone?: string;
          unsubscribed_all_at?: string | null;
          updated_at?: string;
          user_id?: string;
          weekly_digest?: boolean;
        };
        Relationships: [
          {
            foreignKeyName: "notification_prefs_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: true;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      org_campuses: {
        Row: {
          created_at: string;
          id: string;
          location: unknown;
          name: string;
          org_id: string;
          slug: string;
          timezone: string;
          updated_at: string;
        };
        Insert: {
          created_at?: string;
          id?: string;
          location?: unknown;
          name: string;
          org_id: string;
          slug: string;
          timezone?: string;
          updated_at?: string;
        };
        Update: {
          created_at?: string;
          id?: string;
          location?: unknown;
          name?: string;
          org_id?: string;
          slug?: string;
          timezone?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "org_campuses_org_id_fkey";
            columns: ["org_id"];
            isOneToOne: false;
            referencedRelation: "organizations";
            referencedColumns: ["id"];
          },
        ];
      };
      org_email_domains: {
        Row: { created_at: string; domain: string; org_id: string };
        Insert: { created_at?: string; domain: string; org_id: string };
        Update: { created_at?: string; domain?: string; org_id?: string };
        Relationships: [
          {
            foreignKeyName: "org_email_domains_org_id_fkey";
            columns: ["org_id"];
            isOneToOne: false;
            referencedRelation: "organizations";
            referencedColumns: ["id"];
          },
        ];
      };
      org_memberships: {
        Row: {
          campus_id: string | null;
          expires_at: string | null;
          granted_by: string | null;
          org_id: string;
          role: Database["public"]["Enums"]["org_role"];
          source: string;
          user_id: string;
          verified_at: string;
          verified_email_id: string | null;
        };
        Insert: {
          campus_id?: string | null;
          expires_at?: string | null;
          granted_by?: string | null;
          org_id: string;
          role?: Database["public"]["Enums"]["org_role"];
          source?: string;
          user_id: string;
          verified_at?: string;
          verified_email_id?: string | null;
        };
        Update: {
          campus_id?: string | null;
          expires_at?: string | null;
          granted_by?: string | null;
          org_id?: string;
          role?: Database["public"]["Enums"]["org_role"];
          source?: string;
          user_id?: string;
          verified_at?: string;
          verified_email_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "org_memberships_campus_id_fkey";
            columns: ["campus_id"];
            isOneToOne: false;
            referencedRelation: "org_campuses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "org_memberships_granted_by_fkey";
            columns: ["granted_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "org_memberships_org_id_fkey";
            columns: ["org_id"];
            isOneToOne: false;
            referencedRelation: "organizations";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "org_memberships_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "org_memberships_verified_email_id_fkey";
            columns: ["verified_email_id"];
            isOneToOne: false;
            referencedRelation: "verified_emails";
            referencedColumns: ["id"];
          },
        ];
      };
      organizations: {
        Row: {
          created_at: string;
          id: string;
          is_verified: boolean;
          kind: Database["public"]["Enums"]["org_kind"];
          logo_url: string | null;
          name: string;
          slug: string;
          updated_at: string;
          website: string | null;
        };
        Insert: {
          created_at?: string;
          id?: string;
          is_verified?: boolean;
          kind?: Database["public"]["Enums"]["org_kind"];
          logo_url?: string | null;
          name: string;
          slug: string;
          updated_at?: string;
          website?: string | null;
        };
        Update: {
          created_at?: string;
          id?: string;
          is_verified?: boolean;
          kind?: Database["public"]["Enums"]["org_kind"];
          logo_url?: string | null;
          name?: string;
          slug?: string;
          updated_at?: string;
          website?: string | null;
        };
        Relationships: [];
      };
      profile_private: {
        Row: {
          birth_date: string | null;
          created_at: string;
          email: string;
          last_seen_at: string | null;
          location: unknown;
          location_text: string;
          location_updated_at: string | null;
          updated_at: string;
          user_id: string;
        };
        Insert: {
          birth_date?: string | null;
          created_at?: string;
          email: string;
          last_seen_at?: string | null;
          location?: unknown;
          location_text?: string;
          location_updated_at?: string | null;
          updated_at?: string;
          user_id: string;
        };
        Update: {
          birth_date?: string | null;
          created_at?: string;
          email?: string;
          last_seen_at?: string | null;
          location?: unknown;
          location_text?: string;
          location_updated_at?: string | null;
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "profile_private_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: true;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      profiles: {
        Row: {
          avatar_url: string | null;
          bio: string;
          created_at: string;
          deleted_at: string | null;
          deletion_requested_at: string | null;
          first_name: string;
          handle: string;
          handle_changed_at: string | null;
          home_campus_id: string | null;
          home_org_id: string | null;
          id: string;
          onboarding_completed_at: string | null;
          status: Database["public"]["Enums"]["account_status"];
          updated_at: string;
        };
        Insert: {
          avatar_url?: string | null;
          bio?: string;
          created_at?: string;
          deleted_at?: string | null;
          deletion_requested_at?: string | null;
          first_name?: string;
          handle: string;
          handle_changed_at?: string | null;
          home_campus_id?: string | null;
          home_org_id?: string | null;
          id: string;
          onboarding_completed_at?: string | null;
          status?: Database["public"]["Enums"]["account_status"];
          updated_at?: string;
        };
        Update: {
          avatar_url?: string | null;
          bio?: string;
          created_at?: string;
          deleted_at?: string | null;
          deletion_requested_at?: string | null;
          first_name?: string;
          handle?: string;
          handle_changed_at?: string | null;
          home_campus_id?: string | null;
          home_org_id?: string | null;
          id?: string;
          onboarding_completed_at?: string | null;
          status?: Database["public"]["Enums"]["account_status"];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "profiles_home_campus_id_fkey";
            columns: ["home_campus_id"];
            isOneToOne: false;
            referencedRelation: "org_campuses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "profiles_home_org_id_fkey";
            columns: ["home_org_id"];
            isOneToOne: false;
            referencedRelation: "organizations";
            referencedColumns: ["id"];
          },
        ];
      };
      push_devices: {
        Row: {
          app_version: string | null;
          created_at: string;
          failure_count: number;
          id: string;
          last_failure_at: string | null;
          last_seen_at: string;
          platform: Database["public"]["Enums"]["device_platform"];
          revoked_at: string | null;
          subscription: Json;
          token_hash: string;
          user_agent: string | null;
          user_id: string;
        };
        Insert: {
          app_version?: string | null;
          created_at?: string;
          failure_count?: number;
          id?: string;
          last_failure_at?: string | null;
          last_seen_at?: string;
          platform: Database["public"]["Enums"]["device_platform"];
          revoked_at?: string | null;
          subscription: Json;
          token_hash: string;
          user_agent?: string | null;
          user_id: string;
        };
        Update: {
          app_version?: string | null;
          created_at?: string;
          failure_count?: number;
          id?: string;
          last_failure_at?: string | null;
          last_seen_at?: string;
          platform?: Database["public"]["Enums"]["device_platform"];
          revoked_at?: string | null;
          subscription?: Json;
          token_hash?: string;
          user_agent?: string | null;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "push_devices_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      reserved_handles: {
        Row: { handle: string };
        Insert: { handle: string };
        Update: { handle?: string };
        Relationships: [];
      };
      user_roles: {
        Row: {
          created_at: string;
          granted_by: string | null;
          role: Database["public"]["Enums"]["app_role"];
          user_id: string;
        };
        Insert: {
          created_at?: string;
          granted_by?: string | null;
          role: Database["public"]["Enums"]["app_role"];
          user_id: string;
        };
        Update: {
          created_at?: string;
          granted_by?: string | null;
          role?: Database["public"]["Enums"]["app_role"];
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "user_roles_granted_by_fkey";
            columns: ["granted_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "user_roles_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      verified_emails: {
        Row: {
          created_at: string;
          domain: string | null;
          email: string;
          id: string;
          org_id: string | null;
          user_id: string;
          verified_at: string;
        };
        Insert: {
          created_at?: string;
          domain?: string | null;
          email: string;
          id?: string;
          org_id?: string | null;
          user_id: string;
          verified_at?: string;
        };
        Update: {
          created_at?: string;
          domain?: string | null;
          email?: string;
          id?: string;
          org_id?: string | null;
          user_id?: string;
          verified_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "verified_emails_org_id_fkey";
            columns: ["org_id"];
            isOneToOne: false;
            referencedRelation: "organizations";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "verified_emails_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      complete_onboarding: {
        Args: {
          p_birth_date: string;
          p_campus_id?: string;
          p_first_name: string;
          p_handle: string;
          p_hub_ids: string[];
          p_org_id?: string;
        };
        Returns: {
          avatar_url: string | null;
          bio: string;
          created_at: string;
          deleted_at: string | null;
          deletion_requested_at: string | null;
          first_name: string;
          handle: string;
          handle_changed_at: string | null;
          home_campus_id: string | null;
          home_org_id: string | null;
          id: string;
          onboarding_completed_at: string | null;
          status: Database["public"]["Enums"]["account_status"];
          updated_at: string;
        };
        SetofOptions: {
          from: "*";
          to: "profiles";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      generate_handle: { Args: { p_email: string }; Returns: string };
      handle_available: { Args: { p_handle: string }; Returns: boolean };
      has_org_role: {
        Args: { p_org: string; p_role: Database["public"]["Enums"]["org_role"] };
        Returns: boolean;
      };
      has_role: {
        Args: { p_role: Database["public"]["Enums"]["app_role"] };
        Returns: boolean;
      };
      hub_member_counts: {
        Args: { p_hub_ids: string[] };
        Returns: {
          hub_id: string;
          members: number;
        }[];
      };
      is_moderator: { Args: never; Returns: boolean };
      is_privileged: { Args: never; Returns: boolean };
      set_chapter_role: {
        Args: {
          p_chapter: string;
          p_role: Database["public"]["Enums"]["chapter_role"];
          p_user: string;
        };
        Returns: undefined;
      };
      touch_last_seen: { Args: never; Returns: undefined };
    };
    Enums: {
      account_status: "active" | "suspended" | "banned" | "deleted";
      app_role: "moderator" | "admin";
      chapter_role: "member" | "captain" | "organizer";
      device_platform: "web" | "ios" | "android";
      org_kind: "university" | "company" | "community";
      org_role: "member" | "officer" | "admin";
    };
    CompositeTypes: {
      [_ in never]: never;
    };
  };
};

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">;

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">];

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R;
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R;
      }
      ? R
      : never
    : never;

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema["Tables"] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I;
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I;
      }
      ? I
      : never
    : never;

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema["Tables"] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U;
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U;
      }
      ? U
      : never
    : never;

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    keyof DefaultSchema["Enums"] | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never;

export const Constants = {
  public: {
    Enums: {
      account_status: ["active", "suspended", "banned", "deleted"],
      app_role: ["moderator", "admin"],
      chapter_role: ["member", "captain", "organizer"],
      device_platform: ["web", "ios", "android"],
      org_kind: ["university", "company", "community"],
      org_role: ["member", "officer", "admin"],
    },
  },
} as const;
