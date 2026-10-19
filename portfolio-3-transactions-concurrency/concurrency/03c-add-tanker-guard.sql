-- =====================================================================
-- Schema change: at most one live trip per tanker
--
-- Scenario 3a showed nothing in the schema stops one tanker being put
-- on two live trips. assign_trip() prevents it, but only for code that
-- uses it. This partial unique index makes the database itself refuse
-- a second live trip for a tanker, whatever code does the insert.
--
-- The index cannot be created while violations exist, so existing
-- double bookings are resolved first: the earliest live trip on each
-- tanker is kept, later ones are marked failed with an explanatory
-- reason, and their requests go back to pending to be re-offered.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off
\pset footer off

BEGIN;

\echo 'Tankers currently on more than one live trip (before cleanup):'
SELECT count(*) AS double_booked_tankers, sum(n) - count(*) AS extra_trips
FROM (SELECT tanker_id, count(*) AS n FROM trip
      WHERE status IN ('assigned', 'en_route', 'arrived')
      GROUP BY tanker_id HAVING count(*) > 1) x;

WITH ranked AS (
  SELECT id, request_id,
         row_number() OVER (PARTITION BY tanker_id ORDER BY assigned_at, id) AS rn
  FROM trip
  WHERE status IN ('assigned', 'en_route', 'arrived')
),
failed AS (
  UPDATE trip
  SET status = 'failed', failure_reason = 'Data cleanup: tanker was double-booked'
  WHERE id IN (SELECT id FROM ranked WHERE rn > 1)
  RETURNING id, request_id
),
history AS (
  INSERT INTO trip_status_history (trip_id, status)
  SELECT id, 'failed' FROM failed
)
UPDATE delivery_request SET status = 'pending'
WHERE id IN (SELECT request_id FROM failed);

CREATE UNIQUE INDEX IF NOT EXISTS one_live_trip_per_tanker
  ON trip (tanker_id)
  WHERE status IN ('assigned', 'en_route', 'arrived');

COMMENT ON INDEX one_live_trip_per_tanker IS
  'A tanker can be on at most one assigned, en route or arrived trip at a time.';

\echo 'After cleanup:'
SELECT count(*) AS double_booked_tankers
FROM (SELECT tanker_id FROM trip WHERE status IN ('assigned', 'en_route', 'arrived')
      GROUP BY tanker_id HAVING count(*) > 1) x;

COMMIT;
\echo 'Index one_live_trip_per_tanker created.'
