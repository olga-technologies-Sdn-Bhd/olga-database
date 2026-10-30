/*
Create The BrandLaureate BestBrands Awards 2026 in production.

Source reviewed 2026-10-15:
https://www.thebrandlaureate.com/bestbrands-awards-2026/

Published details:
- Event date: 22 October 2026
- Countdown target: 20:00
- Theme: The Courage to Challenge

The source does not publish a venue or end time. Consequently:
- venue_id is NULL;
- ends_at is provisionally midnight after the event date; and
- Live Mode remains disabled until the venue and matching policy are approved.

This script is intentionally idempotent and fail-closed. A row with the same
event_id but different values causes the transaction to fail instead of being
silently overwritten.
*/

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

DO $deployment_guard$
BEGIN
    IF current_database() <> 'olga_connect_prod' THEN
        RAISE EXCEPTION
            'Production event creation stopped: connected to database %, expected olga_connect_prod.',
            current_database();
    END IF;
END;
$deployment_guard$;

SELECT pg_advisory_xact_lock(
    hashtextextended('create_brandlaureate_bestbrands_awards_2026', 0)
);

DO $community_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM core.community
        WHERE community_id = 'olga'
          AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION
            'Required ACTIVE community core.community.community_id=olga does not exist.';
    END IF;
END;
$community_guard$;

INSERT INTO event.event (
    event_id,
    community_id,
    venue_id,
    name,
    description,
    starts_at,
    ends_at,
    status,
    live_mode_enabled
)
VALUES (
    'brandlaureate-bestbrands-2026',
    'olga',
    NULL,
    'The BrandLaureate BestBrands Awards 2026',
    'A recognition and celebration of brand excellence by The World Brands Foundation. Theme: The Courage to Challenge. Source: https://www.thebrandlaureate.com/bestbrands-awards-2026/',
    TIMESTAMPTZ '2026-10-22 20:00:00+08:00',
    TIMESTAMPTZ '2026-10-23 00:00:00+08:00',
    'PUBLISHED',
    false
)
ON CONFLICT (event_id) DO NOTHING;

DO $event_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM event.event
        WHERE event_id = 'brandlaureate-bestbrands-2026'
          AND community_id = 'olga'
          AND venue_id IS NULL
          AND name = 'The BrandLaureate BestBrands Awards 2026'
          AND description = 'A recognition and celebration of brand excellence by The World Brands Foundation. Theme: The Courage to Challenge. Source: https://www.thebrandlaureate.com/bestbrands-awards-2026/'
          AND starts_at = TIMESTAMPTZ '2026-10-22 20:00:00+08:00'
          AND ends_at = TIMESTAMPTZ '2026-10-23 00:00:00+08:00'
          AND status = 'PUBLISHED'
          AND live_mode_enabled IS FALSE
    ) THEN
        RAISE EXCEPTION
            'Event brandlaureate-bestbrands-2026 exists with unexpected values or could not be inserted.';
    END IF;
END;
$event_guard$;

COMMIT;

SELECT
    event_id,
    community_id,
    venue_id,
    name,
    description,
    starts_at,
    ends_at,
    status,
    live_mode_enabled,
    row_version
FROM event.event
WHERE event_id = 'brandlaureate-bestbrands-2026';
