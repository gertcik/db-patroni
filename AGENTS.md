# AGENTS.md — db-patroni

## Quick start

```bash
cd patroni-cluster
docker compose build
docker compose up -d
```

Web UI: http://localhost:80 — `admin@admin.com` / `admin`

## Architecture

- **3 Patroni nodes** (patroni1-3) — PostgreSQL 18 managed by Patroni, etcd for DCS
- **HAProxy** — single R/W endpoint to master (`:5432`), stats at `:7000`
- **pg-physical-replica** (`:5433`) — streaming WAL standby, `pg_basebackup` from HAProxy on first boot
- **pg-logical-replica** (`:5434`) — logical replication via `shop_pub` publication and `shop_sub` subscription
- **pg-audit-log** (`:5435`) — append-only audit log via WAL consumer (Java 17), reads `audit_slot`
- **pgAdmin** (`:80`) — pre-registered servers via `pgadmin/servers.json`
- All services on Docker network `patroni-net`

## Key commands

| Action | Command |
|--------|---------|
| Check cluster state | `docker compose exec patroni1 patronictl list` |
| Check master via SQL | `psql -h localhost -p 5432 -U postgres -d shop -c "SELECT inet_server_addr();"` |
| Check master via REST | `curl -s http://localhost:7000` (HAProxy stats page) |
| Stop master (failover test) | `docker compose stop <master-name>` |
| Check physical replication lag | `SELECT application_name, state, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag FROM pg_stat_replication;` |
| Check logical slot lag (shop_sub + audit_slot) | `SELECT slot_name, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag FROM pg_replication_slots WHERE slot_type = 'logical';` |
| Check logical apply lag on replica | `SELECT subname, pg_size_pretty(pg_wal_lsn_diff(latest_end_lsn, application_lsn)) AS lag FROM pg_stat_subscription;` |
| Check all replication lag (summary) | `WITH phys AS (SELECT 'physical' AS t, application_name, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag FROM pg_stat_replication), slots AS (SELECT 'logical:'||slot_name AS t, pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag FROM pg_replication_slots WHERE slot_type = 'logical') SELECT t, CASE WHEN lag IS NULL THEN 'no data' ELSE pg_size_pretty(lag) END AS lag FROM (SELECT t, lag FROM phys UNION ALL SELECT t, lag FROM slots) x ORDER BY lag DESC NULLS LAST;` |
| Check audit consumer logs | `docker compose logs pg-audit-consumer` |
| Build all services | `docker compose build` |
| Build with specific Patroni | `docker compose build --build-arg PATRONI_VERSION=4.1.5` |
| Reset volumes | `docker compose down -v` |

## Database conventions

- **App DB**: `shop` (created by `patroni/init.sh` on first bootstrap)
- **Tables**: `bookings.*` (9 tables: airplanes, airports, seats, routes, flights, bookings, tickets, segments, boarding_passes) — демо «Авиаперевозки»
- **Users**: `postgres` / `secret` (superuser), `replicator` / `replicator` (replication)
- **wal_level**: `logical` (set in Patroni config)

## Maintenance

### After leader change (failover / switchover)

| Component | Behaviour | Manual action needed? |
|-----------|-----------|-----------------------|
| Patroni nodes | New leader elected, replicas follow | **None** |
| HAProxy (:5432) | Health checks detect new master via `:8008` API | **None** |
| Physical replica | Continues streaming from new master via HAProxy | **None** |
| Logical slot `shop_sub` | Permanent slot already exists on new leader (configured in `bootstrap.dcs.slots`) | **None** |
| Logical slot `audit_slot` | Permanent slot for WAL consumer (configured in `bootstrap.dcs.slots`) | **None** |
| Logical apply worker | Detects new master, reconnects to slot `shop_sub` | **Possibly** — if `pg_stat_subscription` is empty 5 min after failover, restart worker (see below) |
| WAL consumer (pg-audit) | Reconnects to new master via HAProxy, slot survives via DCS | **None** |
| App via HAProxy :5432 | Transparently routed to new master | **None** |
| DDL execution | Must be done on new master (as before) | **None** |

**If logical replication apply worker doesn't restart on its own:**
```sql
-- on pg-logical-replica
ALTER SUBSCRIPTION shop_sub DISABLE;
ALTER SUBSCRIPTION shop_sub ENABLE;
```

### DDL changes

- **DDL only on Patroni master** — physical replica gets DDL via WAL (auto), logical replica needs **manual DDL + ALTER PUBLICATION**
- DDL on master requires matching DDL on logical replica, or subscription breaks
- Use `ALTER SUBSCRIPTION shop_sub DISABLE` before mass DDL, re-enable after

### Logical replication slots

Logical slot `shop_sub` is configured as a **permanent replication slot** in Patroni DCS (`bootstrap.dcs.slots`). This ensures:

- Slot is created on every new leader after failover/switchover automatically
- Slot info is copied to standby nodes, so the downstream subscriber can reconnect without manual intervention
- Patroni advances slot position on standbys via `pg_replication_slot_advance()`

**Adding a new permanent slot:**
```yaml
# in bootstrap.dcs.slots in docker-compose.yml, or via:
# patronictl edit-config
slots:
  my_slot_name:
    type: logical
    database: shop
    plugin: pgoutput
```
Then recreate the subscription referencing `my_slot_name`.

### Logical replica corruption

Если логическая реплика испорчена (например, удалена таблица, нарушена ссылочная целостность, ошибка apply), проще всего пересоздать её с нуля.

**Быстрый способ — пересоздать контейнер:**
```bash
docker compose rm -sf pg-logical-replica
docker compose up -d pg-logical-replica
```
Контейнер запустится заново, entrypoint обнаружит существующий `PGDATA` и создаст подписку заново (через `elif` ветку).

**Ручной способ (если нужно сохранить контейнер):**

1. Зайти на логическую реплику:
```bash
docker compose exec pg-logical-replica bash
```

2. Удалить подписку:
```sql
DROP SUBSCRIPTATION IF EXISTS shop_sub;
```

3. Удалить данные (все таблицы схемы bookings):
```sql
DROP SCHEMA bookings CASCADE;
```

4. Выйти из psql, остановить PostgreSQL, удалить PGDATA, пересоздать:
```bash
gosu postgres pg_ctl -D "$PGDATA" -m fast stop
rm -rf "$PGDATA"/*
exit
docker compose stop pg-logical-replica
docker compose rm -f pg-logical-replica
docker compose up -d pg-logical-replica
```
Контейнер выполнит полную переинициализацию: initdb → создание таблиц → CREATE SUBSCRIPTION с `copy_data = true`.

## Backlog workflow

```
backlog/
├── 01 - wait/       # Pending tasks
├── 02 - work/       # In-progress
└── 03 - finisher/   # Completed
```

Move `.md` files between dirs to track state. Files use frontmatter-style fields (Status, Priority, Created, Deadline) plus DoD checkboxes.

## Files of interest

- `patroni-cluster/docker-compose.yml` — single source of truth for topology
- `patroni-cluster/patroni/init.sh` — bootstrap DDL, test data, publication
- `patroni-cluster/replica-physical/entrypoint.sh` — physical replica init
- `patroni-cluster/replica-logical/entrypoint.sh` — logical replica init
- `patroni-cluster/pgadmin/servers.json` — pgAdmin auto-registration
- `patroni-cluster/haproxy/haproxy.cfg` — HAProxy config
- `README.md` — index (~165 lines, links to docs/*, requirements traceability, primary requirements status)
- `docs/components.md` — components, architecture, build
- `docs/replication.md` — DML replication, audit log, slot recovery
- `docs/maintenance.md` — DDL, indexes, logical replica recovery
- `docs/monitoring.md` — metrics, known limitations, Windows issues
- `docs/issues.md` — hot standby limitations, Postgres Pro Enterprise 18.4.1
- `backlog/README.md` — backlog conventions
