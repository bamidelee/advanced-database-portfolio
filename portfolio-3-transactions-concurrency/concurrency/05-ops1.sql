-- Scenario 5, Operations staff 1: takes one driver off duty, but only
-- after checking the vendor will still have another active driver.
-- The isolation level is passed in by the runner as :iso.
\ir session-header.sql


BEGIN ISOLATION LEVEL :iso;
SELECT demo.log('BEGIN ISOLATION LEVEL ' || upper(current_setting('transaction_isolation')));
SELECT count(*) AS active FROM driver WHERE vendor_id = :vendor AND is_active \gset
SELECT demo.log('Counts active drivers for vendor ' || :vendor || ': ' || :active);
SELECT demo.pause(2, 'More than one, so it is safe to take driver ' || :driver_a || ' off duty');
SELECT demo.try('UPDATE driver ' || :driver_a || ' to inactive',
  format('UPDATE driver SET is_active = false WHERE id = %s', :driver_a)) AS result \gset
\echo :result
SELECT demo.pause(2, 'Finishing the shift change');
SELECT position('FAILED' IN :'result') > 0 AS failed \gset
\if :failed
  SELECT demo.log('ROLLBACK');
  ROLLBACK;
\else
  SELECT demo.log('COMMIT');
  COMMIT;
\endif
