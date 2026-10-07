#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Физическая (streaming) реплика ВНЕ Patroni
# При первом запуске (PGDATA пуст):
#   1. pg_basebackup через HAProxy (ждёт готовности мастера)
#   2. Создаёт symlink /data/pgdata → $PGDATA: конфиги мастера
#      (hba_file/ident_file) привязаны к /data/pgdata, а PGDATA
#      контейнера = /var/lib/postgresql/data
#   3. Настраивает primary_conninfo + primary_slot_name в
#      postgresql.auto.conf: стриминг идёт через постоянный слот
#      pg_physical_replica на мастере (создаётся Patroni из
#      bootstrap.dcs.slots, переживает failover)
#   4. Передаёт управление стандартному docker-entrypoint.sh
# После перезапуска (PGDATA не пуст) — проверяет auto.conf и сразу
# запускает PostgreSQL
# ═══════════════════════════════════════════════════════════════
set -e

# Symlink /data/pgdata → $PGDATA нужен всегда, не только при первом запуске.
# pg_basebackup копирует конфиги мастера, где пути указаны как /data/pgdata/.
if [ "$PGDATA" != "/data/pgdata" ]; then
    mkdir -p /data
    ln -sfn "$PGDATA" /data/pgdata
fi

if [ "$1" = 'postgres' ] && [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "Physical replica: data directory is empty, running pg_basebackup from haproxy..."
    until pg_basebackup -h haproxy -p 5432 -U replicator -D "$PGDATA" -P -v --wal-method=stream 2>/dev/null; do
        echo "Physical replica: retrying pg_basebackup in 5s (HAProxy may not be ready)..."
        sleep 5
    done

    touch "$PGDATA/standby.signal"
    echo "Physical replica: basebackup complete, starting in standby mode"
fi

if [ "$1" = 'postgres' ] && [ -s "$PGDATA/PG_VERSION" ]; then
    # primary_conninfo: подключение к мастеру через HAProxy (идемпотентно)
    if ! grep -q "application_name=pg_physical_replica" "$PGDATA/postgresql.auto.conf" 2>/dev/null; then
        cat >> "$PGDATA/postgresql.auto.conf" <<- EOF
primary_conninfo = 'host=haproxy port=5432 user=replicator password=replicator application_name=pg_physical_replica'
EOF
    fi
    # primary_slot_name: постоянный слот на мастере (идемпотентно)
    if ! grep -q "primary_slot_name" "$PGDATA/postgresql.auto.conf" 2>/dev/null; then
        cat >> "$PGDATA/postgresql.auto.conf" <<- EOF
primary_slot_name = 'pg_physical_replica'
EOF
    fi
fi

exec docker-entrypoint.sh "$@"
