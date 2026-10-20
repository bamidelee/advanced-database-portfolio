-- =====================================================================
-- AquaFlow - Export GPS breadcrumbs for the time-series collection
-- MIT 8103 Advanced Database Systems - Portfolio 4
--
-- PostgreSQL stores no GPS history, so this generates a plausible route
-- for each trip completed in the last 7 days: 10 points from a start
-- position near the trip's service area to the delivery address,
-- spread evenly between assignment and arrival.
-- =====================================================================
\pset tuples_only on
\pset format unaligned
\pset pager off
SET client_min_messages = warning;

WITH centre AS (
  SELECT service_area_id AS area, avg(latitude) AS lat, avg(longitude) AS lng
  FROM address GROUP BY service_area_id
),
trips AS (
  SELECT t.id AS trip_id, t.tanker_id, t.assigned_at,
         -- arrival is about 15 minutes before completion (pumping time)
         t.completed_at - interval '15 minutes' AS arrived_at,
         a.latitude AS end_lat, a.longitude AS end_lng,
         c.lat + ((t.tanker_id * 7919 % 1000) / 1000.0 - 0.5) * 0.016 AS start_lat,
         c.lng + ((t.tanker_id * 104729 % 1000) / 1000.0 - 0.5) * 0.016 AS start_lng
  FROM trip t
  JOIN delivery_request r ON r.id = t.request_id
  JOIN address a ON a.id = r.address_id
  JOIN centre c ON c.area = a.service_area_id
  WHERE t.status = 'completed' AND t.assigned_at >= now() - interval '7 days'
)
SELECT json_build_object(
  'ts', json_build_object('$date',
          to_char((assigned_at + (arrived_at - assigned_at) * s / 9.0) AT TIME ZONE 'UTC',
                  'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),
  'meta', json_build_object('tanker_id', tanker_id, 'trip_id', trip_id),
  'location', json_build_object('type', 'Point', 'coordinates', json_build_array(
      round(start_lng + (end_lng - start_lng) * s / 9.0, 6),
      round(start_lat + (end_lat - start_lat) * s / 9.0, 6))),
  'speed_kmh', CASE WHEN s IN (0, 9) THEN 0 ELSE 8 + (trip_id * s * 31 % 25) END
)
FROM trips CROSS JOIN generate_series(0, 9) AS s
ORDER BY trip_id, s;
