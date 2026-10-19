-- Included at the top of every session script (\ir session-header.sql).
-- Output is one plain line per event so the two sessions' logs can be
-- merged into a single timeline.
\set ON_ERROR_STOP off
\set VERBOSITY terse
\pset tuples_only on
\pset format unaligned
\pset pager off

-- Hide the step-by-step NOTICEs from complete_trip(); the timeline
-- logs each action itself
SET client_min_messages = warning;

-- Load the IDs prepared by the scenario's setup script
SELECT max(val) FILTER (WHERE key = 'request')  AS request,
       max(val) FILTER (WHERE key = 'request2') AS request2,
       max(val) FILTER (WHERE key = 'offer_a')  AS offer_a,
       max(val) FILTER (WHERE key = 'offer_b')  AS offer_b,
       max(val) FILTER (WHERE key = 'driver_a') AS driver_a,
       max(val) FILTER (WHERE key = 'driver_b') AS driver_b,
       max(val) FILTER (WHERE key = 'tanker')   AS tanker,
       max(val) FILTER (WHERE key = 'tanker2')  AS tanker2,
       max(val) FILTER (WHERE key = 'vendor')   AS vendor,
       max(val) FILTER (WHERE key = 'trip')     AS trip
FROM demo.ctx \gset

-- Remember the scenario start time in this session (see demo.log)
SELECT set_config('demo.t0', extract(epoch FROM started_at)::text, false) AS t0
FROM demo.clock \gset
