#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Физическая (streaming) реплика
# При первом запуске (PGDATA пуст):
#   1. pg_basebackup через HAProxy (ждёт готовности мастера)
#   2. Создаёт symlink /data/pgdata → $PGDATA — Patroni использует
#      data_dir=/data/pgdata, поэтому внутри бэкапа все пути
#      привязаны к /data/pgdata, а PGDATA контейнера = /var/lib/postgresql/data
#   3. Настраивает primary_conninfo для streaming replication
#   4. Передаёт управление стандартному docker-entrypoint.sh
# После перезапуска (PGDATA не пуст) — сразу запускает PostgreSQL
# ═══════════════════════════════════════════════════════════════
set -e

# Symlink /data/pgdata → $PGDATA — нужен всегда, не только при первом запуске.
# Patroni на мастере использует data_dir=/data/pgdata, поэтому скопированные
# pg_basebackup конфиги (pg_hba.conf, postgresql.conf) содержат пути /data/pgdata/.
# Symlink решает это несоответствие при любом запуске контейнера.
mkdir -p /data
ln -sfn "$PGDATA" /data/pgdata

if [ "$1" = 'postgres' ] && [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "Physical replica: data directory is empty, running pg_basebackup from haproxy..."
    until pg_basebackup -h haproxy -p 5432 -U replicator -D "$PGDATA" -P -v --wal-method=stream 2>/dev/null; do
        echo "Physical replica: retrying pg_basebackup in 5s (HAProxy may not be ready)..."
        sleep 5
    done

    cat >> "$PGDATA/postgresql.auto.conf" <<- EOF
primary_conninfo = 'host=haproxy port=5432 user=replicator password=replicator application_name=pg_physical_replica'
EOF
    touch "$PGDATA/standby.signal"
    echo "Physical replica: basebackup complete, starting in standby mode"
fi

exec docker-entrypoint.sh "$@"
