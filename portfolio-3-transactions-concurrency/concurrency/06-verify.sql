\pset pager off
\pset footer off
\echo
\echo 'Deadlocks detected in this database since statistics were last reset:'
SELECT deadlocks FROM pg_stat_database WHERE datname = current_database();
