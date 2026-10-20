#!/bin/bash
# Runs once, when the primary's data directory is first created.
# Creates the account the replica uses to stream WAL, and allows it to
# connect for replication from other containers on the Docker network.
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_pw';"
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
