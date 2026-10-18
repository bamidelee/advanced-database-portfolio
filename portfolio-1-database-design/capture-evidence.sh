#!/usr/bin/env bash
# =====================================================================
# AquaFlow - Portfolio 1 Evidence Capture
# MIT 8103 Advanced Database Systems
#
# Runs the schema and constraint tests step by step, clearing the
# screen before each section and pausing so a screenshot can be taken.
# Also saves the full test output to constraint-tests-output.txt.
#
# Usage (from anywhere, with the aquaflow-db container running):
#   bash portfolio-1-database-design/capture-evidence.sh
# =====================================================================

set -e

# Git Bash on Windows rewrites paths like /portfolio/... into Windows
# paths before passing them to docker. This disables that conversion.
export MSYS_NO_PATHCONV=1

CONTAINER="aquaflow-db"
DIR="/portfolio/portfolio-1-database-design"
PSQL="docker exec -it $CONTAINER psql -U postgres -d aquaflow -P pager=off"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

banner() {
  clear
  echo "================================================================"
  echo " $1"
  echo "================================================================"
  echo
}

screenshot() {
  echo
  echo ">>> TAKE SCREENSHOT $1 NOW (save as $2), then press Enter"
  read -r
}

# ---------------------------------------------------------------------
if ! docker ps --format '{{.Names}}' | grep -q "^$CONTAINER$"; then
  echo "Container '$CONTAINER' is not running. Start it with: docker compose up -d"
  exit 1
fi

# ---------------------------------------------------------------------
banner "SCREENSHOT 1 of 6: Applying schema.sql (last lines of output)"
docker exec "$CONTAINER" psql -U postgres -d aquaflow -v ON_ERROR_STOP=1 \
  -f "$DIR/schema.sql" 2>&1 | tail -n 20
screenshot 1 "schema-run.png"

# ---------------------------------------------------------------------
banner "SCREENSHOT 2 of 6: Tables created and constraint summary"
$PSQL -c '\dt'
$PSQL -c "
SELECT CASE contype
         WHEN 'p' THEN 'Primary key'
         WHEN 'f' THEN 'Foreign key'
         WHEN 'u' THEN 'Unique'
         WHEN 'c' THEN 'Check'
       END AS constraint_type,
       count(*) AS total
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace
GROUP BY contype
ORDER BY total DESC;"
screenshot 2 "tables-and-constraints.png"

# ---------------------------------------------------------------------
banner "SCREENSHOT 3 of 6: trip table structure, constraints and partial index"
$PSQL -c '\d trip'
screenshot 3 "trip-structure.png"

# ---------------------------------------------------------------------
# Screenshots 4 to 6 are prompted from inside constraint-tests.sql
clear
$PSQL -q -v pause=1 -f "$DIR/constraint-tests.sql"

# ---------------------------------------------------------------------
clear
echo "Saving full test output to constraint-tests-output.txt ..."
docker exec "$CONTAINER" psql -U postgres -d aquaflow -P pager=off -q \
  -f "$DIR/constraint-tests.sql" > "$SCRIPT_DIR/constraint-tests-output.txt" 2>&1

echo
echo "Done. Save your 6 screenshots in portfolio-1-database-design/screenshots/:"
echo "  1. schema-run.png"
echo "  2. tables-and-constraints.png"
echo "  3. trip-structure.png"
echo "  4. constraint-tests-1.png"
echo "  5. constraint-tests-2.png"
echo "  6. constraint-tests-3.png"
echo
echo "Then commit:"
echo "  git add portfolio-1-database-design"
echo "  git commit -m \"Add Portfolio 1 evidence screenshots and test output\""
