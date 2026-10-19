-- Scenario 2a, Vendor 2: the same plain SQL, starting one second later.
\ir session-header.sql

SELECT demo.pause(1, 'Vendor 2 taps accept a moment later');
BEGIN;
SELECT demo.log('BEGIN');
SELECT demo.log('Reads request ' || id || ': status = ' || status) FROM delivery_request WHERE id = :request;
SELECT demo.pause(2, 'Status is pending, so the app proceeds');
SELECT demo.try('INSERT trip + UPDATE request to assigned',
  format('WITH new_trip AS (
            INSERT INTO trip (request_id, offer_id, tanker_id, driver_id)
            SELECT request_id, id, tanker_id, %s FROM job_offer WHERE id = %s
            RETURNING request_id)
          UPDATE delivery_request SET status = ''assigned''
          WHERE id IN (SELECT request_id FROM new_trip)', :driver_b, :offer_b));
SELECT demo.log('COMMIT');
COMMIT;
