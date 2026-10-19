-- Scenario 4, Driver: completes the delivery while the payout is running,
-- which creates a new unpaid earning for the same vendor.
\ir session-header.sql

SELECT demo.pause(1, 'Driver finishes pumping water');
BEGIN;
SELECT demo.log('BEGIN');
SELECT demo.try('complete_trip(' || :trip || ') - new earning for vendor ' || :vendor,
  format('SELECT complete_trip(%s, 5000, ''card'', %L)', :trip, 'PSTK-ISO-' || :trip));
SELECT demo.log('COMMIT');
COMMIT;
