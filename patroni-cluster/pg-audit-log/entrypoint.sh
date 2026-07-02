#!/bin/bash
set -e

setup_audit_schema() {
    export PGPASSWORD="$POSTGRES_PASSWORD"
    gosu postgres psql -U postgres -f /sql/init-audit.sql
}

if [ "$1" = 'postgres' ]; then
    if [ ! -s "$PGDATA/PG_VERSION" ]; then
        mkdir -p "$PGDATA"
        chown -R postgres:postgres "$PGDATA"

        echo "$POSTGRES_PASSWORD" > /tmp/pwfile
        gosu postgres initdb -D "$PGDATA" --locale=en_US.utf8 --auth=md5 --username=postgres --pwfile=/tmp/pwfile
        rm -f /tmp/pwfile

        echo "host all all 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"

        gosu postgres pg_ctl -D "$PGDATA" -l /tmp/pg_init.log start
        until gosu postgres pg_isready -U postgres 2>/dev/null; do
            sleep 1
        done

        setup_audit_schema

        gosu postgres pg_ctl -D "$PGDATA" -m fast stop
    else
        gosu postgres pg_ctl -D "$PGDATA" -l /tmp/pg_init.log start
        until gosu postgres pg_isready -U postgres 2>/dev/null; do
            sleep 1
        done

        export PGPASSWORD="$POSTGRES_PASSWORD"
        gosu postgres psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='shop'" 2>/dev/null | grep -q 1 || setup_audit_schema

        gosu postgres pg_ctl -D "$PGDATA" -m fast stop
    fi
fi

echo "host all all 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"

exec docker-entrypoint.sh "$@"
