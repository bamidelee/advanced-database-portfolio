-- =====================================================================
-- AquaFlow - Concurrency Demo Helpers
-- MIT 8103 Advanced Database Systems - Portfolio 3
--
-- A separate "demo" schema holding small utilities used by the
-- two-session demonstrations. Kept apart from the AquaFlow tables so
-- the application schema is not affected.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS demo;

-- Values shared between the setup script and the two sessions
CREATE TABLE IF NOT EXISTS demo.ctx (key text PRIMARY KEY, val bigint);

-- Start time of the current scenario, so every log line can show
-- seconds elapsed since the scenario began
CREATE TABLE IF NOT EXISTS demo.clock (started_at timestamptz);

CREATE OR REPLACE FUNCTION demo.set(p_key text, p_val bigint) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO demo.ctx VALUES (p_key, p_val)
  ON CONFLICT (key) DO UPDATE SET val = EXCLUDED.val;
$$;

CREATE OR REPLACE FUNCTION demo.start_clock() RETURNS void
LANGUAGE sql AS $$
  DELETE FROM demo.clock;
  INSERT INTO demo.clock VALUES (clock_timestamp());
$$;

-- A log line stamped with the real time of the event (clock_timestamp,
-- not now(), because now() is frozen at the start of a transaction).
-- The start time is read from a session setting (demo.t0, set by
-- session-header.sql) rather than from a table, so logging never reads
-- table data. Under SERIALIZABLE, any table read can be the point where
-- PostgreSQL raises a serialization failure, which would make the log
-- line itself fail.
CREATE OR REPLACE FUNCTION demo.log(p_msg text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  t0 numeric := nullif(current_setting('demo.t0', true), '')::numeric;
BEGIN
  IF t0 IS NULL THEN
    SELECT extract(epoch FROM started_at) INTO t0 FROM demo.clock;
  END IF;
  RETURN to_char(extract(epoch FROM clock_timestamp()) - t0, 'FM990.000') || 's  ' || p_msg;
END;
$$;

-- Logs a message, then sleeps. Used to hold a transaction open so the
-- other session can act in the meantime.
CREATE OR REPLACE FUNCTION demo.pause(p_seconds numeric, p_why text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  v_line text := demo.log(p_why || ' (holding for ' || p_seconds || 's)');
BEGIN
  PERFORM pg_sleep(p_seconds);
  RETURN v_line;
END;
$$;

-- Runs one statement and logs how it ended, including how long it was
-- blocked waiting for another session. Errors are caught and logged
-- rather than aborting the transaction, so the timeline shows exactly
-- when and why a statement failed.
CREATE OR REPLACE FUNCTION demo.try(p_label text, p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  v_start  timestamptz := clock_timestamp();
  v_waited numeric;
  v_note   text := '';
BEGIN
  EXECUTE p_sql;
  v_waited := extract(epoch FROM clock_timestamp() - v_start);
  IF v_waited > 0.2 THEN
    v_note := ' (after being blocked for ' || round(v_waited, 1) || 's)';
  END IF;
  RETURN demo.log('OK     ' || p_label || v_note);
EXCEPTION WHEN OTHERS THEN
  v_waited := extract(epoch FROM clock_timestamp() - v_start);
  IF v_waited > 0.2 THEN
    v_note := ' (after being blocked for ' || round(v_waited, 1) || 's)';
  END IF;
  RETURN demo.log('FAILED ' || p_label || v_note || E'\n           -> ' || SQLERRM);
END;
$$;
