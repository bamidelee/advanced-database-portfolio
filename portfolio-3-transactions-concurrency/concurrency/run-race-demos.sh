#!/usr/bin/env bash
# =====================================================================
# AquaFlow - Race Condition Demonstrations
# MIT 8103 Advanced Database Systems - Portfolio 3
#
# Runs each scenario as two real PostgreSQL sessions started at the
# same time. Each session logs timestamped events; the two logs are
# then merged into a single timeline showing who did what, when, and
# how long each was blocked waiting for the other.
#
# Usage (from anywhere, with the aquaflow-db container running):
#   bash portfolio-3-transactions-concurrency/concurrency/run-race-demos.sh
#
# Output is printed and saved under concurrency/output/.
# =====================================================================

set -e
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: keep /portfolio/... paths intact

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/output"
DIR="${DEMO_DIR:-/portfolio/portfolio-3-transactions-concurrency/concurrency}"
PSQL="${DEMO_PSQL:-docker exec aquaflow-db psql -X -q -U postgres -d aquaflow}"
TMP="${TMPDIR:-/tmp}"
mkdir -p "$OUT"

# Merge two session logs into one timeline ordered by elapsed time.
# Lines without a timestamp (error detail, continuation lines) stay
# attached to the event before them.
merge_logs() {
  local log_a=$1 label_a=$2 log_b=$3 label_b=$4
  for pair in "1|$label_a|$log_a" "2|$label_b|$log_b"; do
    IFS='|' read -r order label file <<< "$pair"
    sed -E 's/^psql:[^:]*:[0-9]+: //' "$file" | awk -v o="$order" -v l="$label" '
      NF == 0 { next }
      match($0, /^[0-9]+\.[0-9]{3}s  /) {
        ts = substr($0, 1, RLENGTH - 3); msg = substr($0, RLENGTH + 1)
        printf "%s\t%s\t%06d\t%s\t%s\t%s\n", ts, o, NR, l, ts "s", msg; next
      }
      { printf "%s\t%s\t%06d\t%s\t%s\t%s\n", (ts == "" ? 0 : ts), o, NR, l, "", $0 }'
  done | sort -t$'\t' -k1,1n -k2,2n -k3,3n |
    awk -F'\t' '{ printf "%8s  %-9s | %s\n", $5, $4, $6 }'
}

scenario() {
  local name=$1 title=$2 setup=$3 a=$4 label_a=$5 b=$6 label_b=$7 verify=$8
  local out="$OUT/$name.txt"
  {
    echo "======================================================================"
    echo " $title"
    echo "======================================================================"
    $PSQL -f "$DIR/$setup" 2>&1
    $PSQL -f "$DIR/$a" > "$TMP/aquaflow_a.log" 2>&1 &
    local pid_a=$!
    $PSQL -f "$DIR/$b" > "$TMP/aquaflow_b.log" 2>&1 &
    local pid_b=$!
    wait "$pid_a" "$pid_b"
    merge_logs "$TMP/aquaflow_a.log" "$label_a" "$TMP/aquaflow_b.log" "$label_b"
    $PSQL -f "$DIR/$verify" 2>&1
    echo
  } | tee "$out"
}

$PSQL -f "$DIR/demo-helpers.sql" > /dev/null

# Scenario 3a demonstrates double-booking, which is only possible before
# the guard index from 3c exists. Remove it so a rerun replays the full
# sequence; 3c cleans up and recreates it.
$PSQL -c "DROP INDEX IF EXISTS one_live_trip_per_tanker" > /dev/null

scenario 02a-request-race-naive \
  "2a. Two vendors accept the same request - plain SQL, no locking" \
  02-setup-request-race.sql 02a-naive-vendor1.sql "Vendor 1" 02a-naive-vendor2.sql "Vendor 2" 02-verify.sql

scenario 02b-request-race-locked \
  "2b. Two vendors accept the same request - assign_trip() with FOR UPDATE" \
  02-setup-request-race.sql 02b-locked-vendor1.sql "Vendor 1" 02b-locked-vendor2.sql "Vendor 2" 02-verify.sql

scenario 03a-tanker-race-naive \
  "3a. One tanker accepted for two requests - plain SQL, no locking" \
  03-setup-tanker-race.sql 03a-naive-driver1.sql "Driver 1" 03a-naive-driver2.sql "Driver 2" 03-verify.sql

scenario 03b-tanker-race-locked \
  "3b. One tanker accepted for two requests - assign_trip() with FOR UPDATE" \
  03-setup-tanker-race.sql 03b-locked-driver1.sql "Driver 1" 03b-locked-driver2.sql "Driver 2" 03-verify.sql

echo "======================================================================"
echo " 3c. Adding a database guard against double-booking"
echo "======================================================================"
$PSQL -f "$DIR/03c-add-tanker-guard.sql" 2>&1 | tee "$OUT/03c-add-tanker-guard.txt"
echo

scenario 03c-tanker-race-naive-guarded \
  "3c. One tanker, two requests - plain SQL again, now with the guard index" \
  03-setup-tanker-race.sql 03a-naive-driver1.sql "Driver 1" 03a-naive-driver2.sql "Driver 2" 03-verify.sql

echo "Saved timelines in $OUT"
