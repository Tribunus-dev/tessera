#!/bin/bash
# Embedded Postgres init helper for Flatpak — first-run initdb + pg_ctl start
# Called by tessera-studio-linux on startup if XDG_DATA_HOME/tessera/pgdata missing
set -e
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/tessera/pgdata"
if [ ! -f "$DATA_DIR/PG_VERSION" ]; then
    echo "Initializing embedded Postgres at $DATA_DIR"
    mkdir -p "$(dirname "$DATA_DIR")"
    # initdb with trust auth for single-user embedded use; Flatpak docs recommend scram-sha-256 for multi-user
    initdb -D "$DATA_DIR" --auth=trust --no-locale --encoding=UTF8 -U tessera
    cat >> "$DATA_DIR/postgresql.conf" <<EOF
listen_addresses = '127.0.0.1'
port = 5432
max_connections = 20
shared_buffers = 128MB
EOF
    echo "host all all 127.0.0.1/32 trust" >> "$DATA_DIR/pg_hba.conf"
fi
if ! pg_isready -h 127.0.0.1 -p 5432 -q 2>/dev/null; then
    echo "Starting embedded Postgres"
    pg_ctl -D "$DATA_DIR" -l "$DATA_DIR/postgres.log" start
    # Create db if not exists
    createdb -h 127.0.0.1 -U tessera tessera 2>/dev/null || true
    # Run migrations if present
    if [ -f "/app/share/tessera/schema.sql" ]; then
        psql -h 127.0.0.1 -U tessera -d tessera -f /app/share/tessera/schema.sql 2>/dev/null || true
    fi
fi
echo "Embedded Postgres ready"
