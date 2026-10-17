-- Headless HR prototype: bitemporal people and jobs.
--
-- STATUS: prototype, synthetic data only. Not audited. Not HR/legal/payroll advice.
--
-- Two kinds of time on every job record:
--   valid_period    when the fact is true in the real world (dates)
--   recorded_period when this database believed it (timestamps)
-- Nothing is ever overwritten. A correction closes the old belief (ends its
-- recorded_period) and writes a new one, so we can always ask
-- "what did we believe on date X about date Y?".
--
-- Works on PostgreSQL 16 and later. Uses exclusion constraints (btree_gist)
-- instead of the PostgreSQL 18 WITHOUT OVERLAPS / PERIOD syntax so it can be
-- tested on 16. Moving to the 18 syntax later is a constraint swap, not a data
-- model change.

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ---------------------------------------------------------------------------
-- person: the stable internal identity. Survives job changes, rehires, and
-- changes of identity provider. (Name is not effective-dated in this prototype;
-- a real version would version it too.)
-- ---------------------------------------------------------------------------
CREATE TABLE person (
    person_id    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    display_name text        NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------------
-- job_assignment: one primary job per person at any point in valid time,
-- as believed at any point in recorded time. (Simplification: no concurrent
-- or secondary jobs yet.)
-- ---------------------------------------------------------------------------
CREATE TABLE job_assignment (
    row_id            bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    person_id         uuid        NOT NULL REFERENCES person (person_id),
    title             text        NOT NULL,
    department        text        NOT NULL,
    manager_person_id uuid        REFERENCES person (person_id),
    valid_period      daterange   NOT NULL,
    recorded_period   tstzrange   NOT NULL,
    recorded_by       text        NOT NULL,  -- who or what wrote it: 'human:<id>' or 'agent:<id>'
    reason            text        NOT NULL,  -- why it was written

    CONSTRAINT job_valid_nonempty     CHECK (NOT isempty(valid_period)),
    CONSTRAINT job_valid_finite_start CHECK (NOT lower_inf(valid_period)),
    CONSTRAINT job_recorded_nonempty  CHECK (NOT isempty(recorded_period)),
    CONSTRAINT job_not_own_manager    CHECK (manager_person_id IS DISTINCT FROM person_id),

    -- At any recorded moment, one person has at most one job at any valid date.
    CONSTRAINT job_no_overlap EXCLUDE USING gist (
        person_id       WITH =,
        valid_period    WITH &&,
        recorded_period WITH &&
    )
);

CREATE INDEX job_assignment_person_idx ON job_assignment (person_id);

-- ---------------------------------------------------------------------------
-- History is append-only. The only permitted UPDATE is closing a currently
-- believed row by giving it a finite end to recorded_period. No deletes.
-- ---------------------------------------------------------------------------
CREATE FUNCTION job_assignment_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'job_assignment is append-only: deletes are not allowed';
    END IF;

    IF NOT upper_inf(OLD.recorded_period) THEN
        RAISE EXCEPTION 'job_assignment row % is already closed and cannot change', OLD.row_id;
    END IF;

    IF NEW.row_id            IS DISTINCT FROM OLD.row_id
    OR NEW.person_id         IS DISTINCT FROM OLD.person_id
    OR NEW.title             IS DISTINCT FROM OLD.title
    OR NEW.department        IS DISTINCT FROM OLD.department
    OR NEW.manager_person_id IS DISTINCT FROM OLD.manager_person_id
    OR NEW.valid_period      IS DISTINCT FROM OLD.valid_period
    OR NEW.recorded_by       IS DISTINCT FROM OLD.recorded_by
    OR NEW.reason            IS DISTINCT FROM OLD.reason
    OR lower(NEW.recorded_period) IS DISTINCT FROM lower(OLD.recorded_period)
    THEN
        RAISE EXCEPTION 'job_assignment is append-only: only closing recorded_period is allowed';
    END IF;

    IF upper_inf(NEW.recorded_period) THEN
        RAISE EXCEPTION 'job_assignment update must close recorded_period';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER job_assignment_guard_trg
    BEFORE UPDATE OR DELETE ON job_assignment
    FOR EACH ROW EXECUTE FUNCTION job_assignment_guard();

-- ---------------------------------------------------------------------------
-- set_job: record that, for valid dates [p_valid_from, p_valid_to), the person
-- holds this job. p_valid_to NULL means open-ended. Works for new facts and for
-- retroactive corrections alike. Any believed row that overlaps the new range is
-- closed and its non-overlapping remainders are re-recorded unchanged.
--
-- p_recorded_at defaults to the real clock; tests pass explicit values.
-- ---------------------------------------------------------------------------
CREATE FUNCTION set_job(
    p_person_id   uuid,
    p_title       text,
    p_department  text,
    p_manager_id  uuid,
    p_valid_from  date,
    p_valid_to    date,
    p_recorded_by text,
    p_reason      text,
    p_recorded_at timestamptz DEFAULT clock_timestamp()
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    new_valid daterange;
    old       job_assignment%ROWTYPE;
BEGIN
    IF p_valid_from IS NULL THEN
        RAISE EXCEPTION 'valid_from is required';
    END IF;
    IF p_valid_to IS NOT NULL AND p_valid_to <= p_valid_from THEN
        RAISE EXCEPTION 'valid_to must be after valid_from';
    END IF;

    new_valid := daterange(p_valid_from, p_valid_to, '[)');

    FOR old IN
        SELECT * FROM job_assignment
        WHERE person_id = p_person_id
          AND upper_inf(recorded_period)
          AND valid_period && new_valid
        ORDER BY valid_period
        FOR UPDATE
    LOOP
        IF p_recorded_at <= lower(old.recorded_period) THEN
            RAISE EXCEPTION
                'recorded_at % is not after the existing record (recorded %)',
                p_recorded_at, lower(old.recorded_period);
        END IF;

        -- Close the old belief.
        UPDATE job_assignment
           SET recorded_period = tstzrange(lower(old.recorded_period), p_recorded_at, '[)')
         WHERE row_id = old.row_id;

        -- Re-record the part before the new range, unchanged.
        IF lower(old.valid_period) < p_valid_from THEN
            INSERT INTO job_assignment (person_id, title, department, manager_person_id,
                                        valid_period, recorded_period, recorded_by, reason)
            VALUES (old.person_id, old.title, old.department, old.manager_person_id,
                    daterange(lower(old.valid_period), p_valid_from, '[)'),
                    tstzrange(p_recorded_at, NULL, '[)'),
                    p_recorded_by, 'split: ' || p_reason);
        END IF;

        -- Re-record the part after the new range, unchanged.
        IF p_valid_to IS NOT NULL
           AND (upper_inf(old.valid_period) OR p_valid_to < upper(old.valid_period)) THEN
            INSERT INTO job_assignment (person_id, title, department, manager_person_id,
                                        valid_period, recorded_period, recorded_by, reason)
            VALUES (old.person_id, old.title, old.department, old.manager_person_id,
                    daterange(p_valid_to, upper(old.valid_period), '[)'),
                    tstzrange(p_recorded_at, NULL, '[)'),
                    p_recorded_by, 'split: ' || p_reason);
        END IF;
    END LOOP;

    INSERT INTO job_assignment (person_id, title, department, manager_person_id,
                                valid_period, recorded_period, recorded_by, reason)
    VALUES (p_person_id, p_title, p_department, p_manager_id,
            new_valid, tstzrange(p_recorded_at, NULL, '[)'), p_recorded_by, p_reason);
END;
$$;

-- ---------------------------------------------------------------------------
-- job_as_of: what did we believe (at p_known_at) was true on p_valid_on?
-- ---------------------------------------------------------------------------
CREATE FUNCTION job_as_of(
    p_valid_on  date,
    p_known_at  timestamptz DEFAULT clock_timestamp()
) RETURNS TABLE (
    person_id         uuid,
    title             text,
    department        text,
    manager_person_id uuid,
    valid_period      daterange,
    recorded_period   tstzrange
)
LANGUAGE sql STABLE AS $$
    SELECT j.person_id, j.title, j.department, j.manager_person_id,
           j.valid_period, j.recorded_period
    FROM job_assignment j
    WHERE j.valid_period    @> p_valid_on
      AND j.recorded_period @> p_known_at;
$$;
