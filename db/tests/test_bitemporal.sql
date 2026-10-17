-- Tests for db/schema.sql. Synthetic people only. Run via scripts/run_tests.sh.
-- Every check raises an exception on failure; the runner stops at the first one.

\set ON_ERROR_STOP on

CREATE FUNCTION pg_temp.expect(label text, ok boolean) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF ok IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL: %', label;
    END IF;
    RAISE NOTICE 'ok   - %', label;
END;
$$;

-- Fixed people so tests are deterministic.
INSERT INTO person (person_id, display_name) VALUES
    ('00000000-0000-0000-0000-00000000a11c', 'Alice Test'),
    ('00000000-0000-0000-0000-0000000000b0', 'Bob Test');

-- Scenario 1: Alice is hired as Engineer from 2026-01-01; we record it on Jan 5.
SELECT set_job('00000000-0000-0000-0000-00000000a11c', 'Engineer', 'Platform', NULL,
               '2026-01-01', NULL, 'human:test', 'hire', '2026-01-05 09:00+00');

SELECT pg_temp.expect('hire is visible as of valid 2026-02-01 known 2026-02-01',
    (SELECT title FROM job_as_of('2026-02-01', '2026-02-01 00:00+00')) = 'Engineer');

-- Scenario 2: on Mar 10 we learn she was promoted effective Mar 1 (retroactive).
SELECT set_job('00000000-0000-0000-0000-00000000a11c', 'Senior Engineer', 'Platform', NULL,
               '2026-03-01', NULL, 'human:test', 'promotion, learned late', '2026-03-10 09:00+00');

SELECT pg_temp.expect('as of valid Mar 5, known Mar 2: still believed Engineer',
    (SELECT title FROM job_as_of('2026-03-05', '2026-03-02 00:00+00')) = 'Engineer');

SELECT pg_temp.expect('as of valid Mar 5, known Mar 11: now Senior Engineer',
    (SELECT title FROM job_as_of('2026-03-05', '2026-03-11 00:00+00')) = 'Senior Engineer');

SELECT pg_temp.expect('Feb is untouched by the promotion (known Mar 11)',
    (SELECT title FROM job_as_of('2026-02-15', '2026-03-11 00:00+00')) = 'Engineer');

SELECT pg_temp.expect('exactly one job per valid date at any recorded moment (Mar 5 known Mar 11)',
    (SELECT count(*) FROM job_as_of('2026-03-05', '2026-03-11 00:00+00')) = 1);

-- Scenario 3: correct a window in the middle (Mar 15 to Apr 1 was a different department).
SELECT set_job('00000000-0000-0000-0000-00000000a11c', 'Senior Engineer', 'Data', NULL,
               '2026-03-15', '2026-04-01', 'agent:test', 'temporary transfer', '2026-04-05 09:00+00');

SELECT pg_temp.expect('middle window is Data',
    (SELECT department FROM job_as_of('2026-03-20', '2026-04-06 00:00+00')) = 'Data');
SELECT pg_temp.expect('before the window is still Platform',
    (SELECT department FROM job_as_of('2026-03-10', '2026-04-06 00:00+00')) = 'Platform');
SELECT pg_temp.expect('after the window is Platform again (remainder re-recorded)',
    (SELECT department FROM job_as_of('2026-05-01', '2026-04-06 00:00+00')) = 'Platform');
SELECT pg_temp.expect('older belief preserved: Mar 20 known Mar 11 was Platform',
    (SELECT department FROM job_as_of('2026-03-20', '2026-03-11 00:00+00')) = 'Platform');
SELECT pg_temp.expect('agent actor is recorded',
    EXISTS (SELECT 1 FROM job_assignment WHERE recorded_by = 'agent:test'));

-- Scenario 4: a retroactive correction must not erase what we used to believe.
SELECT pg_temp.expect('history keeps closed rows (more rows than current beliefs)',
    (SELECT count(*) FROM job_assignment) >
    (SELECT count(*) FROM job_assignment WHERE upper_inf(recorded_period)));

-- Guard rails ----------------------------------------------------------------

DO $$
BEGIN
    BEGIN
        INSERT INTO job_assignment (person_id, title, department, valid_period, recorded_period, recorded_by, reason)
        VALUES ('00000000-0000-0000-0000-00000000a11c', 'Sneaky', 'Nowhere',
                daterange('2026-05-01', '2026-06-01'), tstzrange('2026-04-06 09:00+00', NULL),
                'human:test', 'direct overlapping insert');
        RAISE EXCEPTION 'FAIL: overlapping insert was accepted';
    EXCEPTION WHEN exclusion_violation THEN
        RAISE NOTICE 'ok   - overlapping insert is rejected by the database';
    END;
END;
$$;

DO $$
BEGIN
    BEGIN
        DELETE FROM job_assignment;
        RAISE EXCEPTION 'FAIL: delete was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'FAIL:%' THEN RAISE; END IF;
        RAISE NOTICE 'ok   - delete is blocked (%)', SQLERRM;
    END;
END;
$$;

DO $$
BEGIN
    BEGIN
        UPDATE job_assignment SET title = 'Rewritten history' WHERE upper_inf(recorded_period);
        RAISE EXCEPTION 'FAIL: in-place edit was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'FAIL:%' THEN RAISE; END IF;
        RAISE NOTICE 'ok   - in-place edit is blocked (%)', SQLERRM;
    END;
END;
$$;

DO $$
BEGIN
    BEGIN
        UPDATE job_assignment SET recorded_period = tstzrange(lower(recorded_period), '2026-12-31 00:00+00')
        WHERE NOT upper_inf(recorded_period);
        RAISE EXCEPTION 'FAIL: reopening or editing a closed row was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'FAIL:%' THEN RAISE; END IF;
        RAISE NOTICE 'ok   - closed rows cannot change (%)', SQLERRM;
    END;
END;
$$;

DO $$
BEGIN
    BEGIN
        PERFORM set_job('00000000-0000-0000-0000-0000000000b0', 'Analyst', 'Finance',
                        '00000000-0000-0000-0000-0000000000b0',
                        '2026-01-01', NULL, 'human:test', 'self-manager', '2026-01-05 09:00+00');
        RAISE EXCEPTION 'FAIL: person set as their own manager was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'ok   - a person cannot be their own manager';
    END;
END;
$$;

DO $$
BEGIN
    BEGIN
        PERFORM set_job('00000000-0000-0000-0000-00000000a11c', 'Late', 'Platform', NULL,
                        '2026-06-01', NULL, 'human:test', 'recorded in the past', '2026-01-01 00:00+00');
        RAISE EXCEPTION 'FAIL: recording earlier than existing belief was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'FAIL:%' THEN RAISE; END IF;
        RAISE NOTICE 'ok   - recorded_at must move forward (%)', SQLERRM;
    END;
END;
$$;

\echo ALL TESTS PASSED
