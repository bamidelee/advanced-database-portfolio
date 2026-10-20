#!/usr/bin/env bash
# =====================================================================
# AquaFlow - MongoDB Replica Set Demonstration
# MIT 8103 Advanced Database Systems - Portfolio 5
#
# Builds a fresh three-member replica set (rs0), then demonstrates:
#   1. Topology and the default write concern
#   2. Replicated writes with different write concerns
#   3. Automatic failover when the primary fails
#   4. Writes waiting for all members while one is down
#   5. Losing the majority: writes refused, stale reads still possible
#   6. Recovery: members rejoin, catch up and agree
#
# Usage (from the repository root):
#   bash portfolio-5-distributed-cloud/mongo/mongo-replicaset-demo.sh
#
# Takes about 2 minutes. Output is saved to
# mongo/mongo-replicaset-demo-output.txt.
# =====================================================================

set -e
export MSYS_NO_PATHCONV=1

HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $HERE/../docker-compose.yml"
NODES="mongo1 mongo2 mongo3"

# How to reach each member. DEMO_LOCAL is only used for testing the
# script against local mongod processes instead of Docker containers.
if [ -n "$DEMO_LOCAL" ]; then
  host_of()    { echo "127.0.0.1:2720${1#mongo}"; }
  mongosh_in() { shift; mongosh "$@"; }
  node_crash() { pkill -9 -f -- "--port 2720${1#mongo} " || true; }
  node_start() { mongod --replSet rs0 --port "2720${1#mongo}" --dbpath "/tmp/rs/m${1#mongo}" --bind_ip 127.0.0.1 --fork --logpath "/tmp/rs/m${1#mongo}.log" > /dev/null; }
else
  host_of()    { echo "$1:27017"; }
  mongosh_in() { local node=$1; shift; docker exec "aquaflow-$node" mongosh "$@"; }
  # docker kill sends SIGKILL: the member dies instantly without stepping
  # down, like a power or hardware failure. (docker stop would shut it
  # down cleanly, handing over to another member first.)
  node_crash() { $COMPOSE kill "$1" 2>&1 | tail -1; }
  node_start() { $COMPOSE start "$1" 2>&1 | tail -1; }
fi

SET_URI="mongodb://$(host_of mongo1),$(host_of mongo2),$(host_of mongo3)/aquaflow?replicaSet=rs0&serverSelectionTimeoutMS=5000"

# Run JavaScript against the replica set (the driver finds the primary),
# from inside a member that is currently running
on_set()    { local via=$1; shift; mongosh_in "$via" "$SET_URI" --quiet --eval "$*" 2>&1 || true; }
# Run JavaScript against one specific member only
on_member() { local node=$1; shift; mongosh_in "$node" "mongodb://$(host_of "$node")/aquaflow?directConnection=true" --quiet --eval "$*" 2>&1 || true; }

section() {
  echo
  echo "======================================================================"
  echo " $1"
  echo "======================================================================"
  [ -n "$2" ] && echo "$2" && echo
  return 0
}

STATUS_JS='rs.status().members.forEach(m => print("  " + m.name.padEnd(18) + m.stateStr.padEnd(26) + (m.health === 1 ? "up" : "DOWN")))'
COUNT_JS='db.getMongo().setReadPref("secondaryPreferred"); print(db.events.countDocuments())'

current_primary() {  # ask a running member which member is primary
  on_member "$1" 'print(db.hello().primary || "none")' | tail -1
}
# Note: helpers that loop with [ ... ] && echo end with "return 0", because
# under "set -e" a final non-matching comparison would otherwise stop the script
node_of() { for n in $NODES; do [ "$(host_of $n)" = "$1" ] && echo "$n"; done; return 0; }
other_than() {  # first member not in the given list
  for n in $NODES; do
    case " $* " in *" $n "*) ;; *) echo "$n"; return 0 ;; esac
  done
}

wait_for_primary() {  # $1 = a running member to ask; prints seconds waited
  local start=$(date +%s%N) p
  for _ in $(seq 1 120); do
    p=$(current_primary "$1")
    if [ "$p" != "none" ] && [ -n "$p" ]; then
      echo "$p $(( ($(date +%s%N) - start) / 1000000 ))"; return 0
    fi
    sleep 0.5
  done
  echo "none 0"
}

{
section "0. Fresh start" \
"Three mongod members are started and joined into replica set rs0.
mongo1 is given priority 2 so it is the preferred primary."
if [ -z "$DEMO_LOCAL" ]; then
  $COMPOSE rm -sf mongo1 mongo2 mongo3 > /dev/null 2>&1 || true
  $COMPOSE up -d mongo1 mongo2 mongo3 2>&1 | tail -1
fi
for n in $NODES; do
  for _ in $(seq 1 60); do
    [ "$(on_member "$n" 'print(db.adminCommand({ping: 1}).ok)' | tail -1)" = "1" ] && break
    sleep 1
  done
done
on_member mongo1 "printjson(rs.initiate({_id: 'rs0', members: [
  {_id: 0, host: '$(host_of mongo1)', priority: 2},
  {_id: 1, host: '$(host_of mongo2)', priority: 1},
  {_id: 2, host: '$(host_of mongo3)', priority: 1}]}).ok)" | sed 's/^/  rs.initiate ok: /'
read -r PRIMARY_HOST WAITED < <(wait_for_primary mongo1)
echo "  Primary elected after ${WAITED} ms: $PRIMARY_HOST"

section "1. Topology" \
"One PRIMARY accepts writes; the SECONDARY members copy its operation log
(oplog) and apply it. The default write concern is majority: a write is
only acknowledged once a majority of members (2 of 3) have it."
on_member mongo1 "$STATUS_JS"
on_member mongo1 'const c = db.adminCommand({getDefaultRWConcern: 1}); print("  Default write concern: " + JSON.stringify(c.defaultWriteConcern))'

section "2. Replicated writes" \
"Two delivery events are written through the replica set: one acknowledged
by a majority, one by all three members. Each member is then read
directly, and all three hold both documents."
on_set mongo1 'const r = db.events.insertOne({ event: "Delivery 300001 completed", at: new Date() }, { writeConcern: { w: "majority" } }); print("  w: majority -> acknowledged: " + r.acknowledged)'
on_set mongo1 'const r = db.events.insertOne({ event: "Payment PSTK-300001 recorded", at: new Date() }, { writeConcern: { w: 3, wtimeout: 5000 } }); print("  w: 3       -> acknowledged: " + r.acknowledged)'
for n in $NODES; do echo "  $n holds $(on_member "$n" "$COUNT_JS" | tail -1) events"; done

section "3. Automatic failover" \
"The primary's server fails without warning. The remaining members stop
receiving its heartbeats (sent every 2 seconds); after 10 seconds without
one (electionTimeoutMillis) they hold an election, and one becomes
primary. No operator acts."
OLD_PRIMARY=$(node_of "$PRIMARY_HOST")
SURVIVOR=$(other_than "$OLD_PRIMARY")
echo "  Killing the primary, $OLD_PRIMARY ..."
node_crash "$OLD_PRIMARY"
read -r NEW_PRIMARY_HOST WAITED < <(wait_for_primary "$SURVIVOR")
echo "  New primary elected after ${WAITED} ms: $NEW_PRIMARY_HOST"
on_member "$SURVIVOR" "$STATUS_JS"
echo
echo "  The application keeps writing through the same connection string;"
echo "  the driver finds the new primary itself:"
on_set "$SURVIVOR" 'const r = db.events.insertOne({ event: "Delivery 300002 completed during failover", at: new Date() }); print("  insert acknowledged: " + r.acknowledged)'

section "4. Waiting for a member that is down" \
"With 2 of 3 members up, majority writes still succeed. A write requiring
all 3 members times out, but it is NOT undone: it was applied on the two
running members, and will reach the third when it returns. A write
concern controls when the client is told about a write, not whether the
write happens."
on_set "$SURVIVOR" 'try {
  db.events.insertOne({ event: "Refund approved", at: new Date() }, { writeConcern: { w: 3, wtimeout: 3000 } });
  print("  w: 3 -> acknowledged");
} catch (e) { print("  w: 3 -> " + e.codeName + ": " + (e.writeConcernError ? e.writeConcernError.errmsg : e.message)); }'
for n in $NODES; do
  [ "$n" = "$OLD_PRIMARY" ] && { echo "  $n is down"; continue; }
  echo "  $n holds the refund event: $(on_member "$n" 'db.getMongo().setReadPref("secondaryPreferred"); print(db.events.countDocuments({ event: "Refund approved" }) === 1)' | tail -1)"
done

section "5. Losing the majority" \
"A second member fails. One member out of three is not a majority, so it
cannot know whether the others have elected a primary of their own on
the far side of a network split. To avoid two primaries accepting
conflicting writes (split brain), it refuses to become primary. Writes
stop; reads that accept possibly stale data still work."
NEW_PRIMARY=$(node_of "$NEW_PRIMARY_HOST")
LAST=$(other_than "$OLD_PRIMARY" "$NEW_PRIMARY")
echo "  Killing $NEW_PRIMARY. Only $LAST remains."
node_crash "$NEW_PRIMARY"
sleep 12
on_member "$LAST" "$STATUS_JS"
echo
# Connect allowing secondaries, so the connection succeeds and the write
# itself is what gets refused
mongosh_in "$LAST" "${SET_URI}&readPreference=secondaryPreferred" --quiet --eval 'const t0 = Date.now();
try {
  db.events.insertOne({ event: "Delivery 300003 completed", at: new Date() });
  print("  write -> acknowledged (unexpected)");
} catch (e) {
  print("  write -> refused after " + ((Date.now() - t0) / 1000).toFixed(1) + "s: " + e.name +
        " (no primary could be found; serverSelectionTimeoutMS is 5000)");
}' 2>&1 || true
mongosh_in "$LAST" "${SET_URI}&readPreference=secondaryPreferred" --quiet --eval \
  'print("  read with readPreference secondaryPreferred -> " + db.events.countDocuments() + " events")' 2>&1 || true

section "6. Recovery" \
"Both failed members return. They rejoin, copy the operations they missed
from the oplog, and an election restores a primary. mongo1 has the
highest priority, so once it has caught up it takes over as primary."
node_start "$OLD_PRIMARY"
node_start "$NEW_PRIMARY"
read -r PRIMARY_HOST WAITED < <(wait_for_primary "$LAST")
echo "  Primary available again after ${WAITED} ms: $PRIMARY_HOST"
for _ in $(seq 1 30); do
  [ "$(current_primary "$LAST")" = "$(host_of mongo1)" ] && break
  sleep 1
done
on_member "$LAST" "$STATUS_JS"
echo
for n in $NODES; do
  for _ in $(seq 1 20); do
    c=$(on_member "$n" "$COUNT_JS" | tail -1)
    [ "$c" = "4" ] && break
    sleep 1
  done
  echo "  $n holds $c events"
done
} 2>&1 | tee "$HERE/mongo-replicaset-demo-output.txt"
