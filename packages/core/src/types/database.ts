/**
 * Database types, generated from the staging project with the Supabase CLI after
 * migrations 1 to 76 (schema_version 2.72). Regenerate after every migration; do not hand-edit.
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
      admin_lookups: {
        Row: {
          created_at: string;
          id: string;
          moderator_id: string | null;
          query: string | null;
          report_id: string | null;
          result_count: number;
          target_user_id: string | null;
          via: string;
        };
        Insert: {
          created_at?: string;
          id?: string;
          moderator_id?: string | null;
          query?: string | null;
          report_id?: string | null;
          result_count?: number;
          target_user_id?: string | null;
          via: string;
        };
        Update: {
          created_at?: string;
          id?: string;
          moderator_id?: string | null;
          query?: string | null;
          report_id?: string | null;
          result_count?: number;
          target_user_id?: string | null;
          via?: string;
        };
        Relationships: [
          {
            foreignKeyName: "admin_lookups_moderator_id_fkey";
            columns: ["moderator_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "admin_lookups_report_id_fkey";
            columns: ["report_id"];
            isOneToOne: false;
            referencedRelation: "reports";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "admin_lookups_target_user_id_fkey";
            columns: ["target_user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
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
      blocked_image_hashes: {
        Row: {
          created_at: string;
          dhash: number | null;
          id: string;
          phash: number | null;
          request_id: string | null;
          sha256: string;
        };
        Insert: {
          created_at?: string;
          dhash?: number | null;
          id?: string;
          phash?: number | null;
          request_id?: string | null;
          sha256: string;
        };
        Update: {
          created_at?: string;
          dhash?: number | null;
          id?: string;
          phash?: number | null;
          request_id?: string | null;
          sha256?: string;
        };
        Relationships: [
          {
            foreignKeyName: "blocked_image_hashes_request_id_fkey";
            columns: ["request_id"];
            isOneToOne: false;
            referencedRelation: "takedown_requests";
            referencedColumns: ["id"];
          },
        ];
      };
      blocks: {
        Row: {
          blocked_id: string;
          blocker_id: string;
          created_at: string;
        };
        Insert: {
          blocked_id: string;
          blocker_id: string;
          created_at?: string;
        };
        Update: {
          blocked_id?: string;
          blocker_id?: string;
          created_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "blocks_blocked_id_fkey";
            columns: ["blocked_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "blocks_blocker_id_fkey";
            columns: ["blocker_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      booking_payments: {
        Row: {
          amount_minor: number;
          booking_id: string;
          checkout_attempts: number;
          checkout_session_id: string | null;
          created_at: string;
          currency: string;
          dispute_status: string | null;
          disputed_at: string | null;
          fee_minor: number;
          last_error: string | null;
          payment_intent_id: string | null;
          refund_requested_minor: number;
          refunded_minor: number;
          stripe_account_id: string;
          updated_at: string;
        };
        Insert: {
          amount_minor: number;
          booking_id: string;
          checkout_attempts?: number;
          checkout_session_id?: string | null;
          created_at?: string;
          currency: string;
          dispute_status?: string | null;
          disputed_at?: string | null;
          fee_minor: number;
          last_error?: string | null;
          payment_intent_id?: string | null;
          refund_requested_minor?: number;
          refunded_minor?: number;
          stripe_account_id: string;
          updated_at?: string;
        };
        Update: {
          amount_minor?: number;
          booking_id?: string;
          checkout_attempts?: number;
          checkout_session_id?: string | null;
          created_at?: string;
          currency?: string;
          dispute_status?: string | null;
          disputed_at?: string | null;
          fee_minor?: number;
          last_error?: string | null;
          payment_intent_id?: string | null;
          refund_requested_minor?: number;
          refunded_minor?: number;
          stripe_account_id?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "booking_payments_booking_id_fkey";
            columns: ["booking_id"];
            isOneToOne: true;
            referencedRelation: "bookings";
            referencedColumns: ["id"];
          },
        ];
      };
      booking_private: {
        Row: {
          booking_id: string;
          meeting_note: string;
          online_link: string | null;
        };
        Insert: {
          booking_id: string;
          meeting_note?: string;
          online_link?: string | null;
        };
        Update: {
          booking_id?: string;
          meeting_note?: string;
          online_link?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "booking_private_booking_id_fkey";
            columns: ["booking_id"];
            isOneToOne: true;
            referencedRelation: "bookings";
            referencedColumns: ["id"];
          },
        ];
      };
      bookings: {
        Row: {
          cancel_reason: string | null;
          cancelled_at: string | null;
          cancelled_by: string | null;
          client_id: string;
          client_note: string;
          client_request_id: string;
          coach_id: string;
          completed_at: string | null;
          confirmed_at: string | null;
          created_at: string;
          currency: string;
          declined_at: string | null;
          delivery: Database["public"]["Enums"]["listing_delivery"];
          ends_at: string;
          expired_at: string | null;
          expires_at: string;
          fee_minor: number;
          format: Database["public"]["Enums"]["listing_format"];
          free_cancel_until: string;
          id: string;
          listing_id: string | null;
          no_show_at: string | null;
          no_show_contested_at: string | null;
          no_show_party: string | null;
          no_show_settled_at: string | null;
          paid_at: string | null;
          pay_by: string | null;
          payment_mode: string;
          payment_state: Database["public"]["Enums"]["booking_payment_state"];
          policy_version: string;
          price_minor: number;
          requested_at: string;
          session_id: string | null;
          starts_at: string;
          status: Database["public"]["Enums"]["booking_status"];
          title: string;
          updated_at: string;
        };
        Insert: {
          cancel_reason?: string | null;
          cancelled_at?: string | null;
          cancelled_by?: string | null;
          client_id: string;
          client_note?: string;
          client_request_id: string;
          coach_id: string;
          completed_at?: string | null;
          confirmed_at?: string | null;
          created_at?: string;
          currency: string;
          declined_at?: string | null;
          delivery: Database["public"]["Enums"]["listing_delivery"];
          ends_at: string;
          expired_at?: string | null;
          expires_at: string;
          fee_minor?: number;
          format: Database["public"]["Enums"]["listing_format"];
          free_cancel_until: string;
          id?: string;
          listing_id?: string | null;
          no_show_at?: string | null;
          no_show_contested_at?: string | null;
          no_show_party?: string | null;
          no_show_settled_at?: string | null;
          paid_at?: string | null;
          pay_by?: string | null;
          payment_mode: string;
          payment_state: Database["public"]["Enums"]["booking_payment_state"];
          policy_version: string;
          price_minor: number;
          requested_at?: string;
          session_id?: string | null;
          starts_at: string;
          status?: Database["public"]["Enums"]["booking_status"];
          title: string;
          updated_at?: string;
        };
        Update: {
          cancel_reason?: string | null;
          cancelled_at?: string | null;
          cancelled_by?: string | null;
          client_id?: string;
          client_note?: string;
          client_request_id?: string;
          coach_id?: string;
          completed_at?: string | null;
          confirmed_at?: string | null;
          created_at?: string;
          currency?: string;
          declined_at?: string | null;
          delivery?: Database["public"]["Enums"]["listing_delivery"];
          ends_at?: string;
          expired_at?: string | null;
          expires_at?: string;
          fee_minor?: number;
          format?: Database["public"]["Enums"]["listing_format"];
          free_cancel_until?: string;
          id?: string;
          listing_id?: string | null;
          no_show_at?: string | null;
          no_show_contested_at?: string | null;
          no_show_party?: string | null;
          no_show_settled_at?: string | null;
          paid_at?: string | null;
          pay_by?: string | null;
          payment_mode?: string;
          payment_state?: Database["public"]["Enums"]["booking_payment_state"];
          policy_version?: string;
          price_minor?: number;
          requested_at?: string;
          session_id?: string | null;
          starts_at?: string;
          status?: Database["public"]["Enums"]["booking_status"];
          title?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "bookings_client_id_fkey";
            columns: ["client_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "bookings_coach_id_fkey";
            columns: ["coach_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "bookings_listing_id_fkey";
            columns: ["listing_id"];
            isOneToOne: false;
            referencedRelation: "coach_listings";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "bookings_session_id_fkey";
            columns: ["session_id"];
            isOneToOne: false;
            referencedRelation: "coach_sessions";
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
      chat_filter_strikes: {
        Row: {
          created_at: string;
          id: string;
          user_id: string;
        };
        Insert: {
          created_at?: string;
          id?: string;
          user_id: string;
        };
        Update: {
          created_at?: string;
          id?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "chat_filter_strikes_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      coach_availability_exceptions: {
        Row: {
          coach_id: string;
          ends_at: string;
          id: string;
          kind: string;
          note: string;
          starts_at: string;
        };
        Insert: {
          coach_id: string;
          ends_at: string;
          id?: string;
          kind: string;
          note?: string;
          starts_at: string;
        };
        Update: {
          coach_id?: string;
          ends_at?: string;
          id?: string;
          kind?: string;
          note?: string;
          starts_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "coach_availability_exceptions_coach_id_fkey";
            columns: ["coach_id"];
            isOneToOne: false;
            referencedRelation: "coach_profiles";
            referencedColumns: ["user_id"];
          },
        ];
      };
      coach_availability_rules: {
        Row: {
          coach_id: string;
          end_local: string;
          id: string;
          listing_id: string | null;
          start_local: string;
          valid_from: string | null;
          valid_until: string | null;
          weekday: number;
        };
        Insert: {
          coach_id: string;
          end_local: string;
          id?: string;
          listing_id?: string | null;
          start_local: string;
          valid_from?: string | null;
          valid_until?: string | null;
          weekday: number;
        };
        Update: {
          coach_id?: string;
          end_local?: string;
          id?: string;
          listing_id?: string | null;
          start_local?: string;
          valid_from?: string | null;
          valid_until?: string | null;
          weekday?: number;
        };
        Relationships: [
          {
            foreignKeyName: "coach_availability_rules_coach_id_fkey";
            columns: ["coach_id"];
            isOneToOne: false;
            referencedRelation: "coach_profiles";
            referencedColumns: ["user_id"];
          },
          {
            foreignKeyName: "coach_availability_rules_listing_id_fkey";
            columns: ["listing_id"];
            isOneToOne: false;
            referencedRelation: "coach_listings";
            referencedColumns: ["id"];
          },
        ];
      };
      coach_credentials: {
        Row: {
          coach_id: string;
          id: string;
          issuer: string;
          position: number;
          title: string;
          year: number | null;
        };
        Insert: {
          coach_id: string;
          id?: string;
          issuer?: string;
          position?: number;
          title: string;
          year?: number | null;
        };
        Update: {
          coach_id?: string;
          id?: string;
          issuer?: string;
          position?: number;
          title?: string;
          year?: number | null;
        };
        Relationships: [
          {
            foreignKeyName: "coach_credentials_coach_id_fkey";
            columns: ["coach_id"];
            isOneToOne: false;
            referencedRelation: "coach_profiles";
            referencedColumns: ["user_id"];
          },
        ];
      };
      coach_fee_minimums: {
        Row: {
          currency: string;
          min_fee_minor: number;
        };
        Insert: {
          currency: string;
          min_fee_minor: number;
        };
        Update: {
          currency?: string;
          min_fee_minor?: number;
        };
        Relationships: [];
      };
      coach_hubs: {
        Row: {
          coach_id: string;
          hub_id: string;
        };
        Insert: {
          coach_id: string;
          hub_id: string;
        };
        Update: {
          coach_id?: string;
          hub_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "coach_hubs_coach_id_fkey";
            columns: ["coach_id"];
            isOneToOne: false;
            referencedRelation: "coach_profiles";
            referencedColumns: ["user_id"];
          },
          {
            foreignKeyName: "coach_hubs_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
        ];
      };
      coach_listing_embeddings: {
        Row: {
          content_hash: string;
          embedded_at: string;
          embedding: unknown;
          listing_id: string;
          model: string;
        };
        Insert: {
          content_hash: string;
          embedded_at?: string;
          embedding: unknown;
          listing_id: string;
          model?: string;
        };
        Update: {
          content_hash?: string;
          embedded_at?: string;
          embedding?: unknown;
          listing_id?: string;
          model?: string;
        };
        Relationships: [
          {
            foreignKeyName: "coach_listing_embeddings_listing_id_fkey";
            columns: ["listing_id"];
            isOneToOne: true;
            referencedRelation: "coach_listings";
            referencedColumns: ["id"];
          },
        ];
      };
      coach_listing_private: {
        Row: {
          listing_id: string;
          meeting_note: string;
          online_link: string | null;
        };
        Insert: {
          listing_id: string;
          meeting_note?: string;
          online_link?: string | null;
        };
        Update: {
          listing_id?: string;
          meeting_note?: string;
          online_link?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "coach_listing_private_listing_id_fkey";
            columns: ["listing_id"];
            isOneToOne: true;
            referencedRelation: "coach_listings";
            referencedColumns: ["id"];
          },
        ];
      };
      coach_listings: {
        Row: {
          auto_confirm: boolean;
          buffer_minutes: number;
          capacity: number;
          coach_id: string;
          created_at: string;
          currency: string;
          delivery: Database["public"]["Enums"]["listing_delivery"];
          description: string;
          duration_minutes: number;
          format: Database["public"]["Enums"]["listing_format"];
          hub_id: string | null;
          id: string;
          max_advance_days: number;
          min_age: number;
          min_notice_hours: number;
          moderated_at: string | null;
          moderation_state: string | null;
          price_minor: number;
          slot_step_minutes: number;
          status: Database["public"]["Enums"]["listing_status"];
          title: string;
          updated_at: string;
        };
        Insert: {
          auto_confirm?: boolean;
          buffer_minutes?: number;
          capacity?: number;
          coach_id: string;
          created_at?: string;
          currency: string;
          delivery: Database["public"]["Enums"]["listing_delivery"];
          description?: string;
          duration_minutes: number;
          format: Database["public"]["Enums"]["listing_format"];
          hub_id?: string | null;
          id?: string;
          max_advance_days?: number;
          min_age?: number;
          min_notice_hours?: number;
          moderated_at?: string | null;
          moderation_state?: string | null;
          price_minor: number;
          slot_step_minutes?: number;
          status?: Database["public"]["Enums"]["listing_status"];
          title: string;
          updated_at?: string;
        };
        Update: {
          auto_confirm?: boolean;
          buffer_minutes?: number;
          capacity?: number;
          coach_id?: string;
          created_at?: string;
          currency?: string;
          delivery?: Database["public"]["Enums"]["listing_delivery"];
          description?: string;
          duration_minutes?: number;
          format?: Database["public"]["Enums"]["listing_format"];
          hub_id?: string | null;
          id?: string;
          max_advance_days?: number;
          min_age?: number;
          min_notice_hours?: number;
          moderated_at?: string | null;
          moderation_state?: string | null;
          price_minor?: number;
          slot_step_minutes?: number;
          status?: Database["public"]["Enums"]["listing_status"];
          title?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "coach_listings_coach_id_fkey";
            columns: ["coach_id"];
            isOneToOne: false;
            referencedRelation: "coach_profiles";
            referencedColumns: ["user_id"];
          },
          {
            foreignKeyName: "coach_listings_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
        ];
      };
      coach_photos: {
        Row: {
          coach_id: string;
          created_at: string;
          id: string;
          position: number;
          url: string;
        };
        Insert: {
          coach_id: string;
          created_at?: string;
          id?: string;
          position?: number;
          url: string;
        };
        Update: {
          coach_id?: string;
          created_at?: string;
          id?: string;
          position?: number;
          url?: string;
        };
        Relationships: [
          {
            foreignKeyName: "coach_photos_coach_id_fkey";
            columns: ["coach_id"];
            isOneToOne: false;
            referencedRelation: "coach_profiles";
            referencedColumns: ["user_id"];
          },
        ];
      };
      coach_profiles: {
        Row: {
          about: string;
          area_label: string;
          completed_count: number;
          created_at: string;
          headline: string;
          in_person: boolean;
          online: boolean;
          published_at: string | null;
          rating_avg: number | null;
          rating_count: number;
          service_point: unknown;
          service_radius_km: number | null;
          status: Database["public"]["Enums"]["coach_status"];
          suspended_at: string | null;
          terms_accepted_at: string | null;
          terms_version: string | null;
          timezone: string;
          updated_at: string;
          user_id: string;
        };
        Insert: {
          about?: string;
          area_label?: string;
          completed_count?: number;
          created_at?: string;
          headline?: string;
          in_person?: boolean;
          online?: boolean;
          published_at?: string | null;
          rating_avg?: number | null;
          rating_count?: number;
          service_point?: unknown;
          service_radius_km?: number | null;
          status?: Database["public"]["Enums"]["coach_status"];
          suspended_at?: string | null;
          terms_accepted_at?: string | null;
          terms_version?: string | null;
          timezone: string;
          updated_at?: string;
          user_id: string;
        };
        Update: {
          about?: string;
          area_label?: string;
          completed_count?: number;
          created_at?: string;
          headline?: string;
          in_person?: boolean;
          online?: boolean;
          published_at?: string | null;
          rating_avg?: number | null;
          rating_count?: number;
          service_point?: unknown;
          service_radius_km?: number | null;
          status?: Database["public"]["Enums"]["coach_status"];
          suspended_at?: string | null;
          terms_accepted_at?: string | null;
          terms_version?: string | null;
          timezone?: string;
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "coach_profiles_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: true;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      coach_reviews: {
        Row: {
          body: string;
          booking_id: string;
          client_id: string;
          coach_id: string;
          created_at: string;
          edited_at: string | null;
          moderated_at: string | null;
          moderation_state: string | null;
          rating: number;
          replied_at: string | null;
          reply: string | null;
          reply_moderation_state: string | null;
        };
        Insert: {
          body?: string;
          booking_id: string;
          client_id: string;
          coach_id: string;
          created_at?: string;
          edited_at?: string | null;
          moderated_at?: string | null;
          moderation_state?: string | null;
          rating: number;
          replied_at?: string | null;
          reply?: string | null;
          reply_moderation_state?: string | null;
        };
        Update: {
          body?: string;
          booking_id?: string;
          client_id?: string;
          coach_id?: string;
          created_at?: string;
          edited_at?: string | null;
          moderated_at?: string | null;
          moderation_state?: string | null;
          rating?: number;
          replied_at?: string | null;
          reply?: string | null;
          reply_moderation_state?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "coach_reviews_booking_id_fkey";
            columns: ["booking_id"];
            isOneToOne: true;
            referencedRelation: "bookings";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "coach_reviews_client_id_fkey";
            columns: ["client_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "coach_reviews_coach_id_fkey";
            columns: ["coach_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      coach_sessions: {
        Row: {
          busy: unknown;
          cancelled_at: string | null;
          capacity: number;
          coach_id: string;
          created_at: string;
          ends_at: string;
          id: string;
          listing_id: string;
          starts_at: string;
          status: Database["public"]["Enums"]["coach_session_status"];
        };
        Insert: {
          busy: unknown;
          cancelled_at?: string | null;
          capacity: number;
          coach_id: string;
          created_at?: string;
          ends_at: string;
          id?: string;
          listing_id: string;
          starts_at: string;
          status?: Database["public"]["Enums"]["coach_session_status"];
        };
        Update: {
          busy?: unknown;
          cancelled_at?: string | null;
          capacity?: number;
          coach_id?: string;
          created_at?: string;
          ends_at?: string;
          id?: string;
          listing_id?: string;
          starts_at?: string;
          status?: Database["public"]["Enums"]["coach_session_status"];
        };
        Relationships: [
          {
            foreignKeyName: "coach_sessions_coach_id_fkey";
            columns: ["coach_id"];
            isOneToOne: false;
            referencedRelation: "coach_profiles";
            referencedColumns: ["user_id"];
          },
          {
            foreignKeyName: "coach_sessions_listing_id_fkey";
            columns: ["listing_id"];
            isOneToOne: false;
            referencedRelation: "coach_listings";
            referencedColumns: ["id"];
          },
        ];
      };
      coach_stripe_accounts: {
        Row: {
          charges_enabled: boolean;
          coach_id: string;
          country: string;
          default_currency: string | null;
          details_submitted: boolean;
          disabled_reason: string | null;
          payouts_enabled: boolean;
          requirements_due: string[];
          stripe_account_id: string;
          updated_at: string;
        };
        Insert: {
          charges_enabled?: boolean;
          coach_id: string;
          country: string;
          default_currency?: string | null;
          details_submitted?: boolean;
          disabled_reason?: string | null;
          payouts_enabled?: boolean;
          requirements_due?: string[];
          stripe_account_id: string;
          updated_at?: string;
        };
        Update: {
          charges_enabled?: boolean;
          coach_id?: string;
          country?: string;
          default_currency?: string | null;
          details_submitted?: boolean;
          disabled_reason?: string | null;
          payouts_enabled?: boolean;
          requirements_due?: string[];
          stripe_account_id?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "coach_stripe_accounts_coach_id_fkey";
            columns: ["coach_id"];
            isOneToOne: true;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      collector_budget: {
        Row: {
          day: string;
          source: string;
          updated_at: string;
          used: number;
        };
        Insert: {
          day: string;
          source: string;
          updated_at?: string;
          used?: number;
        };
        Update: {
          day?: string;
          source?: string;
          updated_at?: string;
          used?: number;
        };
        Relationships: [];
      };
      collector_denylist: {
        Row: {
          created_at: string;
          match: string;
          name: string;
          reason: string;
        };
        Insert: {
          created_at?: string;
          match?: string;
          name: string;
          reason: string;
        };
        Update: {
          created_at?: string;
          match?: string;
          name?: string;
          reason?: string;
        };
        Relationships: [];
      };
      collector_job_runs: {
        Row: {
          created_at: string;
          finished_at: string;
          id: number;
          job: string;
          outcome: string;
          run_id: string;
          started_at: string | null;
          stats: Json;
        };
        Insert: {
          created_at?: string;
          finished_at?: string;
          id?: never;
          job: string;
          outcome: string;
          run_id: string;
          started_at?: string | null;
          stats?: Json;
        };
        Update: {
          created_at?: string;
          finished_at?: string;
          id?: never;
          job?: string;
          outcome?: string;
          run_id?: string;
          started_at?: string | null;
          stats?: Json;
        };
        Relationships: [];
      };
      collector_regions: {
        Row: {
          created_at: string;
          first_user_at: string | null;
          home_count: number;
          id: string;
          label: string | null;
          last_collect_items: number | null;
          last_collect_sources: number | null;
          last_collected_at: string | null;
          last_discovery_at: string | null;
          point: unknown;
          priority: number;
          radius_km: number;
          timezone: string | null;
          updated_at: string;
        };
        Insert: {
          created_at?: string;
          first_user_at?: string | null;
          home_count?: number;
          id?: string;
          label?: string | null;
          last_collect_items?: number | null;
          last_collect_sources?: number | null;
          last_collected_at?: string | null;
          last_discovery_at?: string | null;
          point: unknown;
          priority?: number;
          radius_km?: number;
          timezone?: string | null;
          updated_at?: string;
        };
        Update: {
          created_at?: string;
          first_user_at?: string | null;
          home_count?: number;
          id?: string;
          label?: string | null;
          last_collect_items?: number | null;
          last_collect_sources?: number | null;
          last_collected_at?: string | null;
          last_discovery_at?: string | null;
          point?: unknown;
          priority?: number;
          radius_km?: number;
          timezone?: string | null;
          updated_at?: string;
        };
        Relationships: [];
      };
      conversation_members: {
        Row: {
          conversation_id: string;
          joined_at: string;
          last_read_at: string | null;
          last_read_seq: number;
          left_at: string | null;
          muted_until: string | null;
          notify: boolean | null;
          removed_at: string | null;
          removed_by: string | null;
          role: Database["public"]["Enums"]["conversation_role"];
          user_id: string;
        };
        Insert: {
          conversation_id: string;
          joined_at?: string;
          last_read_at?: string | null;
          last_read_seq?: number;
          left_at?: string | null;
          muted_until?: string | null;
          notify?: boolean | null;
          removed_at?: string | null;
          removed_by?: string | null;
          role?: Database["public"]["Enums"]["conversation_role"];
          user_id: string;
        };
        Update: {
          conversation_id?: string;
          joined_at?: string;
          last_read_at?: string | null;
          last_read_seq?: number;
          left_at?: string | null;
          muted_until?: string | null;
          notify?: boolean | null;
          removed_at?: string | null;
          removed_by?: string | null;
          role?: Database["public"]["Enums"]["conversation_role"];
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "conversation_members_conversation_id_fkey";
            columns: ["conversation_id"];
            isOneToOne: false;
            referencedRelation: "conversations";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "conversation_members_removed_by_fkey";
            columns: ["removed_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "conversation_members_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      conversations: {
        Row: {
          chapter_id: string | null;
          closed_at: string | null;
          created_at: string;
          created_by: string | null;
          dm_key: string | null;
          event_id: string | null;
          hub_id: string | null;
          id: string;
          kind: Database["public"]["Enums"]["conversation_kind"];
          last_message_at: string | null;
          last_seq: number;
          title: string | null;
        };
        Insert: {
          chapter_id?: string | null;
          closed_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          dm_key?: string | null;
          event_id?: string | null;
          hub_id?: string | null;
          id?: string;
          kind: Database["public"]["Enums"]["conversation_kind"];
          last_message_at?: string | null;
          last_seq?: number;
          title?: string | null;
        };
        Update: {
          chapter_id?: string | null;
          closed_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          dm_key?: string | null;
          event_id?: string | null;
          hub_id?: string | null;
          id?: string;
          kind?: Database["public"]["Enums"]["conversation_kind"];
          last_message_at?: string | null;
          last_seq?: number;
          title?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "conversations_chapter_id_fkey";
            columns: ["chapter_id"];
            isOneToOne: false;
            referencedRelation: "hub_chapters";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "conversations_created_by_fkey";
            columns: ["created_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "conversations_event_id_fkey";
            columns: ["event_id"];
            isOneToOne: false;
            referencedRelation: "events";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "conversations_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
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
      event_embeddings: {
        Row: {
          content_hash: string;
          embedded_at: string;
          embedding: unknown;
          event_id: string;
          model: string;
        };
        Insert: {
          content_hash: string;
          embedded_at?: string;
          embedding: unknown;
          event_id: string;
          model?: string;
        };
        Update: {
          content_hash?: string;
          embedded_at?: string;
          embedding?: unknown;
          event_id?: string;
          model?: string;
        };
        Relationships: [
          {
            foreignKeyName: "event_embeddings_event_id_fkey";
            columns: ["event_id"];
            isOneToOne: true;
            referencedRelation: "events";
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
          listing_kind: string;
          location_hint: string;
          members_only: boolean;
          min_age: number;
          min_headcount: number | null;
          moderated_at: string | null;
          moderation_state: string | null;
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
          listing_kind?: string;
          location_hint?: string;
          members_only?: boolean;
          min_age?: number;
          min_headcount?: number | null;
          moderated_at?: string | null;
          moderation_state?: string | null;
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
          listing_kind?: string;
          location_hint?: string;
          members_only?: boolean;
          min_age?: number;
          min_headcount?: number | null;
          moderated_at?: string | null;
          moderation_state?: string | null;
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
          candidate_id: string | null;
          collector: boolean;
          collector_fail_streak: number;
          collector_last_run_id: string | null;
          collector_region_id: string | null;
          collector_seen_at: string | null;
          created_at: string;
          cron_minute: number;
          default_hub_id: string | null;
          denylisted: boolean;
          discovered_from: string | null;
          discovery_status: string | null;
          enabled: boolean;
          homepage_url: string | null;
          hub_tags: string[];
          id: string;
          images_licensed: boolean;
          item_count: number | null;
          item_label: string | null;
          kind: string;
          lane: string | null;
          last_error: string | null;
          last_ok_at: string | null;
          last_run_at: string | null;
          last_sample: Json | null;
          last_stats: Json | null;
          listing_kind: string;
          name: string;
          organizer_claim_id: string | null;
          organizer_hub_id: string | null;
          organizer_id: string | null;
          organizer_images_at: string | null;
          organizer_refresh_requested_at: string | null;
          organizer_stopped_at: string | null;
          organizer_verified_at: string | null;
          origin: string;
          partner: boolean;
          region_label: string | null;
          region_point: unknown;
          region_radius_km: number | null;
          region_timezone: string | null;
          robots_ok_at: string | null;
          slug: string;
          updated_at: string;
          url: string;
        };
        Insert: {
          attribution?: string;
          campus_id?: string | null;
          candidate_id?: string | null;
          collector?: boolean;
          collector_fail_streak?: number;
          collector_last_run_id?: string | null;
          collector_region_id?: string | null;
          collector_seen_at?: string | null;
          created_at?: string;
          cron_minute?: number;
          default_hub_id?: string | null;
          denylisted?: boolean;
          discovered_from?: string | null;
          discovery_status?: string | null;
          enabled?: boolean;
          homepage_url?: string | null;
          hub_tags?: string[];
          id?: string;
          images_licensed?: boolean;
          item_count?: number | null;
          item_label?: string | null;
          kind: string;
          lane?: string | null;
          last_error?: string | null;
          last_ok_at?: string | null;
          last_run_at?: string | null;
          last_sample?: Json | null;
          last_stats?: Json | null;
          listing_kind?: string;
          name: string;
          organizer_claim_id?: string | null;
          organizer_hub_id?: string | null;
          organizer_id?: string | null;
          organizer_images_at?: string | null;
          organizer_refresh_requested_at?: string | null;
          organizer_stopped_at?: string | null;
          organizer_verified_at?: string | null;
          origin?: string;
          partner?: boolean;
          region_label?: string | null;
          region_point?: unknown;
          region_radius_km?: number | null;
          region_timezone?: string | null;
          robots_ok_at?: string | null;
          slug: string;
          updated_at?: string;
          url: string;
        };
        Update: {
          attribution?: string;
          campus_id?: string | null;
          candidate_id?: string | null;
          collector?: boolean;
          collector_fail_streak?: number;
          collector_last_run_id?: string | null;
          collector_region_id?: string | null;
          collector_seen_at?: string | null;
          created_at?: string;
          cron_minute?: number;
          default_hub_id?: string | null;
          denylisted?: boolean;
          discovered_from?: string | null;
          discovery_status?: string | null;
          enabled?: boolean;
          homepage_url?: string | null;
          hub_tags?: string[];
          id?: string;
          images_licensed?: boolean;
          item_count?: number | null;
          item_label?: string | null;
          kind?: string;
          lane?: string | null;
          last_error?: string | null;
          last_ok_at?: string | null;
          last_run_at?: string | null;
          last_sample?: Json | null;
          last_stats?: Json | null;
          listing_kind?: string;
          name?: string;
          organizer_claim_id?: string | null;
          organizer_hub_id?: string | null;
          organizer_id?: string | null;
          organizer_images_at?: string | null;
          organizer_refresh_requested_at?: string | null;
          organizer_stopped_at?: string | null;
          organizer_verified_at?: string | null;
          origin?: string;
          partner?: boolean;
          region_label?: string | null;
          region_point?: unknown;
          region_radius_km?: number | null;
          region_timezone?: string | null;
          robots_ok_at?: string | null;
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
            foreignKeyName: "feed_sources_candidate_fk";
            columns: ["candidate_id"];
            isOneToOne: false;
            referencedRelation: "source_candidates";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "feed_sources_collector_region_fk";
            columns: ["collector_region_id"];
            isOneToOne: false;
            referencedRelation: "collector_regions";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "feed_sources_default_hub_id_fkey";
            columns: ["default_hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "feed_sources_organizer_claim_fk";
            columns: ["organizer_claim_id"];
            isOneToOne: false;
            referencedRelation: "organizer_claims";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "feed_sources_organizer_fk";
            columns: ["organizer_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "feed_sources_organizer_hub_fk";
            columns: ["organizer_hub_id"];
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
          moderated_at: string | null;
          moderation_state: string | null;
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
          moderated_at?: string | null;
          moderation_state?: string | null;
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
          moderated_at?: string | null;
          moderation_state?: string | null;
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
      hub_embeddings: {
        Row: {
          content_hash: string;
          embedded_at: string;
          embedding: unknown;
          hub_id: string;
          model: string;
        };
        Insert: {
          content_hash: string;
          embedded_at?: string;
          embedding: unknown;
          hub_id: string;
          model?: string;
        };
        Update: {
          content_hash?: string;
          embedded_at?: string;
          embedding?: unknown;
          hub_id?: string;
          model?: string;
        };
        Relationships: [
          {
            foreignKeyName: "hub_embeddings_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: true;
            referencedRelation: "hubs";
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
      hub_place_rules: {
        Row: {
          hub_id: string;
          rule_id: number;
        };
        Insert: {
          hub_id: string;
          rule_id: number;
        };
        Update: {
          hub_id?: string;
          rule_id?: number;
        };
        Relationships: [
          {
            foreignKeyName: "hub_place_rules_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "hub_place_rules_rule_id_fkey";
            columns: ["rule_id"];
            isOneToOne: false;
            referencedRelation: "place_rules";
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
          geoapify_categories: string[];
          id: string;
          is_active: boolean;
          is_featured: boolean;
          min_age: number;
          moderated_at: string | null;
          moderation_state: string | null;
          name: string;
          place_mode: string;
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
          geoapify_categories?: string[];
          id?: string;
          is_active?: boolean;
          is_featured?: boolean;
          min_age?: number;
          moderated_at?: string | null;
          moderation_state?: string | null;
          name: string;
          place_mode?: string;
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
          geoapify_categories?: string[];
          id?: string;
          is_active?: boolean;
          is_featured?: boolean;
          min_age?: number;
          moderated_at?: string | null;
          moderation_state?: string | null;
          name?: string;
          place_mode?: string;
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
      image_hashes: {
        Row: {
          attempts: number;
          block_request_id: string | null;
          blocked_at: string | null;
          blocked_hash_id: string | null;
          bucket: string;
          checked_at: string | null;
          created_at: string;
          dhash: number | null;
          dispatched_at: string | null;
          id: string;
          owner_id: string | null;
          path: string;
          phash: number | null;
          purged_at: string | null;
          sha256: string | null;
          status: string;
        };
        Insert: {
          attempts?: number;
          block_request_id?: string | null;
          blocked_at?: string | null;
          blocked_hash_id?: string | null;
          bucket: string;
          checked_at?: string | null;
          created_at?: string;
          dhash?: number | null;
          dispatched_at?: string | null;
          id?: string;
          owner_id?: string | null;
          path: string;
          phash?: number | null;
          purged_at?: string | null;
          sha256?: string | null;
          status?: string;
        };
        Update: {
          attempts?: number;
          block_request_id?: string | null;
          blocked_at?: string | null;
          blocked_hash_id?: string | null;
          bucket?: string;
          checked_at?: string | null;
          created_at?: string;
          dhash?: number | null;
          dispatched_at?: string | null;
          id?: string;
          owner_id?: string | null;
          path?: string;
          phash?: number | null;
          purged_at?: string | null;
          sha256?: string | null;
          status?: string;
        };
        Relationships: [
          {
            foreignKeyName: "image_hashes_block_request_id_fkey";
            columns: ["block_request_id"];
            isOneToOne: false;
            referencedRelation: "takedown_requests";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "image_hashes_blocked_hash_id_fkey";
            columns: ["blocked_hash_id"];
            isOneToOne: false;
            referencedRelation: "blocked_image_hashes";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "image_hashes_owner_id_fkey";
            columns: ["owner_id"];
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
      listing_removal_requests: {
        Row: {
          client_hash: string | null;
          contact_cleared_at: string | null;
          created_at: string;
          email_hash: string;
          event_id: string | null;
          id: string;
          reason: string;
          reference: string;
          relationship: string;
          requester_email: string;
          requester_name: string;
          resolution_note: string;
          resolved_at: string | null;
          resolved_by: string | null;
          scope: string;
          source_id: string | null;
          status: string;
          updated_at: string;
          url: string | null;
        };
        Insert: {
          client_hash?: string | null;
          contact_cleared_at?: string | null;
          created_at?: string;
          email_hash: string;
          event_id?: string | null;
          id?: string;
          reason?: string;
          reference: string;
          relationship: string;
          requester_email: string;
          requester_name: string;
          resolution_note?: string;
          resolved_at?: string | null;
          resolved_by?: string | null;
          scope?: string;
          source_id?: string | null;
          status?: string;
          updated_at?: string;
          url?: string | null;
        };
        Update: {
          client_hash?: string | null;
          contact_cleared_at?: string | null;
          created_at?: string;
          email_hash?: string;
          event_id?: string | null;
          id?: string;
          reason?: string;
          reference?: string;
          relationship?: string;
          requester_email?: string;
          requester_name?: string;
          resolution_note?: string;
          resolved_at?: string | null;
          resolved_by?: string | null;
          scope?: string;
          source_id?: string | null;
          status?: string;
          updated_at?: string;
          url?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "listing_removal_requests_event_id_fkey";
            columns: ["event_id"];
            isOneToOne: false;
            referencedRelation: "events";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "listing_removal_requests_resolved_by_fkey";
            columns: ["resolved_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "listing_removal_requests_source_id_fkey";
            columns: ["source_id"];
            isOneToOne: false;
            referencedRelation: "feed_sources";
            referencedColumns: ["id"];
          },
        ];
      };
      message_report_evidence: {
        Row: {
          author_id: string | null;
          body: string;
          context: Json;
          conversation_id: string | null;
          conversation_kind: Database["public"]["Enums"]["conversation_kind"];
          created_at: string;
          image_evidence_missing_at: string | null;
          image_evidence_path: string | null;
          message_id: string | null;
          report_id: string;
          retain_until: string | null;
        };
        Insert: {
          author_id?: string | null;
          body: string;
          context: Json;
          conversation_id?: string | null;
          conversation_kind: Database["public"]["Enums"]["conversation_kind"];
          created_at?: string;
          image_evidence_missing_at?: string | null;
          image_evidence_path?: string | null;
          message_id?: string | null;
          report_id: string;
          retain_until?: string | null;
        };
        Update: {
          author_id?: string | null;
          body?: string;
          context?: Json;
          conversation_id?: string | null;
          conversation_kind?: Database["public"]["Enums"]["conversation_kind"];
          created_at?: string;
          image_evidence_missing_at?: string | null;
          image_evidence_path?: string | null;
          message_id?: string | null;
          report_id?: string;
          retain_until?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "message_report_evidence_author_id_fkey";
            columns: ["author_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "message_report_evidence_report_id_fkey";
            columns: ["report_id"];
            isOneToOne: true;
            referencedRelation: "reports";
            referencedColumns: ["id"];
          },
        ];
      };
      message_requests: {
        Row: {
          conversation_id: string;
          created_at: string;
          decided_at: string | null;
          from_user: string;
          status: string;
          to_user: string;
        };
        Insert: {
          conversation_id: string;
          created_at?: string;
          decided_at?: string | null;
          from_user: string;
          status?: string;
          to_user: string;
        };
        Update: {
          conversation_id?: string;
          created_at?: string;
          decided_at?: string | null;
          from_user?: string;
          status?: string;
          to_user?: string;
        };
        Relationships: [
          {
            foreignKeyName: "message_requests_conversation_id_fkey";
            columns: ["conversation_id"];
            isOneToOne: true;
            referencedRelation: "conversations";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "message_requests_from_user_fkey";
            columns: ["from_user"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "message_requests_to_user_fkey";
            columns: ["to_user"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      messages: {
        Row: {
          author_id: string | null;
          body: string;
          client_id: string | null;
          conversation_id: string;
          created_at: string;
          deleted_at: string | null;
          deleted_body: string | null;
          deleted_by: string | null;
          has_link: boolean;
          id: string;
          image_path: string | null;
          image_state: string | null;
          kind: string;
          moderated_at: string | null;
          moderation_state: string | null;
          seq: number;
        };
        Insert: {
          author_id?: string | null;
          body?: string;
          client_id?: string | null;
          conversation_id: string;
          created_at?: string;
          deleted_at?: string | null;
          deleted_body?: string | null;
          deleted_by?: string | null;
          has_link?: boolean;
          id?: string;
          image_path?: string | null;
          image_state?: string | null;
          kind?: string;
          moderated_at?: string | null;
          moderation_state?: string | null;
          seq: number;
        };
        Update: {
          author_id?: string | null;
          body?: string;
          client_id?: string | null;
          conversation_id?: string;
          created_at?: string;
          deleted_at?: string | null;
          deleted_body?: string | null;
          deleted_by?: string | null;
          has_link?: boolean;
          id?: string;
          image_path?: string | null;
          image_state?: string | null;
          kind?: string;
          moderated_at?: string | null;
          moderation_state?: string | null;
          seq?: number;
        };
        Relationships: [
          {
            foreignKeyName: "messages_author_id_fkey";
            columns: ["author_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "messages_conversation_id_fkey";
            columns: ["conversation_id"];
            isOneToOne: false;
            referencedRelation: "conversations";
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
      moderation_actions: {
        Row: {
          action: string;
          created_at: string;
          id: string;
          moderator_id: string | null;
          note: string | null;
          report_count: number;
          snapshot: Json | null;
          target_id: string;
          target_kind: string;
          target_user_id: string | null;
        };
        Insert: {
          action: string;
          created_at?: string;
          id?: string;
          moderator_id?: string | null;
          note?: string | null;
          report_count?: number;
          snapshot?: Json | null;
          target_id: string;
          target_kind: string;
          target_user_id?: string | null;
        };
        Update: {
          action?: string;
          created_at?: string;
          id?: string;
          moderator_id?: string | null;
          note?: string | null;
          report_count?: number;
          snapshot?: Json | null;
          target_id?: string;
          target_kind?: string;
          target_user_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "moderation_actions_moderator_id_fkey";
            columns: ["moderator_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "moderation_actions_target_user_id_fkey";
            columns: ["target_user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      mutes: {
        Row: {
          created_at: string;
          muted_id: string;
          muter_id: string;
        };
        Insert: {
          created_at?: string;
          muted_id: string;
          muter_id: string;
        };
        Update: {
          created_at?: string;
          muted_id?: string;
          muter_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "mutes_muted_id_fkey";
            columns: ["muted_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "mutes_muter_id_fkey";
            columns: ["muter_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      notification_email_days: {
        Row: {
          day: string;
          reserved: number;
        };
        Insert: {
          day: string;
          reserved?: number;
        };
        Update: {
          day?: string;
          reserved?: number;
        };
        Relationships: [];
      };
      notification_prefs: {
        Row: {
          bookings: boolean;
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
          bookings?: boolean;
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
          bookings?: boolean;
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
          claimed_at: string | null;
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
          claimed_at?: string | null;
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
          claimed_at?: string | null;
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
      organizer_claims: {
        Row: {
          attempts: number;
          check_requested_at: string | null;
          created_at: string;
          event_id: string | null;
          failure: string | null;
          feed_url: string | null;
          host: string;
          id: string;
          last_checked_at: string | null;
          method: string;
          reviewed_at: string | null;
          source_id: string | null;
          status: string;
          token: string;
          updated_at: string;
          user_id: string;
          verified_at: string | null;
        };
        Insert: {
          attempts?: number;
          check_requested_at?: string | null;
          created_at?: string;
          event_id?: string | null;
          failure?: string | null;
          feed_url?: string | null;
          host: string;
          id?: string;
          last_checked_at?: string | null;
          method?: string;
          reviewed_at?: string | null;
          source_id?: string | null;
          status?: string;
          token: string;
          updated_at?: string;
          user_id: string;
          verified_at?: string | null;
        };
        Update: {
          attempts?: number;
          check_requested_at?: string | null;
          created_at?: string;
          event_id?: string | null;
          failure?: string | null;
          feed_url?: string | null;
          host?: string;
          id?: string;
          last_checked_at?: string | null;
          method?: string;
          reviewed_at?: string | null;
          source_id?: string | null;
          status?: string;
          token?: string;
          updated_at?: string;
          user_id?: string;
          verified_at?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "organizer_claims_event_id_fkey";
            columns: ["event_id"];
            isOneToOne: false;
            referencedRelation: "events";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "organizer_claims_source_id_fkey";
            columns: ["source_id"];
            isOneToOne: false;
            referencedRelation: "feed_sources";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "organizer_claims_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      organizer_oauth_states: {
        Row: {
          created_at: string;
          expires_at: string;
          id: string;
          provider: string;
          state_hash: string;
          used_at: string | null;
          user_id: string;
        };
        Insert: {
          created_at?: string;
          expires_at?: string;
          id?: string;
          provider?: string;
          state_hash: string;
          used_at?: string | null;
          user_id: string;
        };
        Update: {
          created_at?: string;
          expires_at?: string;
          id?: string;
          provider?: string;
          state_hash?: string;
          used_at?: string | null;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "organizer_oauth_states_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      place_edits: {
        Row: {
          changes: Json;
          created_at: string;
          id: string;
          note: string;
          place_id: string;
          proposed_by: string | null;
          review_note: string | null;
          reviewed_at: string | null;
          reviewed_by: string | null;
          status: string;
        };
        Insert: {
          changes: Json;
          created_at?: string;
          id?: string;
          note?: string;
          place_id: string;
          proposed_by?: string | null;
          review_note?: string | null;
          reviewed_at?: string | null;
          reviewed_by?: string | null;
          status?: string;
        };
        Update: {
          changes?: Json;
          created_at?: string;
          id?: string;
          note?: string;
          place_id?: string;
          proposed_by?: string | null;
          review_note?: string | null;
          reviewed_at?: string | null;
          reviewed_by?: string | null;
          status?: string;
        };
        Relationships: [
          {
            foreignKeyName: "place_edits_place_id_fkey";
            columns: ["place_id"];
            isOneToOne: false;
            referencedRelation: "places";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "place_edits_place_id_fkey";
            columns: ["place_id"];
            isOneToOne: false;
            referencedRelation: "places_odbl_export";
            referencedColumns: ["cursor_id"];
          },
          {
            foreignKeyName: "place_edits_proposed_by_fkey";
            columns: ["proposed_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "place_edits_reviewed_by_fkey";
            columns: ["reviewed_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      place_hubs: {
        Row: {
          created_at: string;
          hub_id: string;
          place_id: string;
          via: string;
          weight: number;
        };
        Insert: {
          created_at?: string;
          hub_id: string;
          place_id: string;
          via: string;
          weight?: number;
        };
        Update: {
          created_at?: string;
          hub_id?: string;
          place_id?: string;
          via?: string;
          weight?: number;
        };
        Relationships: [
          {
            foreignKeyName: "place_hubs_hub_id_fkey";
            columns: ["hub_id"];
            isOneToOne: false;
            referencedRelation: "hubs";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "place_hubs_place_id_fkey";
            columns: ["place_id"];
            isOneToOne: false;
            referencedRelation: "places";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "place_hubs_place_id_fkey";
            columns: ["place_id"];
            isOneToOne: false;
            referencedRelation: "places_odbl_export";
            referencedColumns: ["cursor_id"];
          },
        ];
      };
      place_kinds: {
        Row: {
          icon: string;
          label: string;
          slug: string;
          sort: number;
        };
        Insert: {
          icon: string;
          label: string;
          slug: string;
          sort?: number;
        };
        Update: {
          icon?: string;
          label?: string;
          slug?: string;
          sort?: number;
        };
        Relationships: [];
      };
      place_mod_actions: {
        Row: {
          action: string;
          created_at: string;
          id: string;
          item_id: string;
          item_kind: string;
          moderator_id: string | null;
          note: string | null;
          place_id: string;
        };
        Insert: {
          action: string;
          created_at?: string;
          id?: string;
          item_id: string;
          item_kind: string;
          moderator_id?: string | null;
          note?: string | null;
          place_id: string;
        };
        Update: {
          action?: string;
          created_at?: string;
          id?: string;
          item_id?: string;
          item_kind?: string;
          moderator_id?: string | null;
          note?: string | null;
          place_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "place_mod_actions_moderator_id_fkey";
            columns: ["moderator_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "place_mod_actions_place_id_fkey";
            columns: ["place_id"];
            isOneToOne: false;
            referencedRelation: "places";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "place_mod_actions_place_id_fkey";
            columns: ["place_id"];
            isOneToOne: false;
            referencedRelation: "places_odbl_export";
            referencedColumns: ["cursor_id"];
          },
        ];
      };
      place_ops_runs: {
        Row: {
          id: number;
          job: string;
          ran_at: string;
          stats: Json;
        };
        Insert: {
          id?: never;
          job: string;
          ran_at?: string;
          stats?: Json;
        };
        Update: {
          id?: never;
          job?: string;
          ran_at?: string;
          stats?: Json;
        };
        Relationships: [];
      };
      place_rate_log: {
        Row: {
          created_at: string;
          id: number;
          kind: string;
          user_id: string;
        };
        Insert: {
          created_at?: string;
          id?: never;
          kind: string;
          user_id: string;
        };
        Update: {
          created_at?: string;
          id?: never;
          kind?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "place_rate_log_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      place_reports: {
        Row: {
          created_at: string;
          id: string;
          note: string;
          place_id: string;
          reason: string;
          reporter_id: string | null;
          resolved_at: string | null;
          resolved_by: string | null;
          status: string;
        };
        Insert: {
          created_at?: string;
          id?: string;
          note?: string;
          place_id: string;
          reason: string;
          reporter_id?: string | null;
          resolved_at?: string | null;
          resolved_by?: string | null;
          status?: string;
        };
        Update: {
          created_at?: string;
          id?: string;
          note?: string;
          place_id?: string;
          reason?: string;
          reporter_id?: string | null;
          resolved_at?: string | null;
          resolved_by?: string | null;
          status?: string;
        };
        Relationships: [
          {
            foreignKeyName: "place_reports_place_id_fkey";
            columns: ["place_id"];
            isOneToOne: false;
            referencedRelation: "places";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "place_reports_place_id_fkey";
            columns: ["place_id"];
            isOneToOne: false;
            referencedRelation: "places_odbl_export";
            referencedColumns: ["cursor_id"];
          },
          {
            foreignKeyName: "place_reports_reporter_id_fkey";
            columns: ["reporter_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "place_reports_resolved_by_fkey";
            columns: ["resolved_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      place_rules: {
        Row: {
          extra: Json;
          id: number;
          kind: string;
          osm_key: string;
          osm_type: string;
          osm_value: string | null;
          rules_version: number;
          verified: boolean;
        };
        Insert: {
          extra?: Json;
          id: number;
          kind: string;
          osm_key: string;
          osm_type?: string;
          osm_value?: string | null;
          rules_version: number;
          verified?: boolean;
        };
        Update: {
          extra?: Json;
          id?: number;
          kind?: string;
          osm_key?: string;
          osm_type?: string;
          osm_value?: string | null;
          rules_version?: number;
          verified?: boolean;
        };
        Relationships: [
          {
            foreignKeyName: "place_rules_kind_fkey";
            columns: ["kind"];
            isOneToOne: false;
            referencedRelation: "place_kinds";
            referencedColumns: ["slug"];
          },
        ];
      };
      place_tile_runs: {
        Row: {
          batches: Json;
          finished_at: string | null;
          loose: number;
          received: number;
          run_id: string;
          source: Database["public"]["Enums"]["place_source"];
          started_at: string;
          stats: Json;
          tile_id: number;
        };
        Insert: {
          batches?: Json;
          finished_at?: string | null;
          loose?: number;
          received?: number;
          run_id: string;
          source: Database["public"]["Enums"]["place_source"];
          started_at?: string;
          stats?: Json;
          tile_id: number;
        };
        Update: {
          batches?: Json;
          finished_at?: string | null;
          loose?: number;
          received?: number;
          run_id?: string;
          source?: Database["public"]["Enums"]["place_source"];
          started_at?: string;
          stats?: Json;
          tile_id?: number;
        };
        Relationships: [
          {
            foreignKeyName: "place_tile_runs_tile_id_fkey";
            columns: ["tile_id"];
            isOneToOne: false;
            referencedRelation: "place_tiles";
            referencedColumns: ["id"];
          },
        ];
      };
      place_tiles: {
        Row: {
          bbox: unknown;
          created_at: string;
          demand: number;
          file_built_at: string | null;
          file_built_from: string | null;
          file_bytes: number | null;
          file_count: number | null;
          file_path: string | null;
          file_published_at: string | null;
          file_rules_version: number | null;
          file_sha256: string | null;
          geoapify_claimed_at: string | null;
          geoapify_run_at: string | null;
          id: number;
          idle_since: string | null;
          keep: boolean;
          last_member_at: string | null;
          osm_run_at: string | null;
          queue_reason: string | null;
          row_count: number;
          status: Database["public"]["Enums"]["place_tile_status"];
          updated_at: string;
        };
        Insert: {
          bbox?: unknown;
          created_at?: string;
          demand?: number;
          file_built_at?: string | null;
          file_built_from?: string | null;
          file_bytes?: number | null;
          file_count?: number | null;
          file_path?: string | null;
          file_published_at?: string | null;
          file_rules_version?: number | null;
          file_sha256?: string | null;
          geoapify_claimed_at?: string | null;
          geoapify_run_at?: string | null;
          id: number;
          idle_since?: string | null;
          keep?: boolean;
          last_member_at?: string | null;
          osm_run_at?: string | null;
          queue_reason?: string | null;
          row_count?: number;
          status?: Database["public"]["Enums"]["place_tile_status"];
          updated_at?: string;
        };
        Update: {
          bbox?: unknown;
          created_at?: string;
          demand?: number;
          file_built_at?: string | null;
          file_built_from?: string | null;
          file_bytes?: number | null;
          file_count?: number | null;
          file_path?: string | null;
          file_published_at?: string | null;
          file_rules_version?: number | null;
          file_sha256?: string | null;
          geoapify_claimed_at?: string | null;
          geoapify_run_at?: string | null;
          id?: number;
          idle_since?: string | null;
          keep?: boolean;
          last_member_at?: string | null;
          osm_run_at?: string | null;
          queue_reason?: string | null;
          row_count?: number;
          status?: Database["public"]["Enums"]["place_tile_status"];
          updated_at?: string;
        };
        Relationships: [];
      };
      place_venue_file_checks: {
        Row: {
          checked_on: string;
          files_key: string;
          venue_id: string;
        };
        Insert: {
          checked_on?: string;
          files_key: string;
          venue_id: string;
        };
        Update: {
          checked_on?: string;
          files_key?: string;
          venue_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "place_venue_file_checks_venue_id_fkey";
            columns: ["venue_id"];
            isOneToOne: true;
            referencedRelation: "venues";
            referencedColumns: ["id"];
          },
        ];
      };
      places: {
        Row: {
          address_text: string;
          attribution: string;
          country: string | null;
          created_at: string;
          created_by: string | null;
          geom: unknown;
          id: string;
          is_public: boolean;
          kind: string;
          last_run_id: string | null;
          last_seen_at: string;
          lat: number | null;
          license: string;
          lng: number | null;
          locality: string;
          location: unknown;
          locked_fields: string[];
          merged_into: string | null;
          missed_runs: number;
          name: string;
          opening_hours: string | null;
          osm_ref: string | null;
          rule_ids: number[];
          search_text: string | null;
          source: Database["public"]["Enums"]["place_source"];
          source_id: string | null;
          status: Database["public"]["Enums"]["place_status"];
          tags: Json;
          tile_id: number | null;
          updated_at: string;
          website: string | null;
        };
        Insert: {
          address_text?: string;
          attribution: string;
          country?: string | null;
          created_at?: string;
          created_by?: string | null;
          geom?: unknown;
          id?: string;
          is_public?: boolean;
          kind: string;
          last_run_id?: string | null;
          last_seen_at?: string;
          lat?: number | null;
          license?: string;
          lng?: number | null;
          locality?: string;
          location: unknown;
          locked_fields?: string[];
          merged_into?: string | null;
          missed_runs?: number;
          name: string;
          opening_hours?: string | null;
          osm_ref?: string | null;
          rule_ids?: number[];
          search_text?: string | null;
          source: Database["public"]["Enums"]["place_source"];
          source_id?: string | null;
          status?: Database["public"]["Enums"]["place_status"];
          tags?: Json;
          tile_id?: number | null;
          updated_at?: string;
          website?: string | null;
        };
        Update: {
          address_text?: string;
          attribution?: string;
          country?: string | null;
          created_at?: string;
          created_by?: string | null;
          geom?: unknown;
          id?: string;
          is_public?: boolean;
          kind?: string;
          last_run_id?: string | null;
          last_seen_at?: string;
          lat?: number | null;
          license?: string;
          lng?: number | null;
          locality?: string;
          location?: unknown;
          locked_fields?: string[];
          merged_into?: string | null;
          missed_runs?: number;
          name?: string;
          opening_hours?: string | null;
          osm_ref?: string | null;
          rule_ids?: number[];
          search_text?: string | null;
          source?: Database["public"]["Enums"]["place_source"];
          source_id?: string | null;
          status?: Database["public"]["Enums"]["place_status"];
          tags?: Json;
          tile_id?: number | null;
          updated_at?: string;
          website?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "places_created_by_fkey";
            columns: ["created_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "places_kind_fkey";
            columns: ["kind"];
            isOneToOne: false;
            referencedRelation: "place_kinds";
            referencedColumns: ["slug"];
          },
          {
            foreignKeyName: "places_merged_into_fkey";
            columns: ["merged_into"];
            isOneToOne: false;
            referencedRelation: "places";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "places_merged_into_fkey";
            columns: ["merged_into"];
            isOneToOne: false;
            referencedRelation: "places_odbl_export";
            referencedColumns: ["cursor_id"];
          },
        ];
      };
      profile_private: {
        Row: {
          birth_date: string | null;
          created_at: string;
          email: string;
          feed_radius_km: number;
          home_area_id: string | null;
          home_count_noted_at: string | null;
          home_label: string | null;
          home_point: unknown;
          home_region_noted_at: string | null;
          home_set_at: string | null;
          home_tile_noted_at: string | null;
          last_seen_at: string | null;
          location: unknown;
          location_text: string;
          location_updated_at: string | null;
          timezone: string | null;
          updated_at: string;
          user_id: string;
        };
        Insert: {
          birth_date?: string | null;
          created_at?: string;
          email: string;
          feed_radius_km?: number;
          home_area_id?: string | null;
          home_count_noted_at?: string | null;
          home_label?: string | null;
          home_point?: unknown;
          home_region_noted_at?: string | null;
          home_set_at?: string | null;
          home_tile_noted_at?: string | null;
          last_seen_at?: string | null;
          location?: unknown;
          location_text?: string;
          location_updated_at?: string | null;
          timezone?: string | null;
          updated_at?: string;
          user_id: string;
        };
        Update: {
          birth_date?: string | null;
          created_at?: string;
          email?: string;
          feed_radius_km?: number;
          home_area_id?: string | null;
          home_count_noted_at?: string | null;
          home_label?: string | null;
          home_point?: unknown;
          home_region_noted_at?: string | null;
          home_set_at?: string | null;
          home_tile_noted_at?: string | null;
          last_seen_at?: string | null;
          location?: unknown;
          location_text?: string;
          location_updated_at?: string | null;
          timezone?: string | null;
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
          moderated_at: string | null;
          moderation_state: string | null;
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
          moderated_at?: string | null;
          moderation_state?: string | null;
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
          moderated_at?: string | null;
          moderation_state?: string | null;
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
      rec_dismissals: {
        Row: {
          created_at: string;
          subject_id: string;
          subject_kind: Database["public"]["Enums"]["rec_subject_kind"];
          user_id: string;
        };
        Insert: {
          created_at?: string;
          subject_id: string;
          subject_kind: Database["public"]["Enums"]["rec_subject_kind"];
          user_id: string;
        };
        Update: {
          created_at?: string;
          subject_id?: string;
          subject_kind?: Database["public"]["Enums"]["rec_subject_kind"];
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "rec_dismissals_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      rec_embed_daily: {
        Row: {
          day: string;
          embedded: number;
        };
        Insert: {
          day: string;
          embedded?: number;
        };
        Update: {
          day?: string;
          embedded?: number;
        };
        Relationships: [];
      };
      rec_embed_queue: {
        Row: {
          attempts: number;
          claimed_at: string | null;
          failed_at: string | null;
          last_error: string | null;
          priority: number;
          queued_at: string;
          subject_id: string;
          subject_kind: Database["public"]["Enums"]["rec_subject_kind"];
        };
        Insert: {
          attempts?: number;
          claimed_at?: string | null;
          failed_at?: string | null;
          last_error?: string | null;
          priority?: number;
          queued_at?: string;
          subject_id: string;
          subject_kind: Database["public"]["Enums"]["rec_subject_kind"];
        };
        Update: {
          attempts?: number;
          claimed_at?: string | null;
          failed_at?: string | null;
          last_error?: string | null;
          priority?: number;
          queued_at?: string;
          subject_id?: string;
          subject_kind?: Database["public"]["Enums"]["rec_subject_kind"];
        };
        Relationships: [];
      };
      rec_prefs: {
        Row: {
          people_suggestions: boolean;
          personalize: boolean;
          updated_at: string;
          user_id: string;
        };
        Insert: {
          people_suggestions?: boolean;
          personalize?: boolean;
          updated_at?: string;
          user_id: string;
        };
        Update: {
          people_suggestions?: boolean;
          personalize?: boolean;
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "rec_prefs_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: true;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      rec_taste: {
        Row: {
          computed_at: string | null;
          embedding: unknown;
          inputs: number;
          stale: boolean;
          user_id: string;
        };
        Insert: {
          computed_at?: string | null;
          embedding?: unknown;
          inputs?: number;
          stale?: boolean;
          user_id: string;
        };
        Update: {
          computed_at?: string | null;
          embedding?: unknown;
          inputs?: number;
          stale?: boolean;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "rec_taste_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: true;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      reports: {
        Row: {
          created_at: string;
          due_at: string;
          id: string;
          note: string;
          priority: number;
          reason: string;
          reporter_id: string | null;
          resolved_at: string | null;
          resolved_by: string | null;
          status: string;
          target_id: string;
          target_kind: string;
          target_user_id: string | null;
        };
        Insert: {
          created_at?: string;
          due_at?: string;
          id?: string;
          note?: string;
          priority?: number;
          reason: string;
          reporter_id?: string | null;
          resolved_at?: string | null;
          resolved_by?: string | null;
          status?: string;
          target_id: string;
          target_kind: string;
          target_user_id?: string | null;
        };
        Update: {
          created_at?: string;
          due_at?: string;
          id?: string;
          note?: string;
          priority?: number;
          reason?: string;
          reporter_id?: string | null;
          resolved_at?: string | null;
          resolved_by?: string | null;
          status?: string;
          target_id?: string;
          target_kind?: string;
          target_user_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "reports_reporter_id_fkey";
            columns: ["reporter_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "reports_resolved_by_fkey";
            columns: ["resolved_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "reports_target_user_id_fkey";
            columns: ["target_user_id"];
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
      scorecard_active_weeks: {
        Row: {
          active: number;
          week_start: string;
        };
        Insert: {
          active?: number;
          week_start: string;
        };
        Update: {
          active?: number;
          week_start?: string;
        };
        Relationships: [];
      };
      scorecard_runs: {
        Row: {
          counts: Json;
          error: string | null;
          sent_at: string | null;
          status: string;
          week_start: string;
        };
        Insert: {
          counts: Json;
          error?: string | null;
          sent_at?: string | null;
          status: string;
          week_start: string;
        };
        Update: {
          counts?: Json;
          error?: string | null;
          sent_at?: string | null;
          status?: string;
          week_start?: string;
        };
        Relationships: [];
      };
      source_candidates: {
        Row: {
          country: string | null;
          created_at: string;
          empty_runs: number;
          empty_since: string | null;
          error_runs: number;
          error_since: string | null;
          feed_kind: string | null;
          feed_url: string | null;
          host: string;
          id: string;
          last_ok_on: string | null;
          last_probe_at: string | null;
          locked: boolean;
          name: string | null;
          ok_days: number;
          ok_runs: number;
          origin: string;
          place_kind: string | null;
          platform: string | null;
          reason: string | null;
          region_id: string | null;
          retry_after: string | null;
          review_status: string;
          reviewed_at: string | null;
          score: number;
          status: string;
          status_at: string;
          suggest_count: number;
          updated_at: string;
          url: string;
          wikidata_id: string | null;
        };
        Insert: {
          country?: string | null;
          created_at?: string;
          empty_runs?: number;
          empty_since?: string | null;
          error_runs?: number;
          error_since?: string | null;
          feed_kind?: string | null;
          feed_url?: string | null;
          host: string;
          id?: string;
          last_ok_on?: string | null;
          last_probe_at?: string | null;
          locked?: boolean;
          name?: string | null;
          ok_days?: number;
          ok_runs?: number;
          origin: string;
          place_kind?: string | null;
          platform?: string | null;
          reason?: string | null;
          region_id?: string | null;
          retry_after?: string | null;
          review_status?: string;
          reviewed_at?: string | null;
          score?: number;
          status?: string;
          status_at?: string;
          suggest_count?: number;
          updated_at?: string;
          url: string;
          wikidata_id?: string | null;
        };
        Update: {
          country?: string | null;
          created_at?: string;
          empty_runs?: number;
          empty_since?: string | null;
          error_runs?: number;
          error_since?: string | null;
          feed_kind?: string | null;
          feed_url?: string | null;
          host?: string;
          id?: string;
          last_ok_on?: string | null;
          last_probe_at?: string | null;
          locked?: boolean;
          name?: string | null;
          ok_days?: number;
          ok_runs?: number;
          origin?: string;
          place_kind?: string | null;
          platform?: string | null;
          reason?: string | null;
          region_id?: string | null;
          retry_after?: string | null;
          review_status?: string;
          reviewed_at?: string | null;
          score?: number;
          status?: string;
          status_at?: string;
          suggest_count?: number;
          updated_at?: string;
          url?: string;
          wikidata_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "source_candidates_region_id_fkey";
            columns: ["region_id"];
            isOneToOne: false;
            referencedRelation: "collector_regions";
            referencedColumns: ["id"];
          },
        ];
      };
      source_discovery_gates: {
        Row: {
          counts: Json;
          created_at: string;
          expected: number;
          found: number;
          found_sites: string[];
          id: number;
          passed: boolean;
          probe_hash: string;
          region: string;
          required: number;
          run_id: string;
        };
        Insert: {
          counts?: Json;
          created_at?: string;
          expected: number;
          found: number;
          found_sites?: string[];
          id?: never;
          passed: boolean;
          probe_hash: string;
          region: string;
          required: number;
          run_id: string;
        };
        Update: {
          counts?: Json;
          created_at?: string;
          expected?: number;
          found?: number;
          found_sites?: string[];
          id?: never;
          passed?: boolean;
          probe_hash?: string;
          region?: string;
          required?: number;
          run_id?: string;
        };
        Relationships: [];
      };
      source_probe_results: {
        Row: {
          candidate_id: string;
          complete: boolean | null;
          created_at: string;
          errors: number | null;
          feed_kind: string | null;
          good: boolean;
          id: number;
          in_region: number | null;
          items: number | null;
          outcome: string;
          platform: string | null;
          requests: number | null;
          run_id: string;
          run_on: string;
        };
        Insert: {
          candidate_id: string;
          complete?: boolean | null;
          created_at?: string;
          errors?: number | null;
          feed_kind?: string | null;
          good?: boolean;
          id?: never;
          in_region?: number | null;
          items?: number | null;
          outcome: string;
          platform?: string | null;
          requests?: number | null;
          run_id: string;
          run_on?: string;
        };
        Update: {
          candidate_id?: string;
          complete?: boolean | null;
          created_at?: string;
          errors?: number | null;
          feed_kind?: string | null;
          good?: boolean;
          id?: never;
          in_region?: number | null;
          items?: number | null;
          outcome?: string;
          platform?: string | null;
          requests?: number | null;
          run_id?: string;
          run_on?: string;
        };
        Relationships: [
          {
            foreignKeyName: "source_probe_results_candidate_id_fkey";
            columns: ["candidate_id"];
            isOneToOne: false;
            referencedRelation: "source_candidates";
            referencedColumns: ["id"];
          },
        ];
      };
      stripe_events: {
        Row: {
          account: string | null;
          error: string | null;
          id: string;
          livemode: boolean;
          object_id: string | null;
          processed_at: string | null;
          received_at: string;
          type: string;
        };
        Insert: {
          account?: string | null;
          error?: string | null;
          id: string;
          livemode: boolean;
          object_id?: string | null;
          processed_at?: string | null;
          received_at?: string;
          type: string;
        };
        Update: {
          account?: string | null;
          error?: string | null;
          id?: string;
          livemode?: boolean;
          object_id?: string | null;
          processed_at?: string | null;
          received_at?: string;
          type?: string;
        };
        Relationships: [];
      };
      stripe_jobs: {
        Row: {
          amount_minor: number | null;
          attempts: number;
          booking_id: string | null;
          created_at: string;
          id: number;
          idempotency_key: string;
          last_error: string | null;
          next_at: string;
          op: string;
          status: string;
          stripe_account_id: string | null;
          updated_at: string;
        };
        Insert: {
          amount_minor?: number | null;
          attempts?: number;
          booking_id?: string | null;
          created_at?: string;
          id?: number;
          idempotency_key: string;
          last_error?: string | null;
          next_at?: string;
          op: string;
          status?: string;
          stripe_account_id?: string | null;
          updated_at?: string;
        };
        Update: {
          amount_minor?: number | null;
          attempts?: number;
          booking_id?: string | null;
          created_at?: string;
          id?: number;
          idempotency_key?: string;
          last_error?: string | null;
          next_at?: string;
          op?: string;
          status?: string;
          stripe_account_id?: string | null;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "stripe_jobs_booking_id_fkey";
            columns: ["booking_id"];
            isOneToOne: false;
            referencedRelation: "bookings";
            referencedColumns: ["id"];
          },
        ];
      };
      takedown_requests: {
        Row: {
          client_hash: string | null;
          contact_cleared_at: string | null;
          created_at: string;
          description: string;
          due_at: string;
          email_hash: string;
          good_faith: boolean;
          id: string;
          images_blocked: number;
          involves_minor: boolean;
          kind: string;
          locations: string;
          priority: number;
          reference: string;
          relationship: string;
          requester_email: string;
          requester_name: string;
          resolution_note: string;
          resolved_at: string | null;
          resolved_by: string | null;
          signature: string;
          status: string;
          target_user_id: string | null;
          updated_at: string;
        };
        Insert: {
          client_hash?: string | null;
          contact_cleared_at?: string | null;
          created_at?: string;
          description?: string;
          due_at: string;
          email_hash: string;
          good_faith: boolean;
          id?: string;
          images_blocked?: number;
          involves_minor?: boolean;
          kind?: string;
          locations: string;
          priority?: number;
          reference: string;
          relationship: string;
          requester_email: string;
          requester_name: string;
          resolution_note?: string;
          resolved_at?: string | null;
          resolved_by?: string | null;
          signature: string;
          status?: string;
          target_user_id?: string | null;
          updated_at?: string;
        };
        Update: {
          client_hash?: string | null;
          contact_cleared_at?: string | null;
          created_at?: string;
          description?: string;
          due_at?: string;
          email_hash?: string;
          good_faith?: boolean;
          id?: string;
          images_blocked?: number;
          involves_minor?: boolean;
          kind?: string;
          locations?: string;
          priority?: number;
          reference?: string;
          relationship?: string;
          requester_email?: string;
          requester_name?: string;
          resolution_note?: string;
          resolved_at?: string | null;
          resolved_by?: string | null;
          signature?: string;
          status?: string;
          target_user_id?: string | null;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "takedown_requests_resolved_by_fkey";
            columns: ["resolved_by"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "takedown_requests_target_user_id_fkey";
            columns: ["target_user_id"];
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
      venue_geocodes: {
        Row: {
          checked_at: string;
          confidence: number | null;
          expires_at: string;
          key: string;
          place_ref: string | null;
          point: unknown;
          provider: string;
          status: string;
        };
        Insert: {
          checked_at?: string;
          confidence?: number | null;
          expires_at: string;
          key: string;
          place_ref?: string | null;
          point?: unknown;
          provider: string;
          status: string;
        };
        Update: {
          checked_at?: string;
          confidence?: number | null;
          expires_at?: string;
          key?: string;
          place_ref?: string | null;
          point?: unknown;
          provider?: string;
          status?: string;
        };
        Relationships: [];
      };
      venues: {
        Row: {
          address_line1: string;
          address_line2: string;
          campus_id: string | null;
          city: string;
          country: string | null;
          created_at: string;
          created_by: string | null;
          id: string;
          is_public: boolean;
          lat: number | null;
          lng: number | null;
          location: unknown;
          name: string;
          place_id: string | null;
          place_ref: string | null;
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
          country?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          is_public?: boolean;
          lat?: number | null;
          lng?: number | null;
          location?: unknown;
          name: string;
          place_id?: string | null;
          place_ref?: string | null;
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
          country?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          is_public?: boolean;
          lat?: number | null;
          lng?: number | null;
          location?: unknown;
          name?: string;
          place_id?: string | null;
          place_ref?: string | null;
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
          {
            foreignKeyName: "venues_place_ref_fkey";
            columns: ["place_ref"];
            isOneToOne: false;
            referencedRelation: "places";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "venues_place_ref_fkey";
            columns: ["place_ref"];
            isOneToOne: false;
            referencedRelation: "places_odbl_export";
            referencedColumns: ["cursor_id"];
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
      places_odbl_export: {
        Row: {
          cursor_id: string | null;
          kind: string | null;
          lat: number | null;
          lng: number | null;
          name: string | null;
          opening_hours: string | null;
          osm_ref: string | null;
          source: string | null;
          tags: Json | null;
          website: string | null;
        };
        Insert: {
          cursor_id?: string | null;
          kind?: string | null;
          lat?: never;
          lng?: never;
          name?: string | null;
          opening_hours?: string | null;
          osm_ref?: string | null;
          source?: never;
          tags?: Json | null;
          website?: string | null;
        };
        Update: {
          cursor_id?: string | null;
          kind?: string | null;
          lat?: never;
          lng?: never;
          name?: string | null;
          opening_hours?: string | null;
          osm_ref?: string | null;
          source?: never;
          tags?: Json | null;
          website?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "places_kind_fkey";
            columns: ["kind"];
            isOneToOne: false;
            referencedRelation: "place_kinds";
            referencedColumns: ["slug"];
          },
        ];
      };
      source_kind_yield: {
        Row: {
          good: number | null;
          origin: string | null;
          place_kind: string | null;
          probed: number | null;
          rejected: number | null;
          waiting: number | null;
        };
        Relationships: [];
      };
    };
    Functions: {
      accept_coach_terms: { Args: { p_version: string }; Returns: Json };
      accept_guidelines: { Args: never; Returns: string };
      add_availability_exception: { Args: { p: Json }; Returns: string };
      add_group_members: {
        Args: { p_conversation: string; p_users: string[] };
        Returns: Json;
      };
      add_place: { Args: { p_args: Json }; Returns: Json };
      admin_set_moderator: {
        Args: { p_grant: boolean; p_note?: string; p_user: string };
        Returns: Json;
      };
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
      block_user: { Args: { p_user: string }; Returns: Json };
      booking_checkout_opened: {
        Args: {
          p_account: string;
          p_amount: number;
          p_booking: string;
          p_currency: string;
          p_fee: number;
          p_session_id: string;
        };
        Returns: Json;
      };
      booking_checkout_params: {
        Args: { p_booking: string; p_user: string };
        Returns: Json;
      };
      booking_dispute_update: {
        Args: { p_closed: boolean; p_payment_intent: string; p_status: string };
        Returns: string;
      };
      booking_mark_paid: {
        Args: {
          p_amount: number;
          p_booking: string;
          p_payment_intent: string;
          p_session_id: string;
        };
        Returns: string;
      };
      booking_payment_expired: {
        Args: { p_session_id: string };
        Returns: string;
      };
      booking_refund_recorded: {
        Args: { p_payment_intent: string; p_refunded_minor: number };
        Returns: string;
      };
      broadcast_to_event: {
        Args: { p_body: string; p_event_id: string };
        Returns: Json;
      };
      can_read_event: { Args: { p_event: string }; Returns: boolean };
      cancel_booking: {
        Args: { p_id: string; p_reason?: string };
        Returns: Json;
      };
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
          listing_kind: string;
          location_hint: string;
          members_only: boolean;
          min_age: number;
          min_headcount: number | null;
          moderated_at: string | null;
          moderation_state: string | null;
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
      cancel_group_session: { Args: { p_id: string }; Returns: Json };
      chapter_dashboard: {
        Args: { p_chapter: string; p_weeks?: number };
        Returns: Json;
      };
      chapter_public_card: { Args: { p_chapter: string }; Returns: Json };
      chapter_slug_for: { Args: { p_name: string }; Returns: string };
      chat_classifier_reserve: {
        Args: { p_operations: number; p_path: string };
        Returns: Json;
      };
      chat_classifier_settle: {
        Args: { p_month?: string; p_reserved: number; p_used: number };
        Returns: number;
      };
      chat_image_classified: {
        Args: {
          p_bucket: string;
          p_path: string;
          p_scores?: Json;
          p_verdict: string;
        };
        Returns: number;
      };
      chat_image_evidence_list: { Args: { p_limit?: number }; Returns: Json };
      chat_image_evidence_list_for: { Args: { p_user: string }; Returns: Json };
      chat_image_evidence_saved: {
        Args: { p_path: string; p_report: string };
        Returns: boolean;
      };
      chat_image_purge_list: { Args: { p_limit?: number }; Returns: Json };
      chat_list: {
        Args: {
          p_before?: string;
          p_before_id?: string;
          p_limit?: number;
          p_tab?: string;
        };
        Returns: {
          activity_at: string;
          closed: boolean;
          context: Json;
          conversation_id: string;
          kind: Database["public"]["Enums"]["conversation_kind"];
          last_message: Json;
          muted: boolean;
          other: Json;
          request: string;
          title: string;
          unread: number;
        }[];
      };
      chat_typing: { Args: { p_conversation: string }; Returns: undefined };
      chat_unread_total: { Args: never; Returns: Json };
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
      claim_pending_notifications: { Args: { p_limit?: number }; Returns: Json };
      clear_foreign_image_urls: { Args: never; Returns: Json };
      coach_payout_status: { Args: never; Returns: Json };
      coach_reviews_page: {
        Args: { p_before?: Json; p_coach: string; p_limit?: number };
        Returns: Json;
      };
      coach_slots: {
        Args: { p_from: string; p_listing: string; p_to: string };
        Returns: {
          ends_at: string;
          seats_left: number;
          starts_at: string;
        }[];
      };
      coach_stripe_close_blocked: {
        Args: { p_coach: string };
        Returns: boolean;
      };
      coaching_config: { Args: never; Returns: Json };
      coaching_tick: { Args: never; Returns: Json };
      collector_api_budget_cap: { Args: { p_api: string }; Returns: number };
      collector_api_budget_return: {
        Args: { p_api: string; p_calls: number; p_day: string };
        Returns: Json;
      };
      collector_api_budget_take: {
        Args: { p_api: string; p_calls: number };
        Returns: Json;
      };
      collector_api_shows_sweep: { Args: never; Returns: Json };
      collector_claims_due: { Args: { p_limit?: number }; Returns: Json };
      collector_claims_record: { Args: { p_results: Json }; Returns: Json };
      collector_denylist_remote: { Args: never; Returns: Json };
      collector_discovery_yield: { Args: never; Returns: Json };
      collector_geocode_queue: { Args: { p_limit?: number }; Returns: Json };
      collector_geocode_record: { Args: { p_results: Json }; Returns: Json };
      collector_health_alerts: { Args: never; Returns: number };
      collector_health_snapshot: { Args: never; Returns: Json };
      collector_host_denied: { Args: { p_host: string }; Returns: string };
      collector_ingest_events: {
        Args: {
          p_complete?: boolean;
          p_enable?: boolean;
          p_items: Json;
          p_run_id?: string;
          p_seen?: Json;
          p_source: Json;
        };
        Returns: Json;
      };
      collector_job_stale_after: { Args: { p_job: string }; Returns: string };
      collector_note_home_point: {
        Args: { p_label: string; p_old_point?: unknown; p_point: unknown };
        Returns: boolean;
      };
      collector_regions_due: {
        Args: { p_all?: boolean; p_limit?: number };
        Returns: Json;
      };
      collector_regions_record: { Args: { p_regions: Json }; Returns: Json };
      collector_runs_record: { Args: { p_run: Json }; Returns: Json };
      collector_shared_host: { Args: { p_host: string }; Returns: boolean };
      collector_sources_for_regions: {
        Args: { p_regions: string[] };
        Returns: Json;
      };
      collector_verify_secret: { Args: { p_secret: string }; Returns: boolean };
      complete_booking: { Args: { p_id: string }; Returns: Json };
      complete_notification_delivery: {
        Args: { p_devices?: Json; p_results: Json };
        Returns: number;
      };
      complete_onboarding: {
        Args: {
          p_area_id?: string;
          p_birth_date: string;
          p_campus_id?: string;
          p_first_name: string;
          p_handle: string;
          p_hub_ids: string[];
          p_label?: string;
          p_lat?: number;
          p_lng?: number;
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
          moderated_at: string | null;
          moderation_state: string | null;
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
      confirm_booking: { Args: { p_id: string }; Returns: Json };
      confirm_email_verification: {
        Args: { p_code: string; p_email?: string };
        Returns: Json;
      };
      connect_organizer_feed: {
        Args: { p_claim: string; p_lat?: number; p_lng?: number; p_url: string };
        Returns: Json;
      };
      contest_no_show: { Args: { p_id: string; p_note: string }; Returns: Json };
      conversation_info: { Args: { p_conversation: string }; Returns: Json };
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
          listing_kind: string;
          location_hint: string;
          members_only: boolean;
          min_age: number;
          min_headcount: number | null;
          moderated_at: string | null;
          moderation_state: string | null;
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
      create_group: {
        Args: { p_title: string; p_users: string[] };
        Returns: Json;
      };
      create_verification_code: {
        Args: { p_email: string; p_user_id: string };
        Returns: Json;
      };
      decline_booking: { Args: { p_id: string }; Returns: Json };
      default_address_visibility: {
        Args: { p_venue_id: string };
        Returns: Database["public"]["Enums"]["address_visibility"];
      };
      delete_message: { Args: { p_message: string }; Returns: undefined };
      delete_my_place: { Args: { p_place: string }; Returns: undefined };
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
      event_block_warning: { Args: { p_event: string }; Returns: number };
      event_drop_ineligible_rsvps: {
        Args: { p_event_id: string };
        Returns: number;
      };
      event_listing_kind_sync: {
        Args: { p_event_id: string };
        Returns: undefined;
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
      feed_event_area: { Args: { p_event_id: string }; Returns: unknown };
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
          listing_kind: string;
          location_hint: string;
          members_only: boolean;
          min_age: number;
          min_headcount: number | null;
          moderated_at: string | null;
          moderation_state: string | null;
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
          p_listing_kind?: string;
          p_lng?: number;
          p_radius_km?: number;
          p_timezone?: string;
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
      feed_source_withdraw: {
        Args: { p_mode: string; p_reason?: string; p_source: string };
        Returns: number;
      };
      finish_place_tile: {
        Args: {
          p_allow_drop?: boolean;
          p_count: number;
          p_run_id: string;
          p_source?: string;
          p_tile_id: number;
        };
        Returns: Json;
      };
      generate_handle: { Args: { p_email: string }; Returns: string };
      get_booking: { Args: { p_id: string }; Returns: Json };
      get_coach: { Args: { p_handle: string }; Returns: Json };
      get_messages: {
        Args: {
          p_after_seq?: number;
          p_before_seq?: number;
          p_conversation: string;
          p_limit?: number;
        };
        Returns: {
          author: Json;
          body: string;
          client_id: string;
          created_at: string;
          deleted: string;
          hidden: boolean;
          id: string;
          image: Json;
          kind: string;
          mine: boolean;
          seq: number;
        }[];
      };
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
      image_block_hash: {
        Args: {
          p_dhash: number;
          p_phash: number;
          p_request: string;
          p_sha256: string;
        };
        Returns: string;
      };
      image_block_matches: {
        Args: { p_blocked: string; p_moderator?: string };
        Returns: number;
      };
      image_block_row: {
        Args: { p_blocked: string; p_image: string; p_moderator?: string };
        Returns: number;
      };
      image_clear_references: {
        Args: { p_bucket: string; p_path: string };
        Returns: number;
      };
      image_guard_dispatch: { Args: { p_body: Json }; Returns: number };
      image_guard_mark_purged: { Args: { p_ids: string[] }; Returns: number };
      image_guard_purge_list: { Args: { p_limit?: number }; Returns: Json };
      image_guard_record: {
        Args: {
          p_bucket: string;
          p_dhash?: string;
          p_path: string;
          p_phash?: string;
          p_sha256?: string;
          p_status: string;
        };
        Returns: Json;
      };
      image_guard_tick: { Args: never; Returns: Json };
      image_guard_verify_secret: {
        Args: { p_secret: string };
        Returns: boolean;
      };
      image_hash_close: {
        Args: {
          p_dhash_a: number;
          p_dhash_b: number;
          p_phash_a: number;
          p_phash_b: number;
        };
        Returns: boolean;
      };
      image_hash_from_hex: { Args: { p_hex: string }; Returns: number };
      image_owner_from_path: { Args: { p_path: string }; Returns: string };
      import_clip: { Args: { p_max: number; p_text: string }; Returns: string };
      import_dispatch: { Args: { p_slug: string }; Returns: number };
      import_dispatch_all: { Args: never; Returns: Json };
      import_is_21_plus: { Args: { p_text: string }; Returns: boolean };
      import_location_key: {
        Args: { p_location: string; p_region_point: unknown };
        Returns: string;
      };
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
      import_title_key: { Args: { p_title: string }; Returns: string };
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
          geocode_provider: string;
          homepage_url: string;
          host_org: string;
          item_label: string;
          open_to_public: boolean;
          organizer_listed: boolean;
          source_kind: string;
          source_name: string;
          source_slug: string;
        }[];
      };
      ingest_places: {
        Args: {
          p_batch: Json;
          p_batch_no?: number;
          p_run_id: string;
          p_source?: string;
          p_tile_id: number;
        };
        Returns: Json;
      };
      is_campus_org_member: { Args: { p_campus: string }; Returns: boolean };
      is_chapter_captain: { Args: { p_chapter: string }; Returns: boolean };
      is_moderator: { Args: never; Returns: boolean };
      is_own_storage_url: {
        Args: { p_bucket?: string; p_owner?: string; p_url: string };
        Returns: boolean;
      };
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
      leave_conversation: {
        Args: { p_conversation: string };
        Returns: undefined;
      };
      map_in_view: {
        Args: {
          p_east: number;
          p_files?: boolean;
          p_from?: string;
          p_generic?: boolean;
          p_hub_ids?: string[];
          p_layers?: string[];
          p_limit?: number;
          p_north: number;
          p_south: number;
          p_to?: string;
          p_west: number;
        };
        Returns: Json;
      };
      map_view_box: {
        Args: {
          p_east: number;
          p_north: number;
          p_south: number;
          p_west: number;
        };
        Returns: Record<string, unknown>;
      };
      map_view_hubs: { Args: { p_hub_ids: string[] }; Returns: string[] };
      mark_conversation_read: {
        Args: { p_conversation: string; p_seq: number };
        Returns: undefined;
      };
      mark_no_show: { Args: { p_id: string }; Returns: Json };
      mark_notifications_read: { Args: { p_ids?: string[] }; Returns: number };
      materialize_all_event_series: {
        Args: { p_weeks?: number };
        Returns: number;
      };
      materialize_event_series: {
        Args: { p_series_id: string; p_weeks?: number };
        Returns: number;
      };
      meeting_spot_refresh: { Args: { p_venue_id: string }; Returns: undefined };
      meeting_spot_sync_place: {
        Args: { p_place_id: string };
        Returns: undefined;
      };
      mod_ban_user: { Args: { p_note?: string; p_user: string }; Returns: Json };
      mod_booking: {
        Args: { p_action: string; p_id: string; p_note?: string };
        Returns: Json;
      };
      mod_chat_image: {
        Args: { p_decision: string; p_message: string; p_note?: string };
        Returns: Json;
      };
      mod_chat_image_queue: { Args: { p_limit?: number }; Returns: Json };
      mod_coaching_numbers: { Args: never; Returns: Json };
      mod_collector_health: { Args: never; Returns: Json };
      mod_listing_removal_queue: {
        Args: { p_closed?: boolean; p_limit?: number };
        Returns: Json;
      };
      mod_listing_removal_resolve: {
        Args: { p_action: string; p_note?: string; p_request: string };
        Returns: Json;
      };
      mod_lookup_log: { Args: { p_limit?: number }; Returns: Json };
      mod_message_evidence: { Args: { p_report: string }; Returns: Json };
      mod_moderate: {
        Args: {
          p_action: string;
          p_id: string;
          p_kind: string;
          p_note?: string;
        };
        Returns: Json;
      };
      mod_organizer_claim_review: {
        Args: { p_action: string; p_claim: string; p_note?: string };
        Returns: Json;
      };
      mod_organizer_claims: {
        Args: { p_closed?: boolean; p_limit?: number };
        Returns: Json;
      };
      mod_place_facts: { Args: { p_id: string }; Returns: Json };
      mod_place_health: { Args: never; Returns: Json };
      mod_place_queue: { Args: { p_limit?: number }; Returns: Json };
      mod_queue: { Args: { p_limit?: number }; Returns: Json };
      mod_report_queue: { Args: { p_limit?: number }; Returns: Json };
      mod_resolve_place: {
        Args: {
          p_action: string;
          p_id: string;
          p_kind: string;
          p_note?: string;
        };
        Returns: Json;
      };
      mod_review_source_candidate: {
        Args: { p_approve: boolean; p_id: string; p_reason?: string };
        Returns: Json;
      };
      mod_scorecard: { Args: never; Returns: Json };
      mod_set_coach_status: {
        Args: { p_note?: string; p_status: string; p_user: string };
        Returns: Json;
      };
      mod_sla_hours: { Args: { p_source: string }; Returns: number };
      mod_takedown_block_image: {
        Args: { p_image_url: string; p_request: string };
        Returns: Json;
      };
      mod_takedown_queue: {
        Args: { p_closed?: boolean; p_limit?: number };
        Returns: Json;
      };
      mod_takedown_resolve: {
        Args: {
          p_action: string;
          p_note?: string;
          p_request: string;
          p_target_user?: string;
        };
        Returns: Json;
      };
      mod_team: { Args: never; Returns: Json };
      mod_unban_user: {
        Args: { p_note?: string; p_user: string };
        Returns: Json;
      };
      mod_user_lookup: { Args: { p_user: string }; Returns: Json };
      mod_user_search: { Args: { p_query: string }; Returns: Json };
      moderation_is_own: {
        Args: { p_id: string; p_kind: string; p_target_user: string };
        Returns: boolean;
      };
      moderation_set_state: {
        Args: { p_id: string; p_kind: string; p_state: string };
        Returns: string;
      };
      mute_conversation: {
        Args: { p_conversation: string; p_until: string };
        Returns: undefined;
      };
      mute_user: { Args: { p_user: string }; Returns: Json };
      my_blocks: {
        Args: never;
        Returns: {
          avatar_url: string;
          blocked_at: string;
          first_name: string;
          handle: string;
          user_id: string;
        }[];
      };
      my_bookings: {
        Args: {
          p_before?: Json;
          p_limit?: number;
          p_role: string;
          p_scope: string;
        };
        Returns: Json;
      };
      my_bookings_with: { Args: { p_user: string }; Returns: Json };
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
      my_organizer_claims: { Args: never; Returns: Json };
      my_recommendation_prefs: { Args: never; Returns: Json };
      notification_event_payload: {
        Args: { p_event_id: string };
        Returns: Json;
      };
      notification_quiet_until: {
        Args: { p_at?: string; p_user_id: string };
        Returns: string;
      };
      notification_unsubscribe_token: {
        Args: { p_user_id: string };
        Returns: string;
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
      notify_vault_secret: { Args: { p_name: string }; Returns: string };
      notify_worker_dispatch: { Args: { p_force?: boolean }; Returns: number };
      notify_worker_verify_secret: {
        Args: { p_secret: string };
        Returns: boolean;
      };
      open_chapter_chat: { Args: { p_chapter: string }; Returns: Json };
      open_event_chat: { Args: { p_event: string }; Returns: Json };
      open_hub_chat: { Args: { p_hub: string }; Returns: Json };
      organizer_claim_apply: { Args: { p_claim: string }; Returns: undefined };
      organizer_claim_check: { Args: { p_claim: string }; Returns: Json };
      organizer_claim_proofs: {
        Args: { p_host: string; p_token: string };
        Returns: Json;
      };
      organizer_claim_target: { Args: { p_event: string }; Returns: Json };
      organizer_eventbrite_sources: {
        Args: { p_limit?: number };
        Returns: Json;
      };
      organizer_eventbrite_store: {
        Args: { p_token: string; p_user: string };
        Returns: Json;
      };
      organizer_oauth_start: {
        Args: { p_state_hash: string; p_user: string };
        Returns: Json;
      };
      organizer_oauth_take: {
        Args: { p_state_hash: string; p_user: string };
        Returns: boolean;
      };
      organizer_region_for: { Args: { p_point: unknown }; Returns: string };
      organizer_source_detail: { Args: { p_source: string }; Returns: Json };
      organizer_source_update: {
        Args: { p_args: Json; p_source: string };
        Returns: Json;
      };
      organizer_token: { Args: never; Returns: string };
      pause_coach_profile: { Args: never; Returns: Json };
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
      people_you_met: {
        Args: { p_before?: string; p_before_id?: string; p_limit?: number };
        Returns: {
          avatar_url: string;
          can_message: boolean;
          first_name: string;
          handle: string;
          last_plan: Json;
          user_id: string;
        }[];
      };
      place_apply_changes: {
        Args: {
          p_changes: Json;
          p_lock: boolean;
          p_place: string;
          p_via: string;
        };
        Returns: undefined;
      };
      place_caller_can_see: { Args: { p_id: string }; Returns: boolean };
      place_check_hubs: {
        Args: { p_default: boolean; p_hubs: Json; p_kind: string };
        Returns: string[];
      };
      place_clean_changes: { Args: { p_changes: Json }; Returns: Json };
      place_detail: { Args: { p_id: string }; Returns: Json };
      place_duplicates: {
        Args: {
          p_exclude?: string;
          p_kind: string;
          p_name: string;
          p_point: unknown;
        };
        Returns: Json;
      };
      place_file_at: { Args: { p_lat: number; p_lng: number }; Returns: Json };
      place_file_of_tile: { Args: { p_tile: number }; Returns: Json };
      place_file_request_take: { Args: { p_user_id: string }; Returns: Json };
      place_files_in_view: {
        Args: { p_env1: unknown; p_env2: unknown };
        Returns: Json;
      };
      place_files_queue: {
        Args: { p_all?: boolean; p_limit?: number; p_tiles?: number[] };
        Returns: Json;
      };
      place_files_record: { Args: { p: Json }; Returns: Json };
      place_from_file: {
        Args: { p_row: Json; p_sha256: string; p_tile: number };
        Returns: string;
      };
      place_id_by_osm_ref: { Args: { p_osm_ref: string }; Returns: string };
      place_is_mine: { Args: { p_id: string }; Returns: boolean };
      place_match_dispatch: { Args: { p_force?: boolean }; Returns: number };
      place_match_queue: { Args: { p_limit?: number }; Returns: Json };
      place_match_record: { Args: { p_results: Json }; Returns: Json };
      place_near_private: {
        Args: { p_point: unknown; p_uid: string };
        Returns: string;
      };
      place_raise_near: { Args: { p_why: string }; Returns: undefined };
      place_rate_log_prune: { Args: never; Returns: number };
      place_size_status: { Args: never; Returns: Json };
      place_tile_bbox: { Args: { p_id: number }; Returns: unknown };
      place_tile_file_page: {
        Args: { p_after?: string; p_limit?: number; p_tile_id: number };
        Returns: Json;
      };
      place_tile_id: { Args: { p_lat: number; p_lng: number }; Returns: number };
      place_tile_id_of: { Args: { p_point: unknown }; Returns: number };
      place_tile_note_home: {
        Args: { p_old_point?: unknown; p_point: unknown };
        Returns: number;
      };
      place_tiles_mapping_in_view: {
        Args: { p_env1: unknown; p_env2: unknown };
        Returns: boolean;
      };
      place_tiles_mapping_reason_in_view: {
        Args: { p_env1: unknown; p_env2: unknown };
        Returns: string;
      };
      place_tiles_note_member_homes: { Args: never; Returns: Json };
      place_tiles_queue: {
        Args: { p_kinds?: string[]; p_limit?: number };
        Returns: Json;
      };
      place_tiles_set_queue_reasons: {
        Args: { p_reasons: Json };
        Returns: Json;
      };
      places_fill_dispatch: {
        Args: { p_force?: boolean; p_reason?: string };
        Returns: number;
      };
      places_fill_plan: { Args: { p_limit?: number }; Returns: Json };
      places_fill_release: { Args: { p_tile_id: number }; Returns: boolean };
      places_fill_spend: { Args: { p_credits: number }; Returns: number };
      places_fill_supersede: { Args: never; Returns: number };
      places_fill_tick: { Args: never; Returns: Json };
      places_in_view: {
        Args: {
          p_east: number;
          p_generic?: boolean;
          p_hub_ids?: string[];
          p_kinds?: string[];
          p_limit?: number;
          p_north: number;
          p_query?: string;
          p_skip_since?: string;
          p_skip_tiles?: number[];
          p_south: number;
          p_west: number;
        };
        Returns: Json;
      };
      places_odbl_page: {
        Args: { p_after?: string; p_limit?: number };
        Returns: Json;
      };
      places_own_in_view: {
        Args: { p_env1: unknown; p_env2: unknown };
        Returns: string[];
      };
      project_url: { Args: never; Returns: string };
      public_week_near: {
        Args: { p_lat?: number; p_limit?: number; p_lng?: number };
        Returns: {
          distance_band: string;
          going_bucket: string;
          hub: Json;
          id: string;
          is_free: boolean;
          is_imported: boolean;
          price_text: string;
          source_name: string;
          starts_at: string;
          timezone: string;
          title: string;
        }[];
      };
      publish_coach_profile: { Args: never; Returns: Json };
      purge_account_deletions: { Args: never; Returns: number };
      purge_admin_lookups: { Args: never; Returns: number };
      purge_coaching: { Args: never; Returns: Json };
      purge_listing_removal_contacts: { Args: never; Returns: number };
      purge_messaging: { Args: never; Returns: Json };
      purge_read_notifications: { Args: never; Returns: number };
      purge_recs: { Args: never; Returns: Json };
      purge_takedown_contacts: { Args: never; Returns: number };
      push_endpoint_allowed: { Args: { p_endpoint: string }; Returns: boolean };
      rec_dismiss: {
        Args: {
          p_id: string;
          p_kind: Database["public"]["Enums"]["rec_subject_kind"];
        };
        Returns: undefined;
      };
      rec_undismiss: {
        Args: {
          p_id: string;
          p_kind: Database["public"]["Enums"]["rec_subject_kind"];
        };
        Returns: undefined;
      };
      record_place_dump: {
        Args: {
          p_bytes: number;
          p_counts?: Json;
          p_month: string;
          p_published: boolean;
          p_rows: number;
          p_sha256: string;
        };
        Returns: Json;
      };
      recs_backfill: {
        Args: { p_kind?: Database["public"]["Enums"]["rec_subject_kind"] };
        Returns: number;
      };
      recs_coaches: {
        Args: {
          p_lat?: number;
          p_limit?: number;
          p_lng?: number;
          p_radius_km?: number;
        };
        Returns: {
          area_label: string;
          avatar_url: string;
          completed_count: number;
          distance_band: string;
          first_name: string;
          from_currency: string;
          from_price_minor: number;
          handle: string;
          headline: string;
          hub_ids: string[];
          in_person: boolean;
          online: boolean;
          rank: number;
          rating_avg: number;
          rating_count: number;
          reasons: Json;
          user_id: string;
        }[];
      };
      recs_embed_claim: {
        Args: { p_limit?: number };
        Returns: {
          content_hash: string;
          subject_id: string;
          subject_kind: Database["public"]["Enums"]["rec_subject_kind"];
          text: string;
        }[];
      };
      recs_embed_dispatch: { Args: never; Returns: number };
      recs_embed_fail: {
        Args: {
          p_error: string;
          p_id: string;
          p_kind: Database["public"]["Enums"]["rec_subject_kind"];
        };
        Returns: undefined;
      };
      recs_embed_record: { Args: { p_rows: Json }; Returns: number };
      recs_embed_verify_secret: { Args: { p_secret: string }; Returns: boolean };
      recs_for_you: {
        Args: {
          p_lat?: number;
          p_limit?: number;
          p_lng?: number;
          p_radius_km?: number;
          p_timezone?: string;
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
          rank: number;
          reasons: Json;
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
      recs_hubs: {
        Args: {
          p_lat?: number;
          p_limit?: number;
          p_lng?: number;
          p_radius_km?: number;
        };
        Returns: {
          category_slug: string;
          emoji: string;
          id: string;
          member_count: number;
          name: string;
          nearby_plans: number;
          rank: number;
          reasons: Json;
          slug: string;
        }[];
      };
      recs_people: {
        Args: { p_limit?: number };
        Returns: {
          avatar_url: string;
          first_name: string;
          handle: string;
          rank: number;
          reasons: Json;
          user_id: string;
        }[];
      };
      recs_similar_events: {
        Args: {
          p_event_id: string;
          p_lat?: number;
          p_limit?: number;
          p_lng?: number;
          p_radius_km?: number;
          p_timezone?: string;
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
          rank: number;
          reasons: Json;
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
      recs_status: { Args: never; Returns: Json };
      recs_taste_refresh: { Args: { p_limit?: number }; Returns: number };
      recs_tick: { Args: never; Returns: Json };
      refresh_hub_stats: { Args: never; Returns: number };
      refresh_meeting_spots: { Args: never; Returns: number };
      register_push_device: {
        Args: {
          p_app_version?: string;
          p_subscription: Json;
          p_user_agent?: string;
        };
        Returns: string;
      };
      registrable_domain: { Args: { p_host: string }; Returns: string };
      remove_availability_exception: {
        Args: { p_id: string };
        Returns: boolean;
      };
      remove_chapter_member: {
        Args: { p_chapter: string; p_user: string };
        Returns: undefined;
      };
      remove_conversation_member: {
        Args: { p_conversation: string; p_user: string };
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
      rename_group: {
        Args: { p_conversation: string; p_title: string };
        Returns: undefined;
      };
      reply_to_review: {
        Args: { p_booking: string; p_text: string };
        Returns: Json;
      };
      report_coach_no_show: { Args: { p_id: string }; Returns: Json };
      report_content: {
        Args: {
          p_id: string;
          p_kind: string;
          p_note?: string;
          p_reason: string;
        };
        Returns: Json;
      };
      report_place: {
        Args: { p_note?: string; p_place: string; p_reason: string };
        Returns: Json;
      };
      request_account_deletion: {
        Args: { p_reason?: string };
        Returns: undefined;
      };
      request_booking: {
        Args: {
          p_client_request_id: string;
          p_listing: string;
          p_note: string;
          p_policy_version: string;
          p_starts_at: string;
        };
        Returns: Json;
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
      respond_message_request: {
        Args: { p_action: string; p_conversation: string };
        Returns: undefined;
      };
      retire_place_tiles: { Args: never; Returns: Json };
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
      schedule_group_session: {
        Args: { p_listing: string; p_starts_at: string };
        Returns: string;
      };
      scorecard_dispatch: { Args: never; Returns: number };
      scorecard_record: {
        Args: {
          p_counts: Json;
          p_error?: string;
          p_status: string;
          p_week_start: string;
        };
        Returns: Json;
      };
      scorecard_run_state: { Args: { p_week_start?: string }; Returns: Json };
      scorecard_verify_secret: { Args: { p_secret: string }; Returns: boolean };
      scorecard_week: { Args: { p_week_start?: string }; Returns: Json };
      search_coaches: {
        Args: {
          p_before?: Json;
          p_currency?: string;
          p_delivery?: Database["public"]["Enums"]["listing_delivery"];
          p_hub_id?: string;
          p_lat?: number;
          p_limit?: number;
          p_lng?: number;
          p_max_price_minor?: number;
          p_query?: string;
          p_radius_km?: number;
        };
        Returns: {
          area_label: string;
          avatar_url: string;
          completed_count: number;
          distance_band: string;
          first_name: string;
          from_currency: string;
          from_price_minor: number;
          handle: string;
          headline: string;
          hub_ids: string[];
          in_person: boolean;
          online: boolean;
          page_key: Json;
          rating_avg: number;
          rating_count: number;
          user_id: string;
        }[];
      };
      send_message: {
        Args: {
          p_body: string;
          p_client_id: string;
          p_conversation: string;
          p_image_path?: string;
        };
        Returns: Json;
      };
      set_availability: { Args: { p_rules: Json }; Returns: number };
      set_booking_meeting: {
        Args: { p_id: string; p_link: string; p_note: string };
        Returns: Json;
      };
      set_chapter_role: {
        Args: {
          p_chapter: string;
          p_role: Database["public"]["Enums"]["chapter_role"];
          p_user: string;
        };
        Returns: undefined;
      };
      set_coach_credentials: { Args: { p: Json }; Returns: number };
      set_coach_hubs: { Args: { p_hub_ids: string[] }; Returns: number };
      set_coach_photos: { Args: { p_urls: string[] }; Returns: number };
      set_conversation_notify: {
        Args: { p_conversation: string; p_notify: boolean };
        Returns: undefined;
      };
      set_conversation_role: {
        Args: {
          p_conversation: string;
          p_role: Database["public"]["Enums"]["conversation_role"];
          p_user: string;
        };
        Returns: undefined;
      };
      set_home_area: {
        Args: { p_area_id: string; p_radius_km?: number };
        Returns: Json;
      };
      set_home_location: {
        Args: {
          p_label?: string;
          p_lat: number;
          p_lng: number;
          p_radius_km?: number;
        };
        Returns: Json;
      };
      set_listing_status: {
        Args: {
          p_id: string;
          p_status: Database["public"]["Enums"]["listing_status"];
        };
        Returns: Json;
      };
      set_my_place_visibility: {
        Args: { p_confirm?: boolean; p_place: string; p_public: boolean };
        Returns: Json;
      };
      set_my_timezone: { Args: { p_timezone: string }; Returns: Json };
      set_project_url: { Args: { p_url: string }; Returns: Json };
      set_recommendation_prefs: {
        Args: { p_people_suggestions?: boolean; p_personalize?: boolean };
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
      shows_available: { Args: never; Returns: boolean };
      source_candidate_slug: { Args: { p_id: string }; Returns: string };
      source_candidates_add: { Args: { p_candidates: Json }; Returns: Json };
      source_candidates_due: {
        Args: { p_limit?: number; p_regions?: string[] };
        Returns: Json;
      };
      source_candidates_record: { Args: { p_results: Json }; Returns: Json };
      source_candidates_rescore: {
        Args: { p_dry_run?: boolean; p_region: string; p_scores: Json };
        Returns: Json;
      };
      source_discovery_allowed:
        | { Args: { p_country: string; p_origin: string }; Returns: boolean }
        | {
            Args: { p_country: string; p_origin: string; p_region: string };
            Returns: boolean;
          };
      source_discovery_gate_min_required: { Args: never; Returns: number };
      source_discovery_gate_open: {
        Args: { p_probe_hash: string };
        Returns: boolean;
      };
      source_discovery_gate_record: { Args: { p_gate: Json }; Returns: Json };
      source_discovery_gate_status: {
        Args: { p_probe_hash: string };
        Returns: Json;
      };
      source_discovery_probe_queue: {
        Args: {
          p_limit?: number;
          p_per_region?: number;
          p_probe_hash: string;
          p_regions?: string[];
        };
        Returns: Json;
      };
      source_discovery_regions_due: {
        Args: { p_limit?: number };
        Returns: Json;
      };
      source_discovery_regions_record: { Args: { p_ids: Json }; Returns: Json };
      source_discovery_zone_needs_country: {
        Args: { p_tz: string };
        Returns: boolean;
      };
      source_kind_learned_yield: { Args: { p_kind: string }; Returns: number };
      source_url_check: { Args: { p_url: string }; Returns: Json };
      source_url_host: { Args: { p_url: string }; Returns: string };
      start_dm: { Args: { p_user: string }; Returns: Json };
      start_organizer_claim: {
        Args: {
          p_event?: string;
          p_feed_url?: string;
          p_host?: string;
          p_method?: string;
          p_source?: string;
        };
        Returns: Json;
      };
      storage_object_from_url: {
        Args: { p_url: string };
        Returns: Record<string, unknown>;
      };
      stripe_account_closed: { Args: { p_account: string }; Returns: boolean };
      stripe_account_sync: {
        Args: { p: Json; p_account: string };
        Returns: boolean;
      };
      stripe_account_upsert: {
        Args: { p: Json; p_coach: string };
        Returns: Json;
      };
      stripe_checkout_heartbeat: { Args: never; Returns: undefined };
      stripe_connect_context: { Args: { p_user: string }; Returns: Json };
      stripe_dispatch: { Args: never; Returns: number };
      stripe_dispatch_verify_secret: {
        Args: { p_secret: string };
        Returns: boolean;
      };
      stripe_event_begin: {
        Args: {
          p_account: string;
          p_id: string;
          p_livemode: boolean;
          p_object: string;
          p_type: string;
        };
        Returns: string;
      };
      stripe_event_finish: {
        Args: { p_error?: string; p_id: string };
        Returns: undefined;
      };
      stripe_job_done: {
        Args: { p_error?: string; p_id: number; p_ok: boolean };
        Returns: string;
      };
      stripe_jobs_claim: { Args: { p_limit?: number }; Returns: Json };
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
      submit_listing_removal: {
        Args: {
          p_client_hash?: string;
          p_email: string;
          p_event: string;
          p_name: string;
          p_reason: string;
          p_relationship: string;
          p_scope: string;
          p_url: string;
        };
        Returns: Json;
      };
      submit_takedown_request: {
        Args: {
          p_client_hash?: string;
          p_description?: string;
          p_email: string;
          p_good_faith: boolean;
          p_involves_minor?: boolean;
          p_locations: string;
          p_name: string;
          p_relationship: string;
          p_signature: string;
        };
        Returns: Json;
      };
      suggest_calendar: { Args: { p_url: string }; Returns: Json };
      suggest_place_edit: {
        Args: { p_changes: Json; p_note?: string; p_place: string };
        Returns: Json;
      };
      touch_last_seen: { Args: never; Returns: undefined };
      unblock_user: { Args: { p_user: string }; Returns: Json };
      unmute_user: { Args: { p_user: string }; Returns: Json };
      unread_notification_count: { Args: never; Returns: number };
      unregister_push_device: { Args: { p_endpoint: string }; Returns: boolean };
      unsubscribe_email_with_token: { Args: { p_token: string }; Returns: Json };
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
          listing_kind: string;
          location_hint: string;
          members_only: boolean;
          min_age: number;
          min_headcount: number | null;
          moderated_at: string | null;
          moderation_state: string | null;
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
      upsert_coach_profile: { Args: { p: Json }; Returns: Json };
      upsert_listing: { Args: { p: Json }; Returns: Json };
      upsert_venue: {
        Args: { p_args: Json };
        Returns: {
          address_line1: string;
          address_line2: string;
          campus_id: string | null;
          city: string;
          country: string | null;
          created_at: string;
          created_by: string | null;
          id: string;
          is_public: boolean;
          lat: number | null;
          lng: number | null;
          location: unknown;
          name: string;
          place_id: string | null;
          place_ref: string | null;
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
      users_blocked: { Args: { p_a: string; p_b: string }; Returns: boolean };
      venue_for_place: {
        Args: { p_place_id: string };
        Returns: {
          address_line1: string;
          address_line2: string;
          campus_id: string | null;
          city: string;
          country: string | null;
          created_at: string;
          created_by: string | null;
          id: string;
          is_public: boolean;
          lat: number | null;
          lng: number | null;
          location: unknown;
          name: string;
          place_id: string | null;
          place_ref: string | null;
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
      venue_preview_for_place: { Args: { p_place_id: string }; Returns: Json };
      viewer_age: { Args: never; Returns: number };
      viewer_can_manage: {
        Args: { p_chapter: string; p_host: string; p_min_age: number };
        Returns: boolean;
      };
      viewer_can_manage_event: {
        Args: { p_event_id: string };
        Returns: boolean;
      };
      viewer_has_rsvp: { Args: { p_event: string }; Returns: boolean };
      viewer_is_adult: { Args: never; Returns: boolean };
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
      write_review: {
        Args: { p_body: string; p_booking: string; p_rating: number };
        Returns: Json;
      };
    };
    Enums: {
      account_status: "active" | "suspended" | "banned" | "deleted";
      address_visibility: "public" | "approved_only";
      app_role: "moderator" | "admin";
      booking_payment_state:
        | "none"
        | "off_platform"
        | "due"
        | "processing"
        | "paid"
        | "refund_pending"
        | "partially_refunded"
        | "refunded"
        | "disputed"
        | "failed";
      booking_status:
        "requested" | "confirmed" | "declined" | "expired" | "cancelled" | "completed" | "no_show";
      chapter_claim_status: "pending" | "approved" | "rejected" | "withdrawn";
      chapter_role: "member" | "captain" | "organizer";
      coach_session_status: "scheduled" | "cancelled" | "done";
      coach_status: "draft" | "active" | "paused" | "suspended";
      conversation_kind: "dm" | "group" | "event" | "hub" | "chapter";
      conversation_role: "owner" | "admin" | "member";
      device_platform: "web" | "ios" | "android";
      event_kind: "member" | "chapter" | "imported";
      event_status: "published" | "cancelled";
      event_visibility: "public" | "campus";
      listing_delivery: "in_person" | "online";
      listing_format: "one_on_one" | "group";
      listing_status: "active" | "paused" | "archived";
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
        | "chapter_claim_update"
        | "blocked_attendee"
        | "message"
        | "message_request"
        | "booking_requested"
        | "booking_confirmed"
        | "booking_declined"
        | "booking_cancelled"
        | "booking_payment_due"
        | "booking_reminder_day"
        | "booking_reminder_2h"
        | "booking_review_prompt"
        | "booking_no_show"
        | "review_received"
        | "review_reply"
        | "coach_payout_action"
        | "collector_alert";
      org_kind: "university" | "company" | "community";
      org_role: "member" | "officer" | "admin";
      place_source: "osm" | "geoapify" | "user" | "venue";
      place_status: "active" | "pending" | "hidden" | "closed" | "removed";
      place_tile_status: "wanted" | "filling" | "active" | "idle" | "retired";
      rec_subject_kind: "hub" | "event" | "coach" | "person";
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
      booking_payment_state: [
        "none",
        "off_platform",
        "due",
        "processing",
        "paid",
        "refund_pending",
        "partially_refunded",
        "refunded",
        "disputed",
        "failed",
      ],
      booking_status: [
        "requested",
        "confirmed",
        "declined",
        "expired",
        "cancelled",
        "completed",
        "no_show",
      ],
      chapter_claim_status: ["pending", "approved", "rejected", "withdrawn"],
      chapter_role: ["member", "captain", "organizer"],
      coach_session_status: ["scheduled", "cancelled", "done"],
      coach_status: ["draft", "active", "paused", "suspended"],
      conversation_kind: ["dm", "group", "event", "hub", "chapter"],
      conversation_role: ["owner", "admin", "member"],
      device_platform: ["web", "ios", "android"],
      event_kind: ["member", "chapter", "imported"],
      event_status: ["published", "cancelled"],
      event_visibility: ["public", "campus"],
      listing_delivery: ["in_person", "online"],
      listing_format: ["one_on_one", "group"],
      listing_status: ["active", "paused", "archived"],
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
        "blocked_attendee",
        "message",
        "message_request",
        "booking_requested",
        "booking_confirmed",
        "booking_declined",
        "booking_cancelled",
        "booking_payment_due",
        "booking_reminder_day",
        "booking_reminder_2h",
        "booking_review_prompt",
        "booking_no_show",
        "review_received",
        "review_reply",
        "coach_payout_action",
        "collector_alert",
      ],
      org_kind: ["university", "company", "community"],
      org_role: ["member", "officer", "admin"],
      place_source: ["osm", "geoapify", "user", "venue"],
      place_status: ["active", "pending", "hidden", "closed", "removed"],
      place_tile_status: ["wanted", "filling", "active", "idle", "retired"],
      rec_subject_kind: ["hub", "event", "coach", "person"],
      rsvp_status: ["going", "interested", "waitlisted", "cancelled"],
    },
  },
} as const;
