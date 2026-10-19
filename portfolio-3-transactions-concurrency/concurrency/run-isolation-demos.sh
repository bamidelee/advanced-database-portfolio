#!/usr/bin/env bash
# =====================================================================
# AquaFlow - Isolation Level and Deadlock Demonstrations
# MIT 8103 Advanced Database Systems - Portfolio 3
#
# Same two-session method as run-race-demos.sh. Scenarios 4 and 5 run
# twice at different isolation levels to show which anomalies each
# level allows. Scenario 6 reproduces a deadlock and its prevention.
#
# Usage (from anywhere, with the aquaflow-db container running):
#   bash portfolio-3-transactions-concurrency/concurrency/run-isolation-demos.sh
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

# Like run-race-demos.sh, plus an isolation level passed to both sessions
scenario() {
  local name=$1 title=$2 setup=$3 a=$4 label_a=$5 b=$6 label_b=$7 verify=$8
  local iso="${9:-read committed}"
  local out="$OUT/$name.txt"
  {
    echo "======================================================================"
    echo " $title"
    echo "======================================================================"
    $PSQL -f "$DIR/$setup" 2>&1
    $PSQL -v "iso=$iso" -f "$DIR/$a" > "$TMP/aquaflow_a.log" 2>&1 &
    local pid_a=$!
    $PSQL -v "iso=$iso" -f "$DIR/$b" > "$TMP/aquaflow_b.log" 2>&1 &
    local pid_b=$!
    wait "$pid_a" "$pid_b"
    merge_logs "$TMP/aquaflow_a.log" "$label_a" "$TMP/aquaflow_b.log" "$label_b"
    $PSQL -f "$DIR/$verify" 2>&1
    echo
  } | tee "$out"
}

$PSQL -f "$DIR/demo-helpers.sql" > /dev/null 2>&1

scenario 04a-payout-read-committed \
  "4a. Vendor payout during a delivery - READ COMMITTED" \
  04-setup-payout.sql 04-finance.sql "Finance" 04-driver.sql "Driver" 04-verify.sql "read committed"

scenario 04b-payout-repeatable-read \
  "4b. Vendor payout during a delivery - REPEATABLE READ" \
  04-setup-payout.sql 04-finance.sql "Finance" 04-driver.sql "Driver" 04-verify.sql "repeatable read"

scenario 05a-write-skew-repeatable-read \
  "5a. Two staff take drivers off duty - REPEATABLE READ" \
  05-setup-write-skew.sql 05-ops1.sql "Staff 1" 05-ops2.sql "Staff 2" 05-verify.sql "repeatable read"

scenario 05b-write-skew-serializable \
  "5b. Two staff take drivers off duty - SERIALIZABLE" \
  05-setup-write-skew.sql 05-ops1.sql "Staff 1" 05-ops2.sql "Staff 2" 05-verify.sql "serializable"

scenario 06a-deadlock \
  "6a. Two staff update the same two tankers in opposite order" \
  06-setup-deadlock.sql 06a-staff1.sql "Staff 1" 06a-staff2.sql "Staff 2" 06-verify.sql

scenario 06b-deadlock-prevented \
  "6b. The same updates, with both tankers locked up front in id order" \
  06-setup-deadlock.sql 06b-staff1.sql "Staff 1" 06b-staff2.sql "Staff 2" 06-verify.sql

echo "Saved timelines in $OUT"
