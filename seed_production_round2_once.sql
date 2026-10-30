/*
Ol-ga production seed - Round 2 approved scope

Run manually in DBeaver with Execute SQL Script (Alt+X).

Included:
- Ol-ga community display name
- Existing canonical roles, permissions and role grants
- Existing canonical NLP model and ranking configuration
- Approved 18-entry Release 1 industry taxonomy

Consent handling:
- Existing current LIVE_MODE and MATCHING policies are preserved
- If either purpose is missing, the approved Round 2 English wording is
  inserted as prod-v1 for the community default locale

Preserved, not inserted or changed:
- Notification policies

Intentionally out of scope for this one-time activity:
- Venues, events, Rooms and meeting spots
- Retention and moderation policies
- Reference concepts that do not yet have database tables

The application must display the exact consent wording documented beside the
consent insert below. Any wording change requires a new policy version and hash.
*/
BEGIN;

DO $deployment_guard$
BEGIN
    IF current_database() <> 'olga_connect_prod' THEN
        RAISE EXCEPTION
            'Production seed stopped: connected to database %, expected olga_connect_prod.',
            current_database();
    END IF;
END;
$deployment_guard$;

SELECT pg_advisory_xact_lock(hashtextextended('olga_production_seed_round2', 0));

INSERT INTO core.community(community_id, name, status, default_locale)
VALUES ('olga', 'Ol-ga', 'ACTIVE', 'en-IN')
ON CONFLICT (community_id) DO UPDATE
SET name = EXCLUDED.name,
    updated_at = CURRENT_TIMESTAMP
WHERE core.community.name IS DISTINCT FROM EXCLUDED.name;

DO $community_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM core.community
        WHERE community_id = 'olga'
          AND name = 'Ol-ga'
          AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'The olga community must exist with display name Ol-ga and ACTIVE status.';
    END IF;
END;
$community_guard$;

/*
Approved production consent text from OLGA_Seed_Values_Round2.xlsx, Consent!D6:D7.
Hashes are SHA-256 over the exact UTF-8 text, without a trailing newline.

MATCHING:
Ol-ga may use my profile and the intent I write to recommend relevant professionals to me, and to recommend me to them. My name and photo stay hidden until we both accept.

LIVE_MODE (business name: live_presence / Go Live):
While I'm live, Ol-ga will confirm I'm at this venue and show me to matched members here. Ol-ga keeps only an approximate area, never my exact location, and deletes it within 30 minutes. I can go offline at any time.
*/
CREATE TEMP TABLE approved_production_consent (
    policy_id varchar(64) PRIMARY KEY,
    purpose_code varchar(64) NOT NULL UNIQUE,
    version varchar(32) NOT NULL,
    content_hash char(64) NOT NULL
) ON COMMIT DROP;

INSERT INTO approved_production_consent(
    policy_id, purpose_code, version, content_hash
) VALUES
    ('matching-consent-prod-v1', 'MATCHING', 'prod-v1',
     'de5148211929968cc9336bbdf5310dd5bf9992393f914a49471f81aea418109a'),
    ('live-mode-consent-prod-v1', 'LIVE_MODE', 'prod-v1',
     'ce35e96fc2005b5f4f2b2e1add4aeaa77f23619ed93658af6ff010daa05be352');

INSERT INTO consent.consent_policy(
    policy_id, purpose_code, version, locale, content_hash, effective_from
)
SELECT approved.policy_id,
       approved.purpose_code,
       approved.version,
       community.default_locale,
       approved.content_hash,
       CURRENT_TIMESTAMP
FROM approved_production_consent approved
CROSS JOIN core.community community
WHERE community.community_id = 'olga'
  AND NOT EXISTS (
      SELECT 1
      FROM consent.consent_policy existing
      WHERE existing.purpose_code = approved.purpose_code
        AND existing.locale = community.default_locale
        AND existing.effective_from <= CURRENT_TIMESTAMP
        AND existing.retired_at IS NULL
  )
ON CONFLICT (policy_id) DO NOTHING;

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
) VALUES (
    'ranking-v1', 0.40000, 0.25000, 0.15000, 0.10000,
    0.10000, 0.00000, 0.35000, CURRENT_TIMESTAMP
)
ON CONFLICT (ranking_version) DO NOTHING;

CREATE TEMP TABLE approved_production_sector (
    sector_code varchar(64) PRIMARY KEY,
    name varchar(150) NOT NULL UNIQUE,
    sort_order int NOT NULL UNIQUE
) ON COMMIT DROP;

INSERT INTO approved_production_sector(sector_code, name, sort_order) VALUES
    ('TECH',    'Technology & Software',                                      10),
    ('TELCO',   'Telecommunications',                                        20),
    ('FIN',     'Banking & Financial Services',                              30),
    ('VCPE',    'Venture Capital & Private Equity',                           40),
    ('GOV',     'Government & Public Sector',                                 50),
    ('GLC',     'Government-Linked Companies',                               60),
    ('EDU',     'Education & Training (incl. TVET)',                          70),
    ('HEALTH',  'Healthcare & Life Sciences',                                80),
    ('ENERGY',  'Energy & Utilities',                                         90),
    ('OILGAS',  'Oil & Gas',                                                 100),
    ('MFG',     'Manufacturing & Industrial',                                110),
    ('BUILD',   'Construction, Property & Infrastructure',                   120),
    ('LOGI',    'Logistics & Transportation',                                130),
    ('RETAIL',  'Retail, Consumer & E-commerce',                             140),
    ('MEDIA',   'Media, Marketing & Creative',                               150),
    ('PROF',    'Professional Services (Consulting, Legal, Accounting)',      160),
    ('HOSP',    'Hospitality, Travel & Events',                              170),
    ('AGRI',    'Agriculture & Plantation',                                  180);

DO $sector_conflict_guard$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM approved_production_sector approved
        JOIN core.sector existing
          ON existing.name = approved.name
         AND existing.sector_code <> approved.sector_code
    ) THEN
        RAISE EXCEPTION
            'An approved industry name already exists under a different sector code; resolve member mappings before seeding.';
    END IF;
END;
$sector_conflict_guard$;

UPDATE core.sector existing
SET status = 'RETIRED',
    updated_at = CURRENT_TIMESTAMP
WHERE existing.status = 'ACTIVE'
  AND NOT EXISTS (
      SELECT 1
      FROM approved_production_sector approved
      WHERE approved.sector_code = existing.sector_code
  );

INSERT INTO core.sector(
    sector_code, parent_sector_code, name, status, sort_order
)
SELECT sector_code, NULL, name, 'ACTIVE', sort_order
FROM approved_production_sector
ON CONFLICT (sector_code) DO UPDATE SET
    parent_sector_code = NULL,
    name = EXCLUDED.name,
    status = 'ACTIVE',
    sort_order = EXCLUDED.sort_order,
    updated_at = CURRENT_TIMESTAMP;

DO $consent_guard$
DECLARE
    v_locale varchar(16);
BEGIN
    SELECT default_locale
    INTO v_locale
    FROM core.community
    WHERE community_id = 'olga';

    IF (
        SELECT count(*)
        FROM consent.consent_policy
        WHERE purpose_code = 'LIVE_MODE'
          AND locale = v_locale
          AND effective_from <= CURRENT_TIMESTAMP
          AND retired_at IS NULL
    ) <> 1 THEN
        RAISE EXCEPTION
            'Expected exactly one current LIVE_MODE consent policy for locale %, but it was not found.',
            v_locale;
    END IF;

    IF (
        SELECT count(*)
        FROM consent.consent_policy
        WHERE purpose_code = 'MATCHING'
          AND locale = v_locale
          AND effective_from <= CURRENT_TIMESTAMP
          AND retired_at IS NULL
    ) <> 1 THEN
        RAISE EXCEPTION
            'Expected exactly one current MATCHING consent policy for locale %, but it was not found.',
            v_locale;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM approved_production_consent approved
        JOIN consent.consent_policy actual USING (policy_id)
        WHERE actual.purpose_code <> approved.purpose_code
           OR actual.version <> approved.version
           OR actual.locale <> v_locale
           OR actual.content_hash <> approved.content_hash
           OR actual.effective_from > CURRENT_TIMESTAMP
           OR actual.retired_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'An existing prod-v1 consent row conflicts with the approved Round 2 wording.';
    END IF;
END;
$consent_guard$;

DO $result_verification$
BEGIN
    IF (
        SELECT count(*)
        FROM core.sector existing
        JOIN approved_production_sector approved USING (sector_code)
        WHERE existing.parent_sector_code IS NULL
          AND existing.name = approved.name
          AND existing.status = 'ACTIVE'
          AND existing.sort_order = approved.sort_order
    ) <> 18 THEN
        RAISE EXCEPTION 'Approved production industry verification failed.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM core.sector
        WHERE status = 'ACTIVE'
          AND sector_code NOT IN (SELECT sector_code FROM approved_production_sector)
    ) THEN
        RAISE EXCEPTION 'Unexpected active industries remain after production seed.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM nlp.nlp_model_version
        WHERE model_version = 'azure-text-embedding-3-small-1536-v1'
          AND status = 'ACTIVE'
          AND dimensions = 1536
    ) THEN
        RAISE EXCEPTION 'Active NLP model verification failed.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM nlp.nlp_ranking_config
        WHERE ranking_version = 'ranking-v1'
          AND threshold = 0.35000
    ) THEN
        RAISE EXCEPTION 'Existing ranking-v1 configuration verification failed.';
    END IF;
END;
$result_verification$;

SELECT community_id, name, status, default_locale, row_version
FROM core.community
WHERE community_id = 'olga';

SELECT sector_code, name, status, sort_order, row_version
FROM core.sector
WHERE sector_code IN (SELECT sector_code FROM approved_production_sector)
ORDER BY sort_order;

SELECT policy_id, purpose_code, version, locale, effective_from, retired_at
FROM consent.consent_policy
WHERE purpose_code IN ('LIVE_MODE', 'MATCHING')
  AND effective_from <= CURRENT_TIMESTAMP
  AND retired_at IS NULL
ORDER BY purpose_code, locale;

COMMIT;
