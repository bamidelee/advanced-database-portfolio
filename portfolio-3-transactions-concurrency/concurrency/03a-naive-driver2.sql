-- Scenario 3a, Driver 2: accepts request 2 for the same tanker, one
-- second later, with the same plain SQL.
\ir session-header.sql

SELECT demo.pause(1, 'Driver 2 taps accept a moment later');
BEGIN;
SELECT demo.log('BEGIN');
SELECT demo.log('Reads tanker ' || id || ': status = ' || status) FROM tanker WHERE id = :tanker;
SELECT demo.pause(2, 'Tanker is available, so the app proceeds');
SELECT demo.try('INSERT trip + UPDATE tanker to busy',
  format('WITH new_trip AS (
            INSERT INTO trip (request_id, offer_id, tanker_id, driver_id)
            SELECT request_id, id, tanker_id, %s FROM job_offer WHERE id = %s
            RETURNING tanker_id)
          UPDATE tanker SET status = ''busy''
          WHERE id IN (SELECT tanker_id FROM new_trip)', :driver_b, :offer_b));
SELECT demo.log('COMMIT');
COMMIT;
