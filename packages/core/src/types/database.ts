/**
 * Database types, generated from the staging project with the Supabase CLI after
 * migrations 1 to 21 (schema_version 2.17). Regenerate after every migration; do not hand-edit.
 */
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
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
      area_waitlist: {
        Row: {
          city: string;
          created_at: string;
          user_id: string;
        };
        Insert: {
          city: string;
          created_at?: string;
          user_id: string;
        };
        Update: {
          city?: string;
          created_at?: string;
          user_id?: string;
        };
        Relationships: [];
      };
      areas: {
        Row: {
          center: unknown;
          created_at: string;
          default_radius_km: number;
          id: string;
          kind: string;
          name: string;
          parent_id: string | null;
          slug: string;
          sort: number;
          timezone: string;
          updated_at: string;
        };
        Insert: {
          center: unknown;
          created_at?: string;
          default_radius_km?: number;
          id?: string;
          kind?: string;
          name: string;
          parent_id?: string | null;
          slug: string;
          sort?: number;
          timezone?: string;
          updated_at?: string;
        };
        Update: {
          center?: unknown;
          created_at?: string;
          default_radius_km?: number;
          id?: string;
          kind?: string;
          name?: string;
          parent_id?: string | null;
          slug?: string;
          sort?: number;
          timezone?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "areas_parent_id_fkey";
            columns: ["parent_id"];
            isOneToOne: false;
            referencedRelation: "areas";
            referencedColumns: ["id"];
          },
        ];
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
      chapter_claims: {
        Row: {
          agreement_version: string;
          area_id: string | null;
          campus_id: string | null;
          chapter_id: string | null;
          created_at: string;
          hub_id: string;
          id: string;
          kind: string;
          motivation: string;
          officer_role_text: string | null;
          org_id: string | null;
          pin_url: string | null;
          proposed_name: string;
          reference_contact: string | null;
          reference_name: string | null;
          review_note: string | null;
          reviewed_at: string | null;
          reviewed_by: string | null;
          rso_name: string | null;
          status: Database["public"]["Enums"]["chapter_claim_status"];
          updated_at: string;
          user_id: string;
        };
        Insert: {
          agreement_version: string;
          area_id?: string | null;
          campus_id?: string | null;
          chapter_id?: string | null;
          created_at?: string;
          hub_id: string;
          id?: string;
          kind: string;
          motivation?: string;
          officer_role_text?: string | null;
          org_id?: string | null;
          pin_url?: string | null;
          proposed_name: string;
          reference_contact?: string | null;
          reference_name?: string | null;
          review_note?: string | null;
          reviewed_at?: string | null;
          reviewed_by?: string | null;
          rso_name?: string | null;
          status?: Database["public"]["Enums"]["chapter_claim_status"];
          updated_at?: string;
          user_id: string;
        };
        Update: {
          agreement_version?: string;
          area_id?: string | null;
          campus_id?: string | null;
          chapter_id?: string | null;
          created_at?: string;
          hub_id?: string;
          id?: string;
          kind?: string;
          motivation?: string;
          officer_role_text?: string | null;
          org_id?: string | null;
          pin_url?: string | null;
          proposed_name?: string;
          reference_contact?: string | null;
          reference_name?: string | null;
          review_note?: string | null;
          reviewed_at?: string | null;
          reviewed_by?: string | null;
          rso_name?: string | null;
          status?: Database["public"]["Enums"]["chapter_claim_status"];
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "chapter_claims_area_id_fkey";
            columns: ["area_id"];
            isOneToOne: false;
            referencedRelation: "areas";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "chapter_claims_campus_id_fkey";
            columns: ["campus_id"];
            isOneToOne: false;
            referencedRelation: "org_campuses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "chapter_claims_chapter_id_fkey";
            columns: ["chapter_id"];
            isOneToOne: false;
            referencedRelation: "hub_chapters";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "chapter_claims_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "chapter_claims_org_id_fkey";
            columns: ["org_id"];
            isOneToOne: false;
            referencedRelation: "organizations";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "chapter_claims_reviewed_by_fkey";
            columns: ["reviewed_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "chapter_claims_user_id_fkey";
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
      event_addresses: {
        Row: {
          address_note: string;
          created_at: string;
          event_id: string;
          location_text: string;
          updated_at: string;
          venue_id: string | null;
        };
        Insert: {
          address_note?: string;
          created_at?: string;
          event_id: string;
          location_text?: string;
          updated_at?: string;
          venue_id?: string | null;
        };
        Update: {
          address_note?: string;
          created_at?: string;
          event_id?: string;
          location_text?: string;
          updated_at?: string;
          venue_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "event_addresses_event_id_fkey";
            columns: ["event_id"];
            isOneToOne: true;
            referencedRelation: "events";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "event_addresses_venue_id_fkey";
            columns: ["venue_id"];
            isOneToOne: false;
            referencedRelation: "venues";
            referencedColumns: ["id"];
          },
        ];
      };
      event_attendance_reports: {
        Row: {
          answered_at: string | null;
          attended: boolean | null;
          dismissed_at: string | null;
          event_id: string;
          user_id: string;
        };
        Insert: {
          answered_at?: string | null;
          attended?: boolean | null;
          dismissed_at?: string | null;
          event_id: string;
          user_id: string;
        };
        Update: {
          answered_at?: string | null;
          attended?: boolean | null;
          dismissed_at?: string | null;
          event_id?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "event_attendance_reports_rsvp_fkey";
            columns: ["event_id", "user_id"];
            isOneToOne: true;
            referencedRelation: "rsvps";
            referencedColumns: ["event_id", "user_id"];
          },
        ];
      };
      event_broadcasts: {
        Row: {
          body: string;
          created_at: string;
          event_id: string;
          id: string;
          recipient_count: number;
          sender_id: string | null;
        };
        Insert: {
          body: string;
          created_at?: string;
          event_id: string;
          id?: string;
          recipient_count?: number;
          sender_id?: string | null;
        };
        Update: {
          body?: string;
          created_at?: string;
          event_id?: string;
          id?: string;
          recipient_count?: number;
          sender_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "event_broadcasts_event_id_fkey";
            columns: ["event_id"];
            isOneToOne: false;
            referencedRelation: "events";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "event_broadcasts_sender_id_fkey";
            columns: ["sender_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      event_imports: {
        Row: {
          content_hash: string;
          event_id: string | null;
          external_id: string;
          first_seen_at: string;
          host_org: string | null;
          id: string;
          is_primary: boolean;
          last_seen_at: string;
          missed_runs: number;
          open_to_public: boolean | null;
          point_source: string;
          raw: Json;
          removed_at: string | null;
          removed_reason: string | null;
          source_id: string;
        };
        Insert: {
          content_hash: string;
          event_id?: string | null;
          external_id: string;
          first_seen_at?: string;
          host_org?: string | null;
          id?: string;
          is_primary?: boolean;
          last_seen_at?: string;
          missed_runs?: number;
          open_to_public?: boolean | null;
          point_source?: string;
          raw?: Json;
          removed_at?: string | null;
          removed_reason?: string | null;
          source_id: string;
        };
        Update: {
          content_hash?: string;
          event_id?: string | null;
          external_id?: string;
          first_seen_at?: string;
          host_org?: string | null;
          id?: string;
          is_primary?: boolean;
          last_seen_at?: string;
          missed_runs?: number;
          open_to_public?: boolean | null;
          point_source?: string;
          raw?: Json;
          removed_at?: string | null;
          removed_reason?: string | null;
          source_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "event_imports_event_id_fkey";
            columns: ["event_id"];
            isOneToOne: false;
            referencedRelation: "events";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "event_imports_source_id_fkey";
            columns: ["source_id"];
            isOneToOne: false;
            referencedRelation: "feed_sources";
            referencedColumns: ["id"];
          },
        ];
      };
      event_meets: {
        Row: {
          created_at: string;
          event_id: string;
          met_user_id: string;
          user_id: string;
        };
        Insert: {
          created_at?: string;
          event_id: string;
          met_user_id: string;
          user_id: string;
        };
        Update: {
          created_at?: string;
          event_id?: string;
          met_user_id?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "event_meets_event_id_fkey";
            columns: ["event_id"];
            isOneToOne: false;
            referencedRelation: "events";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "event_meets_met_user_id_fkey";
            columns: ["met_user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "event_meets_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      event_series: {
        Row: {
          address_note: string;
          address_visibility: Database["public"]["Enums"]["address_visibility"];
          campus_id: string | null;
          cancel_reason: string | null;
          cancelled_at: string | null;
          capacity: number | null;
          chapter_id: string | null;
          cover_url: string | null;
          created_at: string;
          description: string;
          duration_minutes: number;
          ends_on: string | null;
          host_id: string | null;
          hub_id: string;
          id: string;
          is_free: boolean;
          kind: Database["public"]["Enums"]["event_kind"];
          location_hint: string;
          location_text: string;
          max_occurrences: number | null;
          members_only: boolean;
          min_age: number;
          min_headcount: number | null;
          price_text: string | null;
          start_time: string;
          starts_on: string;
          status: Database["public"]["Enums"]["event_status"];
          timezone: string;
          title: string;
          updated_at: string;
          venue_id: string | null;
          visibility: Database["public"]["Enums"]["event_visibility"];
          waitlist_enabled: boolean;
          weekday: number;
        };
        Insert: {
          address_note?: string;
          address_visibility?: Database["public"]["Enums"]["address_visibility"];
          campus_id?: string | null;
          cancel_reason?: string | null;
          cancelled_at?: string | null;
          capacity?: number | null;
          chapter_id?: string | null;
          cover_url?: string | null;
          created_at?: string;
          description?: string;
          duration_minutes: number;
          ends_on?: string | null;
          host_id?: string | null;
          hub_id: string;
          id?: string;
          is_free?: boolean;
          kind?: Database["public"]["Enums"]["event_kind"];
          location_hint?: string;
          location_text?: string;
          max_occurrences?: number | null;
          members_only?: boolean;
          min_age?: number;
          min_headcount?: number | null;
          price_text?: string | null;
          start_time: string;
          starts_on: string;
          status?: Database["public"]["Enums"]["event_status"];
          timezone?: string;
          title: string;
          updated_at?: string;
          venue_id?: string | null;
          visibility?: Database["public"]["Enums"]["event_visibility"];
          waitlist_enabled?: boolean;
          weekday: number;
        };
        Update: {
          address_note?: string;
          address_visibility?: Database["public"]["Enums"]["address_visibility"];
          campus_id?: string | null;
          cancel_reason?: string | null;
          cancelled_at?: string | null;
          capacity?: number | null;
          chapter_id?: string | null;
          cover_url?: string | null;
          created_at?: string;
          description?: string;
          duration_minutes?: number;
          ends_on?: string | null;
          host_id?: string | null;
          hub_id?: string;
          id?: string;
          is_free?: boolean;
          kind?: Database["public"]["Enums"]["event_kind"];
          location_hint?: string;
          location_text?: string;
          max_occurrences?: number | null;
          members_only?: boolean;
          min_age?: number;
          min_headcount?: number | null;
          price_text?: string | null;
          start_time?: string;
          starts_on?: string;
          status?: Database["public"]["Enums"]["event_status"];
          timezone?: string;
          title?: string;
          updated_at?: string;
          venue_id?: string | null;
          visibility?: Database["public"]["Enums"]["event_visibility"];
          waitlist_enabled?: boolean;
          weekday?: number;
        };
        Relationships: [
          {
            foreignKeyName: "event_series_campus_id_fkey";
            columns: ["campus_id"];
            isOneToOne: false;
            referencedRelation: "org_campuses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "event_series_chapter_id_fkey";
            columns: ["chapter_id"];
            isOneToOne: false;
            referencedRelation: "hub_chapters";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "event_series_host_id_fkey";
            columns: ["host_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "event_series_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "event_series_venue_id_fkey";
            columns: ["venue_id"];
            isOneToOne: false;
            referencedRelation: "venues";
            referencedColumns: ["id"];
          },
        ];
      };
      events: {
        Row: {
          address_visibility: Database["public"]["Enums"]["address_visibility"];
          approx_lat: number | null;
          approx_lng: number | null;
          approx_point: unknown;
          campus_id: string | null;
          cancel_reason: string | null;
          cancelled_at: string | null;
          capacity: number | null;
          chapter_id: string | null;
          cover_url: string | null;
          created_at: string;
          description: string;
          detached_at: string | null;
          ends_at: string;
          external_url: string | null;
          going_count: number;
          host_id: string | null;
          hub_id: string;
          id: string;
          interested_count: number;
          is_free: boolean;
          kind: Database["public"]["Enums"]["event_kind"];
          location_hint: string;
          members_only: boolean;
          min_age: number;
          min_headcount: number | null;
          occurrence_date: string | null;
          price_text: string | null;
          search_text: string | null;
          series_id: string | null;
          source_name: string | null;
          starts_at: string;
          status: Database["public"]["Enums"]["event_status"];
          timezone: string;
          title: string;
          updated_at: string;
          visibility: Database["public"]["Enums"]["event_visibility"];
          waitlist_count: number;
          waitlist_enabled: boolean;
        };
        Insert: {
          address_visibility?: Database["public"]["Enums"]["address_visibility"];
          approx_lat?: number | null;
          approx_lng?: number | null;
          approx_point?: unknown;
          campus_id?: string | null;
          cancel_reason?: string | null;
          cancelled_at?: string | null;
          capacity?: number | null;
          chapter_id?: string | null;
          cover_url?: string | null;
          created_at?: string;
          description?: string;
          detached_at?: string | null;
          ends_at: string;
          external_url?: string | null;
          going_count?: number;
          host_id?: string | null;
          hub_id: string;
          id?: string;
          interested_count?: number;
          is_free?: boolean;
          kind?: Database["public"]["Enums"]["event_kind"];
          location_hint?: string;
          members_only?: boolean;
          min_age?: number;
          min_headcount?: number | null;
          occurrence_date?: string | null;
          price_text?: string | null;
          search_text?: string | null;
          series_id?: string | null;
          source_name?: string | null;
          starts_at: string;
          status?: Database["public"]["Enums"]["event_status"];
          timezone?: string;
          title: string;
          updated_at?: string;
          visibility?: Database["public"]["Enums"]["event_visibility"];
          waitlist_count?: number;
          waitlist_enabled?: boolean;
        };
        Update: {
          address_visibility?: Database["public"]["Enums"]["address_visibility"];
          approx_lat?: number | null;
          approx_lng?: number | null;
          approx_point?: unknown;
          campus_id?: string | null;
          cancel_reason?: string | null;
          cancelled_at?: string | null;
          capacity?: number | null;
          chapter_id?: string | null;
          cover_url?: string | null;
          created_at?: string;
          description?: string;
          detached_at?: string | null;
          ends_at?: string;
          external_url?: string | null;
          going_count?: number;
          host_id?: string | null;
          hub_id?: string;
          id?: string;
          interested_count?: number;
          is_free?: boolean;
          kind?: Database["public"]["Enums"]["event_kind"];
          location_hint?: string;
          members_only?: boolean;
          min_age?: number;
          min_headcount?: number | null;
          occurrence_date?: string | null;
          price_text?: string | null;
          search_text?: string | null;
          series_id?: string | null;
          source_name?: string | null;
          starts_at?: string;
          status?: Database["public"]["Enums"]["event_status"];
          timezone?: string;
          title?: string;
          updated_at?: string;
          visibility?: Database["public"]["Enums"]["event_visibility"];
          waitlist_count?: number;
          waitlist_enabled?: boolean;
        };
        Relationships: [
          {
            foreignKeyName: "events_campus_id_fkey";
            columns: ["campus_id"];
            isOneToOne: false;
            referencedRelation: "org_campuses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "events_chapter_id_fkey";
            columns: ["chapter_id"];
            isOneToOne: false;
            referencedRelation: "hub_chapters";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "events_host_id_fkey";
            columns: ["host_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "events_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "events_series_id_fkey";
            columns: ["series_id"];
            isOneToOne: false;
            referencedRelation: "event_series";
            referencedColumns: ["id"];
          },
        ];
      };
      feed_sources: {
        Row: {
          attribution: string;
          campus_id: string | null;
          created_at: string;
          cron_minute: number;
          default_hub_id: string | null;
          enabled: boolean;
          homepage_url: string | null;
          id: string;
          item_count: number | null;
          item_label: string | null;
          kind: string;
          last_error: string | null;
          last_ok_at: string | null;
          last_run_at: string | null;
          last_sample: Json | null;
          last_stats: Json | null;
          name: string;
          slug: string;
          updated_at: string;
          url: string;
        };
        Insert: {
          attribution?: string;
          campus_id?: string | null;
          created_at?: string;
          cron_minute?: number;
          default_hub_id?: string | null;
          enabled?: boolean;
          homepage_url?: string | null;
          id?: string;
          item_count?: number | null;
          item_label?: string | null;
          kind: string;
          last_error?: string | null;
          last_ok_at?: string | null;
          last_run_at?: string | null;
          last_sample?: Json | null;
          last_stats?: Json | null;
          name: string;
          slug: string;
          updated_at?: string;
          url: string;
        };
        Update: {
          attribution?: string;
          campus_id?: string | null;
          created_at?: string;
          cron_minute?: number;
          default_hub_id?: string | null;
          enabled?: boolean;
          homepage_url?: string | null;
          id?: string;
          item_count?: number | null;
          item_label?: string | null;
          kind?: string;
          last_error?: string | null;
          last_ok_at?: string | null;
          last_run_at?: string | null;
          last_sample?: Json | null;
          last_stats?: Json | null;
          name?: string;
          slug?: string;
          updated_at?: string;
          url?: string;
        };
        Relationships: [
          {
            foreignKeyName: "feed_sources_campus_id_fkey";
            columns: ["campus_id"];
            isOneToOne: false;
            referencedRelation: "org_campuses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "feed_sources_default_hub_id_fkey";
            columns: ["default_hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
        ];
      };
      handle_history: {
        Row: {
          handle: string;
          id: string;
          released_at: string;
          user_id: string;
        };
        Insert: {
          handle: string;
          id?: string;
          released_at?: string;
          user_id: string;
        };
        Update: {
          handle?: string;
          id?: string;
          released_at?: string;
          user_id?: string;
        };
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
          area_id: string | null;
          campus_id: string | null;
          claimed_at: string | null;
          claimed_by: string | null;
          cover_url: string | null;
          created_at: string;
          created_by: string | null;
          description: string;
          hub_id: string;
          id: string;
          is_active: boolean;
          name: string;
          org_id: string | null;
          pin_url: string | null;
          rso_name: string | null;
          slug: string;
          updated_at: string;
          verified_at: string | null;
        };
        Insert: {
          area_id?: string | null;
          campus_id?: string | null;
          claimed_at?: string | null;
          claimed_by?: string | null;
          cover_url?: string | null;
          created_at?: string;
          created_by?: string | null;
          description?: string;
          hub_id: string;
          id?: string;
          is_active?: boolean;
          name: string;
          org_id?: string | null;
          pin_url?: string | null;
          rso_name?: string | null;
          slug: string;
          updated_at?: string;
          verified_at?: string | null;
        };
        Update: {
          area_id?: string | null;
          campus_id?: string | null;
          claimed_at?: string | null;
          claimed_by?: string | null;
          cover_url?: string | null;
          created_at?: string;
          created_by?: string | null;
          description?: string;
          hub_id?: string;
          id?: string;
          is_active?: boolean;
          name?: string;
          org_id?: string | null;
          pin_url?: string | null;
          rso_name?: string | null;
          slug?: string;
          updated_at?: string;
          verified_at?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "hub_chapters_area_id_fkey";
            columns: ["area_id"];
            isOneToOne: false;
            referencedRelation: "areas";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "hub_chapters_campus_id_fkey";
            columns: ["campus_id"];
            isOneToOne: false;
            referencedRelation: "org_campuses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "hub_chapters_claimed_by_fkey";
            columns: ["claimed_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
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
        Row: {
          hub_id: string;
          joined_at: string;
          notify: boolean;
          user_id: string;
        };
        Insert: {
          hub_id: string;
          joined_at?: string;
          notify?: boolean;
          user_id: string;
        };
        Update: {
          hub_id?: string;
          joined_at?: string;
          notify?: boolean;
          user_id?: string;
        };
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
      import_hub_rules: {
        Row: {
          created_at: string;
          hub_id: string;
          id: string;
          match_on: string;
          pattern: string;
          priority: number;
          source_id: string | null;
        };
        Insert: {
          created_at?: string;
          hub_id: string;
          id?: string;
          match_on?: string;
          pattern: string;
          priority?: number;
          source_id?: string | null;
        };
        Update: {
          created_at?: string;
          hub_id?: string;
          id?: string;
          match_on?: string;
          pattern?: string;
          priority?: number;
          source_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "import_hub_rules_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "import_hub_rules_source_id_fkey";
            columns: ["source_id"];
            isOneToOne: false;
            referencedRelation: "feed_sources";
            referencedColumns: ["id"];
          },
        ];
      };
      meta: {
        Row: {
          key: string;
          updated_at: string;
          value: string;
        };
        Insert: {
          key: string;
          updated_at?: string;
          value: string;
        };
        Update: {
          key?: string;
          updated_at?: string;
          value?: string;
        };
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
      notifications: {
        Row: {
          actor_id: string | null;
          attempts: number;
          chapter_id: string | null;
          created_at: string;
          dedupe_key: string;
          email_sent_at: string | null;
          email_status: Database["public"]["Enums"]["notification_channel_status"];
          event_id: string | null;
          hub_id: string | null;
          id: string;
          kind: Database["public"]["Enums"]["notification_kind"];
          last_error: string | null;
          payload: Json;
          push_after: string | null;
          push_sent_at: string | null;
          push_status: Database["public"]["Enums"]["notification_channel_status"];
          read_at: string | null;
          seen_at: string | null;
          user_id: string;
        };
        Insert: {
          actor_id?: string | null;
          attempts?: number;
          chapter_id?: string | null;
          created_at?: string;
          dedupe_key: string;
          email_sent_at?: string | null;
          email_status?: Database["public"]["Enums"]["notification_channel_status"];
          event_id?: string | null;
          hub_id?: string | null;
          id?: string;
          kind: Database["public"]["Enums"]["notification_kind"];
          last_error?: string | null;
          payload?: Json;
          push_after?: string | null;
          push_sent_at?: string | null;
          push_status?: Database["public"]["Enums"]["notification_channel_status"];
          read_at?: string | null;
          seen_at?: string | null;
          user_id: string;
        };
        Update: {
          actor_id?: string | null;
          attempts?: number;
          chapter_id?: string | null;
          created_at?: string;
          dedupe_key?: string;
          email_sent_at?: string | null;
          email_status?: Database["public"]["Enums"]["notification_channel_status"];
          event_id?: string | null;
          hub_id?: string | null;
          id?: string;
          kind?: Database["public"]["Enums"]["notification_kind"];
          last_error?: string | null;
          payload?: Json;
          push_after?: string | null;
          push_sent_at?: string | null;
          push_status?: Database["public"]["Enums"]["notification_channel_status"];
          read_at?: string | null;
          seen_at?: string | null;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "notifications_actor_id_fkey";
            columns: ["actor_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "notifications_chapter_id_fkey";
            columns: ["chapter_id"];
            isOneToOne: false;
            referencedRelation: "hub_chapters";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "notifications_event_id_fkey";
            columns: ["event_id"];
            isOneToOne: false;
            referencedRelation: "events";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "notifications_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "notifications_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
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
        Row: {
          created_at: string;
          domain: string;
          org_id: string;
        };
        Insert: {
          created_at?: string;
          domain: string;
          org_id: string;
        };
        Update: {
          created_at?: string;
          domain?: string;
          org_id?: string;
        };
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
          feed_radius_km: number;
          home_area_id: string | null;
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
          feed_radius_km?: number;
          home_area_id?: string | null;
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
          feed_radius_km?: number;
          home_area_id?: string | null;
          last_seen_at?: string | null;
          location?: unknown;
          location_text?: string;
          location_updated_at?: string | null;
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "profile_private_home_area_id_fkey";
            columns: ["home_area_id"];
            isOneToOne: false;
            referencedRelation: "areas";
            referencedColumns: ["id"];
          },
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
          guidelines_accepted_at: string | null;
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
          guidelines_accepted_at?: string | null;
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
          guidelines_accepted_at?: string | null;
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
        Row: {
          handle: string;
        };
        Insert: {
          handle: string;
        };
        Update: {
          handle?: string;
        };
        Relationships: [];
      };
      rsvps: {
        Row: {
          approved_by_host: boolean;
          attended_self_reported_at: string | null;
          checked_in_at: string | null;
          checked_in_by: string | null;
          created_at: string;
          event_id: string;
          removed_at: string | null;
          removed_by: string | null;
          removed_reason: string | null;
          status: Database["public"]["Enums"]["rsvp_status"];
          updated_at: string;
          user_id: string;
          waitlist_position: number | null;
        };
        Insert: {
          approved_by_host?: boolean;
          attended_self_reported_at?: string | null;
          checked_in_at?: string | null;
          checked_in_by?: string | null;
          created_at?: string;
          event_id: string;
          removed_at?: string | null;
          removed_by?: string | null;
          removed_reason?: string | null;
          status: Database["public"]["Enums"]["rsvp_status"];
          updated_at?: string;
          user_id: string;
          waitlist_position?: number | null;
        };
        Update: {
          approved_by_host?: boolean;
          attended_self_reported_at?: string | null;
          checked_in_at?: string | null;
          checked_in_by?: string | null;
          created_at?: string;
          event_id?: string;
          removed_at?: string | null;
          removed_by?: string | null;
          removed_reason?: string | null;
          status?: Database["public"]["Enums"]["rsvp_status"];
          updated_at?: string;
          user_id?: string;
          waitlist_position?: number | null;
        };
        Relationships: [
          {
            foreignKeyName: "rsvps_checked_in_by_fkey";
            columns: ["checked_in_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "rsvps_event_id_fkey";
            columns: ["event_id"];
            isOneToOne: false;
            referencedRelation: "events";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "rsvps_removed_by_fkey";
            columns: ["removed_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
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
      venues: {
        Row: {
          address_line1: string;
          address_line2: string;
          campus_id: string | null;
          city: string;
          country: string;
          created_at: string;
          created_by: string | null;
          id: string;
          is_public: boolean;
          lat: number | null;
          lng: number | null;
          location: unknown;
          name: string;
          place_id: string | null;
          postal_code: string;
          search_text: string | null;
          state: string;
          updated_at: string;
        };
        Insert: {
          address_line1?: string;
          address_line2?: string;
          campus_id?: string | null;
          city?: string;
          country?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          is_public?: boolean;
          lat?: number | null;
          lng?: number | null;
          location?: unknown;
          name: string;
          place_id?: string | null;
          postal_code?: string;
          search_text?: string | null;
          state?: string;
          updated_at?: string;
        };
        Update: {
          address_line1?: string;
          address_line2?: string;
          campus_id?: string | null;
          city?: string;
          country?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          is_public?: boolean;
          lat?: number | null;
          lng?: number | null;
          location?: unknown;
          name?: string;
          place_id?: string | null;
          postal_code?: string;
          search_text?: string | null;
          state?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "venues_campus_id_fkey";
            columns: ["campus_id"];
            isOneToOne: false;
            referencedRelation: "org_campuses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "venues_created_by_fkey";
            columns: ["created_by"];
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
      accept_guidelines: { Args: never; Returns: string };
      approve_rsvp: {
        Args: { p_approved?: boolean; p_event_id: string; p_user_id: string };
        Returns: {
          approved_by_host: boolean;
          attended_self_reported_at: string | null;
          checked_in_at: string | null;
          checked_in_by: string | null;
          created_at: string;
          event_id: string;
          removed_at: string | null;
          removed_by: string | null;
          removed_reason: string | null;
          status: Database["public"]["Enums"]["rsvp_status"];
          updated_at: string;
          user_id: string;
          waitlist_position: number | null;
        };
        SetofOptions: {
          from: "*";
          to: "rsvps";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      broadcast_to_event: {
        Args: { p_body: string; p_event_id: string };
        Returns: Json;
      };
      can_read_event: { Args: { p_event: string }; Returns: boolean };
      cancel_event: {
        Args: { p_event_id: string; p_reason?: string };
        Returns: {
          address_visibility: Database["public"]["Enums"]["address_visibility"];
          approx_lat: number | null;
          approx_lng: number | null;
          approx_point: unknown;
          campus_id: string | null;
          cancel_reason: string | null;
          cancelled_at: string | null;
          capacity: number | null;
          chapter_id: string | null;
          cover_url: string | null;
          created_at: string;
          description: string;
          detached_at: string | null;
          ends_at: string;
          external_url: string | null;
          going_count: number;
          host_id: string | null;
          hub_id: string;
          id: string;
          interested_count: number;
          is_free: boolean;
          kind: Database["public"]["Enums"]["event_kind"];
          location_hint: string;
          members_only: boolean;
          min_age: number;
          min_headcount: number | null;
          occurrence_date: string | null;
          price_text: string | null;
          search_text: string | null;
          series_id: string | null;
          source_name: string | null;
          starts_at: string;
          status: Database["public"]["Enums"]["event_status"];
          timezone: string;
          title: string;
          updated_at: string;
          visibility: Database["public"]["Enums"]["event_visibility"];
          waitlist_count: number;
          waitlist_enabled: boolean;
        };
        SetofOptions: {
          from: "*";
          to: "events";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      cancel_event_series: {
        Args: { p_reason?: string; p_series_id: string };
        Returns: {
          address_note: string;
          address_visibility: Database["public"]["Enums"]["address_visibility"];
          campus_id: string | null;
          cancel_reason: string | null;
          cancelled_at: string | null;
          capacity: number | null;
          chapter_id: string | null;
          cover_url: string | null;
          created_at: string;
          description: string;
          duration_minutes: number;
          ends_on: string | null;
          host_id: string | null;
          hub_id: string;
          id: string;
          is_free: boolean;
          kind: Database["public"]["Enums"]["event_kind"];
          location_hint: string;
          location_text: string;
          max_occurrences: number | null;
          members_only: boolean;
          min_age: number;
          min_headcount: number | null;
          price_text: string | null;
          start_time: string;
          starts_on: string;
          status: Database["public"]["Enums"]["event_status"];
          timezone: string;
          title: string;
          updated_at: string;
          venue_id: string | null;
          visibility: Database["public"]["Enums"]["event_visibility"];
          waitlist_enabled: boolean;
          weekday: number;
        };
        SetofOptions: {
          from: "*";
          to: "event_series";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      chapter_dashboard: {
        Args: { p_chapter: string; p_weeks?: number };
        Returns: Json;
      };
      chapter_public_card: { Args: { p_chapter: string }; Returns: Json };
      chapter_slug_for: { Args: { p_name: string }; Returns: string };
      check_in: {
        Args: { p_event_id: string };
        Returns: {
          approved_by_host: boolean;
          attended_self_reported_at: string | null;
          checked_in_at: string | null;
          checked_in_by: string | null;
          created_at: string;
          event_id: string;
          removed_at: string | null;
          removed_by: string | null;
          removed_reason: string | null;
          status: Database["public"]["Enums"]["rsvp_status"];
          updated_at: string;
          user_id: string;
          waitlist_position: number | null;
        };
        SetofOptions: {
          from: "*";
          to: "rsvps";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      complete_onboarding: {
        Args: {
          p_area_id?: string;
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
          guidelines_accepted_at: string | null;
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
      confirm_email_verification: {
        Args: { p_code: string; p_email?: string };
        Returns: Json;
      };
      create_event: {
        Args: { p_args: Json };
        Returns: {
          address_visibility: Database["public"]["Enums"]["address_visibility"];
          approx_lat: number | null;
          approx_lng: number | null;
          approx_point: unknown;
          campus_id: string | null;
          cancel_reason: string | null;
          cancelled_at: string | null;
          capacity: number | null;
          chapter_id: string | null;
          cover_url: string | null;
          created_at: string;
          description: string;
          detached_at: string | null;
          ends_at: string;
          external_url: string | null;
          going_count: number;
          host_id: string | null;
          hub_id: string;
          id: string;
          interested_count: number;
          is_free: boolean;
          kind: Database["public"]["Enums"]["event_kind"];
          location_hint: string;
          members_only: boolean;
          min_age: number;
          min_headcount: number | null;
          occurrence_date: string | null;
          price_text: string | null;
          search_text: string | null;
          series_id: string | null;
          source_name: string | null;
          starts_at: string;
          status: Database["public"]["Enums"]["event_status"];
          timezone: string;
          title: string;
          updated_at: string;
          visibility: Database["public"]["Enums"]["event_visibility"];
          waitlist_count: number;
          waitlist_enabled: boolean;
        };
        SetofOptions: {
          from: "*";
          to: "events";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      create_event_series: {
        Args: { p_args: Json };
        Returns: {
          address_note: string;
          address_visibility: Database["public"]["Enums"]["address_visibility"];
          campus_id: string | null;
          cancel_reason: string | null;
          cancelled_at: string | null;
          capacity: number | null;
          chapter_id: string | null;
          cover_url: string | null;
          created_at: string;
          description: string;
          duration_minutes: number;
          ends_on: string | null;
          host_id: string | null;
          hub_id: string;
          id: string;
          is_free: boolean;
          kind: Database["public"]["Enums"]["event_kind"];
          location_hint: string;
          location_text: string;
          max_occurrences: number | null;
          members_only: boolean;
          min_age: number;
          min_headcount: number | null;
          price_text: string | null;
          start_time: string;
          starts_on: string;
          status: Database["public"]["Enums"]["event_status"];
          timezone: string;
          title: string;
          updated_at: string;
          venue_id: string | null;
          visibility: Database["public"]["Enums"]["event_visibility"];
          waitlist_enabled: boolean;
          weekday: number;
        };
        SetofOptions: {
          from: "*";
          to: "event_series";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      create_verification_code: {
        Args: { p_email: string; p_user_id: string };
        Returns: Json;
      };
      default_address_visibility: {
        Args: { p_venue_id: string };
        Returns: Database["public"]["Enums"]["address_visibility"];
      };
      dismiss_attendance_prompt: {
        Args: { p_event_id: string };
        Returns: undefined;
      };
      enqueue_due_reminders: { Args: never; Returns: number };
      enqueue_notification: {
        Args: {
          p_actor_id?: string;
          p_batch?: boolean;
          p_chapter_id?: string;
          p_dedupe_key: string;
          p_event_id?: string;
          p_hub_id?: string;
          p_kind: Database["public"]["Enums"]["notification_kind"];
          p_payload?: Json;
          p_user_id: string;
        };
        Returns: string;
      };
      event_attendees: {
        Args: { p_event_id: string };
        Returns: {
          approved_by_host: boolean;
          attended_self_reported_at: string | null;
          checked_in_at: string | null;
          checked_in_by: string | null;
          created_at: string;
          event_id: string;
          removed_at: string | null;
          removed_by: string | null;
          removed_reason: string | null;
          status: Database["public"]["Enums"]["rsvp_status"];
          updated_at: string;
          user_id: string;
          waitlist_position: number | null;
        }[];
        SetofOptions: {
          from: "*";
          to: "rsvps";
          isOneToOne: false;
          isSetofReturn: true;
        };
      };
      event_drop_ineligible_rsvps: {
        Args: { p_event_id: string };
        Returns: number;
      };
      event_post_rate_check: { Args: { p_series: boolean }; Returns: undefined };
      event_rules_check: {
        Args: {
          p_address_visibility: Database["public"]["Enums"]["address_visibility"];
          p_campus_id: string;
          p_chapter_id: string;
          p_hub_id: string;
          p_kind: Database["public"]["Enums"]["event_kind"];
          p_location_text: string;
          p_min_age: number;
          p_venue_id: string;
          p_visibility: Database["public"]["Enums"]["event_visibility"];
        };
        Returns: string;
      };
      event_set_location: {
        Args: {
          p_address_note: string;
          p_address_visibility: Database["public"]["Enums"]["address_visibility"];
          p_campus_id: string;
          p_event_id: string;
          p_location_hint: string;
          p_location_text: string;
          p_venue_id: string;
        };
        Returns: undefined;
      };
      event_share_card: { Args: { p_event_id: string }; Returns: Json };
      feed_events: {
        Args: { p_from: string; p_limit?: number; p_to: string };
        Returns: {
          address_visibility: Database["public"]["Enums"]["address_visibility"];
          approx_lat: number | null;
          approx_lng: number | null;
          approx_point: unknown;
          campus_id: string | null;
          cancel_reason: string | null;
          cancelled_at: string | null;
          capacity: number | null;
          chapter_id: string | null;
          cover_url: string | null;
          created_at: string;
          description: string;
          detached_at: string | null;
          ends_at: string;
          external_url: string | null;
          going_count: number;
          host_id: string | null;
          hub_id: string;
          id: string;
          interested_count: number;
          is_free: boolean;
          kind: Database["public"]["Enums"]["event_kind"];
          location_hint: string;
          members_only: boolean;
          min_age: number;
          min_headcount: number | null;
          occurrence_date: string | null;
          price_text: string | null;
          search_text: string | null;
          series_id: string | null;
          source_name: string | null;
          starts_at: string;
          status: Database["public"]["Enums"]["event_status"];
          timezone: string;
          title: string;
          updated_at: string;
          visibility: Database["public"]["Enums"]["event_visibility"];
          waitlist_count: number;
          waitlist_enabled: boolean;
        }[];
        SetofOptions: {
          from: "*";
          to: "events";
          isOneToOne: false;
          isSetofReturn: true;
        };
      };
      feed_events_v2: {
        Args: {
          p_free_only?: boolean;
          p_from: string;
          p_hub_ids?: string[];
          p_lat?: number;
          p_limit?: number;
          p_lng?: number;
          p_radius_km?: number;
          p_to: string;
        };
        Returns: {
          address_visibility: Database["public"]["Enums"]["address_visibility"];
          campus_id: string;
          capacity: number;
          chapter_id: string;
          cover_url: string;
          created_at: string;
          description: string;
          distance_band: string;
          ends_at: string;
          external_url: string;
          going_count: number;
          host_id: string;
          hub_emoji: string;
          hub_id: string;
          hub_name: string;
          hub_slug: string;
          id: string;
          interested_count: number;
          is_free: boolean;
          is_imported: boolean;
          kind: Database["public"]["Enums"]["event_kind"];
          location_hint: string;
          matched_by: string;
          members_only: boolean;
          min_age: number;
          min_headcount: number;
          occurrence_date: string;
          price_text: string;
          section: string;
          series_id: string;
          source_name: string;
          starts_at: string;
          status: Database["public"]["Enums"]["event_status"];
          timezone: string;
          title: string;
          updated_at: string;
          visibility: Database["public"]["Enums"]["event_visibility"];
          waitlist_count: number;
          waitlist_enabled: boolean;
        }[];
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
      host_check_in: {
        Args: { p_checked?: boolean; p_event_id: string; p_user_id: string };
        Returns: {
          approved_by_host: boolean;
          attended_self_reported_at: string | null;
          checked_in_at: string | null;
          checked_in_by: string | null;
          created_at: string;
          event_id: string;
          removed_at: string | null;
          removed_by: string | null;
          removed_reason: string | null;
          status: Database["public"]["Enums"]["rsvp_status"];
          updated_at: string;
          user_id: string;
          waitlist_position: number | null;
        };
        SetofOptions: {
          from: "*";
          to: "rsvps";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      hub_member_counts: {
        Args: { p_hub_ids: string[] };
        Returns: {
          hub_id: string;
          members: number;
        }[];
      };
      import_clip: { Args: { p_max: number; p_text: string }; Returns: string };
      import_dispatch: { Args: { p_slug: string }; Returns: number };
      import_dispatch_all: { Args: never; Returns: Json };
      import_pick_hub: {
        Args: {
          p_categories: string;
          p_host: string;
          p_source_id: string;
          p_title: string;
        };
        Returns: string;
      };
      import_record_error: {
        Args: { p_error: string; p_sample?: Json; p_source_slug: string };
        Returns: undefined;
      };
      import_schedule: { Args: never; Returns: number };
      import_set_function_url: { Args: { p_url: string }; Returns: undefined };
      import_upsert_batch: {
        Args: { p_items: Json; p_source_slug: string };
        Returns: Json;
      };
      import_verify_secret: { Args: { p_secret: string }; Returns: boolean };
      imported_event_labels: {
        Args: { p_event_ids: string[] };
        Returns: {
          affiliated_org_name: string;
          approximate_location: boolean;
          attribution: string;
          event_id: string;
          homepage_url: string;
          host_org: string;
          item_label: string;
          open_to_public: boolean;
          source_kind: string;
          source_name: string;
          source_slug: string;
        }[];
      };
      is_campus_org_member: { Args: { p_campus: string }; Returns: boolean };
      is_chapter_captain: { Args: { p_chapter: string }; Returns: boolean };
      is_moderator: { Args: never; Returns: boolean };
      is_privileged: { Args: never; Returns: boolean };
      is_service_role: { Args: never; Returns: boolean };
      is_valid_timezone: { Args: { p_tz: string }; Returns: boolean };
      join_area_waitlist: {
        Args: { p_city: string };
        Returns: {
          city: string;
          created_at: string;
          user_id: string;
        };
        SetofOptions: {
          from: "*";
          to: "area_waitlist";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      mark_notifications_read: { Args: { p_ids?: string[] }; Returns: number };
      materialize_all_event_series: {
        Args: { p_weeks?: number };
        Returns: number;
      };
      materialize_event_series: {
        Args: { p_series_id: string; p_weeks?: number };
        Returns: number;
      };
      my_chapter_claims: {
        Args: never;
        Returns: {
          area_id: string;
          campus_id: string;
          chapter_id: string;
          chapter_slug: string;
          created_at: string;
          hub_id: string;
          hub_name: string;
          hub_slug: string;
          id: string;
          kind: string;
          officer_role_text: string;
          org_id: string;
          pin_url: string;
          place_label: string;
          proposed_name: string;
          review_note: string;
          reviewed_at: string;
          rso_name: string;
          status: Database["public"]["Enums"]["chapter_claim_status"];
        }[];
      };
      my_managed_chapters: {
        Args: never;
        Returns: {
          area_id: string;
          campus_id: string;
          chapter_id: string;
          hub_id: string;
          hub_name: string;
          hub_slug: string;
          is_active: boolean;
          name: string;
          org_id: string;
          place_label: string;
          role: Database["public"]["Enums"]["chapter_role"];
          slug: string;
        }[];
      };
      notification_event_payload: {
        Args: { p_event_id: string };
        Returns: Json;
      };
      notify_chapter_claim_reviewed: {
        Args: { p_claim: Database["public"]["Tables"]["chapter_claims"]["Row"] };
        Returns: string;
      };
      notify_event_audience: {
        Args: {
          p_actor: string;
          p_event_id: string;
          p_extra?: Json;
          p_key: string;
          p_kind: Database["public"]["Enums"]["notification_kind"];
          p_statuses: Database["public"]["Enums"]["rsvp_status"][];
        };
        Returns: number;
      };
      notify_event_managers_joined: {
        Args: { p_event_id: string; p_joiner: string };
        Returns: number;
      };
      pending_attendance_prompts: {
        Args: never;
        Returns: {
          attendees: Json;
          chapter_id: string;
          chapter_name: string;
          checked_in: boolean;
          cover_url: string;
          ends_at: string;
          event_id: string;
          going_count: number;
          hub_emoji: string;
          hub_id: string;
          hub_name: string;
          hub_slug: string;
          location_hint: string;
          starts_at: string;
          timezone: string;
          title: string;
        }[];
      };
      purge_account_deletions: { Args: never; Returns: number };
      purge_read_notifications: { Args: never; Returns: number };
      refresh_hub_stats: { Args: never; Returns: number };
      remove_chapter_member: {
        Args: { p_chapter: string; p_user: string };
        Returns: undefined;
      };
      remove_rsvp: {
        Args: { p_event_id: string; p_reason?: string; p_user_id: string };
        Returns: {
          approved_by_host: boolean;
          attended_self_reported_at: string | null;
          checked_in_at: string | null;
          checked_in_by: string | null;
          created_at: string;
          event_id: string;
          removed_at: string | null;
          removed_by: string | null;
          removed_reason: string | null;
          status: Database["public"]["Enums"]["rsvp_status"];
          updated_at: string;
          user_id: string;
          waitlist_position: number | null;
        };
        SetofOptions: {
          from: "*";
          to: "rsvps";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      request_account_deletion: {
        Args: { p_reason?: string };
        Returns: undefined;
      };
      request_hub: {
        Args: { p_name: string; p_note?: string };
        Returns: {
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
        SetofOptions: {
          from: "*";
          to: "hub_requests";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      review_chapter_claim: {
        Args: { p_approve: boolean; p_claim_id: string; p_note?: string };
        Returns: {
          agreement_version: string;
          area_id: string | null;
          campus_id: string | null;
          chapter_id: string | null;
          created_at: string;
          hub_id: string;
          id: string;
          kind: string;
          motivation: string;
          officer_role_text: string | null;
          org_id: string | null;
          pin_url: string | null;
          proposed_name: string;
          reference_contact: string | null;
          reference_name: string | null;
          review_note: string | null;
          reviewed_at: string | null;
          reviewed_by: string | null;
          rso_name: string | null;
          status: Database["public"]["Enums"]["chapter_claim_status"];
          updated_at: string;
          user_id: string;
        };
        SetofOptions: {
          from: "*";
          to: "chapter_claims";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      rsvp_promote_waitlist: { Args: { p_event_id: string }; Returns: number };
      set_chapter_role: {
        Args: {
          p_chapter: string;
          p_role: Database["public"]["Enums"]["chapter_role"];
          p_user: string;
        };
        Returns: undefined;
      };
      set_home_area: {
        Args: { p_area_id: string; p_radius_km?: number };
        Returns: Json;
      };
      set_rsvp: {
        Args: {
          p_event_id: string;
          p_status: Database["public"]["Enums"]["rsvp_status"];
        };
        Returns: {
          approved_by_host: boolean;
          attended_self_reported_at: string | null;
          checked_in_at: string | null;
          checked_in_by: string | null;
          created_at: string;
          event_id: string;
          removed_at: string | null;
          removed_by: string | null;
          removed_reason: string | null;
          status: Database["public"]["Enums"]["rsvp_status"];
          updated_at: string;
          user_id: string;
          waitlist_position: number | null;
        };
        SetofOptions: {
          from: "*";
          to: "rsvps";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      submit_attendance: {
        Args: { p_attended: boolean; p_event_id: string; p_met?: string[] };
        Returns: Json;
      };
      submit_chapter_claim: {
        Args: { p_args: Json };
        Returns: {
          agreement_version: string;
          area_id: string | null;
          campus_id: string | null;
          chapter_id: string | null;
          created_at: string;
          hub_id: string;
          id: string;
          kind: string;
          motivation: string;
          officer_role_text: string | null;
          org_id: string | null;
          pin_url: string | null;
          proposed_name: string;
          reference_contact: string | null;
          reference_name: string | null;
          review_note: string | null;
          reviewed_at: string | null;
          reviewed_by: string | null;
          rso_name: string | null;
          status: Database["public"]["Enums"]["chapter_claim_status"];
          updated_at: string;
          user_id: string;
        };
        SetofOptions: {
          from: "*";
          to: "chapter_claims";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      touch_last_seen: { Args: never; Returns: undefined };
      unread_notification_count: { Args: never; Returns: number };
      update_event: {
        Args: { p_args: Json; p_event_id: string };
        Returns: {
          address_visibility: Database["public"]["Enums"]["address_visibility"];
          approx_lat: number | null;
          approx_lng: number | null;
          approx_point: unknown;
          campus_id: string | null;
          cancel_reason: string | null;
          cancelled_at: string | null;
          capacity: number | null;
          chapter_id: string | null;
          cover_url: string | null;
          created_at: string;
          description: string;
          detached_at: string | null;
          ends_at: string;
          external_url: string | null;
          going_count: number;
          host_id: string | null;
          hub_id: string;
          id: string;
          interested_count: number;
          is_free: boolean;
          kind: Database["public"]["Enums"]["event_kind"];
          location_hint: string;
          members_only: boolean;
          min_age: number;
          min_headcount: number | null;
          occurrence_date: string | null;
          price_text: string | null;
          search_text: string | null;
          series_id: string | null;
          source_name: string | null;
          starts_at: string;
          status: Database["public"]["Enums"]["event_status"];
          timezone: string;
          title: string;
          updated_at: string;
          visibility: Database["public"]["Enums"]["event_visibility"];
          waitlist_count: number;
          waitlist_enabled: boolean;
        };
        SetofOptions: {
          from: "*";
          to: "events";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      update_event_series: {
        Args: { p_args: Json; p_series_id: string };
        Returns: {
          address_note: string;
          address_visibility: Database["public"]["Enums"]["address_visibility"];
          campus_id: string | null;
          cancel_reason: string | null;
          cancelled_at: string | null;
          capacity: number | null;
          chapter_id: string | null;
          cover_url: string | null;
          created_at: string;
          description: string;
          duration_minutes: number;
          ends_on: string | null;
          host_id: string | null;
          hub_id: string;
          id: string;
          is_free: boolean;
          kind: Database["public"]["Enums"]["event_kind"];
          location_hint: string;
          location_text: string;
          max_occurrences: number | null;
          members_only: boolean;
          min_age: number;
          min_headcount: number | null;
          price_text: string | null;
          start_time: string;
          starts_on: string;
          status: Database["public"]["Enums"]["event_status"];
          timezone: string;
          title: string;
          updated_at: string;
          venue_id: string | null;
          visibility: Database["public"]["Enums"]["event_visibility"];
          waitlist_enabled: boolean;
          weekday: number;
        };
        SetofOptions: {
          from: "*";
          to: "event_series";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      upsert_venue: {
        Args: { p_args: Json };
        Returns: {
          address_line1: string;
          address_line2: string;
          campus_id: string | null;
          city: string;
          country: string;
          created_at: string;
          created_by: string | null;
          id: string;
          is_public: boolean;
          lat: number | null;
          lng: number | null;
          location: unknown;
          name: string;
          place_id: string | null;
          postal_code: string;
          search_text: string | null;
          state: string;
          updated_at: string;
        };
        SetofOptions: {
          from: "*";
          to: "venues";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
      viewer_age: { Args: never; Returns: number };
      viewer_can_manage_event: {
        Args: { p_event_id: string };
        Returns: boolean;
      };
      viewer_has_rsvp: { Args: { p_event: string }; Returns: boolean };
      viewer_is_approved: { Args: { p_event: string }; Returns: boolean };
      viewer_is_attending: { Args: { p_event: string }; Returns: boolean };
      withdraw_chapter_claim: {
        Args: { p_claim_id: string };
        Returns: {
          agreement_version: string;
          area_id: string | null;
          campus_id: string | null;
          chapter_id: string | null;
          created_at: string;
          hub_id: string;
          id: string;
          kind: string;
          motivation: string;
          officer_role_text: string | null;
          org_id: string | null;
          pin_url: string | null;
          proposed_name: string;
          reference_contact: string | null;
          reference_name: string | null;
          review_note: string | null;
          reviewed_at: string | null;
          reviewed_by: string | null;
          rso_name: string | null;
          status: Database["public"]["Enums"]["chapter_claim_status"];
          updated_at: string;
          user_id: string;
        };
        SetofOptions: {
          from: "*";
          to: "chapter_claims";
          isOneToOne: true;
          isSetofReturn: false;
        };
      };
    };
    Enums: {
      account_status: "active" | "suspended" | "banned" | "deleted";
      address_visibility: "public" | "approved_only";
      app_role: "moderator" | "admin";
      chapter_claim_status: "pending" | "approved" | "rejected" | "withdrawn";
      chapter_role: "member" | "captain" | "organizer";
      device_platform: "web" | "ios" | "android";
      event_kind: "member" | "chapter" | "imported";
      event_status: "published" | "cancelled";
      event_visibility: "public" | "campus";
      notification_channel_status: "pending" | "sent" | "skipped" | "failed";
      notification_kind:
        | "rsvp_confirmed"
        | "attendee_joined"
        | "waitlist_promoted"
        | "rsvp_approved"
        | "event_reminder_day"
        | "event_reminder_2h"
        | "event_cancelled"
        | "event_updated"
        | "checkin_prompt"
        | "hub_new_event"
        | "broadcast"
        | "chapter_claim_update";
      org_kind: "university" | "company" | "community";
      org_role: "member" | "officer" | "admin";
      rsvp_status: "going" | "interested" | "waitlisted" | "cancelled";
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

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    keyof DefaultSchema["CompositeTypes"] | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never;

export const Constants = {
  public: {
    Enums: {
      account_status: ["active", "suspended", "banned", "deleted"],
      address_visibility: ["public", "approved_only"],
      app_role: ["moderator", "admin"],
      chapter_claim_status: ["pending", "approved", "rejected", "withdrawn"],
      chapter_role: ["member", "captain", "organizer"],
      device_platform: ["web", "ios", "android"],
      event_kind: ["member", "chapter", "imported"],
      event_status: ["published", "cancelled"],
      event_visibility: ["public", "campus"],
      notification_channel_status: ["pending", "sent", "skipped", "failed"],
      notification_kind: [
        "rsvp_confirmed",
        "attendee_joined",
        "waitlist_promoted",
        "rsvp_approved",
        "event_reminder_day",
        "event_reminder_2h",
        "event_cancelled",
        "event_updated",
        "checkin_prompt",
        "hub_new_event",
        "broadcast",
        "chapter_claim_update",
      ],
      org_kind: ["university", "company", "community"],
      org_role: ["member", "officer", "admin"],
      rsvp_status: ["going", "interested", "waitlisted", "cancelled"],
    },
  },
} as const;
