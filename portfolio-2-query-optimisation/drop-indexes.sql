-- Removes the Portfolio 2 performance indexes, restoring the "before" state.
DROP INDEX IF EXISTS idx_request_customer_created, idx_trip_request,
  idx_history_trip_changed, idx_trip_active, idx_earning_vendor,
  idx_request_created, idx_trip_completed_assigned;
ANALYZE;
