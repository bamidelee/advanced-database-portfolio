-- =====================================================================
-- AquaFlow - Performance Indexes
-- MIT 8103 Advanced Database Systems - Portfolio 2
--
-- Each index targets a specific query in explain.sql. PostgreSQL does
-- not create indexes on foreign key columns automatically, so none of
-- these existed after schema.sql.
--
-- Run with:  psql -U postgres -d aquaflow -f indexes.sql
-- Undo with: psql -U postgres -d aquaflow -f drop-indexes.sql
-- =====================================================================

\set ON_ERROR_STOP on
\pset pager off

-- Q1: a customer's requests, newest first.
-- Composite index: finds the customer's rows AND returns them already
-- sorted by date, so no separate sort step is needed for the LIMIT.
CREATE INDEX IF NOT EXISTS idx_request_customer_created
  ON delivery_request (customer_id, created_at DESC);

-- Q2: trips for a request. The existing partial unique index
-- (one_live_trip_per_request) cannot be used here because it excludes
-- failed and cancelled trips, and this query needs all of them.
CREATE INDEX IF NOT EXISTS idx_trip_request
  ON trip (request_id);

-- Q2: status history for a trip, in time order.
CREATE INDEX IF NOT EXISTS idx_history_trip_changed
  ON trip_status_history (trip_id, changed_at);

-- Q3: partial index covering only trips in progress. It holds a few
-- hundred entries instead of ~294,000, so it is tiny, and completed
-- trips (the vast majority) never touch it.
CREATE INDEX IF NOT EXISTS idx_trip_active
  ON trip (assigned_at)
  WHERE status IN ('assigned', 'en_route', 'arrived');

-- Q5: a vendor's earnings.
CREATE INDEX IF NOT EXISTS idx_earning_vendor
  ON vendor_earning (vendor_id);

-- Q6 / Q6b: requests in a recent date range.
CREATE INDEX IF NOT EXISTS idx_request_created
  ON delivery_request (created_at);

-- Q6b: recently assigned completed trips. Partial, because only
-- completed trips are relevant to delivery-time reporting.
CREATE INDEX IF NOT EXISTS idx_trip_completed_assigned
  ON trip (assigned_at)
  WHERE status = 'completed';

-- Refresh statistics so the optimiser knows about the new indexes
ANALYZE;

-- ---------------------------------------------------------------------
-- Storage cost of each new index (indexes are not free: they use disk
-- space and must be updated on every insert and update)
-- ---------------------------------------------------------------------
SELECT i.indexrelname AS index_name,
       i.relname      AS table_name,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
       pg_size_pretty(pg_relation_size(i.relid))      AS table_size
FROM pg_stat_user_indexes i
WHERE i.indexrelname IN ('idx_request_customer_created', 'idx_trip_request',
                         'idx_history_trip_changed', 'idx_trip_active',
                         'idx_earning_vendor', 'idx_request_created',
                         'idx_trip_completed_assigned')
ORDER BY pg_relation_size(i.indexrelid) DESC;
