\pset pager off
\pset footer off
SELECT val AS tanker FROM demo.ctx WHERE key = 'tanker' \gset
\echo
\echo 'Result: live trips on the tanker (more than one means it is double-booked)'
SELECT t.id AS trip, t.request_id AS request, t.driver_id AS driver, t.status
FROM trip t
WHERE t.tanker_id = :tanker AND t.status IN ('assigned', 'en_route', 'arrived')
ORDER BY t.id;
SELECT CASE WHEN count(*) > 1 THEN 'DOUBLE-BOOKED: one tanker cannot make two deliveries at once'
            ELSE 'OK: tanker has one live trip' END AS verdict
FROM trip WHERE tanker_id = :tanker AND status IN ('assigned', 'en_route', 'arrived');
