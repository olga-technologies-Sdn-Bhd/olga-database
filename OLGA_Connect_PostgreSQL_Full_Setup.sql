/*
OLGA Connect Release 1 - PostgreSQL full database setup
Architecture baseline: Database Architecture and Table-Level Design v2.3 + auditability hardening v2.4
Implementation baseline: MVP Architecture Implementation Guide v1.0
Target: a new, empty PostgreSQL 17 database

This transactional script never drops product tables. Provisional QA notification-policy
seeding remains fail-closed until product and security approve it.
*/
-- ======================== SCHEMAS AND SEQUENCES ========================
BEGIN;

-- Serialize schema deployments even if two external pipelines are started.
SELECT pg_advisory_xact_lock(hashtextextended('olga_schema_migration', 0));

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'olga_ddl_admin') THEN
        EXECUTE 'CREATE ROLE olga_ddl_admin NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'olga_dml_writer') THEN
        EXECUTE 'CREATE ROLE olga_dml_writer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'olga_reader') THEN
        EXECUTE 'CREATE ROLE olga_reader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'olga_nlp_worker') THEN
        EXECUTE 'CREATE ROLE olga_nlp_worker NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION';
    END IF;
END;
$$;

GRANT olga_ddl_admin TO CURRENT_USER;
SET ROLE olga_ddl_admin;

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS iam;
CREATE SCHEMA IF NOT EXISTS consent;
CREATE SCHEMA IF NOT EXISTS event;
CREATE SCHEMA IF NOT EXISTS social;
CREATE SCHEMA IF NOT EXISTS chat;
CREATE SCHEMA IF NOT EXISTS storage;
CREATE SCHEMA IF NOT EXISTS notification;
CREATE SCHEMA IF NOT EXISTS nlp;
CREATE SCHEMA IF NOT EXISTS moderation;
CREATE SCHEMA IF NOT EXISTS ops;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS admin;
CREATE SCHEMA IF NOT EXISTS history;

CREATE SEQUENCE IF NOT EXISTS chat.message_sequence AS bigint START WITH 1 INCREMENT BY 1 CACHE 100;
CREATE SEQUENCE IF NOT EXISTS ops.sync_change_sequence AS bigint START WITH 1 INCREMENT BY 1 CACHE 100;

CREATE OR REPLACE FUNCTION ops.set_row_version()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.row_version := OLD.row_version + 1;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION ops.add_constraint_if_missing(
    p_schema name, p_table name, p_constraint name, p_definition text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = p_schema AND t.relname = p_table AND c.conname = p_constraint
    ) THEN
        EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I %s', p_schema, p_table, p_constraint, p_definition);
    END IF;
END;
$$;

-- ======================== TABLES ========================
-- core.community: Network/community boundary; one OLGA row in Release 1.
CREATE TABLE IF NOT EXISTS core.community (
        community_id varchar(64) NOT NULL, -- Stable API identifier.
        name varchar(200) NOT NULL, -- Display name.
        status varchar(24) NOT NULL CONSTRAINT df_community_status DEFAULT ('ACTIVE'), -- ACTIVE, SUSPENDED or CLOSED.
        default_locale varchar(16) NOT NULL CONSTRAINT df_community_default_locale DEFAULT ('en'), -- BCP-47 default locale.
        created_at timestamptz NOT NULL CONSTRAINT df_community_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_community_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_community_ PRIMARY KEY (community_id)
    );
-- iam.member: Authoritative member account and lifecycle state.
CREATE TABLE IF NOT EXISTS iam.member (
        member_id varchar(64) NOT NULL, -- Opaque identifier; use GUID/ULID string.
        community_id varchar(64) NOT NULL, -- FK core.community.
        status varchar(24) NOT NULL CONSTRAINT df_member_status DEFAULT ('PENDING'), -- PENDING, ACTIVE, SUSPENDED, ANONYMIZED, DELETED.
        locale varchar(16) NOT NULL CONSTRAINT df_member_locale DEFAULT ('en'), -- Preferred locale.
        verified_at timestamptz NULL, -- First completed account verification.
        suspended_at timestamptz NULL, -- Administrative suspension time.
        deleted_at timestamptz NULL, -- Deletion/anonymization workflow start.
        created_at timestamptz NOT NULL CONSTRAINT df_member_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_member_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_member_ PRIMARY KEY (member_id)
    );
-- iam.member_identity: Email/mobile/passwordless/Entra identity mapping.
CREATE TABLE IF NOT EXISTS iam.member_identity (
        member_identity_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Internal key.
        member_id varchar(64) NOT NULL, -- FK iam.member.
        provider varchar(32) NOT NULL, -- EMAIL, PHONE, ENTRA or approved provider.
        provider_subject_hash char(64) NOT NULL, -- Keyed deterministic hash used for equality lookup and uniqueness.
        provider_subject_ciphertext bytea NOT NULL, -- Encrypted normalized email/mobile or external subject.
        display_hint varchar(80) NULL, -- Masked support hint; never authoritative.
        is_primary boolean NOT NULL CONSTRAINT df_member_identity_is_primary DEFAULT (false), -- Primary sign-in identity flag.
        status varchar(16) NOT NULL CONSTRAINT df_member_identity_status DEFAULT ('ACTIVE'), -- ACTIVE or REVOKED.
        verified_at timestamptz NULL, -- Verification completion.
        last_login_at timestamptz NULL, -- Security/account support signal.
        revoked_at timestamptz NULL, -- Explicit identity disablement time.
        created_at timestamptz NOT NULL CONSTRAINT df_member_identity_created_at DEFAULT (CURRENT_TIMESTAMP), -- Creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_member_identity_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_member_identity_ PRIMARY KEY (member_identity_id)
    );
-- iam.permission: Controlled application permission catalog used by API authorization policies.
CREATE TABLE IF NOT EXISTS iam.permission (
        permission_code varchar(96) NOT NULL, -- Stable application permission code.
        resource_type varchar(64) NOT NULL, -- Protected application resource.
        action varchar(32) NOT NULL, -- READ, CREATE, UPDATE, DELETE, APPROVE, EXPORT or CONFIGURE.
        description varchar(500) NULL, -- Human-readable authorization intent.
        status varchar(16) NOT NULL CONSTRAINT df_permission_status DEFAULT ('ACTIVE'), -- ACTIVE or RETIRED.
        created_at timestamptz NOT NULL CONSTRAINT df_permission_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_permission_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_permission_ PRIMARY KEY (permission_code)
    );
-- iam.role_permission: Versioned mapping from application roles to permissions.
CREATE TABLE IF NOT EXISTS iam.role_permission (
        role_code varchar(64) NOT NULL, -- FK iam.role.
        permission_code varchar(96) NOT NULL, -- FK iam.permission.
        granted_at timestamptz NOT NULL CONSTRAINT df_role_permission_granted_at DEFAULT (CURRENT_TIMESTAMP), -- Grant time.
        granted_by varchar(64) NULL, -- Administrator approving the grant.
        revoked_at timestamptz NULL, -- Revocation time; null while active.
        CONSTRAINT pk_role_permission_ PRIMARY KEY (role_code, permission_code)
    );
-- iam.role: Controlled role catalog for member and administrator authorization.
CREATE TABLE IF NOT EXISTS iam.role (
        role_code varchar(64) NOT NULL, -- MEMBER, ADMIN, MODERATOR, NLP_EVALUATOR.
        name varchar(100) NOT NULL, -- Display name.
        description varchar(500) NULL, -- Scope and intended use.
        is_privileged boolean NOT NULL CONSTRAINT df_role_is_privileged DEFAULT (false), -- Requires elevated authentication and audit.
        status varchar(16) NOT NULL CONSTRAINT df_role_status DEFAULT ('ACTIVE'), -- ACTIVE or RETIRED.
        created_at timestamptz NOT NULL CONSTRAINT df_role_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_role_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_role_ PRIMARY KEY (role_code)
    );
-- iam.auth_session: Application session binding and revocation state; no bearer or refresh tokens.
CREATE TABLE IF NOT EXISTS iam.auth_session (
        session_id varchar(64) NOT NULL, -- Opaque application session identifier.
        member_id varchar(64) NOT NULL, -- FK iam.member.
        device_id varchar(64) NULL, -- Optional FK iam.member_device.
        identity_provider varchar(32) NOT NULL, -- Approved CIAM provider.
        provider_session_hash char(64) NULL, -- Hash of provider session reference; never store tokens.
        auth_strength varchar(24) NOT NULL CONSTRAINT df_auth_session_auth_strength DEFAULT ('STANDARD'), -- STANDARD, MFA or STEP_UP.
        issued_at timestamptz NOT NULL CONSTRAINT df_auth_session_issued_at DEFAULT (CURRENT_TIMESTAMP), -- Session issue time.
        expires_at timestamptz NOT NULL, -- Hard application expiry.
        last_seen_at timestamptz NOT NULL CONSTRAINT df_auth_session_last_seen_at DEFAULT (CURRENT_TIMESTAMP), -- Last validated request.
        revoked_at timestamptz NULL, -- Immediate logout, deletion or compromise revocation.
        revocation_reason varchar(64) NULL, -- Controlled reason code.
        created_at timestamptz NOT NULL CONSTRAINT df_auth_session_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_auth_session_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_auth_session_ PRIMARY KEY (session_id)
    );
-- iam.member_role: role assignment with optional expiry.
CREATE TABLE IF NOT EXISTS iam.member_role (
        member_id varchar(64) NOT NULL, -- FK iam.member.
        role_code varchar(64) NOT NULL, -- FK iam.role.
        granted_by varchar(64) NULL, -- Administrator member ID.
        granted_at timestamptz NOT NULL CONSTRAINT df_member_role_granted_at DEFAULT (CURRENT_TIMESTAMP), -- Grant time.
        expires_at timestamptz NULL, -- Optional expiry.
        revoked_at timestamptz NULL, -- Revocation time.
        CONSTRAINT pk_member_role_ PRIMARY KEY (member_id, role_code)
    );
-- iam.member_device: Registered mobile installation and security state.
CREATE TABLE IF NOT EXISTS iam.member_device (
        device_id varchar(64) NOT NULL, -- Client installation identifier, rotated on reinstall.
        member_id varchar(64) NOT NULL, -- FK iam.member.
        platform varchar(16) NOT NULL, -- IOS or ANDROID.
        app_version varchar(32) NOT NULL, -- Last reported app version.
        status varchar(20) NOT NULL CONSTRAINT df_member_device_status DEFAULT ('ACTIVE'), -- ACTIVE or REVOKED.
        last_seen_at timestamptz NOT NULL CONSTRAINT df_member_device_last_seen_at DEFAULT (CURRENT_TIMESTAMP), -- Last authenticated request.
        revoked_at timestamptz NULL, -- Remote logout/device loss handling.
        created_at timestamptz NOT NULL CONSTRAINT df_member_device_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_member_device_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_member_device_ PRIMARY KEY (device_id)
    );
-- core.organization: Professional organization represented in profiles.
CREATE TABLE IF NOT EXISTS core.organization (
        organization_id varchar(64) NOT NULL, -- Stable identifier.
        community_id varchar(64) NOT NULL, -- FK core.community.
        name varchar(250) NOT NULL, -- Canonical organization name.
        normalized_name varchar(250) NOT NULL, -- Search/deduplication form.
        website_domain varchar(255) NULL, -- Verified domain when available.
        industry_code varchar(64) NULL, -- Reference taxonomy.
        verification_status varchar(24) NOT NULL CONSTRAINT df_organization_verification_status DEFAULT ('UNVERIFIED'), -- UNVERIFIED, PENDING, VERIFIED, REJECTED.
        status varchar(20) NOT NULL CONSTRAINT df_organization_status DEFAULT ('ACTIVE'), -- Lifecycle state.
        created_at timestamptz NOT NULL CONSTRAINT df_organization_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_organization_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_organization_ PRIMARY KEY (organization_id)
    );
-- core.organization_member: member affiliation, title and organization-level role.
CREATE TABLE IF NOT EXISTS core.organization_member (
        organization_member_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Internal key.
        organization_id varchar(64) NOT NULL, -- FK core.organization.
        member_id varchar(64) NOT NULL, -- FK iam.member.
        job_title varchar(200) NULL, -- Professional title.
        department varchar(150) NULL, -- Optional function/department.
        is_primary boolean NOT NULL CONSTRAINT df_organization_member_is_primary DEFAULT (false), -- Primary current affiliation.
        started_on date NULL, -- Optional month/day precision per product policy.
        ended_on date NULL, -- Null for current affiliation.
        created_at timestamptz NOT NULL CONSTRAINT df_organization_member_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_organization_member_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_organization_member_ PRIMARY KEY (organization_member_id)
    );
-- core.member_profile: Searchable professional profile and visibility state.
CREATE TABLE IF NOT EXISTS core.member_profile (
        member_id varchar(64) NOT NULL, -- One-to-one FK iam.member.
        display_name varchar(150) NOT NULL, -- member-facing name.
        headline varchar(240) NULL, -- Short professional headline.
        professional_summary varchar(2000) NULL, -- member-authored summary.
        role_category varchar(64) NULL, -- Controlled role/function code.
        profile_status varchar(24) NOT NULL CONSTRAINT df_member_profile_profile_status DEFAULT ('DRAFT'), -- DRAFT, PENDING_REVIEW, ACTIVE, HIDDEN.
        visibility varchar(20) NOT NULL CONSTRAINT df_member_profile_visibility DEFAULT ('MEMBERS'), -- PRIVATE, MEMBERS or CONTEXT_ONLY.
        completeness_score numeric(5,2) NOT NULL CONSTRAINT df_member_profile_completeness_score DEFAULT (0), -- Derived profile completeness percentage.
        published_at timestamptz NULL, -- First/current publication time.
        created_at timestamptz NOT NULL CONSTRAINT df_member_profile_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_member_profile_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_member_profile_ PRIMARY KEY (member_id)
    );
-- core.sector: Controlled sector/industry taxonomy.
CREATE TABLE IF NOT EXISTS core.sector (
        sector_code varchar(64) NOT NULL, -- Stable taxonomy code.
        parent_sector_code varchar(64) NULL, -- Self-referencing hierarchy.
        name varchar(150) NOT NULL, -- Display label.
        status varchar(16) NOT NULL CONSTRAINT df_sector_status DEFAULT ('ACTIVE'), -- ACTIVE or RETIRED.
        sort_order int NOT NULL CONSTRAINT df_sector_sort_order DEFAULT (0), -- Presentation order.
        created_at timestamptz NOT NULL CONSTRAINT df_sector_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_sector_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_sector_ PRIMARY KEY (sector_code)
    );
-- core.member_sector: Many-to-many profile sector selection.
CREATE TABLE IF NOT EXISTS core.member_sector (
        member_id varchar(64) NOT NULL, -- FK member_profile.
        sector_code varchar(64) NOT NULL, -- FK sector.
        is_primary boolean NOT NULL CONSTRAINT df_member_sector_is_primary DEFAULT (false), -- Primary sector flag.
        created_at timestamptz NOT NULL CONSTRAINT df_member_sector_created_at DEFAULT (CURRENT_TIMESTAMP), -- Assignment time.
        CONSTRAINT pk_member_sector_ PRIMARY KEY (member_id, sector_code)
    );
-- core.member_geography: member operating markets; not live location.
CREATE TABLE IF NOT EXISTS core.member_geography (
        member_geography_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Internal key.
        member_id varchar(64) NOT NULL, -- FK member_profile.
        country_code char(2) NOT NULL, -- ISO 3166-1 alpha-2.
        region varchar(120) NULL, -- State/region.
        city varchar(120) NULL, -- Operating city.
        is_primary boolean NOT NULL CONSTRAINT df_member_geography_is_primary DEFAULT (false), -- Primary market.
        created_at timestamptz NOT NULL CONSTRAINT df_member_geography_created_at DEFAULT (CURRENT_TIMESTAMP), -- Creation time.
        CONSTRAINT pk_member_geography_ PRIMARY KEY (member_geography_id)
    );
-- core.profile_field_visibility: Per-field exposure before/after connection.
CREATE TABLE IF NOT EXISTS core.profile_field_visibility (
        member_id varchar(64) NOT NULL, -- FK member_profile.
        field_code varchar(64) NOT NULL, -- PROFILE_SUMMARY, ORGANIZATION, GEOGRAPHY, etc.
        audience varchar(24) NOT NULL CONSTRAINT df_profile_field_visibility_audience DEFAULT ('CONNECTED'), -- PRIVATE, MATCHED, CONNECTED, MEMBERS.
        updated_at timestamptz NOT NULL CONSTRAINT df_profile_field_visibility_updated_at DEFAULT (CURRENT_TIMESTAMP), -- Last preference change.
        row_version bigint NOT NULL DEFAULT 1, -- Concurrency token.
        CONSTRAINT pk_profile_field_visibility_ PRIMARY KEY (member_id, field_code)
    );
-- core.member_verification: Administrator/member verification workflow.
CREATE TABLE IF NOT EXISTS core.member_verification (
        verification_id varchar(64) NOT NULL, -- Case identifier.
        member_id varchar(64) NOT NULL, -- FK iam.member.
        verification_type varchar(32) NOT NULL, -- EMAIL, PHONE, ORGANIZATION or MANUAL.
        status varchar(24) NOT NULL CONSTRAINT df_member_verification_status DEFAULT ('PENDING'), -- PENDING, APPROVED, REJECTED, EXPIRED.
        evidence_file_asset_id varchar(64) NULL, -- Private storage.file_asset evidence reference, if policy permits.
        reviewed_by varchar(64) NULL, -- Administrator member ID.
        reviewed_at timestamptz NULL, -- Review completion.
        reason_code varchar(64) NULL, -- Controlled result reason.
        created_at timestamptz NOT NULL CONSTRAINT df_member_verification_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_member_verification_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_member_verification_ PRIMARY KEY (verification_id)
    );
-- consent.consent_policy: Versioned consent purpose and legal/community text.
CREATE TABLE IF NOT EXISTS consent.consent_policy (
        policy_id varchar(64) NOT NULL, -- Stable policy version ID.
        purpose_code varchar(64) NOT NULL, -- TERMS, LOCATION, LIVE_MODE, NOTIFICATIONS, ANALYTICS.
        version varchar(32) NOT NULL, -- Human-readable version.
        locale varchar(16) NOT NULL CONSTRAINT df_consent_policy_locale DEFAULT ('en'), -- Text locale.
        content_hash char(64) NOT NULL, -- SHA-256 of presented content.
        effective_from timestamptz NOT NULL, -- Activation time.
        retired_at timestamptz NULL, -- Retirement time.
        created_at timestamptz NOT NULL CONSTRAINT df_consent_policy_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_consent_policy_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_consent_policy_ PRIMARY KEY (policy_id)
    );
-- consent.member_consent: Authoritative grant/withdrawal evidence by purpose.
CREATE TABLE IF NOT EXISTS consent.member_consent (
        member_consent_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Evidence record.
        member_id varchar(64) NOT NULL, -- FK iam.member.
        policy_id varchar(64) NOT NULL, -- FK consent_policy.
        decision varchar(16) NOT NULL, -- GRANTED or DENIED.
        captured_at timestamptz NOT NULL CONSTRAINT df_member_consent_captured_at DEFAULT (CURRENT_TIMESTAMP), -- Decision time.
        withdrawn_at timestamptz NULL, -- Withdrawal time.
        capture_channel varchar(24) NOT NULL, -- MOBILE, WEB_ADMIN or SUPPORT.
        evidence_json jsonb NULL, -- Bounded device/app/version evidence; no secrets.
        CONSTRAINT pk_member_consent_ PRIMARY KEY (member_consent_id)
    );
-- consent.privacy_request: member data access, correction, deletion or consent-support case.
CREATE TABLE IF NOT EXISTS consent.privacy_request (
        privacy_request_id varchar(64) NOT NULL, -- Case identifier.
        member_id varchar(64) NOT NULL, -- Requesting member.
        request_type varchar(24) NOT NULL, -- ACCESS, CORRECT, DELETE, EXPORT, CONSENT_SUPPORT.
        status varchar(24) NOT NULL CONSTRAINT df_privacy_request_status DEFAULT ('OPEN'), -- OPEN, VERIFIED, PROCESSING, COMPLETED, REJECTED.
        verified_at timestamptz NULL, -- Identity verification.
        due_at timestamptz NULL, -- Policy deadline.
        completed_at timestamptz NULL, -- Completion time.
        result_file_asset_id varchar(64) NULL, -- Private storage.file_asset export package reference.
        created_at timestamptz NOT NULL CONSTRAINT df_privacy_request_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_privacy_request_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_privacy_request_ PRIMARY KEY (privacy_request_id)
    );
-- consent.privacy_request_task: Per-domain execution and evidence ledger for a privacy request.
CREATE TABLE IF NOT EXISTS consent.privacy_request_task (
        privacy_request_task_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Execution step identifier.
        privacy_request_id varchar(64) NOT NULL, -- FK consent.privacy_request.
        domain_code varchar(32) NOT NULL, -- IAM, PROFILE, EVENT, SOCIAL, CHAT, STORAGE, NLP, ANALYTICS or AUDIT.
        action_type varchar(24) NOT NULL, -- EXPORT, CORRECT, ANONYMIZE, DELETE or RETAIN_EXCEPTION.
        status varchar(20) NOT NULL CONSTRAINT df_privacy_request_task_status DEFAULT ('PENDING'), -- PENDING, RUNNING, COMPLETED, FAILED or EXEMPTED.
        attempt_count smallint NOT NULL CONSTRAINT df_privacy_request_task_attempt_count DEFAULT (0), -- Execution attempts.
        evidence_code varchar(64) NULL, -- Controlled completion or exception evidence.
        evidence_hash char(64) NULL, -- Hash of generated evidence or result manifest.
        started_at timestamptz NULL, -- First execution start.
        completed_at timestamptz NULL, -- Successful or exempted completion.
        last_error_code varchar(64) NULL, -- Sanitized retryable/permanent error.
        created_at timestamptz NOT NULL CONSTRAINT df_privacy_request_task_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_privacy_request_task_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_privacy_request_task_ PRIMARY KEY (privacy_request_task_id)
    );
-- event.venue: Admin-configured venue and coarse proximity boundary.
CREATE TABLE IF NOT EXISTS event.venue (
        venue_id varchar(64) NOT NULL, -- venue identifier.
        name varchar(200) NOT NULL, -- venue name.
        country_code char(2) NOT NULL, -- ISO country.
        region varchar(120) NULL, -- Region/state.
        city varchar(120) NULL, -- City.
        coarse_geo_cell varchar(32) NULL, -- venue-level geohash/H3 cell; not member location.
        timezone_id varchar(64) NOT NULL, -- IANA/Windows mapping controlled by service.
        status varchar(16) NOT NULL CONSTRAINT df_venue_status DEFAULT ('ACTIVE'), -- ACTIVE or RETIRED.
        created_at timestamptz NOT NULL CONSTRAINT df_venue_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_venue_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_venue_ PRIMARY KEY (venue_id)
    );
-- event.event: event/context used for registration, Live Mode and matching.
CREATE TABLE IF NOT EXISTS event.event (
        event_id varchar(64) NOT NULL, -- Also used as matching context_id.
        community_id varchar(64) NOT NULL, -- FK community.
        venue_id varchar(64) NULL, -- FK venue.
        name varchar(250) NOT NULL, -- event name.
        description varchar(2000) NULL, -- Admin-managed description.
        starts_at timestamptz NOT NULL, -- UTC start.
        ends_at timestamptz NOT NULL, -- UTC end.
        status varchar(24) NOT NULL CONSTRAINT df_event_status DEFAULT ('DRAFT'), -- DRAFT, PUBLISHED, ACTIVE, COMPLETED, CANCELLED.
        live_mode_enabled boolean NOT NULL CONSTRAINT df_event_live_mode_enabled DEFAULT (false), -- event allows Live Mode.
        created_at timestamptz NOT NULL CONSTRAINT df_event_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_event_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_event_ PRIMARY KEY (event_id)
    );
-- event.event_matching_policy: Versioned event-level eligibility, proximity, ranking and match-alert controls.
CREATE TABLE IF NOT EXISTS event.event_matching_policy (
        event_matching_policy_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Immutable policy version identifier.
        event_id varchar(64) NOT NULL, -- FK event; policy applies only to this event/context.
        policy_version smallint NOT NULL CONSTRAINT df_event_matching_policy_policy_version DEFAULT (1), -- Monotonic version within the event.
        status varchar(16) NOT NULL CONSTRAINT df_event_matching_policy_status DEFAULT ('DRAFT'), -- DRAFT, ACTIVE or RETIRED.
        registration_required boolean NOT NULL CONSTRAINT df_event_matching_policy_registration_required DEFAULT (true), -- member must hold an eligible event_registration.
        check_in_required boolean NOT NULL CONSTRAINT df_event_matching_policy_check_in_required DEFAULT (false), -- member must be checked in before event matching.
        live_mode_required boolean NOT NULL CONSTRAINT df_event_matching_policy_live_mode_required DEFAULT (true), -- Active consent-backed live_mode_session required.
        proximity_mode varchar(24) NOT NULL CONSTRAINT df_event_matching_policy_proximity_mode DEFAULT ('VENUE'), -- NONE, VENUE or COARSE_CELL.
        max_presence_age_minutes smallint NULL CONSTRAINT df_event_matching_policy_max_presence_age_minutes DEFAULT (15), -- Maximum age of coarse presence when proximity is used.
        match_threshold_override numeric(6,5) NULL, -- Optional override of active NLP ranking threshold.
        alert_confidence_threshold numeric(6,5) NOT NULL CONSTRAINT df_event_matching_policy_alert_confidence_threshold DEFAULT (0.70), -- Minimum final score before a proactive match alert is eligible.
        max_match_alerts_per_hour smallint NOT NULL CONSTRAINT df_event_matching_policy_max_match_alerts_per_hour DEFAULT (2), -- event-specific hourly cap per member.
        max_match_alerts_per_event smallint NOT NULL CONSTRAINT df_event_matching_policy_max_match_alerts_per_event DEFAULT (10), -- event-lifetime cap per member.
        minimum_alert_interval_minutes smallint NOT NULL CONSTRAINT df_event_matching_policy_minimum_alert_interval_minutes DEFAULT (30), -- Minimum spacing between event match alerts.
        effective_from timestamptz NOT NULL, -- Start of policy applicability.
        effective_to timestamptz NULL, -- Optional retirement time.
        created_at timestamptz NOT NULL CONSTRAINT df_event_matching_policy_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_event_matching_policy_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_event_matching_policy_ PRIMARY KEY (event_matching_policy_id)
    );
-- event.event_registration: member eligibility/check-in relationship to an event.
CREATE TABLE IF NOT EXISTS event.event_registration (
        event_registration_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Internal key.
        event_id varchar(64) NOT NULL, -- FK event.
        member_id varchar(64) NOT NULL, -- FK member.
        status varchar(24) NOT NULL CONSTRAINT df_event_registration_status DEFAULT ('REGISTERED'), -- INVITED, REGISTERED, CHECKED_IN, CANCELLED.
        registered_at timestamptz NOT NULL CONSTRAINT df_event_registration_registered_at DEFAULT (CURRENT_TIMESTAMP), -- Registration time.
        checked_in_at timestamptz NULL, -- event check-in time.
        source varchar(24) NOT NULL CONSTRAINT df_event_registration_source DEFAULT ('APP'), -- APP, ADMIN, IMPORT.
        created_at timestamptz NOT NULL CONSTRAINT df_event_registration_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_event_registration_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_event_registration_ PRIMARY KEY (event_registration_id)
    );
-- event.live_mode_session: Bounded, revocable member discovery session.
CREATE TABLE IF NOT EXISTS event.live_mode_session (
        live_session_id varchar(64) NOT NULL, -- Session identifier.
        event_id varchar(64) NOT NULL, -- FK event.
        member_id varchar(64) NOT NULL, -- FK member.
        consent_record_id bigint NOT NULL, -- Valid Live Mode consent evidence.
        status varchar(16) NOT NULL CONSTRAINT df_live_mode_session_status DEFAULT ('ACTIVE'), -- ACTIVE, DISABLED, EXPIRED.
        activated_at timestamptz NOT NULL CONSTRAINT df_live_mode_session_activated_at DEFAULT (CURRENT_TIMESTAMP), -- Activation time.
        active_until timestamptz NOT NULL, -- Hard expiry bounded by event.
        disabled_at timestamptz NULL, -- Immediate revocation time.
        created_at timestamptz NOT NULL CONSTRAINT df_live_mode_session_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_live_mode_session_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_live_mode_session_ PRIMARY KEY (live_session_id)
    );
-- event.event_presence: Coarse, short-lived evidence used for nearby matching.
CREATE TABLE IF NOT EXISTS event.event_presence (
        presence_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Internal key.
        live_session_id varchar(64) NOT NULL, -- FK live_mode_session.
        coarse_cell varchar(32) NOT NULL, -- Approved coarse geohash/H3 cell.
        observed_at timestamptz NOT NULL CONSTRAINT df_event_presence_observed_at DEFAULT (CURRENT_TIMESTAMP), -- Observation time.
        expires_at timestamptz NOT NULL, -- Automatic purge time.
        source varchar(24) NOT NULL, -- CHECK_IN, FOREGROUND_GEO or VENUE_ZONE.
        CONSTRAINT pk_event_presence_ PRIMARY KEY (presence_id)
    );
-- social.connection_request: Consent gate before creating a connection/chat.
CREATE TABLE IF NOT EXISTS social.connection_request (
        connection_request_id varchar(64) NOT NULL, -- Request identifier.
        sender_member_id varchar(64) NOT NULL, -- Requester.
        recipient_member_id varchar(64) NOT NULL, -- Recipient.
        context_id varchar(64) NULL, -- event or general matching context.
        match_result_id bigint NULL, -- Recommendation that led to request.
        note varchar(500) NULL, -- Optional introduction note; moderate as content.
        status varchar(24) NOT NULL CONSTRAINT df_connection_request_status DEFAULT ('PENDING'), -- PENDING, ACCEPTED, DECLINED, WITHDRAWN, EXPIRED.
        expires_at timestamptz NOT NULL, -- Policy-calculated expiry for a pending request.
        responded_at timestamptz NULL, -- Terminal response time.
        created_at timestamptz NOT NULL CONSTRAINT df_connection_request_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_connection_request_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_connection_request_ PRIMARY KEY (connection_request_id)
    );
-- social.connection: Mutually accepted member relationship.
CREATE TABLE IF NOT EXISTS social.connection (
        connection_id varchar(64) NOT NULL, -- connection identifier.
        member_low_id varchar(64) NOT NULL, -- Lexicographically lower member ID.
        member_high_id varchar(64) NOT NULL, -- Lexicographically higher member ID.
        accepted_request_id varchar(64) NOT NULL, -- Accepted connection_request.
        status varchar(20) NOT NULL CONSTRAINT df_connection_status DEFAULT ('ACTIVE'), -- ACTIVE or DISCONNECTED.
        connected_at timestamptz NOT NULL CONSTRAINT df_connection_connected_at DEFAULT (CURRENT_TIMESTAMP), -- Acceptance time.
        disconnected_at timestamptz NULL, -- Relationship end.
        created_at timestamptz NOT NULL CONSTRAINT df_connection_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_connection_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_connection_ PRIMARY KEY (connection_id)
    );
-- social.member_block: Directional block that suppresses discovery and communication both ways.
CREATE TABLE IF NOT EXISTS social.member_block (
        block_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Internal key.
        blocker_member_id varchar(64) NOT NULL, -- member initiating block.
        blocked_member_id varchar(64) NOT NULL, -- Blocked member.
        reason_code varchar(64) NULL, -- Private controlled reason.
        created_at timestamptz NOT NULL CONSTRAINT df_member_block_created_at DEFAULT (CURRENT_TIMESTAMP), -- Effective immediately.
        removed_at timestamptz NULL, -- Optional unblock.
        CONSTRAINT pk_member_block_ PRIMARY KEY (block_id)
    );
-- social.member_report: member-submitted safety/report workflow trigger.
CREATE TABLE IF NOT EXISTS social.member_report (
        report_id varchar(64) NOT NULL, -- Report identifier.
        reporter_member_id varchar(64) NOT NULL, -- Reporter.
        reported_member_id varchar(64) NOT NULL, -- Subject.
        resource_type varchar(32) NULL, -- PROFILE, REQUEST, MESSAGE, ATTACHMENT.
        resource_id varchar(64) NULL, -- Reported object.
        category varchar(64) NOT NULL, -- Controlled report category.
        description varchar(2000) NULL, -- Reporter description.
        status varchar(24) NOT NULL CONSTRAINT df_member_report_status DEFAULT ('OPEN'), -- OPEN, TRIAGED, RESOLVED, DISMISSED.
        created_at timestamptz NOT NULL CONSTRAINT df_member_report_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_member_report_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_member_report_ PRIMARY KEY (report_id)
    );
-- chat.conversation: Accepted-connection one-to-one chat container.
CREATE TABLE IF NOT EXISTS chat.conversation (
        conversation_id varchar(64) NOT NULL, -- conversation identifier.
        connection_id varchar(64) NOT NULL, -- One conversation per accepted connection.
        status varchar(20) NOT NULL CONSTRAINT df_conversation_status DEFAULT ('ACTIVE'), -- ACTIVE, CLOSED, RESTRICTED.
        last_message_at timestamptz NULL, -- conversation list ordering.
        created_at timestamptz NOT NULL CONSTRAINT df_conversation_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_conversation_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_conversation_ PRIMARY KEY (conversation_id)
    );
-- chat.conversation_participant: Per-member chat state and authorization projection.
CREATE TABLE IF NOT EXISTS chat.conversation_participant (
        conversation_id varchar(64) NOT NULL, -- FK conversation.
        member_id varchar(64) NOT NULL, -- Participant.
        joined_at timestamptz NOT NULL CONSTRAINT df_conversation_participant_joined_at DEFAULT (CURRENT_TIMESTAMP), -- Participation start.
        last_read_message_id varchar(64) NULL, -- Read cursor.
        muted_until timestamptz NULL, -- notification suppression.
        left_at timestamptz NULL, -- Closure/disconnect projection.
        CONSTRAINT pk_conversation_participant_ PRIMARY KEY (conversation_id, member_id)
    );
-- chat.message: Durable one-to-one message.
CREATE TABLE IF NOT EXISTS chat.message (
        message_id varchar(64) NOT NULL, -- Client-generated ID supports idempotency.
        conversation_id varchar(64) NOT NULL, -- FK conversation.
        sender_member_id varchar(64) NOT NULL, -- Authorized participant.
        message_type varchar(20) NOT NULL CONSTRAINT df_message_message_type DEFAULT ('TEXT'), -- TEXT, FILE, SYSTEM.
        body text NULL, -- Text content; sanitize for display.
        client_sent_at timestamptz NULL, -- Client timestamp for UX only.
        server_sequence bigint NOT NULL CONSTRAINT df_message_server_sequence DEFAULT (nextval('chat.message_sequence')), -- Monotonic per conversation or global stream.
        moderation_status varchar(24) NOT NULL CONSTRAINT df_message_moderation_status DEFAULT ('PENDING_OR_CLEAR'), -- Safety state.
        deleted_at timestamptz NULL, -- Logical removal time.
        created_at timestamptz NOT NULL CONSTRAINT df_message_created_at DEFAULT (CURRENT_TIMESTAMP), -- Authoritative send time.
        updated_at timestamptz NOT NULL CONSTRAINT df_message_updated_at DEFAULT (CURRENT_TIMESTAMP), -- Last moderation/deletion change.
        row_version bigint NOT NULL DEFAULT 1, -- Concurrency token.
        CONSTRAINT pk_message_ PRIMARY KEY (message_id)
    );
-- chat.message_receipt: message delivered/read evidence by participant.
CREATE TABLE IF NOT EXISTS chat.message_receipt (
        message_id varchar(64) NOT NULL, -- FK message.
        member_id varchar(64) NOT NULL, -- Recipient participant.
        delivered_at timestamptz NULL, -- First delivery.
        read_at timestamptz NULL, -- First read.
        updated_at timestamptz NOT NULL CONSTRAINT df_message_receipt_updated_at DEFAULT (CURRENT_TIMESTAMP), -- Last receipt update.
        CONSTRAINT pk_message_receipt_ PRIMARY KEY (message_id, member_id)
    );
-- storage.file_asset: Domain-neutral metadata and security lifecycle for a private Azure Blob object.
CREATE TABLE IF NOT EXISTS storage.file_asset (
        file_asset_id varchar(64) NOT NULL, -- Opaque file identifier.
        community_id varchar(64) NOT NULL, -- FK core.community and authorization boundary.
        owner_member_id varchar(64) NULL, -- Uploader/owner when the asset belongs to a member.
        purpose_code varchar(32) NOT NULL, -- CHAT_FILE, VERIFICATION_EVIDENCE, PRIVACY_EXPORT or EVALUATION_REPORT.
        container_name varchar(128) NOT NULL, -- Allowlisted private container; not client supplied.
        blob_path varchar(1024) NOT NULL, -- Private blob path; never store a SAS URL.
        blob_path_hash char(64) NOT NULL, -- Deterministic lookup without broad path exposure.
        file_name varchar(255) NOT NULL, -- Sanitized display name.
        media_type varchar(128) NOT NULL, -- Verified MIME type.
        size_bytes bigint NOT NULL, -- Validated size.
        sha256 char(64) NOT NULL, -- Integrity and deduplication hash.
        classification varchar(24) NOT NULL CONSTRAINT df_file_asset_classification DEFAULT ('CONFIDENTIAL'), -- INTERNAL, CONFIDENTIAL, RESTRICTED or HIGHLY_RESTRICTED.
        scan_status varchar(24) NOT NULL CONSTRAINT df_file_asset_scan_status DEFAULT ('PENDING'), -- PENDING, CLEAN, REJECTED or ERROR.
        lifecycle_status varchar(20) NOT NULL CONSTRAINT df_file_asset_lifecycle_status DEFAULT ('UPLOADING'), -- UPLOADING, AVAILABLE, QUARANTINED, DELETED or EXPIRED.
        expires_at timestamptz NULL, -- Purpose policy or orphan-upload purge time.
        deleted_at timestamptz NULL, -- Deletion completion time.
        created_at timestamptz NOT NULL CONSTRAINT df_file_asset_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_file_asset_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_file_asset_ PRIMARY KEY (file_asset_id)
    );
-- storage.file_asset_link: Association between a file_asset and an authorized product resource.
CREATE TABLE IF NOT EXISTS storage.file_asset_link (
        file_asset_link_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Association identifier.
        file_asset_id varchar(64) NOT NULL, -- FK storage.file_asset.
        resource_type varchar(32) NOT NULL, -- MESSAGE, MEMBER_VERIFICATION, PRIVACY_REQUEST or EVALUATION_RUN.
        resource_id varchar(64) NOT NULL, -- Authorized domain resource identifier.
        relationship_type varchar(32) NOT NULL CONSTRAINT df_file_asset_link_relationship_type DEFAULT ('PRIMARY'), -- PRIMARY, EVIDENCE, RESULT or REPORT.
        linked_by varchar(64) NULL, -- member, administrator or service actor.
        created_at timestamptz NOT NULL CONSTRAINT df_file_asset_link_created_at DEFAULT (CURRENT_TIMESTAMP), -- Link creation time.
        removed_at timestamptz NULL, -- Logical unlink time.
        CONSTRAINT pk_file_asset_link_ PRIMARY KEY (file_asset_link_id)
    );
-- notification.notification_policy: Versioned channel, frequency, quiet-hours, retry and expiry controls by notification purpose.
CREATE TABLE IF NOT EXISTS notification.notification_policy (
        notification_policy_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Immutable policy version identifier.
        community_id varchar(64) NULL, -- Optional community scope; null is platform default.
        purpose_code varchar(64) NOT NULL, -- MATCH, REQUEST, CHAT, EVENT, SAFETY or ACCOUNT.
        channel varchar(16) NOT NULL, -- PUSH, EMAIL or IN_APP.
        policy_version smallint NOT NULL CONSTRAINT df_notification_policy_policy_version DEFAULT (1), -- Monotonic version for scope/purpose/channel.
        status varchar(16) NOT NULL CONSTRAINT df_notification_policy_status DEFAULT ('DRAFT'), -- DRAFT, ACTIVE or RETIRED.
        member_opt_out_allowed boolean NOT NULL CONSTRAINT df_notification_policy_member_opt_out_allowed DEFAULT (true), -- Whether member preference may disable this notification.
        quiet_hours_behavior varchar(16) NOT NULL CONSTRAINT df_notification_policy_quiet_hours_behavior DEFAULT ('DEFER'), -- DEFER, SUPPRESS or BYPASS.
        dedupe_window_seconds int NOT NULL CONSTRAINT df_notification_policy_dedupe_window_seconds DEFAULT (300), -- Duplicate suppression window for the same dedupe key.
        max_per_hour smallint NOT NULL CONSTRAINT df_notification_policy_max_per_hour DEFAULT (6), -- Maximum queued/sent notifications per member and policy each hour.
        max_per_day smallint NOT NULL CONSTRAINT df_notification_policy_max_per_day DEFAULT (30), -- Maximum queued/sent notifications per member and policy each day.
        max_attempts smallint NOT NULL CONSTRAINT df_notification_policy_max_attempts DEFAULT (3), -- Bounded provider delivery attempts.
        retry_schedule_seconds varchar(128) NOT NULL CONSTRAINT df_notification_policy_retry_schedule_seconds DEFAULT ('60,300,1800'), -- Validated comma-separated retry delays.
        ttl_minutes int NOT NULL CONSTRAINT df_notification_policy_ttl_minutes DEFAULT (1440), -- notification expiry after initial eligibility.
        effective_from timestamptz NOT NULL, -- Start of policy applicability.
        effective_to timestamptz NULL, -- Optional retirement time.
        created_at timestamptz NOT NULL CONSTRAINT df_notification_policy_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_notification_policy_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_notification_policy_ PRIMARY KEY (notification_policy_id)
    );
-- notification.notification_preference: member channel, quiet hours and purpose preferences.
CREATE TABLE IF NOT EXISTS notification.notification_preference (
        member_id varchar(64) NOT NULL, -- FK member.
        purpose_code varchar(64) NOT NULL, -- MATCH, REQUEST, CHAT, EVENT, SAFETY or ACCOUNT.
        push_enabled boolean NOT NULL CONSTRAINT df_notification_preference_push_enabled DEFAULT (true), -- Push channel preference.
        email_enabled boolean NOT NULL CONSTRAINT df_notification_preference_email_enabled DEFAULT (false), -- Email channel preference.
        quiet_start_local time NULL, -- Optional local quiet start.
        quiet_end_local time NULL, -- Optional local quiet end.
        timezone_id varchar(64) NULL, -- Required when quiet hours set.
        created_at timestamptz NOT NULL CONSTRAINT df_notification_preference_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_notification_preference_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_notification_preference_ PRIMARY KEY (member_id, purpose_code)
    );
-- notification.push_token: Provider push token mapped to a registered device.
CREATE TABLE IF NOT EXISTS notification.push_token (
        push_token_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Internal key.
        device_id varchar(64) NOT NULL, -- FK member_device.
        provider varchar(24) NOT NULL, -- APNS or FCM.
        token_ciphertext bytea NOT NULL, -- Encrypted/tokenized push token.
        status varchar(16) NOT NULL CONSTRAINT df_push_token_status DEFAULT ('ACTIVE'), -- ACTIVE or INVALID.
        last_success_at timestamptz NULL, -- Last accepted delivery.
        invalidated_at timestamptz NULL, -- Provider rejection/revocation.
        created_at timestamptz NOT NULL CONSTRAINT df_push_token_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_push_token_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        token_fingerprint char(64) NOT NULL, -- Stable SHA-256 fingerprint supplied by the service for uniqueness without indexing ciphertext.
        CONSTRAINT pk_push_token_ PRIMARY KEY (push_token_id)
    );
-- notification.notification: Policy-resolved, rate-limited delivery intent and aggregate outcome.
CREATE TABLE IF NOT EXISTS notification.notification (
        notification_id varchar(64) NOT NULL, -- Delivery identifier.
        member_id varchar(64) NOT NULL, -- Recipient.
        notification_policy_id bigint NOT NULL, -- Immutable notification_policy version applied.
        event_matching_policy_id bigint NULL, -- event_matching_policy applied to an event match alert.
        purpose_code varchar(64) NOT NULL, -- notification purpose.
        channel varchar(16) NOT NULL, -- Resolved PUSH, EMAIL or IN_APP channel.
        resource_type varchar(32) NULL, -- MATCH, REQUEST, MESSAGE, EVENT.
        resource_id varchar(64) NULL, -- Deep-link resource.
        template_code varchar(64) NOT NULL, -- Versioned content template.
        dedupe_key varchar(160) NOT NULL, -- Stable purpose/member/resource key used for duplicate suppression.
        dedupe_bucket_start timestamptz NOT NULL, -- Start of the policy-derived deduplication window.
        source_confidence numeric(6,5) NULL, -- Match confidence captured when threshold-based notification is used.
        context_id varchar(64) NULL, -- event ID or GENERAL context used for event-lifetime caps.
        status varchar(20) NOT NULL CONSTRAINT df_notification_status DEFAULT ('PENDING'), -- PENDING, SENT, DELIVERED, FAILED, SUPPRESSED.
        scheduled_at timestamptz NOT NULL CONSTRAINT df_notification_scheduled_at DEFAULT (CURRENT_TIMESTAMP), -- Quiet-hours-aware schedule.
        expires_at timestamptz NOT NULL, -- Policy-calculated time after which delivery is suppressed.
        attempt_count smallint NOT NULL CONSTRAINT df_notification_attempt_count DEFAULT (0), -- Aggregate count of append-only delivery attempts.
        sent_at timestamptz NULL, -- Provider acceptance time.
        delivered_at timestamptz NULL, -- Provider delivery acknowledgment when available.
        suppression_reason varchar(64) NULL, -- OPT_OUT, QUIET_HOURS, RATE_LIMIT, DUPLICATE, EXPIRED, BELOW_THRESHOLD or POLICY.
        failure_code varchar(64) NULL, -- Sanitized provider failure.
        created_at timestamptz NOT NULL CONSTRAINT df_notification_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_notification_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_notification_ PRIMARY KEY (notification_id)
    );
-- notification.notification_delivery_attempt: Append-only provider attempt and acknowledgment history.
CREATE TABLE IF NOT EXISTS notification.notification_delivery_attempt (
        delivery_attempt_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Attempt identifier.
        notification_id varchar(64) NOT NULL, -- FK notification.
        attempt_number smallint NOT NULL, -- One-based attempt number.
        provider varchar(32) NOT NULL, -- APNS, FCM, EMAIL_PROVIDER or IN_APP.
        push_token_id bigint NULL, -- push_token used; null for non-push channels.
        provider_message_id varchar(256) NULL, -- Provider correlation ID; never a credential.
        status varchar(20) NOT NULL CONSTRAINT df_notification_delivery_attempt_status DEFAULT ('STARTED'), -- STARTED, ACCEPTED, DELIVERED, FAILED or EXPIRED.
        attempted_at timestamptz NOT NULL CONSTRAINT df_notification_delivery_attempt_attempted_at DEFAULT (CURRENT_TIMESTAMP), -- Attempt start time.
        acknowledged_at timestamptz NULL, -- Provider acknowledgment time.
        next_attempt_at timestamptz NULL, -- Next policy-derived retry time.
        duration_ms int NULL, -- Provider request duration.
        failure_code varchar(64) NULL, -- Sanitized failure category.
        CONSTRAINT pk_notification_delivery_attempt_ PRIMARY KEY (delivery_attempt_id)
    );
-- nlp.nlp_intent: Current WANT/OFFER text and structured matching metadata.
CREATE TABLE IF NOT EXISTS nlp.nlp_intent (
        intent_id varchar(64) NOT NULL, -- Matches existing API contract.
        member_id varchar(64) NOT NULL, -- Authoritative FK iam.member.
        context_id varchar(64) NOT NULL, -- event ID or GENERAL context.
        intent_type varchar(16) NOT NULL, -- WANT or OFFER.
        original_text varchar(4000) NOT NULL, -- member-authored display text.
        normalized_text varchar(4000) NOT NULL, -- PII-minimized normalization.
        normalized_hash char(64) NOT NULL, -- Content hash for idempotent embedding.
        language_code varchar(16) NOT NULL CONSTRAINT df_nlp_intent_language_code DEFAULT ('en'), -- Detected/approved language.
        contains_pii boolean NOT NULL CONSTRAINT df_nlp_intent_contains_pii DEFAULT (false), -- Preprocessing signal.
        status varchar(32) NOT NULL CONSTRAINT df_nlp_intent_status DEFAULT ('PROCESSING'), -- PROCESSING, MATCH_READY, FAILED, INACTIVE.
        category varchar(128) NULL, -- Structured category.
        industry varchar(128) NULL, -- Structured industry.
        geography varchar(128) NULL, -- Business geography, not live location.
        expires_at timestamptz NOT NULL, -- Freshness/eligibility expiry.
        preprocessing_version varchar(128) NOT NULL, -- Normalizer version.
        created_at timestamptz NOT NULL CONSTRAINT df_nlp_intent_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_nlp_intent_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_nlp_intent_ PRIMARY KEY (intent_id)
    );
-- nlp.nlp_embedding: Versioned vector for a normalized intent.
CREATE TABLE IF NOT EXISTS nlp.nlp_embedding (
        intent_id varchar(64) NOT NULL, -- FK nlp_intent.
        model_version varchar(128) NOT NULL, -- FK nlp_model_version.
        dimensions int NOT NULL, -- Vector dimensions.
        normalized_hash char(64) NOT NULL, -- Text version embedded.
        embedding vector(1536) NOT NULL, -- Exact cosine search remains bounded until HNSW is justified by load tests.
        status varchar(20) NOT NULL CONSTRAINT df_nlp_embedding_status DEFAULT ('ACTIVE'), -- ACTIVE, SUPERSEDED, FAILED.
        created_at timestamptz NOT NULL CONSTRAINT df_nlp_embedding_created_at DEFAULT (CURRENT_TIMESTAMP), -- Creation time.
        CONSTRAINT pk_nlp_embedding_ PRIMARY KEY (intent_id, model_version)
    );
-- nlp.nlp_model_version: Embedding provider/deployment and preprocessing compatibility.
CREATE TABLE IF NOT EXISTS nlp.nlp_model_version (
        model_version varchar(128) NOT NULL, -- Stable version.
        provider varchar(64) NOT NULL, -- Approved provider.
        deployment_name varchar(128) NOT NULL, -- Configuration reference, not secret.
        dimensions int NOT NULL, -- Expected vector length.
        preprocessing_version varchar(128) NOT NULL, -- Compatible preprocessing.
        status varchar(20) NOT NULL CONSTRAINT df_nlp_model_version_status DEFAULT ('CANDIDATE'), -- CANDIDATE, ACTIVE, RETIRED, ROLLED_BACK.
        activated_at timestamptz NULL, -- Promotion time.
        created_at timestamptz NOT NULL CONSTRAINT df_nlp_model_version_created_at DEFAULT (CURRENT_TIMESTAMP), -- Registration time.
        updated_at timestamptz NOT NULL CONSTRAINT df_nlp_model_version_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_nlp_model_version_ PRIMARY KEY (model_version)
    );
-- nlp.nlp_ranking_config: Versioned ranking weights, threshold and policy switches.
CREATE TABLE IF NOT EXISTS nlp.nlp_ranking_config (
        ranking_version varchar(128) NOT NULL, -- Stable configuration version.
        semantic_weight numeric(6,5) NOT NULL CONSTRAINT df_nlp_ranking_config_semantic_weight DEFAULT (0.40), -- Semantic/reciprocal weight.
        category_weight numeric(6,5) NOT NULL CONSTRAINT df_nlp_ranking_config_category_weight DEFAULT (0.25), -- Category compatibility.
        industry_weight numeric(6,5) NOT NULL CONSTRAINT df_nlp_ranking_config_industry_weight DEFAULT (0.15), -- Industry compatibility.
        geography_weight numeric(6,5) NOT NULL CONSTRAINT df_nlp_ranking_config_geography_weight DEFAULT (0.10), -- Business geography fit.
        freshness_weight numeric(6,5) NOT NULL CONSTRAINT df_nlp_ranking_config_freshness_weight DEFAULT (0.10), -- Intent freshness.
        event_weight numeric(6,5) NOT NULL CONSTRAINT df_nlp_ranking_config_event_weight DEFAULT (0), -- Optional event context after evaluation.
        threshold numeric(6,5) NOT NULL CONSTRAINT df_nlp_ranking_config_threshold DEFAULT (0.35), -- Display threshold.
        active_from timestamptz NOT NULL, -- Effective time.
        active_to timestamptz NULL, -- Retirement time.
        config_json jsonb NULL, -- Bounded extra rule settings.
        created_at timestamptz NOT NULL CONSTRAINT df_nlp_ranking_config_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_nlp_ranking_config_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_nlp_ranking_config_ PRIMARY KEY (ranking_version)
    );
-- nlp.nlp_processing_job: Intent embedding and re-embedding retry state.
CREATE TABLE IF NOT EXISTS nlp.nlp_processing_job (
        job_id varchar(64) NOT NULL, -- Job identifier.
        intent_id varchar(64) NOT NULL, -- Target intent.
        job_type varchar(24) NOT NULL CONSTRAINT df_nlp_processing_job_job_type DEFAULT ('EMBED'), -- EMBED or REEMBED. Normalization is synchronous for MVP.
        status varchar(20) NOT NULL CONSTRAINT df_nlp_processing_job_status DEFAULT ('PENDING'), -- PENDING, RUNNING, SUCCEEDED, FAILED, DEAD.
        attempt_count int NOT NULL CONSTRAINT df_nlp_processing_job_attempt_count DEFAULT (0), -- Bounded attempts.
        available_at timestamptz NOT NULL CONSTRAINT df_nlp_processing_job_available_at DEFAULT (CURRENT_TIMESTAMP), -- Retry schedule.
        locked_until timestamptz NULL, -- Worker lease.
        error_code varchar(64) NULL, -- Sanitized failure code.
        created_at timestamptz NOT NULL CONSTRAINT df_nlp_processing_job_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_nlp_processing_job_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_nlp_processing_job_ PRIMARY KEY (job_id)
    );
-- nlp.match_request: Idempotent match-search execution envelope.
CREATE TABLE IF NOT EXISTS nlp.match_request (
        request_id varchar(64) NOT NULL, -- Client/API idempotency key.
        request_hash char(64) NOT NULL, -- Canonical hash of matching inputs; detects idempotency-key reuse with different inputs.
        requester_id varchar(64) NOT NULL, -- Authenticated member.
        intent_id varchar(64) NOT NULL, -- Requester intent.
        context_id varchar(64) NOT NULL, -- Matching context.
        language_code varchar(16) NOT NULL CONSTRAINT df_match_request_language_code DEFAULT ('en'), -- Language snapshot used for this request.
        requested_limit smallint NOT NULL CONSTRAINT df_match_request_requested_limit DEFAULT (7), -- Allowed 3-7.
        request_options_json jsonb NULL, -- Validated bounded options snapshot; no free-form secrets or raw provider payloads.
        status varchar(20) NOT NULL CONSTRAINT df_match_request_status DEFAULT ('PROCESSING'), -- PROCESSING, COMPLETED, FAILED.
        preprocessing_version varchar(128) NULL, -- Resolved synchronous normalization version.
        model_version varchar(128) NULL, -- Resolved model version.
        ranking_version varchar(128) NULL, -- Resolved ranking version.
        ranking_threshold numeric(6,5) NULL, -- Immutable threshold snapshot applied to this execution.
        candidate_count int NULL, -- Eligible bounded candidates examined.
        completed_at timestamptz NULL, -- Completion time.
        created_at timestamptz NOT NULL CONSTRAINT df_match_request_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_match_request_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_match_request_ PRIMARY KEY (request_id)
    );
-- nlp.nlp_match_result: Ranked, explained recommendation returned for one request.
CREATE TABLE IF NOT EXISTS nlp.nlp_match_result (
        match_result_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Internal key.
        request_id varchar(64) NOT NULL, -- FK match_request.
        requester_id varchar(64) NOT NULL, -- Requester.
        candidate_id varchar(64) NOT NULL, -- Candidate.
        rank smallint NOT NULL, -- 1-based result rank.
        semantic_score numeric(8,7) NOT NULL, -- Semantic score.
        reciprocal_score numeric(8,7) NULL, -- Bidirectional harmonic/approved score.
        final_score numeric(8,7) NOT NULL, -- Versioned final ranking score.
        label varchar(32) NOT NULL, -- STRONG_MATCH, PLAUSIBLE_MATCH, etc.
        reason_codes jsonb NOT NULL, -- JSON array of approved codes.
        reason_text varchar(2000) NOT NULL, -- Deterministic explanation.
        model_version varchar(128) NOT NULL, -- Embedding version.
        preprocessing_version varchar(128) NOT NULL, -- Normalization version.
        ranking_version varchar(128) NOT NULL, -- Ranking configuration.
        policy_status varchar(24) NOT NULL CONSTRAINT df_nlp_match_result_policy_status DEFAULT ('ELIGIBLE'), -- ELIGIBLE or SUPPRESSED.
        created_at timestamptz NOT NULL CONSTRAINT df_nlp_match_result_created_at DEFAULT (CURRENT_TIMESTAMP), -- Creation time.
        CONSTRAINT pk_nlp_match_result_ PRIMARY KEY (match_result_id)
    );
-- nlp.nlp_feedback: Useful/not useful/inappropriate signal for recommendation quality.
CREATE TABLE IF NOT EXISTS nlp.nlp_feedback (
        feedback_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Internal key.
        supersedes_feedback_id bigint NULL, -- Optional self-FK to the earlier feedback corrected by this row.
        match_result_id bigint NOT NULL, -- FK nlp_match_result.
        request_id varchar(64) NOT NULL, -- Denormalized request for compatibility.
        requester_id varchar(64) NOT NULL, -- Authenticated feedback author.
        candidate_id varchar(64) NOT NULL, -- Candidate.
        label varchar(64) NOT NULL, -- USEFUL, NOT_USEFUL, INAPPROPRIATE.
        reason_code varchar(64) NULL, -- Controlled error category.
        reason varchar(1000) NULL, -- Optional free text, PII checked.
        created_at timestamptz NOT NULL CONSTRAINT df_nlp_feedback_created_at DEFAULT (CURRENT_TIMESTAMP), -- Feedback time.
        CONSTRAINT pk_nlp_feedback_ PRIMARY KEY (feedback_id)
    );
-- nlp.match_suppression: Administrative or safety suppression independent of model score.
CREATE TABLE IF NOT EXISTS nlp.match_suppression (
        suppression_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Internal key.
        member_id varchar(64) NULL, -- Affected member.
        intent_id varchar(64) NULL, -- Affected intent.
        context_id varchar(64) NULL, -- Optional context.
        reason_code varchar(64) NOT NULL, -- Controlled reason.
        starts_at timestamptz NOT NULL CONSTRAINT df_match_suppression_starts_at DEFAULT (CURRENT_TIMESTAMP), -- Effective time.
        ends_at timestamptz NULL, -- Optional expiry.
        created_by varchar(64) NOT NULL, -- Administrator/service actor.
        CONSTRAINT pk_match_suppression_ PRIMARY KEY (suppression_id)
    );
-- nlp.evaluation_dataset: Versioned labelled-pair dataset metadata.
CREATE TABLE IF NOT EXISTS nlp.evaluation_dataset (
        dataset_id varchar(64) NOT NULL, -- Dataset version ID.
        name varchar(200) NOT NULL, -- Display name.
        version varchar(32) NOT NULL, -- Immutable version.
        description varchar(1000) NULL, -- Sampling/labeling notes.
        source_policy varchar(500) NOT NULL, -- De-identification/provenance statement.
        status varchar(20) NOT NULL CONSTRAINT df_evaluation_dataset_status DEFAULT ('DRAFT'), -- DRAFT, APPROVED, RETIRED.
        approved_by varchar(64) NULL, -- Evaluator/admin.
        created_at timestamptz NOT NULL CONSTRAINT df_evaluation_dataset_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_evaluation_dataset_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_evaluation_dataset_ PRIMARY KEY (dataset_id)
    );
-- nlp.evaluation_pair: One labelled reciprocal matching example.
CREATE TABLE IF NOT EXISTS nlp.evaluation_pair (
        evaluation_pair_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Pair identifier.
        dataset_id varchar(64) NOT NULL, -- FK evaluation_dataset.
        requester_intent_text varchar(4000) NOT NULL, -- De-identified requester sample.
        candidate_intent_text varchar(4000) NOT NULL, -- De-identified candidate sample.
        structured_features_json jsonb NULL, -- Category/industry/geography features.
        gold_label varchar(32) NOT NULL, -- STRONG, PLAUSIBLE, WEAK, NONE, UNSAFE.
        split varchar(16) NOT NULL, -- TRAIN, VALIDATION or TEST.
        organization_group varchar(64) NULL, -- Leakage-prevention grouping, pseudonymous.
        label_reason varchar(1000) NULL, -- Evaluator rationale.
        CONSTRAINT pk_evaluation_pair_ PRIMARY KEY (evaluation_pair_id)
    );
-- nlp.evaluation_run: Reproducible quality evaluation output.
CREATE TABLE IF NOT EXISTS nlp.evaluation_run (
        evaluation_run_id varchar(64) NOT NULL, -- Run identifier.
        dataset_id varchar(64) NOT NULL, -- Dataset version.
        model_version varchar(128) NOT NULL, -- Model under test.
        ranking_version varchar(128) NOT NULL, -- Ranking config.
        status varchar(20) NOT NULL CONSTRAINT df_evaluation_run_status DEFAULT ('RUNNING'), -- RUNNING, PASSED, FAILED, ERROR.
        metrics_json jsonb NULL, -- Precision@5, Recall@20, reciprocal precision, coverage.
        error_report_blob_path varchar(1024) NULL, -- Private report artifact.
        started_at timestamptz NOT NULL CONSTRAINT df_evaluation_run_started_at DEFAULT (CURRENT_TIMESTAMP), -- Run start.
        completed_at timestamptz NULL, -- Run completion.
        CONSTRAINT pk_evaluation_run_ PRIMARY KEY (evaluation_run_id)
    );
-- moderation.moderation_case: Unified case for member reports, content flags and account review.
CREATE TABLE IF NOT EXISTS moderation.moderation_case (
        moderation_case_id varchar(64) NOT NULL, -- Case identifier.
        source_type varchar(32) NOT NULL, -- MEMBER_REPORT, AUTO_SCAN, ADMIN_REVIEW.
        source_id varchar(64) NULL, -- Source record identifier.
        subject_member_id varchar(64) NULL, -- member under review.
        resource_type varchar(32) NULL, -- PROFILE, MESSAGE, ATTACHMENT, INTENT.
        resource_id varchar(64) NULL, -- Reviewed resource.
        priority varchar(16) NOT NULL CONSTRAINT df_moderation_case_priority DEFAULT ('NORMAL'), -- LOW, NORMAL, HIGH, URGENT.
        status varchar(24) NOT NULL CONSTRAINT df_moderation_case_status DEFAULT ('OPEN'), -- OPEN, TRIAGED, ACTIONED, CLOSED.
        assigned_to varchar(64) NULL, -- Moderator.
        closed_at timestamptz NULL, -- Closure time.
        created_at timestamptz NOT NULL CONSTRAINT df_moderation_case_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_moderation_case_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_moderation_case_ PRIMARY KEY (moderation_case_id)
    );
-- moderation.moderation_action: Append-only action taken within a moderation case.
CREATE TABLE IF NOT EXISTS moderation.moderation_action (
        moderation_action_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Action identifier.
        moderation_case_id varchar(64) NOT NULL, -- FK moderation_case.
        actor_member_id varchar(64) NOT NULL, -- Moderator/admin.
        action_type varchar(64) NOT NULL, -- WARN, HIDE, SUSPEND, REJECT_FILE, CLOSE, etc.
        reason_code varchar(64) NOT NULL, -- Controlled reason.
        notes varchar(2000) NULL, -- Restricted case notes.
        effective_until timestamptz NULL, -- Temporary action expiry.
        created_at timestamptz NOT NULL CONSTRAINT df_moderation_action_created_at DEFAULT (CURRENT_TIMESTAMP), -- Action time.
        CONSTRAINT pk_moderation_action_ PRIMARY KEY (moderation_action_id)
    );
-- moderation.content_rule: Versioned blocked-content and moderation configuration.
CREATE TABLE IF NOT EXISTS moderation.content_rule (
        content_rule_id varchar(64) NOT NULL, -- Rule ID.
        rule_type varchar(32) NOT NULL, -- FILE_TYPE, TERM, RATE, POLICY.
        version varchar(32) NOT NULL, -- Rule version.
        config_json jsonb NOT NULL, -- Validated rule configuration.
        status varchar(16) NOT NULL CONSTRAINT df_content_rule_status DEFAULT ('DRAFT'), -- DRAFT, ACTIVE, RETIRED.
        active_from timestamptz NULL, -- Activation time.
        created_by varchar(64) NOT NULL, -- Administrator.
        created_at timestamptz NOT NULL CONSTRAINT df_content_rule_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_content_rule_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_content_rule_ PRIMARY KEY (content_rule_id)
    );
-- moderation.content_scan: Malware/content scan result for files or text resources.
CREATE TABLE IF NOT EXISTS moderation.content_scan (
        content_scan_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Scan record.
        resource_type varchar(32) NOT NULL, -- FILE_ASSET, PROFILE, INTENT or MESSAGE.
        resource_id varchar(64) NOT NULL, -- Target object.
        scanner varchar(64) NOT NULL, -- Scanner/provider ID.
        scanner_version varchar(64) NULL, -- Engine/signature version.
        result varchar(24) NOT NULL, -- CLEAN, FLAGGED, MALICIOUS, ERROR.
        reason_codes jsonb NULL, -- Sanitized JSON reason codes.
        scanned_at timestamptz NOT NULL CONSTRAINT df_content_scan_scanned_at DEFAULT (CURRENT_TIMESTAMP), -- Scan time.
        CONSTRAINT pk_content_scan_ PRIMARY KEY (content_scan_id)
    );
-- ops.sync_change: Authorization-safe mobile delta feed and tombstone ledger.
CREATE TABLE IF NOT EXISTS ops.sync_change (
        sync_sequence bigint NOT NULL CONSTRAINT df_sync_change_sync_sequence DEFAULT (nextval('ops.sync_change_sequence')), -- Monotonic sync API cursor.
        community_id varchar(64) NOT NULL, -- FK core.community.
        member_scope_id varchar(64) NULL, -- Optional member-specific visibility scope.
        resource_type varchar(32) NOT NULL, -- PROFILE, MATCH, REQUEST, CONVERSATION, MESSAGE or NOTIFICATION.
        resource_id varchar(64) NOT NULL, -- Changed resource identifier.
        change_type varchar(16) NOT NULL, -- UPSERT or DELETE.
        resource_version bigint NULL, -- Source concurrency-version snapshot where available.
        payload_json jsonb NULL, -- Minimum authorization-safe read-model payload; null for protected tombstones.
        occurred_at timestamptz NOT NULL CONSTRAINT df_sync_change_occurred_at DEFAULT (CURRENT_TIMESTAMP), -- Authoritative change time.
        expires_at timestamptz NOT NULL, -- Earliest purge time.
        CONSTRAINT pk_sync_change_ PRIMARY KEY (sync_sequence)
    );
-- ops.retention_policy: Versioned retention and disposition rules for product data classes.
CREATE TABLE IF NOT EXISTS ops.retention_policy (
        retention_policy_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Immutable policy version identifier.
        resource_type varchar(64) NOT NULL, -- Governed product data class.
        policy_version smallint NOT NULL CONSTRAINT df_retention_policy_policy_version DEFAULT (1), -- Monotonic version per resource type.
        status varchar(16) NOT NULL CONSTRAINT df_retention_policy_status DEFAULT ('DRAFT'), -- DRAFT, ACTIVE or RETIRED.
        retention_days int NOT NULL, -- Approved retention duration.
        disposition_action varchar(20) NOT NULL, -- DELETE, ANONYMIZE or ARCHIVE.
        legal_hold_supported boolean NOT NULL CONSTRAINT df_retention_policy_legal_hold_supported DEFAULT (true), -- Whether disposition can be delayed by approved legal hold.
        effective_from timestamptz NOT NULL, -- Activation time.
        effective_to timestamptz NULL, -- Optional retirement time.
        approved_by varchar(64) NULL, -- Approving privacy/security administrator.
        created_at timestamptz NOT NULL CONSTRAINT df_retention_policy_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_retention_policy_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_retention_policy_ PRIMARY KEY (retention_policy_id)
    );
-- ops.retention_execution: Auditable execution result for one retention policy batch or resource.
CREATE TABLE IF NOT EXISTS ops.retention_execution (
        retention_execution_id varchar(64) NOT NULL, -- Execution identifier.
        retention_policy_id bigint NOT NULL, -- Immutable policy version applied.
        scope_start timestamptz NOT NULL, -- Inclusive evaluation window start.
        scope_end timestamptz NOT NULL, -- Exclusive evaluation window end.
        status varchar(20) NOT NULL CONSTRAINT df_retention_execution_status DEFAULT ('RUNNING'), -- RUNNING, SUCCEEDED, PARTIAL or FAILED.
        examined_count bigint NOT NULL CONSTRAINT df_retention_execution_examined_count DEFAULT (0), -- Rows/resources evaluated.
        disposed_count bigint NOT NULL CONSTRAINT df_retention_execution_disposed_count DEFAULT (0), -- Rows/resources disposed.
        skipped_hold_count bigint NOT NULL CONSTRAINT df_retention_execution_skipped_hold_count DEFAULT (0), -- Resources skipped due to legal hold.
        evidence_hash char(64) NULL, -- Hash of execution manifest/log evidence.
        started_at timestamptz NOT NULL CONSTRAINT df_retention_execution_started_at DEFAULT (CURRENT_TIMESTAMP), -- Execution start.
        completed_at timestamptz NULL, -- Terminal completion time.
        error_code varchar(64) NULL, -- Sanitized terminal error.
        CONSTRAINT pk_retention_execution_ PRIMARY KEY (retention_execution_id)
    );
-- ops.outbox_event: Transactional event publication without dual-write loss.
CREATE TABLE IF NOT EXISTS ops.outbox_event (
        outbox_event_id varchar(64) NOT NULL, -- event ID/idempotency token.
        aggregate_type varchar(64) NOT NULL, -- MEMBER, CONNECTION, MESSAGE, INTENT.
        aggregate_id varchar(64) NOT NULL, -- Source aggregate.
        event_type varchar(128) NOT NULL, -- Versioned event name.
        payload_json jsonb NOT NULL, -- Minimal event payload; avoid raw content.
        occurred_at timestamptz NOT NULL CONSTRAINT df_outbox_event_occurred_at DEFAULT (CURRENT_TIMESTAMP), -- Business event time.
        published_at timestamptz NULL, -- Successful publish time.
        attempt_count int NOT NULL CONSTRAINT df_outbox_event_attempt_count DEFAULT (0), -- Publish attempts.
        next_attempt_at timestamptz NULL, -- Retry schedule.
        CONSTRAINT pk_outbox_event_ PRIMARY KEY (outbox_event_id)
    );
-- ops.idempotency_record: Safe replay of mobile/API commands.
CREATE TABLE IF NOT EXISTS ops.idempotency_record (
        scope varchar(64) NOT NULL, -- API/operation scope.
        idempotency_key varchar(128) NOT NULL, -- Client key.
        actor_id varchar(64) NOT NULL, -- Authenticated member/service; part of the replay boundary.
        request_hash char(64) NOT NULL, -- Detect key reuse with different body.
        status_code smallint NULL, -- Cached response status.
        response_ref varchar(1000) NULL, -- Bounded response or resource reference.
        created_at timestamptz NOT NULL CONSTRAINT df_idempotency_record_created_at DEFAULT (CURRENT_TIMESTAMP), -- First request.
        expires_at timestamptz NOT NULL, -- Purge time.
        CONSTRAINT pk_idempotency_record_ PRIMARY KEY (scope, actor_id, idempotency_key)
    );
-- ops.background_job: Non-NLP background task lifecycle.
CREATE TABLE IF NOT EXISTS ops.background_job (
        background_job_id varchar(64) NOT NULL, -- Job ID.
        job_type varchar(64) NOT NULL, -- SCAN_FILE, SEND_NOTIFICATION, PURGE_PRESENCE, etc.
        resource_type varchar(32) NULL, -- Target type.
        resource_id varchar(64) NULL, -- Target ID.
        payload_json jsonb NULL, -- Minimal validated payload.
        status varchar(20) NOT NULL CONSTRAINT df_background_job_status DEFAULT ('PENDING'), -- PENDING, RUNNING, SUCCEEDED, FAILED, DEAD.
        attempt_count int NOT NULL CONSTRAINT df_background_job_attempt_count DEFAULT (0), -- Attempts.
        available_at timestamptz NOT NULL CONSTRAINT df_background_job_available_at DEFAULT (CURRENT_TIMESTAMP), -- Schedule/retry time.
        error_code varchar(64) NULL, -- Sanitized failure.
        created_at timestamptz NOT NULL CONSTRAINT df_background_job_created_at DEFAULT (CURRENT_TIMESTAMP), -- UTC creation time.
        updated_at timestamptz NOT NULL CONSTRAINT df_background_job_updated_at DEFAULT (CURRENT_TIMESTAMP), -- UTC last material update time.
        row_version bigint NOT NULL DEFAULT 1, -- Optimistic concurrency token; never client supplied.
        CONSTRAINT pk_background_job_ PRIMARY KEY (background_job_id)
    );
-- ops.audit_event: Append-only evidence of sensitive/security/admin actions.
CREATE TABLE IF NOT EXISTS ops.audit_event (
        audit_event_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Monotonic audit key.
        actor_type varchar(24) NOT NULL, -- MEMBER, ADMIN, SERVICE, SYSTEM.
        actor_id varchar(64) NULL, -- Pseudonymous/service identity.
        action varchar(128) NOT NULL, -- Versioned action code.
        resource_type varchar(64) NULL, -- Affected type.
        resource_id varchar(64) NULL, -- Affected ID.
        outcome varchar(16) NOT NULL, -- SUCCESS or DENIED/FAILED.
        correlation_id varchar(64) NOT NULL, -- End-to-end trace ID.
        metadata_json jsonb NULL, -- Allowlisted, content-free metadata.
        occurred_at timestamptz NOT NULL CONSTRAINT df_audit_event_occurred_at DEFAULT (CURRENT_TIMESTAMP), -- event time.
        CONSTRAINT pk_audit_event_ PRIMARY KEY (audit_event_id)
    );
-- analytics.product_event: Privacy-safe product funnel and match-quality analytics.
CREATE TABLE IF NOT EXISTS analytics.product_event (
        product_event_id varchar(64) NOT NULL, -- event ID.
        event_name varchar(128) NOT NULL, -- PROFILE_COMPLETED, MATCH_VIEWED, REQUEST_SENT, etc.
        member_pseudonym char(64) NULL, -- Environment-specific salted hash, not member_id.
        community_id varchar(64) NOT NULL, -- Aggregation boundary.
        context_type varchar(32) NULL, -- EVENT or GENERAL.
        context_id varchar(64) NULL, -- Allowed context reference.
        properties_json jsonb NULL, -- Allowlisted non-content dimensions.
        occurred_at timestamptz NOT NULL, -- Client/server event time.
        received_at timestamptz NOT NULL CONSTRAINT df_product_event_received_at DEFAULT (CURRENT_TIMESTAMP), -- Server receipt time.
        CONSTRAINT pk_product_event_ PRIMARY KEY (product_event_id)
    );

-- Shared optimistic-concurrency trigger; API clients never supply row_version.
DO $$
DECLARE target record;
BEGIN
    FOR target IN
        SELECT table_schema, table_name
        FROM information_schema.columns
        WHERE column_name = 'row_version'
          AND table_schema IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops')
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS set_row_version ON %I.%I', target.table_schema, target.table_name);
        EXECUTE format(
            'CREATE TRIGGER set_row_version BEFORE UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION ops.set_row_version()',
            target.table_schema, target.table_name
        );
    END LOOP;
END;
$$;

-- ======================== AUDIT ATTRIBUTION AND TEMPORAL HISTORY ========================
-- Database-sourced actor attribution for mutable API resources. Applications should set
-- olga.actor_id after authenticating each request.
CREATE OR REPLACE FUNCTION ops.set_audit_context(p_actor_id varchar(64))
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    IF p_actor_id IS NULL OR btrim(p_actor_id) = '' THEN
        RAISE EXCEPTION 'Audit actor ID is required.' USING ERRCODE = '22023';
    END IF;
    PERFORM set_config('olga.actor_id', p_actor_id, true);
END;
$function$;

CREATE OR REPLACE FUNCTION ops.current_audit_actor_id()
RETURNS varchar(64)
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(NULLIF(current_setting('olga.actor_id', true), ''), session_user)::varchar(64)
$function$;

CREATE OR REPLACE FUNCTION ops.set_audit_actor()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops
AS $function$
DECLARE
    v_actor_id varchar(64) := ops.current_audit_actor_id();
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Never trust audit identities supplied in an INSERT payload.
        NEW.created_by := v_actor_id;
        NEW.updated_by := v_actor_id;
    ELSE
        NEW.created_by := OLD.created_by;
        NEW.updated_by := v_actor_id;
        NEW.updated_at := CURRENT_TIMESTAMP;
    END IF;
    RETURN NEW;
END;
$function$;

-- Add lifecycle support to the few reusable records that had no disable/retire state.
ALTER TABLE iam.member_identity ADD COLUMN IF NOT EXISTS status varchar(16) NOT NULL DEFAULT 'ACTIVE';
ALTER TABLE iam.member_identity ADD COLUMN IF NOT EXISTS revoked_at timestamptz NULL;
ALTER TABLE iam.member_identity ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE iam.member_identity ADD COLUMN IF NOT EXISTS row_version bigint NOT NULL DEFAULT 1;
ALTER TABLE iam.role ADD COLUMN IF NOT EXISTS status varchar(16) NOT NULL DEFAULT 'ACTIVE';
ALTER TABLE event.venue ADD COLUMN IF NOT EXISTS status varchar(16) NOT NULL DEFAULT 'ACTIVE';
ALTER TABLE chat.message ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE nlp.nlp_model_version ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE nlp.nlp_model_version ADD COLUMN IF NOT EXISTS row_version bigint NOT NULL DEFAULT 1;
ALTER TABLE nlp.nlp_ranking_config ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE nlp.nlp_ranking_config ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE nlp.nlp_ranking_config ADD COLUMN IF NOT EXISTS row_version bigint NOT NULL DEFAULT 1;

-- Audit actors may be members, administrators, services, or the database system; they are
-- intentionally polymorphic rather than foreign keys to iam.member.
ALTER TABLE nlp.match_suppression DROP CONSTRAINT IF EXISTS fk_match_suppression_created_by;
ALTER TABLE moderation.content_rule DROP CONSTRAINT IF EXISTS fk_content_rule_created_by;

-- Repair lifecycle checks from the prior baseline only when they omit documented states.
DO $block$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'iam.member'::regclass AND conname = 'ck_member_status'
          AND pg_get_constraintdef(oid) NOT LIKE '%ANONYMIZED%'
    ) THEN
        ALTER TABLE iam.member DROP CONSTRAINT ck_member_status;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'core.member_profile'::regclass AND conname = 'ck_member_profile_profile_status'
          AND pg_get_constraintdef(oid) NOT LIKE '%PENDING_REVIEW%'
    ) THEN
        ALTER TABLE core.member_profile DROP CONSTRAINT ck_member_profile_profile_status;
    END IF;
END;
$block$;

-- Every row_version-backed resource receives immutable creator attribution and a last-writer actor.
-- UNKNOWN is used only when upgrading rows that predate actor capture.
DO $block$
DECLARE
    target record;
BEGIN
    FOR target IN
        SELECT DISTINCT table_schema, table_name
        FROM information_schema.columns
        WHERE (
                column_name = 'row_version'
                AND table_schema IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops')
              )
           OR (table_schema, table_name) IN (
                ('nlp','nlp_model_version'),
                ('nlp','nlp_ranking_config')
              )
    LOOP
        EXECUTE format('ALTER TABLE %I.%I ADD COLUMN IF NOT EXISTS created_by varchar(64)', target.table_schema, target.table_name);
        EXECUTE format('ALTER TABLE %I.%I ADD COLUMN IF NOT EXISTS updated_by varchar(64)', target.table_schema, target.table_name);

        EXECUTE format(
            'UPDATE %I.%I SET created_by = COALESCE(created_by, %L), updated_by = COALESCE(updated_by, created_by, %L) WHERE created_by IS NULL OR updated_by IS NULL',
            target.table_schema, target.table_name, 'legacy_unknown', 'legacy_unknown'
        );

        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN created_by SET DEFAULT ops.current_audit_actor_id()', target.table_schema, target.table_name);
        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN updated_by SET DEFAULT ops.current_audit_actor_id()', target.table_schema, target.table_name);
        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN created_by SET NOT NULL', target.table_schema, target.table_name);
        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN updated_by SET NOT NULL', target.table_schema, target.table_name);

        EXECUTE format('DROP TRIGGER IF EXISTS set_audit_actor ON %I.%I', target.table_schema, target.table_name);
        EXECUTE format(
            'CREATE TRIGGER set_audit_actor BEFORE INSERT OR UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION ops.set_audit_actor()',
            target.table_schema, target.table_name
        );

        IF EXISTS (
            SELECT 1 FROM information_schema.columns c
            WHERE c.table_schema = target.table_schema AND c.table_name = target.table_name AND c.column_name = 'row_version'
        ) THEN
            EXECUTE format('DROP TRIGGER IF EXISTS set_row_version ON %I.%I', target.table_schema, target.table_name);
            EXECUTE format(
                'CREATE TRIGGER set_row_version BEFORE UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION ops.set_row_version()',
                target.table_schema, target.table_name
            );
        END IF;
    END LOOP;
END;
$block$;

-- PostgreSQL 17 has no native SQL Server-style FOR SYSTEM_TIME syntax. Archive OLD rows with an
-- OLGA-owned trigger because Azure-owned extension functions cannot safely be changed to
-- SECURITY DEFINER by a customer administrator.
-- History is intentionally limited to low-volume reference/configuration tables; copying member
-- content, identity ciphertext, messages or presence would conflict with privacy and retention.
CREATE OR REPLACE FUNCTION ops.archive_row_version()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops
AS $function$
DECLARE
    v_effective_at timestamptz := transaction_timestamp();
    v_period_start timestamptz;
    v_history_table regclass;
    v_history_schema name;
BEGIN
    IF TG_WHEN <> 'BEFORE' OR TG_LEVEL <> 'ROW'
       OR TG_OP NOT IN ('INSERT', 'UPDATE', 'DELETE') THEN
        RAISE EXCEPTION 'archive_row_version must be a BEFORE ROW trigger for INSERT, UPDATE or DELETE.'
            USING ERRCODE = '55000';
    END IF;
    IF TG_NARGS <> 1 THEN
        RAISE EXCEPTION 'archive_row_version requires one history-table argument.'
            USING ERRCODE = '22023';
    END IF;

    v_history_table := to_regclass(TG_ARGV[0]);
    IF v_history_table IS NULL THEN
        RAISE EXCEPTION 'History table % does not exist.', TG_ARGV[0]
            USING ERRCODE = '42P01';
    END IF;
    SELECT n.nspname
      INTO v_history_schema
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = v_history_table;
    IF v_history_schema <> 'history' THEN
        RAISE EXCEPTION 'History target must be in the history schema.'
            USING ERRCODE = '22023';
    END IF;

    IF TG_OP = 'INSERT' THEN
        NEW.sys_period := tstzrange(v_effective_at, NULL, '[)');
        RETURN NEW;
    END IF;

    v_period_start := lower(OLD.sys_period);
    IF v_period_start IS NULL OR v_period_start > v_effective_at THEN
        RAISE EXCEPTION 'Invalid system period on %.%.', TG_TABLE_SCHEMA, TG_TABLE_NAME
            USING ERRCODE = '22000';
    END IF;

    -- Multiple changes to a row in one transaction collapse into one externally visible version.
    IF v_period_start < v_effective_at THEN
        OLD.sys_period := tstzrange(v_period_start, v_effective_at, '[)');
        EXECUTE format('INSERT INTO %s SELECT ($1).*', v_history_table) USING OLD;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        NEW.sys_period := tstzrange(v_effective_at, NULL, '[)');
        RETURN NEW;
    END IF;
    RETURN OLD;
END;
$function$;

DO $block$
DECLARE
    target record;
    history_table name;
BEGIN
    FOR target IN
        SELECT * FROM (VALUES
            ('iam','permission','permission_code'),
            ('iam','role','role_code'),
            ('core','sector','sector_code'),
            ('consent','consent_policy','policy_id'),
            ('event','venue','venue_id'),
            ('event','event_matching_policy','event_matching_policy_id'),
            ('notification','notification_policy','notification_policy_id'),
            ('nlp','nlp_model_version','model_version'),
            ('nlp','nlp_ranking_config','ranking_version'),
            ('moderation','content_rule','content_rule_id'),
            ('ops','retention_policy','retention_policy_id')
        ) AS configured(table_schema, table_name, key_column)
    LOOP
        history_table := (target.table_schema || '_' || target.table_name)::name;
        EXECUTE format(
            'ALTER TABLE %I.%I ADD COLUMN IF NOT EXISTS sys_period tstzrange NOT NULL DEFAULT tstzrange(CURRENT_TIMESTAMP, NULL, ''[)'')',
            target.table_schema, target.table_name
        );
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS history.%I (LIKE %I.%I INCLUDING DEFAULTS)',
            history_table, target.table_schema, target.table_name
        );
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS %I ON history.%I (%I, lower(sys_period) DESC)',
            ('ix_' || history_table || '_key_period')::name, history_table, target.key_column
        );
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS %I ON history.%I USING gist (sys_period)',
            ('ix_' || history_table || '_sys_period')::name, history_table
        );
        EXECUTE format('DROP TRIGGER IF EXISTS versioning_history ON %I.%I', target.table_schema, target.table_name);
        EXECUTE format(
            'CREATE TRIGGER versioning_history BEFORE INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION ops.archive_row_version(%L)',
            target.table_schema, target.table_name, 'history.' || quote_ident(history_table)
        );
        EXECUTE format(
            'CREATE OR REPLACE VIEW history.%I AS SELECT * FROM %I.%I UNION ALL SELECT * FROM history.%I',
            (history_table || '_all')::name, target.table_schema, target.table_name, history_table
        );
    END LOOP;
END;
$block$;

-- ======================== CONSTRAINTS AND INDEXES ========================
SELECT ops.add_constraint_if_missing('iam', 'member', 'fk_member_community_id', $constraint$FOREIGN KEY (community_id) REFERENCES core.community (community_id)$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'member_identity', 'fk_member_identity_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'member_role', 'fk_member_role_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'member_role', 'fk_member_role_role_code', $constraint$FOREIGN KEY (role_code) REFERENCES iam.role (role_code)$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'member_role', 'fk_member_role_granted_by', $constraint$FOREIGN KEY (granted_by) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'member_device', 'fk_member_device_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'organization', 'fk_organization_community_id', $constraint$FOREIGN KEY (community_id) REFERENCES core.community (community_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'organization_member', 'fk_organization_member_organization_id', $constraint$FOREIGN KEY (organization_id) REFERENCES core.organization (organization_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'organization_member', 'fk_organization_member_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_profile', 'fk_member_profile_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'sector', 'fk_sector_parent_sector_code', $constraint$FOREIGN KEY (parent_sector_code) REFERENCES core.sector (sector_code)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_sector', 'fk_member_sector_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_sector', 'fk_member_sector_sector_code', $constraint$FOREIGN KEY (sector_code) REFERENCES core.sector (sector_code)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_geography', 'fk_member_geography_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'profile_field_visibility', 'fk_profile_field_visibility_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_verification', 'fk_member_verification_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_verification', 'fk_member_verification_evidence_file_asset_id', $constraint$FOREIGN KEY (evidence_file_asset_id) REFERENCES storage.file_asset (file_asset_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_verification', 'fk_member_verification_reviewed_by', $constraint$FOREIGN KEY (reviewed_by) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('consent', 'member_consent', 'fk_member_consent_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('consent', 'member_consent', 'fk_member_consent_policy_id', $constraint$FOREIGN KEY (policy_id) REFERENCES consent.consent_policy (policy_id)$constraint$);
SELECT ops.add_constraint_if_missing('consent', 'privacy_request', 'fk_privacy_request_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('consent', 'privacy_request', 'fk_privacy_request_result_file_asset_id', $constraint$FOREIGN KEY (result_file_asset_id) REFERENCES storage.file_asset (file_asset_id)$constraint$);
SELECT ops.add_constraint_if_missing('event', 'event', 'fk_event_community_id', $constraint$FOREIGN KEY (community_id) REFERENCES core.community (community_id)$constraint$);
SELECT ops.add_constraint_if_missing('event', 'event', 'fk_event_venue_id', $constraint$FOREIGN KEY (venue_id) REFERENCES event.venue (venue_id)$constraint$);
SELECT ops.add_constraint_if_missing('event', 'event_matching_policy', 'fk_event_matching_policy_event_id', $constraint$FOREIGN KEY (event_id) REFERENCES event.event (event_id)$constraint$);
SELECT ops.add_constraint_if_missing('event', 'event_registration', 'fk_event_registration_event_id', $constraint$FOREIGN KEY (event_id) REFERENCES event.event (event_id)$constraint$);
SELECT ops.add_constraint_if_missing('event', 'event_registration', 'fk_event_registration_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('event', 'live_mode_session', 'fk_live_mode_session_event_id', $constraint$FOREIGN KEY (event_id) REFERENCES event.event (event_id)$constraint$);
SELECT ops.add_constraint_if_missing('event', 'live_mode_session', 'fk_live_mode_session_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('event', 'live_mode_session', 'fk_live_mode_session_consent_record_id', $constraint$FOREIGN KEY (consent_record_id) REFERENCES consent.member_consent (member_consent_id)$constraint$);
SELECT ops.add_constraint_if_missing('event', 'event_presence', 'fk_event_presence_live_session_id', $constraint$FOREIGN KEY (live_session_id) REFERENCES event.live_mode_session (live_session_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'connection_request', 'fk_connection_request_sender_member_id', $constraint$FOREIGN KEY (sender_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'connection_request', 'fk_connection_request_recipient_member_id', $constraint$FOREIGN KEY (recipient_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'connection_request', 'fk_connection_request_match_result_id', $constraint$FOREIGN KEY (match_result_id) REFERENCES nlp.nlp_match_result (match_result_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'connection', 'fk_connection_member_low_id', $constraint$FOREIGN KEY (member_low_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'connection', 'fk_connection_member_high_id', $constraint$FOREIGN KEY (member_high_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'connection', 'fk_connection_accepted_request_id', $constraint$FOREIGN KEY (accepted_request_id) REFERENCES social.connection_request (connection_request_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'member_block', 'fk_member_block_blocker_member_id', $constraint$FOREIGN KEY (blocker_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'member_block', 'fk_member_block_blocked_member_id', $constraint$FOREIGN KEY (blocked_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'member_report', 'fk_member_report_reporter_member_id', $constraint$FOREIGN KEY (reporter_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'member_report', 'fk_member_report_reported_member_id', $constraint$FOREIGN KEY (reported_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('chat', 'conversation', 'fk_conversation_connection_id', $constraint$FOREIGN KEY (connection_id) REFERENCES social.connection (connection_id)$constraint$);
SELECT ops.add_constraint_if_missing('chat', 'conversation_participant', 'fk_conversation_participant_conversation_id', $constraint$FOREIGN KEY (conversation_id) REFERENCES chat.conversation (conversation_id)$constraint$);
SELECT ops.add_constraint_if_missing('chat', 'conversation_participant', 'fk_conversation_participant_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('chat', 'conversation_participant', 'fk_conversation_participant_last_read_message_id', $constraint$FOREIGN KEY (last_read_message_id) REFERENCES chat.message (message_id)$constraint$);
SELECT ops.add_constraint_if_missing('chat', 'message', 'fk_message_conversation_id', $constraint$FOREIGN KEY (conversation_id) REFERENCES chat.conversation (conversation_id)$constraint$);
SELECT ops.add_constraint_if_missing('chat', 'message', 'fk_message_sender_member_id', $constraint$FOREIGN KEY (sender_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('chat', 'message_receipt', 'fk_message_receipt_message_id', $constraint$FOREIGN KEY (message_id) REFERENCES chat.message (message_id)$constraint$);
SELECT ops.add_constraint_if_missing('chat', 'message_receipt', 'fk_message_receipt_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification_policy', 'fk_notification_policy_community_id', $constraint$FOREIGN KEY (community_id) REFERENCES core.community (community_id)$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification_preference', 'fk_notification_preference_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'push_token', 'fk_push_token_device_id', $constraint$FOREIGN KEY (device_id) REFERENCES iam.member_device (device_id)$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification', 'fk_notification_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification', 'fk_notification_notification_policy_id', $constraint$FOREIGN KEY (notification_policy_id) REFERENCES notification.notification_policy (notification_policy_id)$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification', 'fk_notification_event_matching_policy_id', $constraint$FOREIGN KEY (event_matching_policy_id) REFERENCES event.event_matching_policy (event_matching_policy_id)$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification_delivery_attempt', 'fk_notification_delivery_attempt_notification_id', $constraint$FOREIGN KEY (notification_id) REFERENCES notification.notification (notification_id)$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification_delivery_attempt', 'fk_notification_delivery_attempt_push_token_id', $constraint$FOREIGN KEY (push_token_id) REFERENCES notification.push_token (push_token_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_intent', 'fk_nlp_intent_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_embedding', 'fk_nlp_embedding_intent_id', $constraint$FOREIGN KEY (intent_id) REFERENCES nlp.nlp_intent (intent_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_embedding', 'fk_nlp_embedding_model_version', $constraint$FOREIGN KEY (model_version) REFERENCES nlp.nlp_model_version (model_version)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_processing_job', 'fk_nlp_processing_job_intent_id', $constraint$FOREIGN KEY (intent_id) REFERENCES nlp.nlp_intent (intent_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'match_request', 'fk_match_request_requester_id', $constraint$FOREIGN KEY (requester_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'match_request', 'fk_match_request_intent_id', $constraint$FOREIGN KEY (intent_id) REFERENCES nlp.nlp_intent (intent_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'match_request', 'fk_match_request_model_version', $constraint$FOREIGN KEY (model_version) REFERENCES nlp.nlp_model_version (model_version)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'match_request', 'fk_match_request_ranking_version', $constraint$FOREIGN KEY (ranking_version) REFERENCES nlp.nlp_ranking_config (ranking_version)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_match_result', 'fk_nlp_match_result_request_id', $constraint$FOREIGN KEY (request_id) REFERENCES nlp.match_request (request_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_match_result', 'fk_nlp_match_result_requester_id', $constraint$FOREIGN KEY (requester_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_match_result', 'fk_nlp_match_result_candidate_id', $constraint$FOREIGN KEY (candidate_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_match_result', 'fk_nlp_match_result_model_version', $constraint$FOREIGN KEY (model_version) REFERENCES nlp.nlp_model_version (model_version)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_match_result', 'fk_nlp_match_result_ranking_version', $constraint$FOREIGN KEY (ranking_version) REFERENCES nlp.nlp_ranking_config (ranking_version)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_feedback', 'fk_nlp_feedback_supersedes_feedback_id', $constraint$FOREIGN KEY (supersedes_feedback_id) REFERENCES nlp.nlp_feedback (feedback_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_feedback', 'fk_nlp_feedback_match_result_id', $constraint$FOREIGN KEY (match_result_id) REFERENCES nlp.nlp_match_result (match_result_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_feedback', 'fk_nlp_feedback_request_id', $constraint$FOREIGN KEY (request_id) REFERENCES nlp.match_request (request_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_feedback', 'fk_nlp_feedback_requester_id', $constraint$FOREIGN KEY (requester_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_feedback', 'fk_nlp_feedback_candidate_id', $constraint$FOREIGN KEY (candidate_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'match_suppression', 'fk_match_suppression_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'match_suppression', 'fk_match_suppression_intent_id', $constraint$FOREIGN KEY (intent_id) REFERENCES nlp.nlp_intent (intent_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'evaluation_dataset', 'fk_evaluation_dataset_approved_by', $constraint$FOREIGN KEY (approved_by) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'evaluation_pair', 'fk_evaluation_pair_dataset_id', $constraint$FOREIGN KEY (dataset_id) REFERENCES nlp.evaluation_dataset (dataset_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'evaluation_run', 'fk_evaluation_run_dataset_id', $constraint$FOREIGN KEY (dataset_id) REFERENCES nlp.evaluation_dataset (dataset_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'evaluation_run', 'fk_evaluation_run_model_version', $constraint$FOREIGN KEY (model_version) REFERENCES nlp.nlp_model_version (model_version)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'evaluation_run', 'fk_evaluation_run_ranking_version', $constraint$FOREIGN KEY (ranking_version) REFERENCES nlp.nlp_ranking_config (ranking_version)$constraint$);
SELECT ops.add_constraint_if_missing('moderation', 'moderation_case', 'fk_moderation_case_subject_member_id', $constraint$FOREIGN KEY (subject_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('moderation', 'moderation_case', 'fk_moderation_case_assigned_to', $constraint$FOREIGN KEY (assigned_to) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('moderation', 'moderation_action', 'fk_moderation_action_moderation_case_id', $constraint$FOREIGN KEY (moderation_case_id) REFERENCES moderation.moderation_case (moderation_case_id)$constraint$);
SELECT ops.add_constraint_if_missing('moderation', 'moderation_action', 'fk_moderation_action_actor_member_id', $constraint$FOREIGN KEY (actor_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('analytics', 'product_event', 'fk_product_event_community_id', $constraint$FOREIGN KEY (community_id) REFERENCES core.community (community_id)$constraint$);

-- Scope idempotency keys by authenticated actor. The earlier two-column key was
-- unnecessarily global and could make unrelated members collide on the same client key.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'ops.idempotency_record'::regclass
          AND conname = 'pk_idempotency_record_'
          AND pg_get_constraintdef(oid) <> 'PRIMARY KEY (scope, actor_id, idempotency_key)'
    ) THEN
        ALTER TABLE ops.idempotency_record DROP CONSTRAINT pk_idempotency_record_;
        ALTER TABLE ops.idempotency_record
            ADD CONSTRAINT pk_idempotency_record_ PRIMARY KEY (scope, actor_id, idempotency_key);
    END IF;
END;
$$;

SELECT ops.add_constraint_if_missing('iam', 'member', 'ck_member_status', $constraint$CHECK (status IN ('PENDING','ACTIVE','SUSPENDED','ANONYMIZED','DELETED'))$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'member_identity', 'ck_member_identity_status', $constraint$CHECK (status IN ('ACTIVE','REVOKED'))$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'member_identity', 'ck_member_identity_revocation', $constraint$CHECK ((status = 'REVOKED') = (revoked_at IS NOT NULL))$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'role', 'ck_role_status', $constraint$CHECK (status IN ('ACTIVE','RETIRED'))$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'member_device', 'ck_member_device_platform', $constraint$CHECK (platform IN ('IOS','ANDROID'))$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'member_device', 'ck_member_device_status', $constraint$CHECK (status IN ('ACTIVE','REVOKED'))$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_profile', 'ck_member_profile_profile_status', $constraint$CHECK (profile_status IN ('DRAFT','PENDING_REVIEW','ACTIVE','HIDDEN'))$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_profile', 'ck_member_profile_visibility', $constraint$CHECK (visibility IN ('PUBLIC','MEMBERS','CONNECTED','HIDDEN'))$constraint$);
SELECT ops.add_constraint_if_missing('consent', 'member_consent', 'ck_member_consent_decision', $constraint$CHECK (decision IN ('GRANTED','DENIED','WITHDRAWN'))$constraint$);
SELECT ops.add_constraint_if_missing('event', 'event', 'ck_event_status', $constraint$CHECK (status IN ('DRAFT','PUBLISHED','ACTIVE','COMPLETED','CANCELLED'))$constraint$);
SELECT ops.add_constraint_if_missing('event', 'event_matching_policy', 'ck_event_matching_policy_status', $constraint$CHECK (status IN ('DRAFT','ACTIVE','RETIRED'))$constraint$);
SELECT ops.add_constraint_if_missing('event', 'event_matching_policy', 'ck_event_matching_policy_proximity_mode', $constraint$CHECK (proximity_mode IN ('NONE','VENUE','COARSE_CELL'))$constraint$);
SELECT ops.add_constraint_if_missing('event', 'event_registration', 'ck_event_registration_status', $constraint$CHECK (status IN ('INVITED','REGISTERED','CHECKED_IN','CANCELLED'))$constraint$);
SELECT ops.add_constraint_if_missing('event', 'live_mode_session', 'ck_live_mode_session_status', $constraint$CHECK (status IN ('ACTIVE','DISABLED','EXPIRED'))$constraint$);
SELECT ops.add_constraint_if_missing('event', 'live_mode_session', 'ck_live_mode_session_dates', $constraint$CHECK (active_until > activated_at AND (disabled_at IS NULL OR disabled_at >= activated_at))$constraint$);
SELECT ops.add_constraint_if_missing('event', 'venue', 'ck_venue_status', $constraint$CHECK (status IN ('ACTIVE','RETIRED'))$constraint$);
SELECT ops.add_constraint_if_missing('social', 'connection_request', 'ck_connection_request_status', $constraint$CHECK (status IN ('PENDING','ACCEPTED','DECLINED','WITHDRAWN','EXPIRED'))$constraint$);
SELECT ops.add_constraint_if_missing('social', 'connection', 'ck_connection_status', $constraint$CHECK (status IN ('ACTIVE','DISCONNECTED'))$constraint$);
SELECT ops.add_constraint_if_missing('chat', 'conversation', 'ck_conversation_status', $constraint$CHECK (status IN ('ACTIVE','CLOSED','RESTRICTED'))$constraint$);
SELECT ops.add_constraint_if_missing('chat', 'message', 'ck_message_message_type', $constraint$CHECK (message_type IN ('TEXT','FILE','SYSTEM'))$constraint$);
SELECT ops.add_constraint_if_missing('chat', 'conversation_participant', 'ck_conversation_participant_dates', $constraint$CHECK (left_at IS NULL OR left_at >= joined_at)$constraint$);
SELECT ops.add_constraint_if_missing('chat', 'message_receipt', 'ck_message_receipt_dates', $constraint$CHECK ((delivered_at IS NOT NULL OR read_at IS NOT NULL) AND (read_at IS NULL OR (delivered_at IS NOT NULL AND read_at >= delivered_at)))$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification_policy', 'ck_notification_policy_channel', $constraint$CHECK (channel IN ('PUSH','EMAIL','IN_APP'))$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification_policy', 'ck_notification_policy_status', $constraint$CHECK (status IN ('DRAFT','ACTIVE','RETIRED'))$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification_policy', 'ck_notification_policy_quiet_hours_behavior', $constraint$CHECK (quiet_hours_behavior IN ('DEFER','SUPPRESS','BYPASS'))$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'push_token', 'ck_push_token_provider', $constraint$CHECK (provider IN ('APNS','FCM'))$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'push_token', 'ck_push_token_status', $constraint$CHECK (status IN ('ACTIVE','INVALID'))$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification', 'ck_notification_channel', $constraint$CHECK (channel IN ('PUSH','EMAIL','IN_APP'))$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification', 'ck_notification_status', $constraint$CHECK (status IN ('PENDING','SENT','DELIVERED','FAILED','SUPPRESSED'))$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification_delivery_attempt', 'ck_notification_delivery_attempt_status', $constraint$CHECK (status IN ('STARTED','ACCEPTED','DELIVERED','FAILED','EXPIRED'))$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_intent', 'ck_nlp_intent_intent_type', $constraint$CHECK (intent_type IN ('WANT','OFFER'))$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_intent', 'ck_nlp_intent_status', $constraint$CHECK (status IN ('PROCESSING','MATCH_READY','FAILED','INACTIVE'))$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_embedding', 'ck_nlp_embedding_status', $constraint$CHECK (status IN ('ACTIVE','SUPERSEDED','FAILED'))$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_embedding', 'ck_nlp_embedding_dimensions', $constraint$CHECK (dimensions = 1536)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_model_version', 'ck_nlp_model_version_status', $constraint$CHECK (status IN ('CANDIDATE','ACTIVE','RETIRED','ROLLED_BACK'))$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_model_version', 'ck_nlp_model_version_dimensions', $constraint$CHECK (dimensions = 1536)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_processing_job', 'ck_nlp_processing_job_job_type', $constraint$CHECK (job_type IN ('EMBED','REEMBED'))$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_processing_job', 'ck_nlp_processing_job_status', $constraint$CHECK (status IN ('PENDING','RUNNING','SUCCEEDED','FAILED','DEAD'))$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'match_request', 'ck_match_request_status', $constraint$CHECK (status IN ('PROCESSING','COMPLETED','FAILED'))$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_feedback', 'ck_nlp_feedback_label', $constraint$CHECK (label IN ('USEFUL','NOT_USEFUL','INAPPROPRIATE'))$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_profile', 'ck_member_profile_completeness', $constraint$CHECK (completeness_score BETWEEN 0 AND 100)$constraint$);
SELECT ops.add_constraint_if_missing('event', 'event', 'ck_event_date_range', $constraint$CHECK (ends_at > starts_at)$constraint$);
SELECT ops.add_constraint_if_missing('event', 'event_matching_policy', 'ck_event_matching_policy_thresholds', $constraint$CHECK ((match_threshold_override IS NULL OR match_threshold_override BETWEEN 0 AND 1) AND alert_confidence_threshold BETWEEN 0 AND 1)$constraint$);
SELECT ops.add_constraint_if_missing('event', 'event_matching_policy', 'ck_event_matching_policy_limits', $constraint$CHECK (max_match_alerts_per_hour >= 0 AND max_match_alerts_per_event >= 0 AND minimum_alert_interval_minutes >= 0 AND (effective_to IS NULL OR effective_to > effective_from))$constraint$);
SELECT ops.add_constraint_if_missing('event', 'event_matching_policy', 'ck_event_matching_policy_proximity', $constraint$CHECK ((check_in_required IS FALSE OR registration_required IS TRUE) AND (proximity_mode <> 'COARSE_CELL' OR (live_mode_required IS TRUE AND max_presence_age_minutes IS NOT NULL AND max_presence_age_minutes > 0)))$constraint$);
SELECT ops.add_constraint_if_missing('social', 'connection_request', 'ck_connection_request_members', $constraint$CHECK (sender_member_id <> recipient_member_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'connection_request', 'ck_connection_request_expiry', $constraint$CHECK (expires_at > created_at)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'connection', 'ck_connection_canonical_pair', $constraint$CHECK (member_low_id < member_high_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'member_block', 'ck_member_block_members', $constraint$CHECK (blocker_member_id <> blocked_member_id)$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification_policy', 'ck_notification_policy_limits', $constraint$CHECK (dedupe_window_seconds > 0 AND max_per_hour > 0 AND max_per_day > 0 AND max_attempts > 0 AND ttl_minutes > 0 AND (effective_to IS NULL OR effective_to > effective_from))$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification', 'ck_notification_confidence', $constraint$CHECK (source_confidence IS NULL OR source_confidence BETWEEN 0 AND 1)$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification', 'ck_notification_expiry', $constraint$CHECK (expires_at > created_at)$constraint$);
SELECT ops.add_constraint_if_missing('notification', 'notification_delivery_attempt', 'ck_notification_delivery_attempt_attempt', $constraint$CHECK (attempt_number > 0 AND (duration_ms IS NULL OR duration_ms >= 0))$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_ranking_config', 'ck_nlp_ranking_config_weights', $constraint$CHECK (semantic_weight BETWEEN 0 AND 1 AND category_weight BETWEEN 0 AND 1 AND industry_weight BETWEEN 0 AND 1 AND geography_weight BETWEEN 0 AND 1 AND freshness_weight BETWEEN 0 AND 1 AND event_weight BETWEEN 0 AND 1 AND threshold BETWEEN 0 AND 1)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'match_request', 'ck_match_request_limit', $constraint$CHECK (requested_limit BETWEEN 3 AND 7)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_match_result', 'ck_nlp_match_result_scores', $constraint$CHECK (semantic_score BETWEEN 0 AND 1 AND (reciprocal_score IS NULL OR reciprocal_score BETWEEN 0 AND 1) AND final_score BETWEEN 0 AND 1 AND rank > 0)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'match_suppression', 'ck_match_suppression_target', $constraint$CHECK ((member_id IS NOT NULL OR intent_id IS NOT NULL OR context_id IS NOT NULL) AND (ends_at IS NULL OR ends_at > starts_at))$constraint$);
CREATE UNIQUE INDEX IF NOT EXISTS ux_community_name ON core.community (name);
CREATE UNIQUE INDEX IF NOT EXISTS ux_member_identity_provider_subject_hash ON iam.member_identity (provider, provider_subject_hash);
CREATE UNIQUE INDEX IF NOT EXISTS ux_member_identity_primary ON iam.member_identity (member_id) WHERE is_primary IS TRUE;
CREATE UNIQUE INDEX IF NOT EXISTS ux_role_name ON iam.role (name);
CREATE UNIQUE INDEX IF NOT EXISTS ux_organization_community_name ON core.organization (community_id, normalized_name);
CREATE UNIQUE INDEX IF NOT EXISTS ux_organization_member_active ON core.organization_member (organization_id, member_id) WHERE ended_on IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_member_sector_primary ON core.member_sector (member_id) WHERE is_primary IS TRUE;
CREATE UNIQUE INDEX IF NOT EXISTS ux_member_geography_primary ON core.member_geography (member_id) WHERE is_primary IS TRUE;
CREATE UNIQUE INDEX IF NOT EXISTS ux_consent_policy_purpose_version_locale ON consent.consent_policy (purpose_code, version, locale);
CREATE UNIQUE INDEX IF NOT EXISTS ux_event_matching_policy_version ON event.event_matching_policy (event_id, policy_version);
CREATE UNIQUE INDEX IF NOT EXISTS ux_event_matching_policy_active ON event.event_matching_policy (event_id) WHERE status = 'ACTIVE';
CREATE UNIQUE INDEX IF NOT EXISTS ux_event_registration_event_member ON event.event_registration (event_id, member_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_live_mode_session_active ON event.live_mode_session (event_id, member_id) WHERE status = 'ACTIVE';
CREATE UNIQUE INDEX IF NOT EXISTS ux_connection_request_open_pair ON social.connection_request (sender_member_id, recipient_member_id) WHERE status = 'PENDING';
CREATE UNIQUE INDEX IF NOT EXISTS ux_connection_pair ON social.connection (member_low_id, member_high_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_connection_accepted_request ON social.connection (accepted_request_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_member_block_active ON social.member_block (blocker_member_id, blocked_member_id) WHERE removed_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_conversation_connection ON chat.conversation (connection_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_message_conversation_message ON chat.message (conversation_id, message_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_notification_policy_version ON notification.notification_policy (community_id, purpose_code, channel, policy_version) NULLS NOT DISTINCT;
CREATE UNIQUE INDEX IF NOT EXISTS ux_notification_policy_active ON notification.notification_policy (community_id, purpose_code, channel) NULLS NOT DISTINCT WHERE status = 'ACTIVE';
CREATE UNIQUE INDEX IF NOT EXISTS ux_push_token_fingerprint ON notification.push_token (token_fingerprint);
CREATE UNIQUE INDEX IF NOT EXISTS ux_notification_dedupe ON notification.notification (member_id, channel, dedupe_key, dedupe_bucket_start);
CREATE UNIQUE INDEX IF NOT EXISTS ux_notification_attempt_number ON notification.notification_delivery_attempt (notification_id, attempt_number);
CREATE UNIQUE INDEX IF NOT EXISTS ux_nlp_embedding_hash_model ON nlp.nlp_embedding (intent_id, normalized_hash, model_version);
CREATE UNIQUE INDEX IF NOT EXISTS ux_nlp_model_version_active ON nlp.nlp_model_version (status) WHERE status = 'ACTIVE';
CREATE UNIQUE INDEX IF NOT EXISTS ux_nlp_ranking_config_active ON nlp.nlp_ranking_config (active_to) NULLS NOT DISTINCT WHERE active_to IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_nlp_processing_job_active ON nlp.nlp_processing_job (intent_id, job_type) WHERE status IN ('PENDING','RUNNING');
CREATE UNIQUE INDEX IF NOT EXISTS ux_nlp_match_result_request_candidate ON nlp.nlp_match_result (request_id, candidate_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_nlp_match_result_request_rank ON nlp.nlp_match_result (request_id, rank);
CREATE UNIQUE INDEX IF NOT EXISTS ux_nlp_feedback_original ON nlp.nlp_feedback (match_result_id, requester_id) WHERE supersedes_feedback_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_nlp_feedback_superseded ON nlp.nlp_feedback (supersedes_feedback_id) WHERE supersedes_feedback_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_evaluation_dataset_name_version ON nlp.evaluation_dataset (name, version);
CREATE INDEX IF NOT EXISTS ix_member_community_status ON iam.member (community_id, status);
CREATE INDEX IF NOT EXISTS ix_member_profile_discovery ON core.member_profile (profile_status, visibility, updated_at);
CREATE INDEX IF NOT EXISTS ix_event_community_status_start ON event.event (community_id, status, starts_at);
CREATE INDEX IF NOT EXISTS ix_event_presence_cell_expiry ON event.event_presence (coarse_cell, expires_at);
CREATE INDEX IF NOT EXISTS ix_connection_request_recipient_status_expiry ON social.connection_request (recipient_member_id, status, expires_at, created_at);
CREATE INDEX IF NOT EXISTS ix_message_conversation_sequence ON chat.message (conversation_id, server_sequence);
CREATE INDEX IF NOT EXISTS ix_notification_due ON notification.notification (status, scheduled_at, expires_at);
CREATE INDEX IF NOT EXISTS ix_notification_rate_limit ON notification.notification (member_id, notification_policy_id, created_at);
CREATE INDEX IF NOT EXISTS ix_notification_event_limit ON notification.notification (member_id, event_matching_policy_id, context_id, created_at);
CREATE INDEX IF NOT EXISTS ix_notification_attempt_retry ON notification.notification_delivery_attempt (status, next_attempt_at);
CREATE INDEX IF NOT EXISTS ix_nlp_intent_context_type_status_expiry ON nlp.nlp_intent (context_id, intent_type, status, expires_at);
CREATE INDEX IF NOT EXISTS ix_match_request_requester_created ON nlp.match_request (requester_id, created_at);
CREATE INDEX IF NOT EXISTS ix_nlp_match_result_candidate_created ON nlp.nlp_match_result (candidate_id, created_at);
CREATE INDEX IF NOT EXISTS ix_outbox_event_due ON ops.outbox_event (published_at, next_attempt_at);
CREATE INDEX IF NOT EXISTS ix_background_job_due ON ops.background_job (status, available_at);
CREATE INDEX IF NOT EXISTS ix_idempotency_record_expiry ON ops.idempotency_record (expires_at);
CREATE INDEX IF NOT EXISTS ix_product_event_name_occurred ON analytics.product_event (event_name, occurred_at);
CREATE INDEX IF NOT EXISTS ix_member_role_granted_by ON iam.member_role (granted_by);
CREATE INDEX IF NOT EXISTS ix_member_verification_evidence_file_asset_id ON core.member_verification (evidence_file_asset_id);
CREATE INDEX IF NOT EXISTS ix_member_verification_reviewed_by ON core.member_verification (reviewed_by);
CREATE INDEX IF NOT EXISTS ix_privacy_request_result_file_asset_id ON consent.privacy_request (result_file_asset_id);
CREATE INDEX IF NOT EXISTS ix_live_mode_session_consent_record_id ON event.live_mode_session (consent_record_id);
CREATE INDEX IF NOT EXISTS ix_connection_request_match_result_id ON social.connection_request (match_result_id);
CREATE INDEX IF NOT EXISTS ix_member_report_reporter_member_id ON social.member_report (reporter_member_id);
CREATE INDEX IF NOT EXISTS ix_conversation_participant_last_read_message_id ON chat.conversation_participant (last_read_message_id);
CREATE INDEX IF NOT EXISTS ix_notification_notification_policy_id ON notification.notification (notification_policy_id);
CREATE INDEX IF NOT EXISTS ix_notification_event_matching_policy_id ON notification.notification (event_matching_policy_id);
CREATE INDEX IF NOT EXISTS ix_notification_delivery_attempt_push_token_id ON notification.notification_delivery_attempt (push_token_id);
CREATE INDEX IF NOT EXISTS ix_nlp_embedding_model_version ON nlp.nlp_embedding (model_version);
CREATE INDEX IF NOT EXISTS ix_match_request_intent_id ON nlp.match_request (intent_id);
CREATE INDEX IF NOT EXISTS ix_match_request_model_version ON nlp.match_request (model_version);
CREATE INDEX IF NOT EXISTS ix_match_request_ranking_version ON nlp.match_request (ranking_version);
CREATE INDEX IF NOT EXISTS ix_nlp_match_result_requester_id ON nlp.nlp_match_result (requester_id);
CREATE INDEX IF NOT EXISTS ix_nlp_match_result_model_version ON nlp.nlp_match_result (model_version);
CREATE INDEX IF NOT EXISTS ix_nlp_match_result_ranking_version ON nlp.nlp_match_result (ranking_version);
CREATE INDEX IF NOT EXISTS ix_nlp_feedback_request_id ON nlp.nlp_feedback (request_id);
CREATE INDEX IF NOT EXISTS ix_nlp_feedback_requester_id ON nlp.nlp_feedback (requester_id);
CREATE INDEX IF NOT EXISTS ix_nlp_feedback_candidate_id ON nlp.nlp_feedback (candidate_id);
CREATE INDEX IF NOT EXISTS ix_match_suppression_created_by ON nlp.match_suppression (created_by);
CREATE INDEX IF NOT EXISTS ix_evaluation_dataset_approved_by ON nlp.evaluation_dataset (approved_by);
CREATE INDEX IF NOT EXISTS ix_evaluation_run_ranking_version ON nlp.evaluation_run (ranking_version);
CREATE INDEX IF NOT EXISTS ix_moderation_case_assigned_to ON moderation.moderation_case (assigned_to);
CREATE INDEX IF NOT EXISTS ix_content_rule_created_by ON moderation.content_rule (created_by);
-- v2.3 cross-domain foreign keys.
SELECT ops.add_constraint_if_missing('iam', 'role_permission', 'fk_role_permission_role_code', $constraint$FOREIGN KEY (role_code) REFERENCES iam.role (role_code)$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'role_permission', 'fk_role_permission_permission_code', $constraint$FOREIGN KEY (permission_code) REFERENCES iam.permission (permission_code)$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'role_permission', 'fk_role_permission_granted_by', $constraint$FOREIGN KEY (granted_by) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'auth_session', 'fk_auth_session_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'auth_session', 'fk_auth_session_device_id', $constraint$FOREIGN KEY (device_id) REFERENCES iam.member_device (device_id)$constraint$);
SELECT ops.add_constraint_if_missing('consent', 'privacy_request_task', 'fk_privacy_request_task_privacy_request_id', $constraint$FOREIGN KEY (privacy_request_id) REFERENCES consent.privacy_request (privacy_request_id)$constraint$);
SELECT ops.add_constraint_if_missing('storage', 'file_asset', 'fk_file_asset_community_id', $constraint$FOREIGN KEY (community_id) REFERENCES core.community (community_id)$constraint$);
SELECT ops.add_constraint_if_missing('storage', 'file_asset', 'fk_file_asset_owner_member_id', $constraint$FOREIGN KEY (owner_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('storage', 'file_asset_link', 'fk_file_asset_link_file_asset_id', $constraint$FOREIGN KEY (file_asset_id) REFERENCES storage.file_asset (file_asset_id)$constraint$);
SELECT ops.add_constraint_if_missing('storage', 'file_asset_link', 'fk_file_asset_link_linked_by', $constraint$FOREIGN KEY (linked_by) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('ops', 'sync_change', 'fk_sync_change_community_id', $constraint$FOREIGN KEY (community_id) REFERENCES core.community (community_id)$constraint$);
SELECT ops.add_constraint_if_missing('ops', 'sync_change', 'fk_sync_change_member_scope_id', $constraint$FOREIGN KEY (member_scope_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('ops', 'retention_policy', 'fk_retention_policy_approved_by', $constraint$FOREIGN KEY (approved_by) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('ops', 'retention_execution', 'fk_retention_execution_retention_policy_id', $constraint$FOREIGN KEY (retention_policy_id) REFERENCES ops.retention_policy (retention_policy_id)$constraint$);
-- v2.3 state, lifecycle and bounded-value constraints.
SELECT ops.add_constraint_if_missing('iam', 'permission', 'ck_permission_action', $constraint$CHECK (action IN ('READ','CREATE','UPDATE','DELETE','APPROVE','EXPORT','CONFIGURE'))$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'permission', 'ck_permission_status', $constraint$CHECK (status IN ('ACTIVE','RETIRED'))$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'role_permission', 'ck_role_permission_dates', $constraint$CHECK (revoked_at IS NULL OR revoked_at >= granted_at)$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'auth_session', 'ck_auth_session_auth_strength', $constraint$CHECK (auth_strength IN ('STANDARD','MFA','STEP_UP'))$constraint$);
SELECT ops.add_constraint_if_missing('iam', 'auth_session', 'ck_auth_session_dates', $constraint$CHECK (expires_at > issued_at AND last_seen_at >= issued_at AND (revoked_at IS NULL OR revoked_at >= issued_at))$constraint$);
SELECT ops.add_constraint_if_missing('consent', 'privacy_request_task', 'ck_privacy_request_task_domain', $constraint$CHECK (domain_code IN ('IAM','PROFILE','EVENT','SOCIAL','CHAT','STORAGE','NLP','ANALYTICS','AUDIT'))$constraint$);
SELECT ops.add_constraint_if_missing('consent', 'privacy_request_task', 'ck_privacy_request_task_action', $constraint$CHECK (action_type IN ('EXPORT','CORRECT','ANONYMIZE','DELETE','RETAIN_EXCEPTION'))$constraint$);
SELECT ops.add_constraint_if_missing('consent', 'privacy_request_task', 'ck_privacy_request_task_state', $constraint$CHECK (status IN ('PENDING','RUNNING','COMPLETED','FAILED','EXEMPTED') AND attempt_count >= 0 AND (status NOT IN ('COMPLETED','EXEMPTED') OR (completed_at IS NOT NULL AND evidence_code IS NOT NULL)))$constraint$);
SELECT ops.add_constraint_if_missing('storage', 'file_asset', 'ck_file_asset_purpose', $constraint$CHECK (purpose_code IN ('CHAT_FILE','VERIFICATION_EVIDENCE','PRIVACY_EXPORT','EVALUATION_REPORT'))$constraint$);
SELECT ops.add_constraint_if_missing('storage', 'file_asset', 'ck_file_asset_classification', $constraint$CHECK (classification IN ('INTERNAL','CONFIDENTIAL','RESTRICTED','HIGHLY_RESTRICTED'))$constraint$);
SELECT ops.add_constraint_if_missing('storage', 'file_asset', 'ck_file_asset_lifecycle', $constraint$CHECK (size_bytes >= 0 AND scan_status IN ('PENDING','CLEAN','REJECTED','ERROR') AND lifecycle_status IN ('UPLOADING','AVAILABLE','QUARANTINED','DELETED','EXPIRED') AND (lifecycle_status <> 'AVAILABLE' OR scan_status = 'CLEAN') AND (lifecycle_status NOT IN ('DELETED','EXPIRED') OR deleted_at IS NOT NULL))$constraint$);
SELECT ops.add_constraint_if_missing('storage', 'file_asset_link', 'ck_file_asset_link_values', $constraint$CHECK (resource_type IN ('MESSAGE','MEMBER_VERIFICATION','PRIVACY_REQUEST','EVALUATION_RUN') AND relationship_type IN ('PRIMARY','EVIDENCE','RESULT','REPORT'))$constraint$);
SELECT ops.add_constraint_if_missing('ops', 'sync_change', 'ck_sync_change_values', $constraint$CHECK (change_type IN ('UPSERT','DELETE') AND resource_type IN ('PROFILE','MATCH','REQUEST','CONVERSATION','MESSAGE','NOTIFICATION') AND expires_at > occurred_at)$constraint$);
SELECT ops.add_constraint_if_missing('ops', 'idempotency_record', 'ck_idempotency_record_completion', $constraint$CHECK (expires_at > created_at AND (status_code IS NULL OR status_code BETWEEN 100 AND 599) AND ((status_code IS NULL) = (response_ref IS NULL)))$constraint$);
SELECT ops.add_constraint_if_missing('ops', 'retention_policy', 'ck_retention_policy_values', $constraint$CHECK (policy_version > 0 AND retention_days >= 0 AND status IN ('DRAFT','ACTIVE','RETIRED') AND disposition_action IN ('DELETE','ANONYMIZE','ARCHIVE') AND (effective_to IS NULL OR effective_to > effective_from))$constraint$);
SELECT ops.add_constraint_if_missing('ops', 'retention_execution', 'ck_retention_execution_values', $constraint$CHECK (scope_end > scope_start AND status IN ('RUNNING','SUCCEEDED','PARTIAL','FAILED') AND examined_count >= 0 AND disposed_count >= 0 AND skipped_hold_count >= 0 AND disposed_count + skipped_hold_count <= examined_count AND (status = 'RUNNING' OR completed_at IS NOT NULL))$constraint$);
-- v2.3 lookup, uniqueness and worker access paths.
CREATE UNIQUE INDEX IF NOT EXISTS ux_permission_resource_action ON iam.permission (resource_type, action);
CREATE INDEX IF NOT EXISTS ix_permission_status ON iam.permission (status);
CREATE INDEX IF NOT EXISTS ix_role_permission_permission_revoked ON iam.role_permission (permission_code, revoked_at);
CREATE UNIQUE INDEX IF NOT EXISTS ux_auth_session_provider_session_hash ON iam.auth_session (provider_session_hash) WHERE provider_session_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_auth_session_member_active ON iam.auth_session (member_id, revoked_at, expires_at);
CREATE INDEX IF NOT EXISTS ix_auth_session_device_revoked ON iam.auth_session (device_id, revoked_at);
CREATE UNIQUE INDEX IF NOT EXISTS ux_privacy_request_task_domain_action ON consent.privacy_request_task (privacy_request_id, domain_code, action_type);
CREATE INDEX IF NOT EXISTS ix_privacy_request_task_due_work ON consent.privacy_request_task (status, updated_at);
-- Long blob paths can exceed PostgreSQL B-tree entry limits; the hash is unique and full paths are collision-checked by the service.
CREATE UNIQUE INDEX IF NOT EXISTS ux_file_asset_blob_path_hash ON storage.file_asset (blob_path_hash);
CREATE INDEX IF NOT EXISTS ix_file_asset_owner_created ON storage.file_asset (owner_member_id, created_at);
CREATE INDEX IF NOT EXISTS ix_file_asset_lifecycle_expiry ON storage.file_asset (purpose_code, lifecycle_status, expires_at);
CREATE INDEX IF NOT EXISTS ix_file_asset_scan_queue ON storage.file_asset (scan_status, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS ux_file_asset_link_resource ON storage.file_asset_link (file_asset_id, resource_type, resource_id, relationship_type);
CREATE INDEX IF NOT EXISTS ix_file_asset_link_resource ON storage.file_asset_link (resource_type, resource_id, removed_at);
CREATE INDEX IF NOT EXISTS ix_sync_change_community_cursor ON ops.sync_change (community_id, sync_sequence);
CREATE INDEX IF NOT EXISTS ix_sync_change_member_cursor ON ops.sync_change (member_scope_id, sync_sequence);
CREATE INDEX IF NOT EXISTS ix_sync_change_expiry ON ops.sync_change (expires_at);
CREATE UNIQUE INDEX IF NOT EXISTS ux_retention_policy_version ON ops.retention_policy (resource_type, policy_version);
CREATE UNIQUE INDEX IF NOT EXISTS ux_retention_policy_active ON ops.retention_policy (resource_type) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS ix_retention_policy_status_effective ON ops.retention_policy (status, effective_from);
CREATE INDEX IF NOT EXISTS ix_retention_execution_policy_started ON ops.retention_execution (retention_policy_id, started_at DESC);
CREATE INDEX IF NOT EXISTS ix_retention_execution_status_started ON ops.retention_execution (status, started_at);
-- Documented v2.3 access paths not already covered by a matching key.
CREATE INDEX IF NOT EXISTS ix_community_status ON core.community (status);
CREATE INDEX IF NOT EXISTS ix_organization_website_domain ON core.organization (website_domain);
CREATE UNIQUE INDEX IF NOT EXISTS uq_organization_member_organization_id_member_id_started_on ON core.organization_member (organization_id, member_id, started_on);
CREATE INDEX IF NOT EXISTS ix_organization_member_member_id_is_primary ON core.organization_member (member_id, is_primary);
CREATE INDEX IF NOT EXISTS ix_member_profile_updated_at ON core.member_profile (updated_at);
CREATE UNIQUE INDEX IF NOT EXISTS uq_sector_name ON core.sector (name);
CREATE INDEX IF NOT EXISTS ix_sector_parent_sector_code_status ON core.sector (parent_sector_code, status);
CREATE INDEX IF NOT EXISTS ix_member_sector_sector_code_member_id ON core.member_sector (sector_code, member_id);
CREATE INDEX IF NOT EXISTS ix_member_geography_member_id_is_primary ON core.member_geography (member_id, is_primary);
CREATE INDEX IF NOT EXISTS ix_member_geography_country_code_region_city ON core.member_geography (country_code, region, city);
CREATE INDEX IF NOT EXISTS ix_profile_field_visibility_audience ON core.profile_field_visibility (audience);
CREATE INDEX IF NOT EXISTS ix_member_verification_member_id_status ON core.member_verification (member_id, status);
CREATE INDEX IF NOT EXISTS ix_member_verification_status_created_at ON core.member_verification (status, created_at);
CREATE INDEX IF NOT EXISTS ix_member_status_updated_at ON iam.member (status, updated_at);
CREATE INDEX IF NOT EXISTS ix_member_identity_member_id_is_primary ON iam.member_identity (member_id, is_primary);
CREATE INDEX IF NOT EXISTS ix_member_identity_member_id_status ON iam.member_identity (member_id, status);
CREATE INDEX IF NOT EXISTS ix_role_status ON iam.role (status);
CREATE INDEX IF NOT EXISTS ix_member_role_role_code_expires_at ON iam.member_role (role_code, expires_at);
CREATE INDEX IF NOT EXISTS ix_member_device_member_id_status ON iam.member_device (member_id, status);
CREATE INDEX IF NOT EXISTS ix_member_device_last_seen_at ON iam.member_device (last_seen_at);
CREATE INDEX IF NOT EXISTS ix_consent_policy_purpose_code_effective_from ON consent.consent_policy (purpose_code, effective_from);
CREATE INDEX IF NOT EXISTS ix_member_consent_member_id_policy_id_captured_at ON consent.member_consent (member_id, policy_id, captured_at);
CREATE INDEX IF NOT EXISTS ix_member_consent_policy_id_decision ON consent.member_consent (policy_id, decision);
CREATE INDEX IF NOT EXISTS ix_privacy_request_status_due_at ON consent.privacy_request (status, due_at);
CREATE INDEX IF NOT EXISTS ix_privacy_request_member_id_created_at ON consent.privacy_request (member_id, created_at);
CREATE INDEX IF NOT EXISTS ix_venue_country_code_region_city ON event.venue (country_code, region, city);
CREATE INDEX IF NOT EXISTS ix_venue_status_country_code_region_city ON event.venue (status, country_code, region, city);
CREATE INDEX IF NOT EXISTS ix_event_venue_id_starts_at ON event.event (venue_id, starts_at);
CREATE INDEX IF NOT EXISTS ix_event_matching_policy_status_effective_from_effective_to ON event.event_matching_policy (status, effective_from, effective_to);
CREATE INDEX IF NOT EXISTS ix_event_registration_member_id_status ON event.event_registration (member_id, status);
CREATE INDEX IF NOT EXISTS ix_event_registration_event_id_status ON event.event_registration (event_id, status);
CREATE INDEX IF NOT EXISTS ix_live_mode_session_event_id_status_active_until ON event.live_mode_session (event_id, status, active_until);
CREATE INDEX IF NOT EXISTS ix_live_mode_session_member_id_status ON event.live_mode_session (member_id, status);
CREATE INDEX IF NOT EXISTS ix_event_presence_live_session_id_observed_at ON event.event_presence (live_session_id, observed_at);
CREATE INDEX IF NOT EXISTS ix_connection_request_sender_member_id_status ON social.connection_request (sender_member_id, status);
CREATE INDEX IF NOT EXISTS ix_connection_member_low_id_status ON social.connection (member_low_id, status);
CREATE INDEX IF NOT EXISTS ix_connection_member_high_id_status ON social.connection (member_high_id, status);
CREATE INDEX IF NOT EXISTS ix_member_block_blocked_member_id_removed_at ON social.member_block (blocked_member_id, removed_at);
CREATE INDEX IF NOT EXISTS ix_member_report_status_created_at ON social.member_report (status, created_at);
CREATE INDEX IF NOT EXISTS ix_member_report_reported_member_id_created_at ON social.member_report (reported_member_id, created_at);
CREATE INDEX IF NOT EXISTS ix_conversation_status_last_message_at ON chat.conversation (status, last_message_at);
CREATE INDEX IF NOT EXISTS ix_conversation_participant_member_id_left_at ON chat.conversation_participant (member_id, left_at);
CREATE INDEX IF NOT EXISTS ix_message_sender_member_id_created_at ON chat.message (sender_member_id, created_at);
CREATE INDEX IF NOT EXISTS ix_message_receipt_member_id_read_at ON chat.message_receipt (member_id, read_at);
CREATE INDEX IF NOT EXISTS ix_notification_policy_status_effective_from_effective_to ON notification.notification_policy (status, effective_from, effective_to);
CREATE INDEX IF NOT EXISTS ix_push_token_device_id_status ON notification.push_token (device_id, status);
CREATE INDEX IF NOT EXISTS ix_notification_member_id_created_at ON notification.notification (member_id, created_at);
CREATE INDEX IF NOT EXISTS ix_notification_delivery_attempt_provider_provider_message_id ON notification.notification_delivery_attempt (provider, provider_message_id);
CREATE INDEX IF NOT EXISTS ix_nlp_intent_member_id_status ON nlp.nlp_intent (member_id, status);
CREATE INDEX IF NOT EXISTS ix_nlp_intent_normalized_hash ON nlp.nlp_intent (normalized_hash);
CREATE INDEX IF NOT EXISTS ix_nlp_model_version_status_created_at ON nlp.nlp_model_version (status, created_at);
CREATE INDEX IF NOT EXISTS ix_nlp_ranking_config_active_from_active_to ON nlp.nlp_ranking_config (active_from, active_to);
CREATE INDEX IF NOT EXISTS ix_nlp_processing_job_status_available_at ON nlp.nlp_processing_job (status, available_at);
CREATE INDEX IF NOT EXISTS ix_match_request_status_created_at ON nlp.match_request (status, created_at);
CREATE INDEX IF NOT EXISTS ix_match_request_request_hash ON nlp.match_request (request_hash);
CREATE INDEX IF NOT EXISTS ix_nlp_feedback_label_created_at ON nlp.nlp_feedback (label, created_at);
CREATE INDEX IF NOT EXISTS ix_match_suppression_member_id_context_id_ends_at ON nlp.match_suppression (member_id, context_id, ends_at);
CREATE INDEX IF NOT EXISTS ix_match_suppression_intent_id_ends_at ON nlp.match_suppression (intent_id, ends_at);
CREATE INDEX IF NOT EXISTS ix_evaluation_dataset_status_created_at ON nlp.evaluation_dataset (status, created_at);
CREATE INDEX IF NOT EXISTS ix_evaluation_pair_dataset_id_split ON nlp.evaluation_pair (dataset_id, split);
CREATE INDEX IF NOT EXISTS ix_evaluation_pair_gold_label ON nlp.evaluation_pair (gold_label);
CREATE INDEX IF NOT EXISTS ix_evaluation_run_dataset_id_started_at ON nlp.evaluation_run (dataset_id, started_at);
CREATE INDEX IF NOT EXISTS ix_evaluation_run_model_version_ranking_version ON nlp.evaluation_run (model_version, ranking_version);
CREATE INDEX IF NOT EXISTS ix_moderation_case_status_priority_created_at ON moderation.moderation_case (status, priority, created_at);
CREATE INDEX IF NOT EXISTS ix_moderation_case_subject_member_id_created_at ON moderation.moderation_case (subject_member_id, created_at);
CREATE INDEX IF NOT EXISTS ix_moderation_action_moderation_case_id_created_at ON moderation.moderation_action (moderation_case_id, created_at);
CREATE INDEX IF NOT EXISTS ix_moderation_action_actor_member_id_created_at ON moderation.moderation_action (actor_member_id, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS uq_content_rule_rule_type_version ON moderation.content_rule (rule_type, version);
CREATE INDEX IF NOT EXISTS ix_content_rule_rule_type_status ON moderation.content_rule (rule_type, status);
CREATE INDEX IF NOT EXISTS ix_content_scan_resource_type_resource_id_scanned_at ON moderation.content_scan (resource_type, resource_id, scanned_at);
CREATE INDEX IF NOT EXISTS ix_content_scan_result_scanned_at ON moderation.content_scan (result, scanned_at);
CREATE INDEX IF NOT EXISTS ix_outbox_event_aggregate_type_aggregate_id_occurred_at ON ops.outbox_event (aggregate_type, aggregate_id, occurred_at);
CREATE INDEX IF NOT EXISTS ix_background_job_resource_type_resource_id ON ops.background_job (resource_type, resource_id);
CREATE INDEX IF NOT EXISTS ix_audit_event_resource_type_resource_id_occurred_at ON ops.audit_event (resource_type, resource_id, occurred_at);
CREATE INDEX IF NOT EXISTS ix_audit_event_actor_id_occurred_at ON ops.audit_event (actor_id, occurred_at);
CREATE INDEX IF NOT EXISTS ix_audit_event_correlation_id ON ops.audit_event (correlation_id);
CREATE INDEX IF NOT EXISTS ix_product_event_community_id_occurred_at ON analytics.product_event (community_id, occurred_at);

DROP FUNCTION ops.add_constraint_if_missing(name, name, name, text);

-- ======================== CROSS-ROW INVARIANTS ========================
-- Polymorphic file links remain referentially safe even though one FK cannot target four tables.
CREATE OR REPLACE FUNCTION storage.enforce_file_asset_link_resource()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF (NEW.resource_type = 'MESSAGE' AND NOT EXISTS (SELECT 1 FROM chat.message WHERE message_id = NEW.resource_id))
       OR (NEW.resource_type = 'MEMBER_VERIFICATION' AND NOT EXISTS (SELECT 1 FROM core.member_verification WHERE verification_id = NEW.resource_id))
       OR (NEW.resource_type = 'PRIVACY_REQUEST' AND NOT EXISTS (SELECT 1 FROM consent.privacy_request WHERE privacy_request_id = NEW.resource_id))
       OR (NEW.resource_type = 'EVALUATION_RUN' AND NOT EXISTS (SELECT 1 FROM nlp.evaluation_run WHERE evaluation_run_id = NEW.resource_id)) THEN
        RAISE EXCEPTION USING ERRCODE = '23503', MESSAGE = 'FileAssetLink resource does not exist in its owning domain.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_file_asset_link_resource ON storage.file_asset_link;
CREATE TRIGGER enforce_file_asset_link_resource
BEFORE INSERT OR UPDATE ON storage.file_asset_link
FOR EACH ROW EXECUTE FUNCTION storage.enforce_file_asset_link_resource();

-- Active Live Mode sessions must be event-bounded and backed by the same member's
-- latest effective, unwithdrawn LIVE_MODE grant. This prevents an unrelated consent
-- row from satisfying the foreign key and makes session creation fail closed.
CREATE OR REPLACE FUNCTION event.enforce_live_mode_session_consent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, event, iam, consent
AS $$
DECLARE
    v_event_ends_at timestamptz;
BEGIN
    IF NEW.status <> 'ACTIVE' THEN
        RETURN NEW;
    END IF;

    SELECT e.ends_at
    INTO v_event_ends_at
    FROM event.event e
    JOIN iam.member m
      ON m.member_id = NEW.member_id
     AND m.community_id = e.community_id
     AND m.status = 'ACTIVE'
    WHERE e.event_id = NEW.event_id
      AND e.status = 'ACTIVE'
      AND e.live_mode_enabled
      AND CURRENT_TIMESTAMP >= e.starts_at
      AND CURRENT_TIMESTAMP < e.ends_at;

    IF v_event_ends_at IS NULL OR NEW.active_until > v_event_ends_at
       OR NEW.active_until <= CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Active Live Mode session requires an active same-community event and an event-bounded future expiry.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM consent.member_consent mc
        JOIN consent.consent_policy cp ON cp.policy_id = mc.policy_id
        WHERE mc.member_consent_id = NEW.consent_record_id
          AND mc.member_id = NEW.member_id
          AND mc.decision = 'GRANTED'
          AND mc.withdrawn_at IS NULL
          AND cp.purpose_code = 'LIVE_MODE'
          AND cp.effective_from <= CURRENT_TIMESTAMP
          AND cp.retired_at IS NULL
          AND NOT EXISTS (
              SELECT 1
              FROM consent.member_consent newer
              JOIN consent.consent_policy newer_policy ON newer_policy.policy_id = newer.policy_id
              WHERE newer.member_id = mc.member_id
                AND newer_policy.purpose_code = 'LIVE_MODE'
                AND newer_policy.effective_from <= CURRENT_TIMESTAMP
                AND newer_policy.retired_at IS NULL
                AND (newer.captured_at, newer.member_consent_id) > (mc.captured_at, mc.member_consent_id)
          )
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Active Live Mode session requires the member''s latest effective LIVE_MODE grant.';
    END IF;

    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_live_mode_session_consent ON event.live_mode_session;
CREATE TRIGGER enforce_live_mode_session_consent
BEFORE INSERT OR UPDATE ON event.live_mode_session
FOR EACH ROW EXECUTE FUNCTION event.enforce_live_mode_session_consent();

-- When suppression dimensions are combined, they must describe the same intent.
CREATE OR REPLACE FUNCTION nlp.enforce_match_suppression_target()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.intent_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM nlp.nlp_intent i
        WHERE i.intent_id = NEW.intent_id
          AND (NEW.member_id IS NULL OR i.member_id = NEW.member_id)
          AND (NEW.context_id IS NULL OR i.context_id = NEW.context_id)
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Match suppression member, intent and context targets are inconsistent.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_match_suppression_target ON nlp.match_suppression;
CREATE TRIGGER enforce_match_suppression_target
BEFORE INSERT OR UPDATE ON nlp.match_suppression
FOR EACH ROW EXECUTE FUNCTION nlp.enforce_match_suppression_target();

-- A connection must represent exactly the two members from its accepted request.
CREATE OR REPLACE FUNCTION social.enforce_connection_request_pair()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_sender_member_id varchar(64);
    v_recipient_member_id varchar(64);
BEGIN
    SELECT sender_member_id, recipient_member_id
    INTO v_sender_member_id, v_recipient_member_id
    FROM social.connection_request
    WHERE connection_request_id = NEW.accepted_request_id
      AND status = 'ACCEPTED';

    IF v_sender_member_id IS NULL
       OR NEW.member_low_id <> LEAST(v_sender_member_id, v_recipient_member_id)
       OR NEW.member_high_id <> GREATEST(v_sender_member_id, v_recipient_member_id) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Connection members must exactly match the accepted connection request.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_connection_request_pair ON social.connection;
CREATE TRIGGER enforce_connection_request_pair
BEFORE INSERT OR UPDATE OF member_low_id, member_high_id, accepted_request_id ON social.connection
FOR EACH ROW EXECUTE FUNCTION social.enforce_connection_request_pair();

CREATE OR REPLACE FUNCTION social.validate_accepted_request_connection()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_connection_request_id varchar(64);
    v_new_connection_request_id varchar(64);
    v_connection_request_id varchar(64);
    v_old_row jsonb;
    v_new_row jsonb;
BEGIN
    IF TG_TABLE_SCHEMA <> 'social'
       OR TG_TABLE_NAME NOT IN ('connection_request', 'connection') THEN
        RAISE EXCEPTION 'Unexpected relation for accepted-request validation: %.%.',
            TG_TABLE_SCHEMA, TG_TABLE_NAME USING ERRCODE = '55000';
    END IF;

    -- Convert the relation-specific trigger records before extracting fields. Direct references
    -- to fields from both relations in one CASE expression are resolved by PostgreSQL even when
    -- that branch is not selected, causing undefined-column errors.
    IF TG_OP <> 'INSERT' THEN
        v_old_row := to_jsonb(OLD);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new_row := to_jsonb(NEW);
    END IF;

    IF TG_TABLE_NAME = 'connection_request' THEN
        v_old_connection_request_id := v_old_row ->> 'connection_request_id';
        v_new_connection_request_id := v_new_row ->> 'connection_request_id';
    ELSE
        v_old_connection_request_id := v_old_row ->> 'accepted_request_id';
        v_new_connection_request_id := v_new_row ->> 'accepted_request_id';
    END IF;

    FOR v_connection_request_id IN
        SELECT DISTINCT affected_id
        FROM unnest(ARRAY[
            v_old_connection_request_id, v_new_connection_request_id
        ]) AS affected(affected_id)
        WHERE affected_id IS NOT NULL
    LOOP
        IF EXISTS (
            SELECT 1 FROM social.connection_request cr
            WHERE cr.connection_request_id = v_connection_request_id AND cr.status = 'ACCEPTED'
        ) AND NOT EXISTS (
            SELECT 1 FROM social.connection c
            WHERE c.accepted_request_id = v_connection_request_id
        ) THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = 'An accepted connection request must have its canonical connection in the same transaction.';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS validate_accepted_request_connection_on_request ON social.connection_request;
CREATE CONSTRAINT TRIGGER validate_accepted_request_connection_on_request
AFTER INSERT OR UPDATE OR DELETE ON social.connection_request
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION social.validate_accepted_request_connection();
DROP TRIGGER IF EXISTS validate_accepted_request_connection_on_connection ON social.connection;
CREATE CONSTRAINT TRIGGER validate_accepted_request_connection_on_connection
AFTER INSERT OR UPDATE OR DELETE ON social.connection
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION social.validate_accepted_request_connection();

-- Participant rows may contain only the two members of the underlying connection.
-- Read cursors must point into the same conversation and may never move backwards.
CREATE OR REPLACE FUNCTION chat.enforce_conversation_participant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, chat, social
AS $$
DECLARE
    v_member_low_id varchar(64);
    v_member_high_id varchar(64);
    v_new_sequence bigint;
    v_old_sequence bigint;
BEGIN
    IF TG_OP = 'UPDATE' AND (
        NEW.conversation_id IS DISTINCT FROM OLD.conversation_id
        OR NEW.member_id IS DISTINCT FROM OLD.member_id
        OR NEW.joined_at IS DISTINCT FROM OLD.joined_at
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Conversation participant identity and join time are immutable.';
    END IF;

    SELECT cn.member_low_id, cn.member_high_id
    INTO v_member_low_id, v_member_high_id
    FROM chat.conversation c
    JOIN social.connection cn ON cn.connection_id = c.connection_id
    WHERE c.conversation_id = NEW.conversation_id;

    IF v_member_low_id IS NULL OR NEW.member_id NOT IN (v_member_low_id, v_member_high_id) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Conversation participant must be a member of the underlying connection.';
    END IF;

    IF NEW.last_read_message_id IS NOT NULL THEN
        SELECT server_sequence INTO v_new_sequence
        FROM chat.message
        WHERE message_id = NEW.last_read_message_id
          AND conversation_id = NEW.conversation_id;
        IF v_new_sequence IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = 'Last-read message must belong to the participant conversation.';
        END IF;
        IF TG_OP = 'UPDATE' AND OLD.last_read_message_id IS NOT NULL
           AND NEW.last_read_message_id IS DISTINCT FROM OLD.last_read_message_id THEN
            SELECT server_sequence INTO v_old_sequence
            FROM chat.message
            WHERE message_id = OLD.last_read_message_id
              AND conversation_id = OLD.conversation_id;
            IF v_old_sequence IS NULL OR v_new_sequence < v_old_sequence THEN
                RAISE EXCEPTION USING ERRCODE = '23514',
                    MESSAGE = 'Last-read message cursor cannot move backwards.';
            END IF;
        END IF;
    ELSIF TG_OP = 'UPDATE' AND OLD.last_read_message_id IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Last-read message cursor cannot be cleared.';
    END IF;

    IF TG_OP = 'UPDATE' AND OLD.left_at IS NOT NULL
       AND NEW.left_at IS DISTINCT FROM OLD.left_at THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Participant leave time is immutable once set.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_conversation_participant ON chat.conversation_participant;
CREATE TRIGGER enforce_conversation_participant
BEFORE INSERT OR UPDATE ON chat.conversation_participant
FOR EACH ROW EXECUTE FUNCTION chat.enforce_conversation_participant();

-- Deferred validation permits the two participants to be inserted in separate statements
-- while guaranteeing that every conversation has exactly the connection pair at commit.
CREATE OR REPLACE FUNCTION chat.validate_conversation_participant_set()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, chat, social
AS $$
DECLARE
    v_conversation_id varchar(64);
    v_member_low_id varchar(64);
    v_member_high_id varchar(64);
    v_participant_count int;
BEGIN
    v_conversation_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.conversation_id ELSE NEW.conversation_id END;

    SELECT cn.member_low_id, cn.member_high_id
    INTO v_member_low_id, v_member_high_id
    FROM chat.conversation c
    JOIN social.connection cn ON cn.connection_id = c.connection_id
    WHERE c.conversation_id = v_conversation_id;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT count(*) INTO v_participant_count
    FROM chat.conversation_participant cp
    WHERE cp.conversation_id = v_conversation_id
      AND cp.member_id IN (v_member_low_id, v_member_high_id);

    IF v_participant_count <> 2 OR EXISTS (
        SELECT 1 FROM chat.conversation_participant cp
        WHERE cp.conversation_id = v_conversation_id
          AND cp.member_id NOT IN (v_member_low_id, v_member_high_id)
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Conversation must contain exactly the two members of its connection.';
    END IF;
    RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS validate_conversation_participant_set_on_conversation ON chat.conversation;
CREATE CONSTRAINT TRIGGER validate_conversation_participant_set_on_conversation
AFTER INSERT OR UPDATE ON chat.conversation
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION chat.validate_conversation_participant_set();
DROP TRIGGER IF EXISTS validate_conversation_participant_set_on_participant ON chat.conversation_participant;
CREATE CONSTRAINT TRIGGER validate_conversation_participant_set_on_participant
AFTER INSERT OR UPDATE OR DELETE ON chat.conversation_participant
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION chat.validate_conversation_participant_set();

-- Direct message writes cannot bypass participant/connection/block authorization.
CREATE OR REPLACE FUNCTION chat.enforce_message_sender()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND (
        NEW.message_id IS DISTINCT FROM OLD.message_id
        OR NEW.conversation_id IS DISTINCT FROM OLD.conversation_id
        OR NEW.sender_member_id IS DISTINCT FROM OLD.sender_member_id
        OR NEW.server_sequence IS DISTINCT FROM OLD.server_sequence
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Message identity, conversation, sender and server sequence are immutable.';
    END IF;
    IF TG_OP = 'INSERT' AND NOT EXISTS (
        SELECT 1 FROM chat.vw_authorized_conversation authorized
        WHERE authorized.conversation_id = NEW.conversation_id
          AND authorized.member_id = NEW.sender_member_id
          AND authorized.can_send
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '42501',
            MESSAGE = 'Message sender is not authorized for the conversation.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_message_sender ON chat.message;
CREATE TRIGGER enforce_message_sender
BEFORE INSERT OR UPDATE ON chat.message
FOR EACH ROW EXECUTE FUNCTION chat.enforce_message_sender();

-- Receipts belong to the non-sending participant and first-delivered/read timestamps
-- are monotonic, immutable evidence.
CREATE OR REPLACE FUNCTION chat.enforce_message_receipt()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_conversation_id varchar(64);
    v_sender_member_id varchar(64);
BEGIN
    IF TG_OP = 'UPDATE' AND (
        NEW.message_id IS DISTINCT FROM OLD.message_id
        OR NEW.member_id IS DISTINCT FROM OLD.member_id
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Message receipt identity is immutable.';
    END IF;

    SELECT conversation_id, sender_member_id
    INTO v_conversation_id, v_sender_member_id
    FROM chat.message
    WHERE message_id = NEW.message_id;

    IF v_conversation_id IS NULL OR NEW.member_id = v_sender_member_id OR NOT EXISTS (
        SELECT 1 FROM chat.conversation_participant cp
        WHERE cp.conversation_id = v_conversation_id AND cp.member_id = NEW.member_id
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Message receipt must belong to the non-sending conversation participant.';
    END IF;

    IF NEW.read_at IS NOT NULL AND (NEW.delivered_at IS NULL OR NEW.read_at < NEW.delivered_at) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Read time cannot precede delivery time.';
    END IF;
    IF TG_OP = 'UPDATE' AND (
        (OLD.delivered_at IS NOT NULL AND NEW.delivered_at IS DISTINCT FROM OLD.delivered_at)
        OR (OLD.read_at IS NOT NULL AND NEW.read_at IS DISTINCT FROM OLD.read_at)
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Delivered and read timestamps are immutable once recorded.';
    END IF;
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_message_receipt ON chat.message_receipt;
CREATE TRIGGER enforce_message_receipt
BEFORE INSERT OR UPDATE ON chat.message_receipt
FOR EACH ROW EXECUTE FUNCTION chat.enforce_message_receipt();

-- A privacy request is terminal only after its explicit domain work is terminal and evidenced.
CREATE OR REPLACE FUNCTION consent.enforce_privacy_request_completion()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.status = 'COMPLETED' AND NEW.status <> 'COMPLETED' THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'A completed PrivacyRequest cannot return to a mutable state.';
    END IF;
    IF NEW.status = 'COMPLETED' AND (
        NOT EXISTS (SELECT 1 FROM consent.privacy_request_task WHERE privacy_request_id = NEW.privacy_request_id)
        OR EXISTS (
            SELECT 1 FROM consent.privacy_request_task
            WHERE privacy_request_id = NEW.privacy_request_id
              AND (status NOT IN ('COMPLETED','EXEMPTED') OR evidence_code IS NULL OR completed_at IS NULL)
        )
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'PrivacyRequest cannot complete until every required task is completed or evidenced as exempt.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_privacy_request_completion ON consent.privacy_request;
CREATE TRIGGER enforce_privacy_request_completion
BEFORE INSERT OR UPDATE ON consent.privacy_request
FOR EACH ROW EXECUTE FUNCTION consent.enforce_privacy_request_completion();

CREATE OR REPLACE FUNCTION consent.protect_completed_privacy_request_tasks()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM consent.privacy_request
        WHERE privacy_request_id = OLD.privacy_request_id AND status = 'COMPLETED'
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Tasks and evidence for a completed PrivacyRequest are immutable.';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS protect_completed_privacy_request_tasks ON consent.privacy_request_task;
CREATE TRIGGER protect_completed_privacy_request_tasks
BEFORE UPDATE OR DELETE ON consent.privacy_request_task
FOR EACH ROW EXECUTE FUNCTION consent.protect_completed_privacy_request_tasks();

-- Active retention versions are immutable except for the ACTIVE-to-RETIRED transition.
CREATE OR REPLACE FUNCTION ops.protect_active_retention_policy()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status = 'ACTIVE' AND (
        NEW.resource_type IS DISTINCT FROM OLD.resource_type
        OR NEW.policy_version IS DISTINCT FROM OLD.policy_version
        OR NEW.retention_days IS DISTINCT FROM OLD.retention_days
        OR NEW.disposition_action IS DISTINCT FROM OLD.disposition_action
        OR NEW.legal_hold_supported IS DISTINCT FROM OLD.legal_hold_supported
        OR NEW.effective_from IS DISTINCT FROM OLD.effective_from
        OR NEW.approved_by IS DISTINCT FROM OLD.approved_by
        OR NEW.status NOT IN ('ACTIVE','RETIRED')
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'An active retention policy version is immutable and may only be retired.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS protect_active_retention_policy ON ops.retention_policy;
CREATE TRIGGER protect_active_retention_policy
BEFORE UPDATE ON ops.retention_policy
FOR EACH ROW EXECUTE FUNCTION ops.protect_active_retention_policy();

-- ======================== CONTROLLED VIEWS ========================
CREATE OR REPLACE VIEW nlp.vw_member_context_eligibility
AS
WITH latest_consent AS MATERIALIZED (
    SELECT DISTINCT ON (mc.member_id, cp.purpose_code)
           mc.member_consent_id, mc.member_id, cp.purpose_code, mc.decision, mc.withdrawn_at
    FROM consent.member_consent mc
    JOIN consent.consent_policy cp ON cp.policy_id = mc.policy_id
    WHERE cp.effective_from <= CURRENT_TIMESTAMP AND cp.retired_at IS NULL
    ORDER BY mc.member_id, cp.purpose_code, mc.captured_at DESC, mc.member_consent_id DESC
), granted_consent AS (
    SELECT member_id, purpose_code
    FROM latest_consent
    WHERE decision = 'GRANTED' AND withdrawn_at IS NULL
), active_event_policy AS (
    SELECT p.*
    FROM event.event_matching_policy p
    WHERE p.status = 'ACTIVE' AND p.effective_from <= CURRENT_TIMESTAMP
      AND (p.effective_to IS NULL OR p.effective_to > CURRENT_TIMESTAMP)
), valid_live_session AS MATERIALIZED (
    SELECT ls.live_session_id, ls.event_id, ls.member_id, ls.active_until
    FROM event.live_mode_session ls
    JOIN latest_consent lc
      ON lc.member_consent_id = ls.consent_record_id
     AND lc.member_id = ls.member_id
     AND lc.purpose_code = 'LIVE_MODE'
     AND lc.decision = 'GRANTED'
     AND lc.withdrawn_at IS NULL
    WHERE ls.status = 'ACTIVE'
      AND ls.active_until > CURRENT_TIMESTAMP
)
SELECT m.member_id, CAST('GENERAL' AS varchar(64)) AS context_id,
       true AS is_live,
       (CASE WHEN m.status = 'ACTIVE' AND p.profile_status = 'ACTIVE' AND p.visibility <> 'HIDDEN' THEN true ELSE false END) AS is_visible,
       EXISTS (SELECT 1 FROM granted_consent gc WHERE gc.member_id = m.member_id AND gc.purpose_code IN ('MATCH','MATCHING')) AS has_consent,
       (CASE WHEN m.status = 'SUSPENDED' OR m.suspended_at IS NOT NULL THEN true ELSE false END) AS is_suspended,
       (CASE WHEN m.status = 'DELETED' OR m.deleted_at IS NOT NULL THEN true ELSE false END) AS is_deleted,
       m.community_id
FROM iam.member m
JOIN core.member_profile p ON p.member_id = m.member_id
UNION ALL
SELECT m.member_id, e.event_id,
       (CASE WHEN (ep.live_mode_required IS FALSE OR ls.live_session_id IS NOT NULL)
                   AND (ep.proximity_mode <> 'COARSE_CELL' OR EXISTS (
                       SELECT 1 FROM event.event_presence pr
                       WHERE pr.live_session_id = ls.live_session_id
                         AND pr.observed_at >= CURRENT_TIMESTAMP - make_interval(mins => ep.max_presence_age_minutes)
                         AND pr.expires_at > CURRENT_TIMESTAMP
                   )) THEN true ELSE false END) AS is_live,
       (CASE WHEN m.status = 'ACTIVE' AND p.profile_status = 'ACTIVE' AND p.visibility <> 'HIDDEN' THEN true ELSE false END) AS is_visible,
       EXISTS (SELECT 1 FROM granted_consent gc WHERE gc.member_id = m.member_id AND gc.purpose_code IN ('MATCH','MATCHING')) AS has_consent,
       (CASE WHEN m.status = 'SUSPENDED' OR m.suspended_at IS NOT NULL THEN true ELSE false END) AS is_suspended,
       (CASE WHEN m.status = 'DELETED' OR m.deleted_at IS NOT NULL THEN true ELSE false END) AS is_deleted,
       m.community_id
FROM event.event e
JOIN active_event_policy ep ON ep.event_id = e.event_id
JOIN event.event_registration er ON er.event_id = e.event_id
JOIN iam.member m ON m.member_id = er.member_id AND m.community_id = e.community_id
JOIN core.member_profile p ON p.member_id = m.member_id
LEFT JOIN valid_live_session ls ON ls.event_id = e.event_id AND ls.member_id = m.member_id
WHERE e.status = 'ACTIVE'
  AND CURRENT_TIMESTAMP >= e.starts_at AND CURRENT_TIMESTAMP < e.ends_at
  AND (ep.registration_required IS FALSE OR er.status IN ('REGISTERED','CHECKED_IN'))
  AND (ep.check_in_required IS FALSE OR er.status = 'CHECKED_IN');

CREATE OR REPLACE VIEW nlp.vw_member_relationship
AS
SELECT c.member_low_id AS member_id, c.member_high_id AS other_member_id,
       CAST('GLOBAL' AS varchar(64)) AS context_id, false AS is_blocked, true AS is_connected
FROM social.connection c WHERE c.status = 'ACTIVE'
UNION ALL
SELECT c.member_high_id, c.member_low_id, CAST('GLOBAL' AS varchar(64)), false, true
FROM social.connection c WHERE c.status = 'ACTIVE'
UNION ALL
SELECT b.blocker_member_id, b.blocked_member_id, CAST('GLOBAL' AS varchar(64)), true, false
FROM social.member_block b WHERE b.removed_at IS NULL
UNION ALL
SELECT b.blocked_member_id, b.blocker_member_id, CAST('GLOBAL' AS varchar(64)), true, false
FROM social.member_block b WHERE b.removed_at IS NULL;

CREATE OR REPLACE VIEW chat.vw_authorized_conversation
AS
SELECT cp.conversation_id, cp.member_id, c.connection_id, c.status AS conversation_status,
       (CASE WHEN c.status = 'ACTIVE' AND cn.status = 'ACTIVE' AND cp.left_at IS NULL
                      AND NOT EXISTS (
                          SELECT 1 FROM social.member_block b
                          WHERE b.removed_at IS NULL
                            AND ((b.blocker_member_id = cp.member_id AND b.blocked_member_id IN (cn.member_low_id, cn.member_high_id))
                              OR (b.blocked_member_id = cp.member_id AND b.blocker_member_id IN (cn.member_low_id, cn.member_high_id)))
                      ) THEN true ELSE false END) AS can_send
FROM chat.conversation_participant cp
JOIN chat.conversation c ON c.conversation_id = cp.conversation_id
JOIN social.connection cn ON cn.connection_id = c.connection_id
JOIN iam.member sender ON sender.member_id = cp.member_id AND sender.status = 'ACTIVE';

CREATE OR REPLACE VIEW admin.vw_member_review
AS
SELECT m.member_id, m.community_id, m.status AS member_status, m.verified_at, m.suspended_at, m.deleted_at,
       p.display_name, p.headline, p.profile_status, p.visibility, p.completeness_score,
       v.verification_id, v.verification_type, v.status AS verification_status, v.reviewed_by, v.reviewed_at, v.reason_code
FROM iam.member m
LEFT JOIN core.member_profile p ON p.member_id = m.member_id
LEFT JOIN core.member_verification v ON v.member_id = m.member_id;

-- ======================== CONTROLLED FUNCTIONS ========================
CREATE OR REPLACE FUNCTION nlp.get_requester_intent(
    p_member_id varchar(64), p_intent_id varchar(64), p_context_id varchar(64)
)
RETURNS TABLE (
    intent_id varchar(64), member_id varchar(64), context_id varchar(64), intent_type varchar(16),
    normalized_text varchar(4000), category varchar(128), industry varchar(128), geography varchar(128),
    updated_at timestamptz, model_version varchar(128), dimensions int, embedding_hash char(64), embedding vector(1536)
)
LANGUAGE sql
STABLE
AS $$
    SELECT i.intent_id, i.member_id, i.context_id, i.intent_type, i.normalized_text,
           i.category, i.industry, i.geography, i.updated_at,
           e.model_version, e.dimensions, e.normalized_hash, e.embedding
    FROM nlp.nlp_intent i
    JOIN nlp.nlp_embedding e
      ON e.intent_id = i.intent_id
     AND e.status = 'ACTIVE'
     AND e.normalized_hash = i.normalized_hash
    JOIN nlp.nlp_model_version mv
      ON mv.model_version = e.model_version
     AND mv.status = 'ACTIVE'
     AND mv.dimensions = e.dimensions
     AND mv.preprocessing_version = i.preprocessing_version
    WHERE i.intent_id = p_intent_id AND i.member_id = p_member_id AND i.context_id = p_context_id
      AND i.status = 'MATCH_READY' AND i.expires_at > CURRENT_TIMESTAMP;
$$;

CREATE OR REPLACE FUNCTION nlp.get_eligible_candidates(
    p_requester_id varchar(64), p_context_id varchar(64), p_max_rows int DEFAULT 200
)
RETURNS TABLE (
    intent_id varchar(64), member_id varchar(64), context_id varchar(64), intent_type varchar(16),
    normalized_text varchar(4000), category varchar(128), industry varchar(128), geography varchar(128),
    updated_at timestamptz, model_version varchar(128), dimensions int, embedding_hash char(64),
    embedding vector(1536), cosine_distance double precision
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_max_rows NOT BETWEEN 50 AND 200 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'max_rows must be between 50 and 200.';
    END IF;
    RETURN QUERY
    WITH requester_scope AS MATERIALIZED (
        SELECT eligibility.community_id
        FROM nlp.vw_member_context_eligibility eligibility
        WHERE eligibility.member_id = p_requester_id
          AND eligibility.context_id = p_context_id
          AND eligibility.is_live
          AND eligibility.is_visible
          AND eligibility.has_consent
          AND NOT eligibility.is_suspended
          AND NOT eligibility.is_deleted
        LIMIT 1
    ), requester_embedding AS MATERIALIZED (
        SELECT i.intent_id, e.embedding
        FROM nlp.nlp_intent i
        CROSS JOIN requester_scope
        JOIN nlp.nlp_embedding e
          ON e.intent_id = i.intent_id
         AND e.status = 'ACTIVE'
         AND e.normalized_hash = i.normalized_hash
        JOIN nlp.nlp_model_version mv
          ON mv.model_version = e.model_version
         AND mv.status = 'ACTIVE'
         AND mv.dimensions = e.dimensions
         AND mv.preprocessing_version = i.preprocessing_version
        WHERE i.member_id = p_requester_id AND i.context_id = p_context_id
          AND i.intent_type = 'WANT' AND i.status = 'MATCH_READY' AND i.expires_at > CURRENT_TIMESTAMP
        ORDER BY i.updated_at DESC, i.intent_id
        LIMIT 1
    ), matching_policy AS MATERIALIZED (
        SELECT p.proximity_mode, p.max_presence_age_minutes
        FROM event.event_matching_policy p
        WHERE p.event_id = p_context_id AND p.status = 'ACTIVE'
          AND p.effective_from <= CURRENT_TIMESTAMP
          AND (p.effective_to IS NULL OR p.effective_to > CURRENT_TIMESTAMP)
        ORDER BY p.policy_version DESC
        LIMIT 1
    ), eligible_members AS MATERIALIZED (
        SELECT m.member_id
        FROM nlp.vw_member_context_eligibility m
        JOIN requester_scope requester ON requester.community_id = m.community_id
        WHERE m.context_id = p_context_id AND m.member_id <> p_requester_id
          AND m.is_live AND m.is_visible AND m.has_consent AND NOT m.is_suspended AND NOT m.is_deleted
          AND NOT EXISTS (
              SELECT 1 FROM nlp.vw_member_relationship r
              WHERE r.context_id = 'GLOBAL' AND r.member_id = p_requester_id AND r.other_member_id = m.member_id
                AND (r.is_blocked OR r.is_connected)
          )
          AND (
              NOT EXISTS (SELECT 1 FROM matching_policy p WHERE p.proximity_mode = 'COARSE_CELL')
              OR EXISTS (
                  SELECT 1
                  FROM matching_policy p
                  JOIN event.live_mode_session requester_session
                    ON requester_session.event_id = p_context_id AND requester_session.member_id = p_requester_id
                   AND requester_session.status = 'ACTIVE' AND requester_session.active_until > CURRENT_TIMESTAMP
                  JOIN event.event_presence requester_presence
                    ON requester_presence.live_session_id = requester_session.live_session_id
                   AND requester_presence.observed_at >= CURRENT_TIMESTAMP - make_interval(mins => p.max_presence_age_minutes)
                   AND requester_presence.expires_at > CURRENT_TIMESTAMP
                  JOIN event.live_mode_session candidate_session
                    ON candidate_session.event_id = p_context_id AND candidate_session.member_id = m.member_id
                   AND candidate_session.status = 'ACTIVE' AND candidate_session.active_until > CURRENT_TIMESTAMP
                  JOIN event.event_presence candidate_presence
                    ON candidate_presence.live_session_id = candidate_session.live_session_id
                   AND candidate_presence.coarse_cell = requester_presence.coarse_cell
                   AND candidate_presence.observed_at >= CURRENT_TIMESTAMP - make_interval(mins => p.max_presence_age_minutes)
                   AND candidate_presence.expires_at > CURRENT_TIMESTAMP
                  WHERE p.proximity_mode = 'COARSE_CELL'
              )
          )
    ), eligible_candidates AS MATERIALIZED (
        SELECT i.intent_id, i.member_id, i.context_id, i.intent_type, i.normalized_text,
               i.category, i.industry, i.geography, i.updated_at,
               e.model_version, e.dimensions, e.normalized_hash AS embedding_hash, e.embedding
        FROM eligible_members m
        JOIN nlp.nlp_intent i ON i.member_id = m.member_id AND i.context_id = p_context_id
        JOIN nlp.nlp_embedding e
          ON e.intent_id = i.intent_id
         AND e.status = 'ACTIVE'
         AND e.normalized_hash = i.normalized_hash
        JOIN nlp.nlp_model_version mv
          ON mv.model_version = e.model_version
         AND mv.status = 'ACTIVE'
         AND mv.dimensions = e.dimensions
         AND mv.preprocessing_version = i.preprocessing_version
        CROSS JOIN requester_embedding requester
        WHERE i.intent_type = 'OFFER' AND i.status = 'MATCH_READY' AND i.expires_at > CURRENT_TIMESTAMP
          AND NOT EXISTS (
              SELECT 1
              FROM nlp.match_suppression s
              WHERE s.starts_at <= CURRENT_TIMESTAMP
                AND (s.ends_at IS NULL OR s.ends_at > CURRENT_TIMESTAMP)
                AND (s.member_id IS NULL OR s.member_id IN (p_requester_id, m.member_id))
                AND (s.context_id IS NULL OR s.context_id = p_context_id)
                AND (s.intent_id IS NULL OR s.intent_id IN (requester.intent_id, i.intent_id))
          )
        ORDER BY i.updated_at DESC, i.intent_id
        LIMIT p_max_rows
    )
    -- MATERIALIZED eligibility bounds the exact vector scan before cosine ranking.
    SELECT c.intent_id, c.member_id, c.context_id, c.intent_type, c.normalized_text,
           c.category, c.industry, c.geography, c.updated_at,
           c.model_version, c.dimensions, c.embedding_hash, c.embedding,
           (c.embedding <=> r.embedding)::double precision
    FROM eligible_candidates c
    CROSS JOIN requester_embedding r
    ORDER BY c.embedding <=> r.embedding, c.updated_at DESC, c.intent_id;
END;
$$;

CREATE OR REPLACE FUNCTION nlp.save_match_results(
    p_request_id varchar(64), p_requester_id varchar(64), p_results jsonb
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_request_id varchar(64);
BEGIN
    IF jsonb_typeof(p_results) <> 'array' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'results must be a JSON array.';
    END IF;
    SELECT request_id INTO v_request_id
    FROM nlp.match_request
    WHERE request_id = p_request_id AND requester_id = p_requester_id
    FOR UPDATE;
    IF v_request_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Match request not found for requester.';
    END IF;
    INSERT INTO nlp.nlp_match_result(
        request_id, requester_id, candidate_id, rank, semantic_score, reciprocal_score, final_score,
        label, reason_codes, reason_text, model_version, preprocessing_version, ranking_version, policy_status
    )
    SELECT p_request_id, p_requester_id, x.candidate_id, x.rank, x.semantic_score, x.reciprocal_score,
           x.final_score, x.label, x.reason_codes, x.reason_text, x.model_version,
           x.preprocessing_version, x.ranking_version, COALESCE(x.policy_status, 'ELIGIBLE')
    FROM jsonb_to_recordset(p_results) AS x(
        candidate_id varchar(64), rank smallint, semantic_score numeric(8,7), reciprocal_score numeric(8,7),
        final_score numeric(8,7), label varchar(32), reason_codes jsonb, reason_text varchar(2000),
        model_version varchar(128), preprocessing_version varchar(128), ranking_version varchar(128), policy_status varchar(24)
    )
    ON CONFLICT (request_id, candidate_id) DO NOTHING;
    UPDATE nlp.match_request
    SET status = 'COMPLETED',
        candidate_count = (SELECT count(*) FROM nlp.nlp_match_result WHERE request_id = p_request_id),
        completed_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE request_id = p_request_id;
END;
$$;

CREATE OR REPLACE FUNCTION nlp.save_feedback(
    p_match_result_id bigint, p_requester_id varchar(64), p_label varchar(64),
    p_reason_code varchar(64) DEFAULT NULL, p_reason varchar(1000) DEFAULT NULL,
    p_supersedes_feedback_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_request_id varchar(64);
    v_candidate_id varchar(64);
    v_feedback_id bigint;
BEGIN
    IF p_label NOT IN ('USEFUL','NOT_USEFUL','INAPPROPRIATE') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Unsupported feedback label.';
    END IF;
    SELECT request_id, candidate_id INTO v_request_id, v_candidate_id
    FROM nlp.nlp_match_result
    WHERE match_result_id = p_match_result_id AND requester_id = p_requester_id;
    IF v_request_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Match result not found for requester.';
    END IF;
    IF p_supersedes_feedback_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM nlp.nlp_feedback
        WHERE feedback_id = p_supersedes_feedback_id
          AND requester_id = p_requester_id AND match_result_id = p_match_result_id
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Feedback correction does not reference the same requester and match result.';
    END IF;
    INSERT INTO nlp.nlp_feedback(
        supersedes_feedback_id, match_result_id, request_id, requester_id, candidate_id, label, reason_code, reason
    ) VALUES (
        p_supersedes_feedback_id, p_match_result_id, v_request_id, p_requester_id, v_candidate_id, p_label, p_reason_code, p_reason
    ) RETURNING feedback_id INTO v_feedback_id;
    RETURN v_feedback_id;
END;
$$;

DROP FUNCTION IF EXISTS social.accept_connection_request(varchar, varchar, varchar, varchar);
CREATE OR REPLACE FUNCTION social.accept_connection_request(
    p_connection_request_id varchar(64), p_recipient_member_id varchar(64),
    p_connection_id varchar(64), p_conversation_id varchar(64),
    p_idempotency_key varchar(128), p_request_hash char(64),
    p_idempotency_expires_at timestamptz, p_sync_expires_at timestamptz
)
RETURNS TABLE (connection_id varchar(64), conversation_id varchar(64))
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, social, chat, ops, iam
AS $$
DECLARE
    v_sender_id varchar(64);
    v_community_id varchar(64);
    v_request_version bigint;
    v_existing_connection_id varchar(64);
    v_existing_conversation_id varchar(64);
    v_existing_hash char(64);
    v_idempotency_status smallint;
    v_claimed boolean := false;
BEGIN
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' OR p_request_hash IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Idempotency key and request hash are required.';
    END IF;
    IF p_idempotency_expires_at <= CURRENT_TIMESTAMP OR p_sync_expires_at <= CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Idempotency and sync expiry must be in the future.';
    END IF;

    INSERT INTO ops.idempotency_record(scope, idempotency_key, actor_id, request_hash, expires_at)
    VALUES ('social.accept_connection_request', p_idempotency_key, p_recipient_member_id, p_request_hash, p_idempotency_expires_at)
    ON CONFLICT (scope, actor_id, idempotency_key) DO NOTHING
    RETURNING true INTO v_claimed;

    SELECT request_hash, status_code
    INTO v_existing_hash, v_idempotency_status
    FROM ops.idempotency_record
    WHERE scope = 'social.accept_connection_request'
      AND actor_id = p_recipient_member_id
      AND idempotency_key = p_idempotency_key
    FOR UPDATE;

    IF v_existing_hash IS DISTINCT FROM p_request_hash THEN
        RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'Idempotency key was already used with a different request.';
    END IF;
    IF NOT COALESCE(v_claimed, false) THEN
        IF v_idempotency_status IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = '55P03', MESSAGE = 'Idempotent operation is still in progress.';
        END IF;
        SELECT c.connection_id, cv.conversation_id
        INTO v_existing_connection_id, v_existing_conversation_id
        FROM social.connection c
        JOIN chat.conversation cv ON cv.connection_id = c.connection_id
        WHERE c.accepted_request_id = p_connection_request_id
          AND p_recipient_member_id IN (c.member_low_id, c.member_high_id);
        IF v_existing_connection_id = p_connection_id AND v_existing_conversation_id = p_conversation_id THEN
            RETURN QUERY SELECT v_existing_connection_id, v_existing_conversation_id;
            RETURN;
        END IF;
        RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'Idempotency result does not match the requested resource identifiers.';
    END IF;

    SELECT cr.sender_member_id, sender.community_id
    INTO v_sender_id, v_community_id
    FROM social.connection_request cr
    JOIN iam.member sender ON sender.member_id = cr.sender_member_id AND sender.status = 'ACTIVE'
    JOIN iam.member recipient
      ON recipient.member_id = cr.recipient_member_id
     AND recipient.status = 'ACTIVE'
     AND recipient.community_id = sender.community_id
    WHERE cr.connection_request_id = p_connection_request_id
      AND cr.recipient_member_id = p_recipient_member_id
      AND cr.status = 'PENDING' AND cr.expires_at > CURRENT_TIMESTAMP
    FOR UPDATE OF cr;
    IF v_sender_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Eligible pending connection request not found.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM social.member_block
        WHERE removed_at IS NULL
          AND ((blocker_member_id = v_sender_id AND blocked_member_id = p_recipient_member_id)
            OR (blocker_member_id = p_recipient_member_id AND blocked_member_id = v_sender_id))
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Connection is not eligible.';
    END IF;
    UPDATE social.connection_request
    SET status = 'ACCEPTED', responded_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
    WHERE connection_request_id = p_connection_request_id
    RETURNING row_version INTO v_request_version;
    INSERT INTO social.connection(connection_id, member_low_id, member_high_id, accepted_request_id)
    VALUES (p_connection_id, LEAST(v_sender_id, p_recipient_member_id), GREATEST(v_sender_id, p_recipient_member_id), p_connection_request_id);
    INSERT INTO chat.conversation(conversation_id, connection_id) VALUES (p_conversation_id, p_connection_id);
    INSERT INTO chat.conversation_participant(conversation_id, member_id)
    VALUES (p_conversation_id, v_sender_id), (p_conversation_id, p_recipient_member_id);
    INSERT INTO ops.outbox_event(outbox_event_id, aggregate_type, aggregate_id, event_type, payload_json)
    VALUES (gen_random_uuid()::text, 'CONNECTION', p_connection_id, 'connection.accepted',
            jsonb_build_object('connectionId', p_connection_id, 'conversationId', p_conversation_id));

    INSERT INTO ops.sync_change(
        community_id, member_scope_id, resource_type, resource_id, change_type,
        resource_version, payload_json, expires_at
    )
    SELECT v_community_id, member_id, 'REQUEST', p_connection_request_id, 'UPSERT',
           v_request_version,
           jsonb_build_object('requestId', p_connection_request_id, 'status', 'ACCEPTED'),
           p_sync_expires_at
    FROM (VALUES (v_sender_id), (p_recipient_member_id)) AS recipients(member_id)
    UNION ALL
    SELECT v_community_id, member_id, 'CONVERSATION', p_conversation_id, 'UPSERT',
           1,
           jsonb_build_object('conversationId', p_conversation_id, 'connectionId', p_connection_id),
           p_sync_expires_at
    FROM (VALUES (v_sender_id), (p_recipient_member_id)) AS recipients(member_id);

    UPDATE ops.idempotency_record
    SET status_code = 200, response_ref = p_connection_id || ':' || p_conversation_id
    WHERE scope = 'social.accept_connection_request'
      AND actor_id = p_recipient_member_id
      AND idempotency_key = p_idempotency_key;
    RETURN QUERY SELECT p_connection_id, p_conversation_id;
END;
$$;

DROP FUNCTION IF EXISTS chat.save_message(varchar, varchar, varchar, varchar, text, timestamptz);
CREATE OR REPLACE FUNCTION chat.save_message(
    p_message_id varchar(64), p_conversation_id varchar(64), p_sender_member_id varchar(64),
    p_message_type varchar(20), p_body text, p_client_sent_at timestamptz,
    p_idempotency_key varchar(128), p_request_hash char(64),
    p_idempotency_expires_at timestamptz, p_sync_expires_at timestamptz
)
RETURNS SETOF chat.message
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, chat, ops, iam
AS $$
DECLARE
    v_message chat.message%ROWTYPE;
    v_existing_hash char(64);
    v_idempotency_status smallint;
    v_claimed boolean := false;
    v_community_id varchar(64);
BEGIN
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' OR p_request_hash IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Idempotency key and request hash are required.';
    END IF;
    IF p_idempotency_expires_at <= CURRENT_TIMESTAMP OR p_sync_expires_at <= CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Idempotency and sync expiry must be in the future.';
    END IF;
    IF p_message_type NOT IN ('TEXT','FILE','SYSTEM') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Unsupported message type.';
    END IF;

    INSERT INTO ops.idempotency_record(scope, idempotency_key, actor_id, request_hash, expires_at)
    VALUES ('chat.save_message', p_idempotency_key, p_sender_member_id, p_request_hash, p_idempotency_expires_at)
    ON CONFLICT (scope, actor_id, idempotency_key) DO NOTHING
    RETURNING true INTO v_claimed;
    SELECT request_hash, status_code
    INTO v_existing_hash, v_idempotency_status
    FROM ops.idempotency_record
    WHERE scope = 'chat.save_message'
      AND actor_id = p_sender_member_id
      AND idempotency_key = p_idempotency_key
    FOR UPDATE;
    IF v_existing_hash IS DISTINCT FROM p_request_hash THEN
        RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'Idempotency key was already used with a different request.';
    END IF;
    IF NOT COALESCE(v_claimed, false) THEN
        IF v_idempotency_status IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = '55P03', MESSAGE = 'Idempotent operation is still in progress.';
        END IF;
        SELECT * INTO v_message FROM chat.message WHERE message_id = p_message_id;
        IF NOT FOUND OR v_message.conversation_id IS DISTINCT FROM p_conversation_id
           OR v_message.sender_member_id IS DISTINCT FROM p_sender_member_id
           OR v_message.message_type IS DISTINCT FROM p_message_type
           OR v_message.body IS DISTINCT FROM p_body
           OR v_message.client_sent_at IS DISTINCT FROM p_client_sent_at THEN
            RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'Idempotency result does not match the message request.';
        END IF;
        RETURN NEXT v_message;
        RETURN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM chat.vw_authorized_conversation
        WHERE conversation_id = p_conversation_id AND member_id = p_sender_member_id AND can_send
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Member is not authorized to send to this conversation.';
    END IF;
    PERFORM 1 FROM chat.conversation WHERE conversation_id = p_conversation_id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM chat.message WHERE message_id = p_message_id) THEN
        RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'message_id is already bound to another idempotent operation.';
    END IF;
    INSERT INTO chat.message(message_id, conversation_id, sender_member_id, message_type, body, client_sent_at)
    VALUES (p_message_id, p_conversation_id, p_sender_member_id, p_message_type, p_body, p_client_sent_at)
    RETURNING * INTO v_message;

    UPDATE chat.conversation
    SET last_message_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
    WHERE conversation_id = p_conversation_id;
    INSERT INTO ops.outbox_event(outbox_event_id, aggregate_type, aggregate_id, event_type, payload_json)
    VALUES (gen_random_uuid()::text, 'MESSAGE', p_message_id, 'chat.message.created',
            jsonb_build_object('messageId', p_message_id, 'conversationId', p_conversation_id));

    SELECT community_id INTO v_community_id
    FROM iam.member WHERE member_id = p_sender_member_id;
    INSERT INTO ops.sync_change(
        community_id, member_scope_id, resource_type, resource_id, change_type,
        resource_version, payload_json, expires_at
    )
    SELECT v_community_id, cp.member_id, 'MESSAGE', p_message_id, 'UPSERT',
           v_message.row_version,
           jsonb_build_object(
               'messageId', p_message_id,
               'conversationId', p_conversation_id,
               'senderMemberId', p_sender_member_id,
               'serverSequence', v_message.server_sequence
           ),
           p_sync_expires_at
    FROM chat.conversation_participant cp
    WHERE cp.conversation_id = p_conversation_id;

    UPDATE ops.idempotency_record
    SET status_code = 200, response_ref = p_message_id
    WHERE scope = 'chat.save_message'
      AND actor_id = p_sender_member_id
      AND idempotency_key = p_idempotency_key;
    RETURN NEXT v_message;
END;
$$;

CREATE OR REPLACE FUNCTION chat.save_message_receipt(
    p_message_id varchar(64), p_member_id varchar(64),
    p_delivered_at timestamptz, p_read_at timestamptz,
    p_idempotency_key varchar(128), p_request_hash char(64),
    p_idempotency_expires_at timestamptz, p_sync_expires_at timestamptz
)
RETURNS SETOF chat.message_receipt
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, chat, ops, iam
AS $$
DECLARE
    v_receipt chat.message_receipt%ROWTYPE;
    v_existing_hash char(64);
    v_idempotency_status smallint;
    v_claimed boolean := false;
    v_changed boolean := false;
    v_delivered_at timestamptz := COALESCE(p_delivered_at, p_read_at);
    v_conversation_id varchar(64);
    v_community_id varchar(64);
    v_message_version bigint;
BEGIN
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' OR p_request_hash IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Idempotency key and request hash are required.';
    END IF;
    IF p_idempotency_expires_at <= CURRENT_TIMESTAMP OR p_sync_expires_at <= CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Idempotency and sync expiry must be in the future.';
    END IF;
    IF v_delivered_at IS NULL AND p_read_at IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A delivered or read timestamp is required.';
    END IF;

    INSERT INTO ops.idempotency_record(scope, idempotency_key, actor_id, request_hash, expires_at)
    VALUES ('chat.save_message_receipt', p_idempotency_key, p_member_id, p_request_hash, p_idempotency_expires_at)
    ON CONFLICT (scope, actor_id, idempotency_key) DO NOTHING
    RETURNING true INTO v_claimed;
    SELECT request_hash, status_code
    INTO v_existing_hash, v_idempotency_status
    FROM ops.idempotency_record
    WHERE scope = 'chat.save_message_receipt'
      AND actor_id = p_member_id
      AND idempotency_key = p_idempotency_key
    FOR UPDATE;
    IF v_existing_hash IS DISTINCT FROM p_request_hash THEN
        RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'Idempotency key was already used with a different request.';
    END IF;
    IF NOT COALESCE(v_claimed, false) THEN
        IF v_idempotency_status IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = '55P03', MESSAGE = 'Idempotent operation is still in progress.';
        END IF;
        SELECT * INTO v_receipt
        FROM chat.message_receipt
        WHERE message_id = p_message_id AND member_id = p_member_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'Idempotency result does not match the receipt request.';
        END IF;
        RETURN NEXT v_receipt;
        RETURN;
    END IF;

    SELECT msg.conversation_id, msg.row_version, sender.community_id
    INTO v_conversation_id, v_message_version, v_community_id
    FROM chat.message msg
    JOIN iam.member sender ON sender.member_id = msg.sender_member_id
    WHERE msg.message_id = p_message_id
    FOR UPDATE OF msg;
    IF v_conversation_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Message not found.';
    END IF;

    INSERT INTO chat.message_receipt(message_id, member_id, delivered_at, read_at)
    VALUES (p_message_id, p_member_id, v_delivered_at, p_read_at)
    ON CONFLICT (message_id, member_id) DO UPDATE
    SET delivered_at = COALESCE(chat.message_receipt.delivered_at, EXCLUDED.delivered_at),
        read_at = COALESCE(chat.message_receipt.read_at, EXCLUDED.read_at),
        updated_at = CURRENT_TIMESTAMP
    WHERE (chat.message_receipt.delivered_at IS NULL AND EXCLUDED.delivered_at IS NOT NULL)
       OR (chat.message_receipt.read_at IS NULL AND EXCLUDED.read_at IS NOT NULL)
    RETURNING * INTO v_receipt;
    v_changed := FOUND;
    IF NOT v_changed THEN
        SELECT * INTO v_receipt
        FROM chat.message_receipt
        WHERE message_id = p_message_id AND member_id = p_member_id;
    END IF;

    IF p_read_at IS NOT NULL THEN
        UPDATE chat.conversation_participant cp
        SET last_read_message_id = p_message_id
        WHERE cp.conversation_id = v_conversation_id
          AND cp.member_id = p_member_id
          AND (
              cp.last_read_message_id IS NULL
              OR (SELECT old_message.server_sequence FROM chat.message old_message
                  WHERE old_message.message_id = cp.last_read_message_id) <=
                 (SELECT current_message.server_sequence FROM chat.message current_message
                  WHERE current_message.message_id = p_message_id)
          );
    END IF;

    IF v_changed THEN
        INSERT INTO ops.outbox_event(outbox_event_id, aggregate_type, aggregate_id, event_type, payload_json)
        VALUES (gen_random_uuid()::text, 'MESSAGE', p_message_id, 'chat.message.receipt_updated',
                jsonb_build_object('messageId', p_message_id, 'memberId', p_member_id));
        INSERT INTO ops.sync_change(
            community_id, member_scope_id, resource_type, resource_id, change_type,
            resource_version, payload_json, expires_at
        )
        SELECT v_community_id, cp.member_id, 'MESSAGE', p_message_id, 'UPSERT',
               v_message_version,
               jsonb_build_object(
                   'messageId', p_message_id,
                   'receiptMemberId', p_member_id,
                   'isDelivered', v_receipt.delivered_at IS NOT NULL,
                   'isRead', v_receipt.read_at IS NOT NULL
               ),
               p_sync_expires_at
        FROM chat.conversation_participant cp
        WHERE cp.conversation_id = v_conversation_id;
    END IF;

    UPDATE ops.idempotency_record
    SET status_code = 200, response_ref = p_message_id || ':' || p_member_id
    WHERE scope = 'chat.save_message_receipt'
      AND actor_id = p_member_id
      AND idempotency_key = p_idempotency_key;
    RETURN NEXT v_receipt;
END;
$$;

CREATE OR REPLACE FUNCTION event.purge_expired_presence(p_batch_size int DEFAULT 5000)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_deleted bigint;
BEGIN
    IF p_batch_size NOT BETWEEN 1 AND 20000 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'batch_size must be between 1 and 20000.';
    END IF;
    WITH targets AS (
        SELECT ctid FROM event.event_presence
        WHERE expires_at <= CURRENT_TIMESTAMP
        ORDER BY expires_at
        LIMIT p_batch_size
        FOR UPDATE SKIP LOCKED
    )
    DELETE FROM event.event_presence p USING targets t WHERE p.ctid = t.ctid;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$;

CREATE OR REPLACE FUNCTION notification.try_enqueue(
    p_notification_id varchar(64), p_member_id varchar(64), p_purpose_code varchar(64), p_channel varchar(16),
    p_resource_type varchar(32), p_resource_id varchar(64), p_template_code varchar(64), p_dedupe_key varchar(160),
    p_context_id varchar(64) DEFAULT NULL, p_source_confidence numeric(6,5) DEFAULT NULL
)
RETURNS TABLE (
    notification_id varchar(64), status varchar(20), scheduled_at timestamptz,
    expires_at timestamptz, suppression_reason varchar(64)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_now timestamptz := CURRENT_TIMESTAMP;
    v_community_id varchar(64);
    v_policy_id bigint;
    v_opt_out boolean;
    v_quiet_behavior varchar(16);
    v_dedupe_seconds int;
    v_max_hour smallint;
    v_max_day smallint;
    v_ttl int;
    v_event_policy_id bigint;
    v_alert_threshold numeric(6,5);
    v_event_max_hour smallint;
    v_event_max_total smallint;
    v_min_interval smallint;
    v_suppression varchar(64);
    v_scheduled_at timestamptz := v_now;
    v_bucket_start timestamptz;
    v_push_enabled boolean := true;
    v_email_enabled boolean := true;
    v_quiet_start time;
    v_quiet_end time;
    v_timezone_id varchar(64);
    v_local_now timestamp;
    v_local_time time;
    v_target_date date;
BEGIN
    SELECT m.community_id INTO v_community_id
    FROM iam.member m WHERE m.member_id = p_member_id AND m.status = 'ACTIVE';
    IF v_community_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Active member not found.';
    END IF;
    SELECT p.notification_policy_id, p.member_opt_out_allowed, p.quiet_hours_behavior,
           p.dedupe_window_seconds, p.max_per_hour, p.max_per_day, p.ttl_minutes
    INTO v_policy_id, v_opt_out, v_quiet_behavior, v_dedupe_seconds, v_max_hour, v_max_day, v_ttl
    FROM notification.notification_policy p
    WHERE p.status = 'ACTIVE' AND p.purpose_code = p_purpose_code AND p.channel = p_channel
      AND (p.community_id = v_community_id OR p.community_id IS NULL)
      AND p.effective_from <= v_now AND (p.effective_to IS NULL OR p.effective_to > v_now)
    ORDER BY CASE WHEN p.community_id = v_community_id THEN 0 ELSE 1 END, p.policy_version DESC
    LIMIT 1;
    IF v_policy_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'No active notification policy.';
    END IF;
    IF p_context_id IS NOT NULL AND p_context_id <> 'GENERAL' THEN
        SELECT p.event_matching_policy_id, p.alert_confidence_threshold,
               p.max_match_alerts_per_hour, p.max_match_alerts_per_event, p.minimum_alert_interval_minutes
        INTO v_event_policy_id, v_alert_threshold, v_event_max_hour, v_event_max_total, v_min_interval
        FROM event.event_matching_policy p
        WHERE p.event_id = p_context_id AND p.status = 'ACTIVE'
          AND p.effective_from <= v_now AND (p.effective_to IS NULL OR p.effective_to > v_now)
        ORDER BY p.policy_version DESC LIMIT 1;
        IF p_purpose_code = 'MATCH' AND (v_event_policy_id IS NULL OR p_source_confidence IS NULL) THEN
            v_suppression := 'POLICY';
        END IF;
    END IF;
    SELECT p.push_enabled, p.email_enabled, p.quiet_start_local, p.quiet_end_local, p.timezone_id
    INTO v_push_enabled, v_email_enabled, v_quiet_start, v_quiet_end, v_timezone_id
    FROM notification.notification_preference p
    WHERE p.member_id = p_member_id AND p.purpose_code = p_purpose_code;
    IF NOT FOUND THEN
        v_push_enabled := true;
        v_email_enabled := true;
        v_quiet_start := NULL;
        v_quiet_end := NULL;
        v_timezone_id := NULL;
    END IF;

    v_bucket_start := to_timestamp(floor(extract(epoch FROM v_now) / v_dedupe_seconds) * v_dedupe_seconds);
    -- Serializes policy counters per member without locking unrelated recipients.
    PERFORM pg_advisory_xact_lock(hashtextextended(p_member_id || ':' || v_policy_id::text, 0));

    RETURN QUERY
    SELECT n.notification_id, n.status, n.scheduled_at, n.expires_at, n.suppression_reason
    FROM notification.notification n
    WHERE n.member_id = p_member_id AND n.channel = p_channel
      AND n.dedupe_key = p_dedupe_key AND n.dedupe_bucket_start = v_bucket_start;
    IF FOUND THEN RETURN; END IF;

    IF v_suppression IS NULL AND v_opt_out
       AND ((p_channel = 'PUSH' AND NOT v_push_enabled) OR (p_channel = 'EMAIL' AND NOT v_email_enabled)) THEN
        v_suppression := 'OPT_OUT';
    ELSIF v_suppression IS NULL AND v_event_policy_id IS NOT NULL
       AND p_source_confidence IS NOT NULL AND p_source_confidence < v_alert_threshold THEN
        v_suppression := 'BELOW_THRESHOLD';
    ELSIF v_suppression IS NULL AND ((SELECT count(*) FROM notification.notification n WHERE n.member_id = p_member_id AND n.notification_policy_id = v_policy_id AND n.created_at > v_now - interval '1 hour' AND n.status IN ('PENDING','SENT','DELIVERED')) >= v_max_hour
       OR (SELECT count(*) FROM notification.notification n WHERE n.member_id = p_member_id AND n.notification_policy_id = v_policy_id AND n.created_at > v_now - interval '1 day' AND n.status IN ('PENDING','SENT','DELIVERED')) >= v_max_day) THEN
        v_suppression := 'RATE_LIMIT';
    ELSIF v_suppression IS NULL AND v_event_policy_id IS NOT NULL AND (
        (SELECT count(*) FROM notification.notification n WHERE n.member_id = p_member_id AND n.event_matching_policy_id = v_event_policy_id AND n.created_at > v_now - interval '1 hour' AND n.status IN ('PENDING','SENT','DELIVERED')) >= v_event_max_hour
        OR (SELECT count(*) FROM notification.notification n WHERE n.member_id = p_member_id AND n.event_matching_policy_id = v_event_policy_id AND n.status IN ('PENDING','SENT','DELIVERED')) >= v_event_max_total
        OR EXISTS (SELECT 1 FROM notification.notification n WHERE n.member_id = p_member_id AND n.event_matching_policy_id = v_event_policy_id AND n.created_at > v_now - make_interval(mins => v_min_interval) AND n.status IN ('PENDING','SENT','DELIVERED'))
    ) THEN
        v_suppression := 'RATE_LIMIT';
    END IF;

    IF v_suppression IS NULL AND v_quiet_start IS NOT NULL AND v_quiet_end IS NOT NULL AND v_timezone_id IS NOT NULL THEN
        v_local_now := v_now AT TIME ZONE v_timezone_id;
        v_local_time := v_local_now::time;
        IF (v_quiet_start < v_quiet_end AND v_local_time >= v_quiet_start AND v_local_time < v_quiet_end)
           OR (v_quiet_start > v_quiet_end AND (v_local_time >= v_quiet_start OR v_local_time < v_quiet_end)) THEN
            IF v_quiet_behavior = 'SUPPRESS' THEN
                v_suppression := 'QUIET_HOURS';
            ELSIF v_quiet_behavior = 'DEFER' THEN
                v_target_date := CASE WHEN v_local_time < v_quiet_end THEN v_local_now::date ELSE v_local_now::date + 1 END;
                v_scheduled_at := (v_target_date + v_quiet_end) AT TIME ZONE v_timezone_id;
            END IF;
        END IF;
    END IF;

    INSERT INTO notification.notification(
        notification_id, member_id, notification_policy_id, event_matching_policy_id, purpose_code, channel,
        resource_type, resource_id, template_code, dedupe_key, dedupe_bucket_start, source_confidence,
        context_id, status, scheduled_at, expires_at, suppression_reason
    ) VALUES (
        p_notification_id, p_member_id, v_policy_id, v_event_policy_id, p_purpose_code, p_channel,
        p_resource_type, p_resource_id, p_template_code, p_dedupe_key, v_bucket_start, p_source_confidence,
        p_context_id, CASE WHEN v_suppression IS NULL THEN 'PENDING' ELSE 'SUPPRESSED' END,
        v_scheduled_at, v_now + make_interval(mins => v_ttl), v_suppression
    );
    IF v_suppression IS NULL THEN
        INSERT INTO ops.outbox_event(outbox_event_id, aggregate_type, aggregate_id, event_type, payload_json)
        VALUES (gen_random_uuid()::text, 'NOTIFICATION', p_notification_id, 'notification.queued',
                jsonb_build_object('notificationId', p_notification_id));
    END IF;
    RETURN QUERY
    SELECT n.notification_id, n.status, n.scheduled_at, n.expires_at, n.suppression_reason
    FROM notification.notification n WHERE n.notification_id = p_notification_id;
END;
$$;

-- ======================== REFERENCE DATA ========================
-- Release 1 operates within a single default OLGA community.
-- Preserve any production-managed values when the row already exists.
INSERT INTO core.community(community_id, name, status, default_locale)
VALUES ('olga', 'OLGA', 'ACTIVE', 'en-IN')
ON CONFLICT (community_id) DO NOTHING;

INSERT INTO iam.role(role_code, name, description, is_privileged) VALUES
    ('MEMBER','Member','Standard product member',false),
    ('ADMIN','Administrator','Privileged product administration through explicit permissions',true),
    ('EVENT_ADMIN','Event administrator','Manages events and event policies',true),
    ('MODERATOR','Moderator','Reviews reports and moderation cases',true),
    ('PRODUCT_ADMIN','Product administrator','Manages configuration and member status',true),
    ('NLP_EVALUATOR','NLP evaluator','Manages models, ranking and evaluation',true),
    ('SUPPORT','Support','Privacy and consent support with restricted access',true)
ON CONFLICT (role_code) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    is_privileged = EXCLUDED.is_privileged,
    updated_at = CURRENT_TIMESTAMP;

INSERT INTO iam.permission(permission_code, resource_type, action, description, status) VALUES
    ('PROFILE_READ','PROFILE','READ','Read an authorized member profile','ACTIVE'),
    ('PROFILE_UPDATE','PROFILE','UPDATE','Update the authenticated member profile','ACTIVE'),
    ('EVENT_READ','EVENT','READ','Read published or authorized event data','ACTIVE'),
    ('EVENT_CONFIGURE','EVENT','CONFIGURE','Create and administer events and matching policies','ACTIVE'),
    ('MATCH_READ','MATCH','READ','Read authorized match results','ACTIVE'),
    ('MATCH_CREATE','MATCH','CREATE','Create an intent or match request','ACTIVE'),
    ('CONNECTION_CREATE','CONNECTION','CREATE','Create and respond to connection requests','ACTIVE'),
    ('CONNECTION_UPDATE','CONNECTION','UPDATE','Disconnect or manage an existing connection','ACTIVE'),
    ('CHAT_READ','CHAT','READ','Read an authorized conversation','ACTIVE'),
    ('CHAT_CREATE','CHAT','CREATE','Send a message to an authorized conversation','ACTIVE'),
    ('FILE_READ','FILE_ASSET','READ','Download an authorized clean file asset','ACTIVE'),
    ('FILE_CREATE','FILE_ASSET','CREATE','Create and finalize an authorized file asset','ACTIVE'),
    ('NOTIFICATION_READ','NOTIFICATION','READ','Read the authenticated member notifications','ACTIVE'),
    ('NOTIFICATION_UPDATE','NOTIFICATION','UPDATE','Update notification preferences and acknowledgements','ACTIVE'),
    ('PRIVACY_READ','PRIVACY_REQUEST','READ','Read an authorized privacy request','ACTIVE'),
    ('PRIVACY_CREATE','PRIVACY_REQUEST','CREATE','Submit a privacy request','ACTIVE'),
    ('PRIVACY_APPROVE','PRIVACY_REQUEST','APPROVE','Approve privacy exceptions and completion evidence','ACTIVE'),
    ('MODERATION_READ','MODERATION_CASE','READ','Read an authorized moderation case','ACTIVE'),
    ('MODERATION_APPROVE','MODERATION_CASE','APPROVE','Review and action moderation cases','ACTIVE'),
    ('NLP_EVALUATION_READ','NLP_EVALUATION','READ','Read de-identified NLP evaluation data','ACTIVE'),
    ('NLP_EVALUATION_CONFIGURE','NLP_EVALUATION','CONFIGURE','Manage model, ranking and evaluation versions','ACTIVE'),
    ('ROLE_CONFIGURE','AUTHORIZATION','CONFIGURE','Manage roles and permission assignments','ACTIVE')
ON CONFLICT (permission_code) DO UPDATE SET
    resource_type = EXCLUDED.resource_type,
    action = EXCLUDED.action,
    description = EXCLUDED.description,
    status = 'ACTIVE',
    updated_at = CURRENT_TIMESTAMP;

INSERT INTO iam.role_permission(role_code, permission_code) VALUES
    ('MEMBER','PROFILE_READ'),('MEMBER','PROFILE_UPDATE'),('MEMBER','EVENT_READ'),('MEMBER','MATCH_READ'),('MEMBER','MATCH_CREATE'),
    ('MEMBER','CONNECTION_CREATE'),('MEMBER','CONNECTION_UPDATE'),('MEMBER','CHAT_READ'),('MEMBER','CHAT_CREATE'),
    ('MEMBER','FILE_READ'),('MEMBER','FILE_CREATE'),('MEMBER','NOTIFICATION_READ'),('MEMBER','NOTIFICATION_UPDATE'),
    ('MEMBER','PRIVACY_READ'),('MEMBER','PRIVACY_CREATE'),
    ('EVENT_ADMIN','EVENT_READ'),('EVENT_ADMIN','EVENT_CONFIGURE'),('EVENT_ADMIN','PROFILE_READ'),
    ('MODERATOR','MODERATION_READ'),('MODERATOR','MODERATION_APPROVE'),('MODERATOR','PROFILE_READ'),('MODERATOR','FILE_READ'),
    ('NLP_EVALUATOR','NLP_EVALUATION_READ'),('NLP_EVALUATOR','NLP_EVALUATION_CONFIGURE'),('NLP_EVALUATOR','PROFILE_READ'),
    ('SUPPORT','PRIVACY_READ'),('SUPPORT','PRIVACY_APPROVE'),('SUPPORT','PROFILE_READ'),('SUPPORT','FILE_READ'),
    ('PRODUCT_ADMIN','PROFILE_READ'),('PRODUCT_ADMIN','EVENT_READ'),('PRODUCT_ADMIN','EVENT_CONFIGURE'),('PRODUCT_ADMIN','MODERATION_READ'),
    ('PRODUCT_ADMIN','NLP_EVALUATION_READ'),('PRODUCT_ADMIN','ROLE_CONFIGURE'),
    ('ADMIN','PROFILE_READ'),('ADMIN','EVENT_READ'),('ADMIN','EVENT_CONFIGURE'),('ADMIN','MODERATION_READ'),('ADMIN','MODERATION_APPROVE'),
    ('ADMIN','NLP_EVALUATION_READ'),('ADMIN','NLP_EVALUATION_CONFIGURE'),('ADMIN','PRIVACY_READ'),('ADMIN','PRIVACY_APPROVE'),('ADMIN','ROLE_CONFIGURE')
ON CONFLICT (role_code, permission_code) DO UPDATE SET revoked_at = NULL;

UPDATE nlp.nlp_model_version
SET status = 'RETIRED',
    updated_at = CURRENT_TIMESTAMP
WHERE status = 'ACTIVE'
  AND model_version <> 'azure-text-embedding-3-small-1536-v1';

INSERT INTO nlp.nlp_model_version(
    model_version, provider, deployment_name, dimensions, preprocessing_version, status, activated_at
) VALUES (
    'azure-text-embedding-3-small-1536-v1', 'AZURE_OPENAI', 'text-embedding-3-small',
    1536, 'normalizer-v1', 'ACTIVE', CURRENT_TIMESTAMP
)
ON CONFLICT (model_version) DO UPDATE SET
    provider = EXCLUDED.provider,
    deployment_name = EXCLUDED.deployment_name,
    dimensions = EXCLUDED.dimensions,
    preprocessing_version = EXCLUDED.preprocessing_version,
    status = 'ACTIVE',
    activated_at = CASE
        WHEN nlp.nlp_model_version.status = 'ACTIVE'
            THEN COALESCE(nlp.nlp_model_version.activated_at, EXCLUDED.activated_at)
        ELSE EXCLUDED.activated_at
    END,
    updated_at = CURRENT_TIMESTAMP;

INSERT INTO nlp.nlp_ranking_config(
    ranking_version, semantic_weight, category_weight, industry_weight, geography_weight,
    freshness_weight, event_weight, threshold, active_from
) VALUES ('ranking-v1',0.40000,0.25000,0.15000,0.10000,0.10000,0.00000,0.35000,CURRENT_TIMESTAMP)
ON CONFLICT (ranking_version) DO NOTHING;

-- Production activation remains fail-closed unless the deployer explicitly enables QA policies.
INSERT INTO notification.notification_policy(
    community_id, purpose_code, channel, policy_version, status, member_opt_out_allowed,
    quiet_hours_behavior, dedupe_window_seconds, max_per_hour, max_per_day, max_attempts,
    retry_schedule_seconds, ttl_minutes, effective_from
)
SELECT * FROM (VALUES
    (NULL::varchar(64),'MATCH','PUSH',1::smallint,'ACTIVE',true,'DEFER',300,6::smallint,30::smallint,3::smallint,'60,300,1800',1440,CURRENT_TIMESTAMP),
    (NULL::varchar(64),'REQUEST','PUSH',1::smallint,'ACTIVE',true,'DEFER',300,12::smallint,50::smallint,3::smallint,'60,300,1800',1440,CURRENT_TIMESTAMP),
    (NULL::varchar(64),'CHAT','PUSH',1::smallint,'ACTIVE',true,'DEFER',60,30::smallint,200::smallint,3::smallint,'60,300,1800',1440,CURRENT_TIMESTAMP),
    (NULL::varchar(64),'EVENT','PUSH',1::smallint,'ACTIVE',true,'DEFER',300,8::smallint,40::smallint,3::smallint,'60,300,1800',1440,CURRENT_TIMESTAMP),
    (NULL::varchar(64),'SAFETY','PUSH',1::smallint,'ACTIVE',false,'BYPASS',60,20::smallint,100::smallint,5::smallint,'30,120,300,900,1800',2880,CURRENT_TIMESTAMP),
    (NULL::varchar(64),'ACCOUNT','EMAIL',1::smallint,'ACTIVE',false,'BYPASS',300,10::smallint,30::smallint,5::smallint,'60,300,1800,3600,7200',10080,CURRENT_TIMESTAMP)
) AS seed(community_id,purpose_code,channel,policy_version,status,member_opt_out_allowed,quiet_hours_behavior,dedupe_window_seconds,max_per_hour,max_per_day,max_attempts,retry_schedule_seconds,ttl_minutes,effective_from)
WHERE current_setting('olga.seed_mvp_policies', true) = '1'
ON CONFLICT DO NOTHING;

-- ======================== DATABASE ROLES AND GRANTS ========================
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA core, iam, consent, event, social, chat,
    storage, notification, nlp, moderation, ops, analytics, admin, history FROM PUBLIC;
REVOKE ALL ON SCHEMA history FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA history FROM PUBLIC;

GRANT USAGE ON SCHEMA core, iam, consent, event, social, chat, storage, notification,
    nlp, moderation, ops, analytics, admin, history TO olga_dml_writer, olga_reader;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, iam, consent, event,
    social, chat, storage, notification, nlp, moderation, ops, analytics, admin, history
    TO olga_dml_writer;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA core, iam, consent, event, social,
    chat, storage, notification, nlp, moderation, ops, analytics, admin, history
    TO olga_dml_writer;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA core, iam, consent, event, social, chat, storage,
    notification, nlp, moderation, ops, analytics, admin, history TO olga_dml_writer;

GRANT SELECT ON ALL TABLES IN SCHEMA core, iam, consent, event, social, chat, storage,
    notification, nlp, moderation, ops, analytics, admin, history TO olga_reader;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA core, iam, consent, event, social, chat, storage,
    notification, nlp, moderation, ops, analytics, admin, history TO olga_reader;

-- The embedding worker can read its input and lease queue rows, but it cannot create or
-- delete intents/jobs or access unrelated NLP and operational data.
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA nlp, ops FROM olga_nlp_worker;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA nlp, ops FROM olga_nlp_worker;
REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA nlp, ops FROM olga_nlp_worker;
REVOKE ALL PRIVILEGES ON SCHEMA nlp, ops FROM olga_nlp_worker;
GRANT USAGE ON SCHEMA nlp, ops TO olga_nlp_worker;
GRANT SELECT ON nlp.nlp_intent, nlp.nlp_processing_job, nlp.nlp_embedding TO olga_nlp_worker;
GRANT UPDATE (status, updated_at) ON nlp.nlp_intent TO olga_nlp_worker;
GRANT UPDATE (status, attempt_count, available_at, locked_until, error_code, updated_at)
    ON nlp.nlp_processing_job TO olga_nlp_worker;
GRANT INSERT, UPDATE ON nlp.nlp_embedding TO olga_nlp_worker;
GRANT INSERT ON ops.outbox_event TO olga_nlp_worker;

ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO olga_dml_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO olga_dml_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT EXECUTE ON FUNCTIONS TO olga_dml_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT SELECT ON TABLES TO olga_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT SELECT ON SEQUENCES TO olga_reader;

-- ======================== VERIFICATION ========================
DO $$
DECLARE
    expected_tables text[] := ARRAY[
        'core.community','core.organization','core.organization_member','core.member_profile','core.sector','core.member_sector','core.member_geography','core.profile_field_visibility','core.member_verification',
        'iam.member','iam.member_identity','iam.role','iam.permission','iam.role_permission','iam.member_role','iam.member_device','iam.auth_session',
        'consent.consent_policy','consent.member_consent','consent.privacy_request','consent.privacy_request_task',
        'event.venue','event.event','event.event_matching_policy','event.event_registration','event.live_mode_session','event.event_presence',
        'social.connection_request','social.connection','social.member_block','social.member_report',
        'chat.conversation','chat.conversation_participant','chat.message','chat.message_receipt',
        'storage.file_asset','storage.file_asset_link',
        'notification.notification_policy','notification.notification_preference','notification.push_token','notification.notification','notification.notification_delivery_attempt',
        'nlp.nlp_intent','nlp.nlp_embedding','nlp.nlp_model_version','nlp.nlp_ranking_config','nlp.nlp_processing_job','nlp.match_request','nlp.nlp_match_result','nlp.nlp_feedback','nlp.match_suppression','nlp.evaluation_dataset','nlp.evaluation_pair','nlp.evaluation_run',
        'moderation.moderation_case','moderation.moderation_action','moderation.content_rule','moderation.content_scan',
        'ops.outbox_event','ops.idempotency_record','ops.background_job','ops.sync_change','ops.retention_policy','ops.retention_execution','ops.audit_event',
        'analytics.product_event'
    ];
    expected_views text[] := ARRAY[
        'nlp.vw_member_context_eligibility','nlp.vw_member_relationship','chat.vw_authorized_conversation','admin.vw_member_review'
    ];
    expected_history_tables text[] := ARRAY[
        'history.iam_permission','history.iam_role','history.core_sector','history.consent_consent_policy',
        'history.event_venue','history.event_event_matching_policy','history.notification_notification_policy',
        'history.nlp_nlp_model_version','history.nlp_nlp_ranking_config','history.moderation_content_rule',
        'history.ops_retention_policy'
    ];
    expected_history_source_tables text[] := ARRAY[
        'iam.permission','iam.role','core.sector','consent.consent_policy','event.venue',
        'event.event_matching_policy','notification.notification_policy','nlp.nlp_model_version',
        'nlp.nlp_ranking_config','moderation.content_rule','ops.retention_policy'
    ];
    expected_functions text[] := ARRAY[
        'nlp.get_requester_intent','nlp.get_eligible_candidates','nlp.save_match_results','nlp.save_feedback',
        'social.accept_connection_request','chat.save_message','chat.save_message_receipt',
        'event.purge_expired_presence','notification.try_enqueue',
        'ops.set_audit_context','ops.current_audit_actor_id','ops.set_audit_actor','ops.archive_row_version'
    ];
    expected_triggers text[] := ARRAY[
        'storage.file_asset_link.enforce_file_asset_link_resource',
        'event.live_mode_session.enforce_live_mode_session_consent',
        'nlp.match_suppression.enforce_match_suppression_target',
        'social.connection.enforce_connection_request_pair',
        'social.connection_request.validate_accepted_request_connection_on_request',
        'social.connection.validate_accepted_request_connection_on_connection',
        'chat.conversation_participant.enforce_conversation_participant',
        'chat.conversation.validate_conversation_participant_set_on_conversation',
        'chat.conversation_participant.validate_conversation_participant_set_on_participant',
        'chat.message.enforce_message_sender',
        'chat.message_receipt.enforce_message_receipt',
        'consent.privacy_request.enforce_privacy_request_completion',
        'consent.privacy_request_task.protect_completed_privacy_request_tasks',
        'ops.retention_policy.protect_active_retention_policy'
    ];
    item text;
    actual_count int;
BEGIN
    SELECT count(*) INTO actual_count
    FROM information_schema.tables
    WHERE table_type = 'BASE TABLE'
      AND table_schema IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops','analytics');
    IF actual_count <> cardinality(expected_tables) THEN
        RAISE EXCEPTION 'Unexpected OLGA product-table count: expected %, found %', cardinality(expected_tables), actual_count;
    END IF;
    FOREACH item IN ARRAY expected_tables LOOP
        IF to_regclass(item) IS NULL THEN RAISE EXCEPTION 'Required table is missing: %', item; END IF;
    END LOOP;
    FOREACH item IN ARRAY expected_views LOOP
        IF to_regclass(item) IS NULL THEN RAISE EXCEPTION 'Required view is missing: %', item; END IF;
    END LOOP;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'nlp' AND table_name = 'vw_member_context_eligibility'
          AND column_name = 'community_id'
    ) THEN RAISE EXCEPTION 'Matching eligibility view must expose the authoritative community boundary.'; END IF;
    FOREACH item IN ARRAY expected_history_tables LOOP
        IF to_regclass(item) IS NULL THEN RAISE EXCEPTION 'Required temporal history table is missing: %', item; END IF;
    END LOOP;
    FOREACH item IN ARRAY expected_history_source_tables LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_trigger t
            WHERE t.tgrelid = item::regclass AND t.tgname = 'versioning_history'
              AND t.tgfoid = 'ops.archive_row_version()'::regprocedure AND t.tgenabled <> 'D'
        ) THEN RAISE EXCEPTION 'Required temporal versioning trigger is missing: %', item; END IF;
    END LOOP;
    FOREACH item IN ARRAY expected_functions LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = split_part(item,'.',1) AND p.proname = split_part(item,'.',2)
        ) THEN RAISE EXCEPTION 'Required function is missing: %', item; END IF;
    END LOOP;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'social' AND p.proname = 'accept_connection_request'
          AND p.pronargs = 8 AND p.prosecdef
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'chat' AND p.proname = 'save_message'
          AND p.pronargs = 10 AND p.prosecdef
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'chat' AND p.proname = 'save_message_receipt'
          AND p.pronargs = 8 AND p.prosecdef
    ) THEN RAISE EXCEPTION 'Atomic mutation functions are missing required signatures or SECURITY DEFINER protection.'; END IF;
    FOREACH item IN ARRAY expected_triggers LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_trigger t
            JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE NOT t.tgisinternal AND n.nspname = split_part(item,'.',1)
              AND c.relname = split_part(item,'.',2) AND t.tgname = split_part(item,'.',3)
        ) THEN RAISE EXCEPTION 'Required trigger is missing: %', item; END IF;
    END LOOP;
    IF to_regclass('chat.message_sequence') IS NULL OR to_regclass('ops.sync_change_sequence') IS NULL THEN
        RAISE EXCEPTION 'One or more required sequences are missing.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'ops.idempotency_record'::regclass
          AND conname = 'pk_idempotency_record_'
          AND pg_get_constraintdef(oid) = 'PRIMARY KEY (scope, actor_id, idempotency_key)'
    ) THEN RAISE EXCEPTION 'Idempotency primary key must be scoped by operation, actor and client key.'; END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'ops.archive_row_version()'::regprocedure) THEN
        RAISE EXCEPTION 'Temporal history trigger must run as a security-definer function.';
    END IF;
    IF to_regclass('chat.attachment') IS NOT NULL THEN RAISE EXCEPTION 'Legacy chat.attachment must not remain.'; END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'iam' AND table_name = 'member_identity' AND column_name = 'provider_subject'
    ) THEN RAISE EXCEPTION 'Plaintext identity subject column remains.'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'iam' AND table_name = 'member_identity' AND column_name = 'provider_subject_hash'
    ) OR NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'iam' AND table_name = 'member_identity' AND column_name = 'provider_subject_ciphertext' AND data_type = 'bytea'
    ) THEN RAISE EXCEPTION 'Protected identity subject columns are missing or invalid.'; END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute a
        JOIN pg_class t ON t.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = 'nlp' AND t.relname = 'nlp_embedding' AND a.attname = 'embedding'
          AND format_type(a.atttypid, a.atttypmod) = 'vector(1536)'
    ) THEN RAISE EXCEPTION 'nlp_embedding.embedding must use pgvector.'; END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE column_name = 'row_version'
          AND table_schema IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops')
          AND (data_type <> 'bigint' OR column_default IS NULL OR column_default !~ '^1(?:::bigint)?$')
    ) THEN RAISE EXCEPTION 'Every row_version must be bigint with default 1.'; END IF;
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.column_name = 'row_version'
          AND c.table_schema IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops')
          AND NOT EXISTS (
              SELECT 1 FROM pg_trigger t
              WHERE t.tgrelid = format('%I.%I', c.table_schema, c.table_name)::regclass
                AND t.tgname = 'set_row_version' AND t.tgfoid = 'ops.set_row_version()'::regprocedure
                AND t.tgenabled <> 'D'
          )
    ) THEN RAISE EXCEPTION 'One or more row_version triggers are missing or disabled.'; END IF;
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.column_name = 'row_version'
          AND c.table_schema IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops')
          AND (
              NOT EXISTS (
                  SELECT 1 FROM information_schema.columns a
                  WHERE a.table_schema = c.table_schema AND a.table_name = c.table_name
                    AND a.column_name IN ('created_by','updated_by')
                  GROUP BY a.table_schema, a.table_name HAVING count(*) = 2
              )
              OR NOT EXISTS (
                  SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = format('%I.%I', c.table_schema, c.table_name)::regclass
                    AND t.tgname = 'set_audit_actor' AND t.tgfoid = 'ops.set_audit_actor()'::regprocedure
                    AND t.tgenabled <> 'D'
              )
          )
    ) THEN RAISE EXCEPTION 'One or more mutable resources lack audit actor columns or triggers.'; END IF;
    IF EXISTS (
        SELECT 1 FROM unnest(expected_history_tables) h(history_name)
        WHERE NOT EXISTS (
            SELECT 1 FROM information_schema.columns c
            WHERE c.table_schema = split_part(h.history_name,'.',1)
              AND c.table_name = split_part(h.history_name,'.',2)
              AND c.column_name = 'sys_period' AND c.udt_name = 'tstzrange'
        )
    ) THEN RAISE EXCEPTION 'One or more temporal history tables lack a tstzrange system period.'; END IF;
    IF EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops','analytics')
          AND NOT c.convalidated
    ) THEN RAISE EXCEPTION 'One or more constraints are not validated.'; END IF;
    IF EXISTS (
        SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops','analytics')
          AND NOT i.indisvalid
    ) THEN RAISE EXCEPTION 'One or more indexes are invalid.'; END IF;
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops','analytics')
          AND indexdef ~* 'USING[[:space:]]+(hnsw|ivfflat)'
    ) THEN RAISE EXCEPTION 'Approximate vector indexes are not approved.'; END IF;
    IF EXISTS (
        SELECT 1
        FROM chat.conversation c
        JOIN social.connection cn ON cn.connection_id = c.connection_id
        LEFT JOIN chat.conversation_participant cp ON cp.conversation_id = c.conversation_id
        GROUP BY c.conversation_id, cn.member_low_id, cn.member_high_id
        HAVING count(cp.member_id) <> 2
           OR count(*) FILTER (WHERE cp.member_id IN (cn.member_low_id, cn.member_high_id)) <> 2
    ) THEN RAISE EXCEPTION 'One or more conversations do not contain exactly their connection members.'; END IF;
    IF EXISTS (
        SELECT 1
        FROM chat.message_receipt mr
        JOIN chat.message m ON m.message_id = mr.message_id
        LEFT JOIN chat.conversation_participant cp
          ON cp.conversation_id = m.conversation_id AND cp.member_id = mr.member_id
        WHERE cp.member_id IS NULL OR mr.member_id = m.sender_member_id
           OR (mr.read_at IS NOT NULL AND (mr.delivered_at IS NULL OR mr.read_at < mr.delivered_at))
    ) THEN RAISE EXCEPTION 'One or more message receipts violate participant or timestamp integrity.'; END IF;
    IF EXISTS (
        SELECT 1
        FROM chat.conversation_participant cp
        JOIN chat.message m ON m.message_id = cp.last_read_message_id
        WHERE cp.last_read_message_id IS NOT NULL AND m.conversation_id <> cp.conversation_id
    ) THEN RAISE EXCEPTION 'One or more participant read cursors reference another conversation.'; END IF;
    IF NOT EXISTS (SELECT 1 FROM iam.permission WHERE status = 'ACTIVE')
       OR NOT EXISTS (SELECT 1 FROM iam.role_permission WHERE revoked_at IS NULL) THEN
        RAISE EXCEPTION 'Authorization permission seeds are missing.';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM nlp.nlp_model_version
        WHERE model_version = 'azure-text-embedding-3-small-1536-v1'
          AND provider = 'AZURE_OPENAI'
          AND deployment_name = 'text-embedding-3-small'
          AND dimensions = 1536
          AND preprocessing_version = 'normalizer-v1'
          AND status = 'ACTIVE'
          AND activated_at IS NOT NULL
    ) THEN RAISE EXCEPTION 'The approved active NLP model seed is missing or inconsistent.'; END IF;
    IF NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_intent', 'SELECT')
       OR NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_processing_job', 'SELECT')
       OR NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_embedding', 'SELECT')
       OR NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_embedding', 'INSERT')
       OR NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_embedding', 'UPDATE')
       OR NOT has_table_privilege('olga_nlp_worker', 'ops.outbox_event', 'INSERT')
       OR NOT has_column_privilege('olga_nlp_worker', 'nlp.nlp_intent', 'status', 'UPDATE')
       OR NOT has_column_privilege('olga_nlp_worker', 'nlp.nlp_processing_job', 'locked_until', 'UPDATE')
       OR has_table_privilege('olga_nlp_worker', 'nlp.nlp_intent', 'INSERT')
       OR has_table_privilege('olga_nlp_worker', 'nlp.nlp_intent', 'DELETE')
       OR has_table_privilege('olga_nlp_worker', 'nlp.nlp_processing_job', 'INSERT')
       OR has_table_privilege('olga_nlp_worker', 'nlp.nlp_processing_job', 'DELETE')
       OR has_table_privilege('olga_nlp_worker', 'ops.outbox_event', 'SELECT')
       OR has_table_privilege('olga_nlp_worker', 'ops.outbox_event', 'UPDATE')
       OR has_table_privilege('olga_nlp_worker', 'ops.outbox_event', 'DELETE')
       OR has_table_privilege('olga_nlp_worker', 'nlp.match_request', 'SELECT')
       OR has_table_privilege('olga_nlp_worker', 'nlp.match_request', 'INSERT')
       OR has_table_privilege('olga_nlp_worker', 'nlp.match_request', 'UPDATE')
       OR has_table_privilege('olga_nlp_worker', 'nlp.match_request', 'DELETE') THEN
        RAISE EXCEPTION 'NLP worker privileges are missing or exceed the approved boundary.';
    END IF;
END;
$$;

COMMENT ON SCHEMA ops IS 'OLGA.SchemaVersion=2.4';
RESET ROLE;
COMMIT;
