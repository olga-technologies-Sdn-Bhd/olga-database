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
