#!/usr/bin/env bash
# =====================================================================
# AquaFlow - PostgreSQL Streaming Replication Demonstration
# MIT 8103 Advanced Database Systems - Portfolio 5
#
# Rebuilds a fresh primary + replica pair, then demonstrates:
#   1. Replication topology
#   2. Replication lag while bulk-loading AquaFlow on the primary
#   3. The replica is read-only
#   4. A stale read on the replica (eventual consistency)
#   5. Synchronous replication: stronger guarantee, and what it costs
#      when the replica goes down
#   6. Failover: promoting the replica after the primary fails
#
# Usage (from the repository root):
#   bash portfolio-5-distributed-cloud/postgres/pg-replication-demo.sh
#
# Takes about 3 to 4 minutes. Output is saved to
# postgres/pg-replication-demo-output.txt.
# =====================================================================

set -e
export MSYS_NO_PATHCONV=1

HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $HERE/../docker-compose.yml"
P="docker exec aquaflow-pg-primary psql -X -U postgres -d aquaflow"
R="docker exec aquaflow-pg-replica psql -X -U postgres -d aquaflow"

section() {
  echo
  echo "======================================================================"
  echo " $1"
  echo "======================================================================"
  [ -n "$2" ] && echo "$2" && echo
  return 0
}
on_primary() { echo "[primary]> $*"; $P -c "$*" 2>&1; }
on_replica() { echo "[replica]> $*"; $R -c "$*" 2>&1; }

wait_for_streaming() {
  for _ in $(seq 1 60); do
    state=$($P -At -c "SELECT state FROM pg_stat_replication WHERE application_name = 'replica1'" 2>/dev/null || true)
    [ "$state" = "streaming" ] && return 0
    sleep 2
  done
  echo "Replica did not start streaming within 2 minutes"; exit 1
}

wait_for_catch_up() {
  for _ in $(seq 1 120); do
    behind=$($P -At -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) FROM pg_stat_replication WHERE application_name = 'replica1'")
    [ "$behind" = "0" ] && return 0
    sleep 1
  done
}

{
section "0. Fresh start" \
"Removing any previous primary/replica pair and building a new one. The
replica clones the primary with pg_basebackup, then streams its WAL."
$COMPOSE rm -sf pg-primary pg-replica > /dev/null 2>&1 || true
docker volume rm -f aquaflow-distributed_primary_data aquaflow-distributed_replica_data > /dev/null 2>&1 || true
$COMPOSE up -d --wait pg-primary pg-replica 2>&1 | grep -v -E "^\s*$" | tail -3
wait_for_streaming

section "1. Replication topology" \
"The primary lists its connected replicas; the replica reports that it is
in recovery mode, continuously replaying the primary's write-ahead log."
on_primary "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"
on_replica "SELECT pg_is_in_recovery() AS is_replica, status, sender_host FROM pg_stat_wal_receiver;"

section "2. Replication lag during a bulk load" \
"The AquaFlow schema and the Portfolio 2 seed data (about 400 MB) are
loaded on the primary only. Every 3 seconds, the primary reports how far
the replica's replay is behind its current WAL position."
$P -q -f /portfolio/portfolio-1-database-design/schema.sql > /dev/null 2>&1
echo "Schema created on the primary. Starting seed.sql ..."
$P -q -f /portfolio/portfolio-2-query-optimisation/seed.sql > /tmp/aquaflow-seed.log 2>&1 &
SEED=$!
printf "%-10s %-18s %-16s %s\n" "time" "replica_behind" "replay_lag" "replica_rows_visible"
while kill -0 "$SEED" 2>/dev/null; do
  line=$($P -At -F' ' -c "SELECT to_char(now(), 'HH24:MI:SS'),
           pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)),
           coalesce(date_trunc('millisecond', replay_lag)::text, '0')
         FROM pg_stat_replication WHERE application_name = 'replica1'" 2>/dev/null || true)
  rows=$($R -At -c "SELECT count(*) FROM delivery_request" 2>/dev/null || echo "-")
  [ -n "$line" ] && printf "%-10s %-18s %-16s %s\n" $(echo "$line" | awk '{print $1}') \
    "$(echo "$line" | awk '{print $2, $3}')" "$(echo "$line" | awk '{print $4}')" "$rows"
  sleep 3
done
wait "$SEED" || { echo "Seed failed:"; tail -5 /tmp/aquaflow-seed.log; exit 1; }
wait_for_catch_up
echo
echo "Seed finished and the replica has caught up. Row counts on each server:"
on_primary "SELECT (SELECT count(*) FROM delivery_request) AS requests, (SELECT count(*) FROM trip_status_history) AS status_history;"
on_replica "SELECT (SELECT count(*) FROM delivery_request) AS requests, (SELECT count(*) FROM trip_status_history) AS status_history;"

section "3. The replica is read-only" \
"A hot standby accepts queries but refuses every write. All writes must go
to the primary."
on_replica "INSERT INTO service_area (name) VALUES ('Lekki');"

section "4. A stale read (eventual consistency)" \
"Replay on the replica is paused to make the delay visible, as if it had
fallen behind. A customer registers on the primary; the app then reads
from the replica and cannot find them. This is the read-your-writes
problem of asynchronous replicas."
on_replica "SELECT pg_wal_replay_pause();"
on_primary "INSERT INTO customer (full_name, phone, customer_type) VALUES ('Adaeze Nwosu', '08099990001', 'household');"
on_primary "SELECT id, full_name FROM customer WHERE phone = '08099990001';"
on_replica "SELECT id, full_name FROM customer WHERE phone = '08099990001';"
on_primary "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replica_behind FROM pg_stat_replication;"
echo "Resuming replay ..."
on_replica "SELECT pg_wal_replay_resume();"
sleep 1
on_replica "SELECT id, full_name FROM customer WHERE phone = '08099990001';"

section "5. Synchronous replication" \
"With synchronous_standby_names set, a commit on the primary waits until
the replica confirms it has the WAL. A committed transaction then exists
on both servers. First, commit time for 300 single-row inserts,
asynchronous versus synchronous. Here both servers run on one machine, so
the replica is microseconds away and the difference is small. Across data
centres, every synchronous commit also waits for a network round trip."
time_inserts() {
  local label=$1 start end
  start=$(date +%s%N)
  $P -q -c "DO \$\$ BEGIN FOR i IN 1..300 LOOP
              INSERT INTO service_area (name) VALUES ('$label-' || i);
              COMMIT;
            END LOOP; END \$\$;" > /dev/null
  end=$(date +%s%N)
  echo "  $label: $(( (end - start) / 1000000 )) ms for 300 commits"
}
time_inserts async
on_primary "ALTER SYSTEM SET synchronous_standby_names = 'replica1';" > /dev/null
on_primary "SELECT pg_reload_conf();" > /dev/null
sleep 1
time_inserts sync
echo
on_primary "SELECT application_name, state, sync_state FROM pg_stat_replication;"

echo
echo "Now the replica goes down while synchronous replication is required."
$COMPOSE stop pg-replica 2>&1 | tail -1
echo "A delivery request is inserted on the primary (in the background):"
$P -c "INSERT INTO service_area (name) VALUES ('Sync test while replica down');" > /tmp/aquaflow-sync-wait.log 2>&1 &
WAITER=$!
sleep 4
echo "4 seconds later, the commit is still waiting for the replica:"
on_primary "SELECT pid, state, wait_event_type, wait_event, left(query, 45) AS query FROM pg_stat_activity WHERE wait_event = 'SyncRep';"
echo "And other sessions cannot see the row yet:"
on_primary "SELECT count(*) AS visible FROM service_area WHERE name = 'Sync test while replica down';"
echo "An operator cancels the waiting commit:"
on_primary "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep';" > /dev/null
wait "$WAITER" || true
echo "[waiting session's output]"
cat /tmp/aquaflow-sync-wait.log
on_primary "SELECT count(*) AS visible FROM service_area WHERE name = 'Sync test while replica down';"

echo
echo "Returning to asynchronous replication and restarting the replica:"
on_primary "ALTER SYSTEM RESET synchronous_standby_names;" > /dev/null
on_primary "SELECT pg_reload_conf();" > /dev/null
$COMPOSE start pg-replica 2>&1 | tail -1
wait_for_streaming
wait_for_catch_up
echo "The replica reconnected and replayed what it missed:"
on_replica "SELECT count(*) AS visible FROM service_area WHERE name = 'Sync test while replica down';"

section "6. Failover" \
"The primary server fails. The replica is promoted: it stops replaying,
leaves recovery mode and starts accepting writes."
$COMPOSE stop pg-primary 2>&1 | tail -1
on_replica "INSERT INTO customer (full_name, phone) VALUES ('Before promotion', '08099990002');"
START=$(date +%s%N)
on_replica "SELECT pg_promote();"
END=$(date +%s%N)
echo "Promotion took $(( (END - START) / 1000000 )) ms"
on_replica "SELECT pg_is_in_recovery() AS is_replica;"
on_replica "INSERT INTO customer (full_name, phone, customer_type) VALUES ('Chukwuemeka Obi', '08099990003', 'household') RETURNING id, full_name;"
on_replica "SELECT count(*) AS requests_still_present FROM delivery_request;"
echo
echo "The old primary is now out of date and must not be restarted as a"
echo "primary. It would need to be rebuilt as a replica of the new primary."
echo "Rerunning this script rebuilds the pair from scratch."
} 2>&1 | tee "$HERE/pg-replication-demo-output.txt"
