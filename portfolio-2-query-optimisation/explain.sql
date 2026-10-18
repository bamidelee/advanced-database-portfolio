-- =====================================================================
-- AquaFlow - Query Performance Analysis
-- MIT 8103 Advanced Database Systems - Portfolio 2
--
-- Seven queries the AquaFlow apps and staff run regularly. Each one is
-- run with EXPLAIN (ANALYZE, BUFFERS), which executes the query and
-- reports the plan the optimiser chose, the real row counts, the time
-- spent in each step, and how many data pages were read.
--
-- This file is run twice: once before and once after indexes.sql.
--   psql -U postgres -d aquaflow -f explain.sql > explain-before.txt 2>&1
--   psql -U postgres -d aquaflow -f indexes.sql
--   psql -U postgres -d aquaflow -f explain.sql > explain-after.txt 2>&1
--
-- Each query is executed once silently first (a warm-up), so both runs
-- measure data already in memory and the comparison is fair.
-- =====================================================================

\pset pager off
\timing off


-- =====================================================================
-- Q1. Customer request history (customer app home screen)
-- Shows a customer's 20 most recent requests with the delivery address.
-- Runs every time a customer opens the app, so it must be fast.
-- =====================================================================
\echo
\echo '==================== Q1: Customer request history ===================='
\o /dev/null
SELECT r.id, r.created_at, r.volume_litres, r.quoted_price, r.status, a.label, a.street_address
FROM delivery_request r
JOIN address a ON a.id = r.address_id
WHERE r.customer_id = 7004
ORDER BY r.created_at DESC
LIMIT 20;
\o
EXPLAIN (ANALYZE, BUFFERS)
SELECT r.id, r.created_at, r.volume_litres, r.quoted_price, r.status, a.label, a.street_address
FROM delivery_request r
JOIN address a ON a.id = r.address_id
WHERE r.customer_id = 7004
ORDER BY r.created_at DESC
LIMIT 20;


-- =====================================================================
-- Q2. Delivery tracking timeline (customer app tracking screen)
-- Every trip for a request, with each status change in order. Request
-- 299963 had a failed trip and a retry, so both trips appear.
-- =====================================================================
\echo
\echo '==================== Q2: Delivery tracking timeline ===================='
\o /dev/null
SELECT t.id AS trip_id, t.status AS trip_status, h.status, h.changed_at
FROM trip t
JOIN trip_status_history h ON h.trip_id = t.id
WHERE t.request_id = 299963
ORDER BY h.changed_at;
\o
EXPLAIN (ANALYZE, BUFFERS)
SELECT t.id AS trip_id, t.status AS trip_status, h.status, h.changed_at
FROM trip t
JOIN trip_status_history h ON h.trip_id = t.id
WHERE t.request_id = 299963
ORDER BY h.changed_at;


-- =====================================================================
-- Q3. Live operations dashboard (operations staff)
-- All trips currently in progress, with tanker, driver and destination.
-- Refreshed every few seconds, but matches only a few hundred of the
-- ~294,000 trips.
-- =====================================================================
\echo
\echo '==================== Q3: Live operations dashboard ===================='
\o /dev/null
SELECT t.id, t.status, t.assigned_at, tk.plate_number, d.full_name, d.phone,
       a.street_address, sa.name AS area
FROM trip t
JOIN tanker tk          ON tk.id = t.tanker_id
JOIN driver d           ON d.id = t.driver_id
JOIN delivery_request r ON r.id = t.request_id
JOIN address a          ON a.id = r.address_id
JOIN service_area sa    ON sa.id = a.service_area_id
WHERE t.status IN ('assigned', 'en_route', 'arrived')
ORDER BY t.assigned_at;
\o
EXPLAIN (ANALYZE, BUFFERS)
SELECT t.id, t.status, t.assigned_at, tk.plate_number, d.full_name, d.phone,
       a.street_address, sa.name AS area
FROM trip t
JOIN tanker tk          ON tk.id = t.tanker_id
JOIN driver d           ON d.id = t.driver_id
JOIN delivery_request r ON r.id = t.request_id
JOIN address a          ON a.id = r.address_id
JOIN service_area sa    ON sa.id = a.service_area_id
WHERE t.status IN ('assigned', 'en_route', 'arrived')
ORDER BY t.assigned_at;


-- =====================================================================
-- Q4. Tanker matching (runs on every new request)
-- Available, verified tankers big enough for the request, excluding any
-- already offered this request. Control case: expected to be fast
-- already (see analysis).
-- =====================================================================
\echo
\echo '==================== Q4: Tanker matching ===================='
\o /dev/null
SELECT tk.id, tk.plate_number, tk.capacity_litres, v.business_name
FROM tanker tk
JOIN vendor v ON v.id = tk.vendor_id
WHERE tk.status = 'available'
  AND v.verification_status = 'verified'
  AND tk.capacity_litres >= (SELECT volume_litres FROM delivery_request WHERE id = 299963)
  AND NOT EXISTS (SELECT 1 FROM job_offer jo WHERE jo.request_id = 299963 AND jo.tanker_id = tk.id)
ORDER BY tk.capacity_litres
LIMIT 10;
\o
EXPLAIN (ANALYZE, BUFFERS)
SELECT tk.id, tk.plate_number, tk.capacity_litres, v.business_name
FROM tanker tk
JOIN vendor v ON v.id = tk.vendor_id
WHERE tk.status = 'available'
  AND v.verification_status = 'verified'
  AND tk.capacity_litres >= (SELECT volume_litres FROM delivery_request WHERE id = 299963)
  AND NOT EXISTS (SELECT 1 FROM job_offer jo WHERE jo.request_id = 299963 AND jo.tanker_id = tk.id)
ORDER BY tk.capacity_litres
LIMIT 10;


-- =====================================================================
-- Q5. Vendor monthly statement (vendor app, finance)
-- Daily trips and earnings for one vendor over the previous month.
-- =====================================================================
\echo
\echo '==================== Q5: Vendor monthly statement ===================='
\o /dev/null
SELECT t.completed_at::date AS day, count(*) AS trips,
       sum(ve.gross_amount) AS gross, sum(ve.commission_amount) AS commission,
       sum(ve.net_amount) AS net
FROM vendor_earning ve
JOIN trip t ON t.id = ve.trip_id
WHERE ve.vendor_id = 345
  AND t.completed_at >= date_trunc('month', now()) - interval '1 month'
  AND t.completed_at <  date_trunc('month', now())
GROUP BY 1
ORDER BY 1;
\o
EXPLAIN (ANALYZE, BUFFERS)
SELECT t.completed_at::date AS day, count(*) AS trips,
       sum(ve.gross_amount) AS gross, sum(ve.commission_amount) AS commission,
       sum(ve.net_amount) AS net
FROM vendor_earning ve
JOIN trip t ON t.id = ve.trip_id
WHERE ve.vendor_id = 345
  AND t.completed_at >= date_trunc('month', now()) - interval '1 month'
  AND t.completed_at <  date_trunc('month', now())
GROUP BY 1
ORDER BY 1;


-- =====================================================================
-- Q6. Weekly area performance report (management)
-- Requests, completions and average delivery time per area, last 7 days.
-- =====================================================================
\echo
\echo '==================== Q6: Weekly area report (original) ===================='
\o /dev/null
SELECT sa.name AS area, count(*) AS requests,
       count(*) FILTER (WHERE r.status = 'completed') AS completed,
       round(avg(extract(epoch FROM t.completed_at - t.assigned_at) / 60)) AS avg_minutes
FROM delivery_request r
JOIN address a      ON a.id = r.address_id
JOIN service_area sa ON sa.id = a.service_area_id
LEFT JOIN trip t    ON t.request_id = r.id AND t.status = 'completed'
WHERE r.created_at >= now() - interval '7 days'
GROUP BY sa.name
ORDER BY requests DESC;
\o
EXPLAIN (ANALYZE, BUFFERS)
SELECT sa.name AS area, count(*) AS requests,
       count(*) FILTER (WHERE r.status = 'completed') AS completed,
       round(avg(extract(epoch FROM t.completed_at - t.assigned_at) / 60)) AS avg_minutes
FROM delivery_request r
JOIN address a      ON a.id = r.address_id
JOIN service_area sa ON sa.id = a.service_area_id
LEFT JOIN trip t    ON t.request_id = r.id AND t.status = 'completed'
WHERE r.created_at >= now() - interval '7 days'
GROUP BY sa.name
ORDER BY requests DESC;


-- =====================================================================
-- Q6b. Weekly area report (rewritten)
-- Same report with an extra condition on the trip side. A trip is
-- always assigned after its request is created, so this condition
-- cannot exclude any matching trip and the results are identical. It
-- lets the optimiser read only recent completed trips instead of all
-- of them.
-- =====================================================================
\echo
\echo '==================== Q6b: Weekly area report (rewritten) ===================='
\o /dev/null
SELECT sa.name AS area, count(*) AS requests,
       count(*) FILTER (WHERE r.status = 'completed') AS completed,
       round(avg(extract(epoch FROM t.completed_at - t.assigned_at) / 60)) AS avg_minutes
FROM delivery_request r
JOIN address a      ON a.id = r.address_id
JOIN service_area sa ON sa.id = a.service_area_id
LEFT JOIN trip t    ON t.request_id = r.id AND t.status = 'completed'
                   AND t.assigned_at >= now() - interval '7 days'
WHERE r.created_at >= now() - interval '7 days'
GROUP BY sa.name
ORDER BY requests DESC;
\o
EXPLAIN (ANALYZE, BUFFERS)
SELECT sa.name AS area, count(*) AS requests,
       count(*) FILTER (WHERE r.status = 'completed') AS completed,
       round(avg(extract(epoch FROM t.completed_at - t.assigned_at) / 60)) AS avg_minutes
FROM delivery_request r
JOIN address a      ON a.id = r.address_id
JOIN service_area sa ON sa.id = a.service_area_id
LEFT JOIN trip t    ON t.request_id = r.id AND t.status = 'completed'
                   AND t.assigned_at >= now() - interval '7 days'
WHERE r.created_at >= now() - interval '7 days'
GROUP BY sa.name
ORDER BY requests DESC;


-- =====================================================================
-- Selectivity check: when does the optimiser use the created_at index?
-- Plans only (no ANALYZE). Compare 7 days (~5% of rows) with 365 days
-- (~half the table).
-- =====================================================================
\echo
\echo '==================== Selectivity: 7 days vs 365 days ===================='
EXPLAIN SELECT count(*) FROM delivery_request WHERE created_at >= now() - interval '7 days';
EXPLAIN SELECT count(*) FROM delivery_request WHERE created_at >= now() - interval '365 days';
