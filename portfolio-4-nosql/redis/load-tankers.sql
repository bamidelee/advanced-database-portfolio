-- =====================================================================
-- AquaFlow - Redis loader
-- MIT 8103 Advanced Database Systems - Portfolio 4
--
-- Reads tankers from PostgreSQL and prints Redis commands, one per
-- line, to be piped into redis-cli. PostgreSQL stays the system of
-- record; Redis holds the fast-changing live state built from it.
--
-- PostgreSQL has no tanker positions (they only exist while a tanker
-- is driving), so a starting position is generated near the centre of
-- one of the six service areas. Area centres are the average of the
-- customer addresses in each area.
-- =====================================================================
\pset tuples_only on
\pset format unaligned
\pset pager off

SELECT 'DEL geo:tankers geo:tankers:available';

WITH centre AS (
  SELECT service_area_id AS area, avg(latitude) AS lat, avg(longitude) AS lng
  FROM address GROUP BY service_area_id
),
positioned AS (
  SELECT t.id, t.plate_number, t.vendor_id, t.capacity_litres, t.status,
         round(c.lat + ((t.id * 7919 % 1000) / 1000.0 - 0.5) * 0.016, 6) AS lat,
         round(c.lng + ((t.id * 104729 % 1000) / 1000.0 - 0.5) * 0.016, 6) AS lng
  FROM tanker t
  JOIN centre c ON c.area = 1 + t.id % 6
)
SELECT cmd FROM positioned p
CROSS JOIN LATERAL (VALUES
  -- Every tanker's details, as a hash
  (format('HSET tanker:%s plate %s vendor_id %s capacity %s status %s lat %s lng %s',
          id, plate_number, vendor_id, capacity_litres, status, lat, lng)),
  -- Tankers on the road (available or busy) have a live position
  (CASE WHEN status IN ('available', 'busy')
        THEN format('GEOADD geo:tankers %s %s %s', lng, lat, id) END),
  -- Only available tankers are in the set used for matching
  (CASE WHEN status = 'available'
        THEN format('GEOADD geo:tankers:available %s %s %s', lng, lat, id) END),
  -- Heartbeat: expires if the tanker's app stops reporting
  (CASE WHEN status IN ('available', 'busy')
        THEN format('SET tanker:%s:alive 1 EX 3600', id) END)
) AS v(cmd)
WHERE cmd IS NOT NULL
ORDER BY id;
