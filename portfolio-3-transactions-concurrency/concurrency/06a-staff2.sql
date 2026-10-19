-- Scenario 6, Staff 2: updates both tankers' statuses in one transaction.
\ir session-header.sql

SELECT demo.pause(0.5, 'Staff 2 starts a moment later');
BEGIN;
SELECT demo.log('BEGIN');

SELECT demo.try('UPDATE tanker ' || :tanker2,
  format('UPDATE tanker SET status = ''available'' WHERE id = %s', :tanker2)) AS result \gset
\echo :result
SELECT demo.pause(1.5, 'Doing other work');
SELECT demo.try('UPDATE tanker ' || :tanker,
  format('UPDATE tanker SET status = ''available'' WHERE id = %s', :tanker)) AS result \gset
\echo :result
SELECT position('FAILED' IN :'result') > 0 AS failed \gset
\if :failed
  SELECT demo.log('ROLLBACK');
  ROLLBACK;
\else
  SELECT demo.log('COMMIT');
  COMMIT;
\endif
