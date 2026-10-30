-- Run after the baseline with a migration-owner test connection. This test updates one seeded
-- role, verifies its prior version was archived, and rolls back both the update and history row.
BEGIN;
SELECT ops.set_audit_context('test-temporal-history');

DO $block$
DECLARE
    v_role_code varchar(64);
    v_history_before integer;
    v_history_after integer;
    v_effective_at timestamptz := transaction_timestamp();
BEGIN
    SELECT role_code
      INTO v_role_code
      FROM iam.role
     ORDER BY role_code
     LIMIT 1;
    IF v_role_code IS NULL THEN
        RAISE EXCEPTION 'Temporal-history test requires at least one seeded iam.role row.';
    END IF;

    SELECT count(*) INTO v_history_before
      FROM history.iam_role
     WHERE role_code = v_role_code;

    UPDATE iam.role
       SET description = left(COALESCE(description, ''), 450) || ' [history-test]'
     WHERE role_code = v_role_code;

    SELECT count(*) INTO v_history_after
      FROM history.iam_role
     WHERE role_code = v_role_code;
    IF v_history_after <> v_history_before + 1 THEN
        RAISE EXCEPTION 'Expected one archived role version; before %, after %.',
            v_history_before, v_history_after;
    END IF;
    IF NOT EXISTS (
        SELECT 1
          FROM history.iam_role
         WHERE role_code = v_role_code
           AND upper(sys_period) = v_effective_at
           AND lower_inc(sys_period)
           AND NOT upper_inc(sys_period)
    ) THEN
        RAISE EXCEPTION 'Archived role version has an invalid system period.';
    END IF;
    IF NOT EXISTS (
        SELECT 1
          FROM iam.role
         WHERE role_code = v_role_code
           AND lower(sys_period) = v_effective_at
           AND upper_inf(sys_period)
    ) THEN
        RAISE EXCEPTION 'Current role version has an invalid open system period.';
    END IF;
END;
$block$;

ROLLBACK;
