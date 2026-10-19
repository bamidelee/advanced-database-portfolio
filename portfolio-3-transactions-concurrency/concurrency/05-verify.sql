\pset pager off
\pset footer off
SELECT val AS vendor FROM demo.ctx WHERE key = 'vendor' \gset
\echo
\echo 'Result: active drivers left for the vendor (the rule requires at least one)'
SELECT count(*) FILTER (WHERE is_active) AS active_drivers,
       CASE WHEN count(*) FILTER (WHERE is_active) = 0
            THEN 'RULE BROKEN: vendor has no active driver'
            ELSE 'OK: rule holds' END AS verdict
FROM driver WHERE vendor_id = :vendor;
