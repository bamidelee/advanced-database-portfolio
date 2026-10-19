#!/usr/bin/env bash
# =====================================================================
# AquaFlow - Redis Demonstration: Live Tanker Locations and Matching
# MIT 8103 Advanced Database Systems - Portfolio 4
#
# Loads live tanker state from PostgreSQL into Redis, then demonstrates
# geospatial search, server-side matching in Lua, atomic location
# updates, expiring heartbeats, first-accept-wins claims, and
# throughput. Every command is printed before its result.
#
# Usage (from anywhere, with aquaflow-db and aquaflow-redis running):
#   bash portfolio-4-nosql/redis/redis-demo.sh
#
# Output is printed and saved to redis/redis-demo-output.txt.
# =====================================================================

set -e
export MSYS_NO_PATHCONV=1

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${DEMO_DIR:-/portfolio/portfolio-4-nosql/redis}"
PG="${DEMO_PG:-docker exec aquaflow-db psql -X -q -U postgres -d aquaflow}"
RC="${DEMO_REDIS:-docker exec -i aquaflow-redis redis-cli}"
BENCH="${DEMO_BENCH:-docker exec aquaflow-redis redis-benchmark}"

section() {
  echo
  echo "======================================================================"
  echo " $1"
  echo "======================================================================"
  [ -n "$2" ] && echo "$2" && echo
  return 0
}
run() {
  echo "> $*"
  local out
  out=$($RC "$@")
  # redis-cli prints nothing for a nil reply when not attached to a terminal
  [ -z "$out" ] && out="(nil)"
  echo "$out"
  echo
}

# Distance in km from the customer to one tanker, read from the live geo set
distance_to_customer() {
  $RC GEOSEARCH geo:tankers FROMLONLAT "$LNG" "$LAT" BYRADIUS 20 km ASC WITHDIST |
    awk -v t="$1" 'prev == t { print $0 " km"; exit } { prev = $0 }'
}

{
section "1. Load live tanker state from PostgreSQL" \
"PostgreSQL remains the system of record. Redis holds the fast-changing
live state: positions, availability and heartbeats."
$PG -f "$DIR/load-tankers.sql" | $RC > /dev/null
run ZCARD geo:tankers
run ZCARD geo:tankers:available
run DBSIZE
run MEMORY USAGE geo:tankers

# A real customer address to search from (Victoria Island)
read -r ADDRESS LAT LNG < <($PG -At -F' ' -c \
  "SELECT id, latitude, longitude FROM address WHERE service_area_id = 3 ORDER BY id LIMIT 1")
echo "Customer address $ADDRESS is at latitude $LAT, longitude $LNG"

section "2. The data model" \
"Each tanker is a hash. Positions are in a geo set, which Redis stores as
a sorted set scored by a 52-bit geohash, so nearby points have nearby
scores and a radius search is a range scan."
FIRST=$($RC GEOSEARCH geo:tankers:available FROMLONLAT "$LNG" "$LAT" BYRADIUS 5 km ASC COUNT 1)
run HGETALL "tanker:$FIRST"
run TYPE geo:tankers
run ZSCORE geo:tankers "$FIRST"
run GEOPOS geo:tankers "$FIRST"
run TTL "tanker:$FIRST:alive"

section "3. Nearest available tankers to the customer" \
"GEOSEARCH returns the closest available tankers within 2 km, nearest first."
run GEOSEARCH geo:tankers:available FROMLONLAT "$LNG" "$LAT" BYRADIUS 2 km ASC WITHDIST COUNT 5

section "4. Matching inside Redis with a Lua script" \
"The customer needs 15,000 litres. match.lua searches by distance, then
skips tankers whose heartbeat has expired or that are too small, all in
one atomic server-side step."
echo "> redis-cli --eval match.lua geo:tankers:available , $LNG $LAT 3 15000 5"
$RC --eval "$DIR/match.lua" geo:tankers:available , "$LNG" "$LAT" 3 15000 5
echo
T=$($RC --eval "$DIR/match.lua" geo:tankers:available , "$LNG" "$LAT" 3 15000 5 | head -1 | awk '{print $2}')
U=$($RC --eval "$DIR/match.lua" geo:tankers:available , "$LNG" "$LAT" 3 15000 5 | sed -n '5p' | awk '{print $2}')
echo "Best match: tanker $T. Second match: tanker $U."

section "5. First accept wins" \
"Two vendors accept request 9001 at the same moment. SET ... NX only
succeeds if the key does not exist yet, and Redis executes commands one
at a time, so exactly one claim succeeds. EX 30 releases the claim
automatically if the vendor's app never confirms."
$RC DEL request:9001:accepted > /dev/null   # clear any claim left by a previous run
run SET request:9001:accepted "tanker:$T" NX EX 30
run SET request:9001:accepted "tanker:$U" NX EX 30
run GET request:9001:accepted
run TTL request:9001:accepted

section "6. Tanker becomes busy" \
"MULTI/EXEC applies both changes as one unit: removed from the matching
set and its status updated. Matching no longer returns it."
echo "> MULTI / ZREM geo:tankers:available $T / HSET tanker:$T status busy / EXEC"
printf 'MULTI\nZREM geo:tankers:available %s\nHSET tanker:%s status busy\nEXEC\n' "$T" "$T" | $RC
echo
echo "> redis-cli --eval match.lua geo:tankers:available , $LNG $LAT 3 15000 5"
$RC --eval "$DIR/match.lua" geo:tankers:available , "$LNG" "$LAT" 3 15000 5
echo

section "7. Live location updates while driving to the customer" \
"Each GPS ping updates the position, the hash and the heartbeat in one
MULTI/EXEC transaction. GEOADD on an existing member moves it."
read -r TLNG TLAT < <($RC GEOPOS geo:tankers "$T" | tr '\n' ' '; echo)
echo "Distance before driving: $(distance_to_customer "$T")"
for step in 1 2 3; do
  NLNG=$(awk -v a="$TLNG" -v b="$LNG" -v s="$step" 'BEGIN { printf "%.6f", a + (b - a) * s / 3.2 }')
  NLAT=$(awk -v a="$TLAT" -v b="$LAT" -v s="$step" 'BEGIN { printf "%.6f", a + (b - a) * s / 3.2 }')
  echo "> MULTI / GEOADD geo:tankers $NLNG $NLAT $T / HSET tanker:$T lat $NLAT lng $NLNG / SET tanker:$T:alive 1 EX 60 / EXEC"
  printf 'MULTI\nGEOADD geo:tankers %s %s %s\nHSET tanker:%s lat %s lng %s\nSET tanker:%s:alive 1 EX 60\nEXEC\n' \
    "$NLNG" "$NLAT" "$T" "$T" "$NLAT" "$NLNG" "$T" | $RC > /dev/null
  echo "  Ping $step: $(distance_to_customer "$T") from the customer"
done

section "8. Heartbeat expiry" \
"Tanker $U's app stops reporting. Its heartbeat key was given a 2 second
lifetime; once it expires, matching skips the tanker even though it is
still in the available set. No cleanup job is needed for correctness."
run SET "tanker:$U:alive" 1 EX 2
run TTL "tanker:$U:alive"
echo "(waiting 3 seconds)"
sleep 3
run EXISTS "tanker:$U:alive"
echo "> redis-cli --eval match.lua geo:tankers:available , $LNG $LAT 3 15000 5"
$RC --eval "$DIR/match.lua" geo:tankers:available , "$LNG" "$LAT" 3 15000 5
echo

section "9. Throughput" \
"redis-benchmark runs 20,000 nearest-tanker searches from 50 parallel
clients."
echo "> redis-benchmark -n 20000 -c 50 -q GEOSEARCH geo:tankers:available FROMLONLAT $LNG $LAT BYRADIUS 3 km ASC WITHDIST COUNT 10"
# Keep only the final summary line (the benchmark redraws a progress line)
$BENCH -n 20000 -c 50 -q GEOSEARCH geo:tankers:available FROMLONLAT "$LNG" "$LAT" BYRADIUS 3 km ASC WITHDIST COUNT 10 |
  tr '\r' '\n' | grep 'requests per second'
echo
} 2>&1 | tee "$HERE/redis-demo-output.txt"
