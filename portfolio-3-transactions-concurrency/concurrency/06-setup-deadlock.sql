-- =====================================================================
-- Scenario 6 setup: two available tankers belonging to one vendor.
-- At a shift change, two staff update both tankers' statuses at once.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off
DELETE FROM demo.ctx;

SELECT min(t.id) AS tanker, max(t.id) AS tanker2
FROM tanker t
WHERE t.vendor_id = (
  SELECT vendor_id FROM tanker
  WHERE status = 'available'
  GROUP BY vendor_id HAVING count(*) >= 2
  ORDER BY vendor_id LIMIT 1)
AND t.status = 'available' \gset

\o /dev/null
SELECT demo.set('tanker', :tanker), demo.set('tanker2', :tanker2);
\o
\echo 'Setup: tankers' :tanker 'and' :tanker2
\echo
\o /dev/null
SELECT demo.start_clock();
\o
