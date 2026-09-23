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
