-- Scenario 2b, Vendor 2: calls assign_trip() one second later.
\ir session-header.sql

SELECT demo.pause(1, 'Vendor 2 taps accept a moment later');
BEGIN;
SELECT demo.log('BEGIN');
SELECT demo.try('assign_trip(offer ' || :offer_b || ')',
  format('SELECT assign_trip(%s, %s)', :offer_b, :driver_b));
SELECT demo.log('ROLLBACK');
ROLLBACK;
