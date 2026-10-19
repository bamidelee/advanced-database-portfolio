-- Scenario 2b, Vendor 1: accepts using assign_trip(), which locks the
-- request row with SELECT ... FOR UPDATE before checking its status.
\ir session-header.sql

BEGIN;
SELECT demo.log('BEGIN');
SELECT demo.try('assign_trip(offer ' || :offer_a || ')',
  format('SELECT assign_trip(%s, %s)', :offer_a, :driver_a));
SELECT demo.pause(3, 'Holding the lock until commit');
SELECT demo.log('COMMIT');
COMMIT;
