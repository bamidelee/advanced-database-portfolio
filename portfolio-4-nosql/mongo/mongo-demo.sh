#!/usr/bin/env bash
# =====================================================================
# AquaFlow - MongoDB Demonstration: Delivery Documents and GPS History
# MIT 8103 Advanced Database Systems - Portfolio 4
#
# 1. Creates the collections (validation, indexes, time series)
# 2. Exports deliveries and GPS routes from PostgreSQL as JSON and
#    imports them with mongoimport
# 3. Runs the demonstration queries
#
# Usage (from anywhere, with aquaflow-db and aquaflow-mongo running):
#   bash portfolio-4-nosql/mongo/mongo-demo.sh
#
# Output is printed and saved to mongo/mongo-demo-output.txt.
# =====================================================================

set -e
export MSYS_NO_PATHCONV=1

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${DEMO_DIR:-/portfolio/portfolio-4-nosql/mongo}"
PG="${DEMO_PG:-docker exec aquaflow-db psql -X -q -U postgres -d aquaflow}"
MONGOSH="${DEMO_MONGOSH:-docker exec aquaflow-mongo mongosh aquaflow --quiet}"
MONGOIMPORT="${DEMO_MONGOIMPORT:-docker exec -i aquaflow-mongo mongoimport --db aquaflow}"

{
echo "======================================================================"
echo " Setup: collections, validator, indexes, time-series collection"
echo "======================================================================"
$MONGOSH --file "$DIR/setup.js"

echo
echo "======================================================================"
echo " Import: PostgreSQL -> JSON -> MongoDB"
echo "======================================================================"
echo "Deliveries from the last 60 days:"
IMPORT_LOG=$($PG -f "$DIR/export-deliveries.sql" | $MONGOIMPORT --collection deliveries 2>&1 || true)
echo "$IMPORT_LOG" | grep "imported successfully" | sed 's/^[0-9T:.+-]*\t/  /'
echo "  Rejected by the \$jsonSchema validator: $(echo "$IMPORT_LOG" | grep -c "failed validation" || true)"
echo "GPS routes for trips completed in the last 7 days:"
$PG -f "$DIR/export-positions.sql" | $MONGOIMPORT --collection tanker_positions 2>&1 |
  grep -E "imported successfully" | sed 's/^[0-9T:.+-]*\t/  /'

$MONGOSH --file "$DIR/queries.js"
} 2>&1 | tee "$HERE/mongo-demo-output.txt"
