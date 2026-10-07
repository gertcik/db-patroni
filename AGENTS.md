# AGENTS.md — db-patroni

Docs, code comments, backlog and commit subjects are written in **Russian** — keep new prose in Russian.
Commit style: `(type): subject`, e.g. `(docs): ...`, `(feat): ...`.
Unless stated otherwise, all commands run from `patroni-cluster/`.

## Quick start

```bash
cd patroni-cluster
docker compose build
docker compose up -d
```

pgAdmin: http://localhost:80 — `admin@admin.com` / `admin`.
No lint/typecheck/CI in this repo — the only automated verification is the replication test suite (see Tests).

## Architecture

- **4 Patroni nodes** — `patroni1/2/3` (leader-capable) + `patroni4_readonly` (physical replica member, `tags.nofailover: true`): PostgreSQL 18, etcd DCS. `patroni4_readonly` can **never** become Leader — never run `patronictl promote patroni4_readonly`.
- **`pg-physical-replica`** — **not a Patroni member** (no etcd, no REST :8008, not in `patronictl list`). Plain slot-based streaming replica: `pg_basebackup` via HAProxy, `primary_conninfo` + `primary_slot_name = 'pg_physical_replica'` in `postgresql.auto.conf`. Host `:5433`, PGDATA `./data/pg_physical`. Also **never promote**.
- **HAProxy** `:5432` — single R/W endpoint; health check `GET /master` on Patroni REST `:8008`; backend contains only patroni1-3 (never patroni4_readonly / pg-physical-replica). Stats page: `:7000`.
- **pg-logical-replica** `:5434` — logical replication, publication `shop_pub` → subscription `shop_sub`.
- **pg-audit-log** `:5435` + **pg-audit-consumer** — Java 17 WAL consumer reading slot `audit_slot`.
- **load-generator** (DML via HAProxy), **pgAdmin** `:80`, **Prometheus** `:9090` / **Grafana** `:3000` / **cadvisor** `:8080`, 7 × postgres_exporter (one per PG instance: patroni1-3, patroni4_readonly, physical replica, logical, audit). All on Docker network `patroni-net`.
- Host PG ports **read-only**: `pg-physical-replica` `:5433`, `patroni4_readonly` `:5436`; `patroni1/2/3` expose **no host ports** — connect via HAProxy, pgAdmin or `docker compose exec`. (README's stale `users/products/orders` examples are corrected to the `bookings.*` schema.)
- Logical slots `shop_sub` + `audit_slot` + physical slot `pg_physical_replica` are **permanent slots** in `bootstrap.dcs.slots` (`docker-compose.yml`) → created on every node, recreated on the new leader after failover. `pg_physical_replica` has `type: physical` — keep it in the list, do not drop it (the plain replica's `primary_slot_name` depends on it).

## Tests

Dockerized pytest suite runs against the **live** cluster (`docker compose up -d` first):

```bash
docker compose build replication-tests                                    # once
docker compose run --rm replication-tests                                 # all tests (DML replication + failover)
docker compose run --rm replication-tests -k "not failover"               # skip failover
docker compose run --rm replication-tests -k "failover"                   # failover only
docker compose run --rm replication-tests test_replication.py::test_insert_replicates   # single test
```

- The suite creates/drops `bookings.repl_test` on the master, in pg-audit-log and on pg-logical-replica (session fixture — the logical mirror is mandatory: `FOR ALL TABLES` does not make the subscriber create new tables, and the apply worker crash-loops on the first `INSERT`). The failover test **stops the leader container** via `/var/run/docker.sock` (mounted in the service; host Docker API must be ≥ 1.44).
- Reports land in `patroni-cluster/data_tests/reports/` (bind mount in `docker-compose.yml`). `tests/README.md` and `docs/replication-tests.md` say `tests/reports/` — stale; trust compose.
- The service has `profiles: ["tests"]` in `docker-compose.yml` — `docker compose up -d` does not start it; explicit `build`/`run replication-tests` still work.
- Env overrides (e.g. `-e TEST_REJOIN_TIMEOUT=180`) are defined on the `replication-tests` service in `docker-compose.yml`.

## Key commands

| Action | Command |
|--------|---------|
| Cluster state | `docker compose exec patroni1 patronictl list` |
| Who is master (SQL) | `psql -h localhost -p 5432 -U postgres -d shop -c "SELECT inet_server_addr();"` (password `secret`) |
| HAProxy stats (master highlighted) | http://localhost:7000 |
| Failover test | `docker compose stop <master>`, later `docker compose start <master>` |
| Physical lag (on master) | `SELECT application_name, state, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag FROM pg_stat_replication;` |
| Logical slot lag (`shop_sub`, `audit_slot`) | `SELECT slot_name, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag FROM pg_replication_slots WHERE slot_type = 'logical';` |
| Apply lag on logical replica | `SELECT subname, pg_size_pretty(pg_wal_lsn_diff(latest_end_lsn, application_lsn)) AS lag FROM pg_stat_subscription;` |
| Audit consumer logs | `docker compose logs pg-audit-consumer` |
| Rebuild Patroni nodes with another version | `docker compose build --build-arg PATRONI_VERSION=4.1.5` (ARG in `patroni/Dockerfile`, default `4.1.3`) |
| Full reset | `docker compose down -v` **+ delete `patroni-cluster/data/`** — PGDATA lives in bind mounts, `-v` does not remove them (see `_clean_data.cmd`) |

More monitoring SQL: `docs/monitoring.md`.

## Database conventions

- App DB `shop`, schema `bookings` — 9 tables: `airplanes_data, airports_data, seats, routes, flights, bookings, tickets, segments, boarding_passes`. Created by `patroni/init.sh` (post_bootstrap) from `demo-airlines.sql`.
- Publication `shop_pub` is `FOR ALL TABLES` → tables created later are included automatically on the **publisher** (no `ALTER PUBLICATION` needed), but the **subscriber does not create them** (observed: no sync worker) — create new tables manually on pg-logical-replica too (the tests fixture does this for `repl_test`).
- Users: `postgres` / `secret` (superuser), `replicator` / `replicator` (replication). `wal_level: logical`.
- Slots `shop_sub` + `audit_slot` (logical) and `pg_physical_replica` (physical, for the plain replica) are **permanent slots** in `bootstrap.dcs.slots` (`docker-compose.yml`) → recreated on the new leader after failover; subscriber/consumer/replica reconnect by themselves. Adding a slot: add it under `bootstrap.dcs.slots` (or `patronictl edit-config`), then create the subscription with `create_slot = false`.

## Maintenance

### After failover / switchover

- Patroni, HAProxy, physical replicas, WAL consumer and apps via `:5432` recover **automatically**; logical + physical slots survive via DCS. DDL is just executed on the (new) master.
- Only manual check: apply worker on pg-logical-replica — if `pg_stat_subscription` is empty ~5 min after failover:
  `ALTER SUBSCRIPTION shop_sub DISABLE; ALTER SUBSCRIPTION shop_sub ENABLE;`
- Never promote `patroni4_readonly` or `pg-physical-replica` (breaks the "never leader" guarantee). `pg-physical-replica`/`patroni4_readonly` follow the new leader automatically (`pg-physical-replica` via DCS-updated `primary_conninfo` in Patroni REST → wait ~30s; the plain replica re-reads `primary_conninfo` from its own config only — after failover it reconnects automatically because it uses `primary_slot_name` + streaming, no manual step).
- If `pg-audit-consumer` loops on `requested WAL segment ... has already been removed`, a permanent logical slot on the current leader points to removed WAL (possible after several failovers/TL jumps). Fix: `docker compose stop pg-audit-consumer` → on the leader run `SELECT pg_drop_replication_slot('audit_slot'); SELECT pg_create_logical_replication_slot('audit_slot','pgoutput');` → `docker compose start pg-audit-consumer` (rows written between old and new LSN are lost). If `shop_sub` shows the same error (apply worker loops on `requested WAL segment ... has already been removed`), do the full resync from *Logical replica corruption* — note `DROP SUBSCRIPTION` also drops the slot on the publisher, so it must be recreated before the container.

### DDL changes

- Run DDL **only on the Patroni master**; the physical replica gets it via WAL automatically.
- Logical replication does not carry DDL: repeat the same DDL manually on pg-logical-replica, or the subscription breaks. For mass DDL: `ALTER SUBSCRIPTION shop_sub DISABLE` → DDL on master + logical replica → `ALTER SUBSCRIPTION shop_sub ENABLE`.

### Logical replica corruption

`replica-logical/entrypoint.sh` has two paths: fresh `PGDATA` → full initdb; existing `PGDATA` + missing `/tmp/.subscription_created` marker → re-run `setup_subscription()`, which **creates only what is missing** (DB, tables `IF NOT EXISTS`, subscription).

- Recreating the container alone (`docker compose rm -sf pg-logical-replica && docker compose up -d pg-logical-replica`) re-runs setup, but does **not** repair an existing broken `shop_sub` and does **not** wipe data (`./data/pg_logical` persists).
- Reliable recovery: on the replica run `ALTER SUBSCRIPTION shop_sub DISABLE; DROP SUBSCRIPTION shop_sub; DROP SCHEMA bookings CASCADE;`, then recreate the container — the `elif` path recreates the schema and the subscription with `copy_data = true`.
- Gotcha: `DROP SUBSCRIPTION` **also drops the `shop_sub` slot on the publisher**, while the entrypoint creates the subscription with `create_slot = false` — before recreating the container run on the current leader: `SELECT pg_create_logical_replication_slot('shop_sub','pgoutput');` (skip if the slot still exists). This psql rejects `DROP SUBSCRIPTION ... WITH (FORCE)` — `DISABLE` first, plain `DROP` then works.
- Full re-init alternative: stop the service, delete `./data/pg_logical`, recreate the container (slow on Windows — see gotchas).

## Gotchas / known noise

- Patroni 4.1.3 + PG18 logs `column "checkpoints_timed" does not exist` (PG18 moved `pg_stat_bgwriter` → `pg_stat_checkpointer`) — known, non-fatal, fix expected in Patroni 4.2+. The equivalent postgres_exporter error is already silenced via `--no-collector.stat_bgwriter` in compose.
- `pg-physical-replica` is built from `./replica-physical` (postgres:18 + entrypoint.sh: fresh PGDATA → pg_basebackup via haproxy + `primary_slot_name='pg_physical_replica'`; existing PGDATA → idempotent append of `primary_conninfo`/`primary_slot_name` to `postgresql.auto.conf`). Recreate after wipe: `docker compose rm -sf pg-physical-replica; Remove-Item -Recurse -Force 'patroni-cluster/data/pg_physical/*'; docker compose up -d pg-physical-replica` (takes 3–5 min; do NOT wipe unnecessarily — slot-based rebuild first, see `docs/monitoring.md`).
- Windows + bind mounts: slow fsync can trap a node in a crash-recovery kill loop (`Cancelling long running task doing crash recovery...`, `code=1`). Fix: stop that node, delete its directory under `patroni-cluster/data/`, start it again (re-joins via `pg_basebackup`, takes 3–5 min on Windows). Details: `docs/monitoring.md`.
- `patroni-cluster/replica-physical2/` (if present) is **legacy** — the second physical replica is now the Patroni member `patroni4_readonly`, built from `./patroni`.

## Backlog workflow

```
backlog/01 - wait/   →   backlog/02 - work/   →   backlog/03 - done/
```

Move the `.md` file between dirs to track state (dir names contain spaces — quote them). Files use Status/Priority/Created/Deadline fields + DoD checkboxes (`backlog/README.md`). Record notable changes as dated entries in `changes.md`.

## Files of interest

- `patroni-cluster/docker-compose.yml` — source of truth: topology, host ports, permanent slots, tests env
- `patroni-cluster/patroni/` — `Dockerfile` (ARG `PATRONI_VERSION`), `init.sh` (post_bootstrap DDL, demo data, publication), `demo-airlines.sql`
- `patroni-cluster/replica-logical/entrypoint.sh` — logical replica init (fresh vs. re-setup branch)
- `patroni-cluster/replica-physical/` — plain physical replica init (pg_basebackup via haproxy + physical slot)
- `patroni-cluster/haproxy/haproxy.cfg`, `pgadmin/servers.json`, `prometheus/`, `grafana/provisioning/`, `load-generator/`, `pg-audit-consumer/`
- `patroni-cluster/tests/` — replication test suite (run.sh → pytest + HTML/Allure reports)
- `README.md` (index) · `docs/` — components, replication, maintenance, monitoring, issues, replication-tests · `changes.md` (changelog)
