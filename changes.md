# Changelog

## 2026-10-07 — Реорганизация топологии: patroni4_readonly (член Patroni) + pg-physical-replica (вне Patroni)

Вторая физическая реплика переведена из автономной standby (`pg-physical-replica2`) в **член кластера Patroni** `patroni4_readonly` (`tags.nofailover: true`), а `pg-physical-replica` возвращена в статус **plain-реплики вне Patroni** (нет etcd/REST, стриминг через постоянный физический слот `pg_physical_replica`). Хост-порты: `pg-physical-replica` `:5433`, `patroni4_readonly` `:5436`.

### Изменённые файлы

| Файл | Что изменено |
|------|-------------|
| `patroni-cluster/docker-compose.yml` | `pg-physical-replica2` → `patroni4_readonly` (имя/connect_address/volume `./data/pg_physical2`, `5436:5432`, `nofailover: true`, образ `./patroni`); `pg-physical-replica` → `build: ./replica-physical`, env `PGPASSWORD: replicator`, **`PGDATA: /var/lib/postgresql/data`** (в postgres:18 иначе бекап уходит в анонимный volume и падает `Permission denied`), `5433:5432`; `pg_physical_replica` (`type: physical`) добавлен в `bootstrap.dcs.slots` на patroni1/2/3; `pg-exporter-physical2` → `pg-exporter-patroni4` (DSN patroni4_readonly); pgadmin volume → named `pgadmin-data` (bind-mount на Windows не переживал `chown`) |
| `patroni-cluster/replica-physical/entrypoint.sh` | Переписан: guard от записи не туда при `PGDATA != /data/pgdata`; свежий PGDATA → `pg_basebackup` через haproxy + `standby.signal`; существующий PGDATA → идемпотентное добавление `primary_conninfo` (`application_name=pg_physical_replica`) и `primary_slot_name = 'pg_physical_replica'` в `postgresql.auto.conf` |
| `patroni-cluster/pgadmin/servers.json` | Сервер `"5"`: Patroni4 readonly → `patroni4_readonly`; переимпорт серверов — через wipe named volume `patroni-cluster_pgadmin-data` (не `data/pgadmin`) |
| `patroni-cluster/prometheus/prometheus.yml` | job `patroni`: 4 цели (patroni1/2/3 + `patroni4_readonly:8008`); job `postgresql`: `pg-exporter-patroni4:9187` (7 целей); `pg-physical-replica:8008` из job `patroni` убран (нет REST) |
| `patroni-cluster/architecture.dot` | Панель 4 членов Patroni (+nofailover), `pg-physical-replica` в отдельной группе с пометкой слота |
| `patroni-cluster/tests/config.py` | `NOFAILOVER_NODES = ["patroni4_readonly"]` (+ комментарий, что `pg-physical-replica` вне DCS); `tests/test_failover.py`, `tests/README.md` — актуализированы |
| `AGENTS.md`, `README.md`, `docs/issues.md`, `docs/components.md`, `docs/replication.md`, `docs/maintenance.md`, `docs/replication-tests.md` | Новая топология: 4 узла Patroni + plain-реплика; never-promote → `patroni4_readonly`/`pg-physical-replica`; слот `pg_physical_replica` (permanent, `type: physical`); восстановление реплик; README: добавлен раздел «Источники и материалы» |
| Живой кластер | DCS-конфиг обновлён через REST `PATCH /config` (slots + `pg_physical_replica`); старый слот `pg_physical_replica2` удалён; `./data/pg_physical` пересоздан с нуля; pgadmin пересоздан на named volume |

### Результаты верификации (2026-10-07)

| Проверка | Статус | Детали |
|----------|--------|--------|
| Вход в кластер | OK | `patronictl list`: patroni1 Leader TL19, patroni2/3 Replica, patroni4_readonly Replica `nofailover: true`, lag 0 |
| `pg-physical-replica` | OK | Вне `patronictl list`; `pg_is_in_recovery() = t`; `flights` = 61114 (совпадает с мастером); стример `pg_physical_replica` в `pg_stat_replication` активен |
| Слоты | OK | `pg_physical_replica` (physical) + `shop_sub` + `audit_slot` активны на лидере; переносятся на нового лидера через DCS |
| R/W через HAProxy | OK | `5432` → лидер (172.18.0.4), запись проходит |
| Хост-порты | OK | `localhost:5433` (pg-physical-replica) и `localhost:5436` (patroni4_readonly) читаются |
| Логическая реплика | OK | `shop_sub` active, `received_lsn` продвигается, max flight_id совпадает с мастером |
| Аудит-лог | OK | consumer применяет изменения |
| Мониторинг | OK | Prometheus 14/14 targets `up` |

## 2026-10-07 — Вторая физическая реплика в кластере Patroni (nofailover)

**Задача:** backlog/02 - work/011-additional-physical-replica-patroni-no-leader.md

Кластер вырос с 4 до 5 нод: `patroni1/2/3` + `pg-physical-replica` + `pg-physical-replica2` (обе физические реплики — полные члены Patroni с `tags.nofailover: true`, никогда не становятся лидером).

### Изменённые файлы

| Файл | Что изменено |
|------|-------------|
| `patroni-cluster/docker-compose.yml` | Сервис `pg-physical-replica2` (образ `./patroni`, REST `:8008`, volume `./data/pg_physical2`, хост-порт `5436:5432`, `nofailover: true`, без `post_bootstrap`); сервис `pg-exporter-physical2`; у `replication-tests` добавлен `profiles: ["tests"]` (при обычном `up -d` тесты не запускаются), env `TEST_LOGICAL_HOST/PORT` и `depends_on: pg-logical-replica` |
| `patroni-cluster/pgadmin/servers.json` | Сервер `"5"`: Physical Replica 2 → `pg-physical-replica2` |
| `patroni-cluster/prometheus/prometheus.yml` | В job `patroni` добавлены `pg-physical-replica:8008` и `pg-physical-replica2:8008` (закрыт разрыв мониторинга из задачи 007); в job `postgresql` — `pg-exporter-physical2:9187` (7 целей) |
| `patroni-cluster/architecture.dot` | 5 членов кластера, узлы `nofailover`, абстракция «текущий Leader» как WAL source, порты 5433/5436 |
| `patroni-cluster/tests/config.py` | `NOFAILOVER_NODES = ["pg-physical-replica", "pg-physical-replica2"]`; `LOGICAL_HOST/LOGICAL_PORT` (зеркало тестовой таблицы на логической реплике) |
| `patroni-cluster/tests/conftest.py` | Фикстура `test_table` теперь создаёт/удаляет `bookings.repl_test` ещё и на `pg-logical-replica` (без этого apply-worker падал в crash-loop на первом INSERT — см. инциденты) |
| `patroni-cluster/tests/test_failover.py` | Проверка «новый лидер ≠ nofailover-узел» и маппинг контейнер→сервис по `config.NOFAILOVER_NODES` |
| `AGENTS.md` | 5 нод, порты 5433/5436, запрет промоута обеих реплик, 7 postgres_exporter, `profiles: ["tests"]`, инструкция по лечению протухшего логического слота; нюансы: `FOR ALL TABLES` не создаёт таблицы на подписчике, зеркало `repl_test` в фикстуре, полный рецепт resync `shop_sub` (слот + подписка) |
| `README.md` | 5 нод в описании и требованиях; убраны устаревшие хост-порты `5001–5003` и запросы `users/products/orders` (заменены на `bookings.*`); пример вывода REST — 5 членов |
| `docs/replication.md` | Раздел физической реплики → обе реплики (:5433/:5436); исправлена публикация (`FOR ALL TABLES`, `bookings.*`); добавлено восстановление протухшего слота (`requested WAL segment ... has already been removed` → drop+create) |
| `docs/components.md` | Таблица компонентов (реплики 5433/5436, убраны несуществующие порты 5001–5003), pgAdmin-серверы (5 шт.), раздел «never leader» для обеих реплик, leader election — из 3 leader-capable нод |
| `docs/maintenance.md` | Обе физические реплики в таблицах категорий; в восстановлении логической реплики добавлен шаг пересоздания слота `shop_sub` на лидере (`DROP SUBSCRIPTION` удаляет слот, а `create_slot = false` его не создаёт) и уточнение про пересоздание контейнера |
| `docs/replication-tests.md`, `patroni-cluster/tests/README.md` | Failover-тест проверяет оба nofailover-узла; путь отчётов → `data_tests/reports/`; описание зеркала `repl_test` на логической реплике |
| `.gitignore` | + `patroni-cluster/data_tests/reports/` |

### Результаты верификации (2026-10-07)

| Проверка | Статус | Детали |
|----------|--------|--------|
| Вход в кластер | OK | 5 нод, `pg-physical-replica2`: `streaming`, `nofailover: true`, TL13→15, lag 0 |
| `pg_is_in_recovery()` | OK | `t`; `post_bootstrap`/`init.sh` на новой реплике не запускались |
| REST `:8008` | OK | `http://pg-physical-replica2:8008/patroni` → `{"role":"replica", ... "tags":{"nofailover":true}}` |
| Хост-порт | OK | `localhost:5436` принимает подключения |
| Тест лидерства | OK | Остановка лидера → новым лидером `patroni1` (потом `patroni3`), обе физические реплики остались `replica`; бывший лидер вернулся через `pg_rewind` |
| Тесты репликации | OK | Три прогона `4 passed` (167s / 170s / 172s — INSERT/UPDATE/DELETE + failover); последний прогон — уже с зеркалом `repl_test` на логической реплике, без ошибок apply |
| Мониторинг | OK | Все 14 Prometheus-targets `up` (в т.ч. `pg-physical-replica:8008`, `pg-physical-replica2:8008`, `pg-exporter-physical2:9187`) |
| Аудит-лог | OK | 264 строки за 2 мин; consumer переподключён после пересоздания `audit_slot` |
| Логическая реплика | OK | Resync после протухшего слота: счётчики master = replica (flights/tickets/segments/boardings), `shop_sub` active, лаг ~0–15 kB |
| Итоговое состояние | OK | 5 нод в кластере (лидер — `patroni1`/TL18 после последнего failover-теста), обе реплики `streaming` + `nofailover: true`, lag 0; `patroni3` (бывший лидер) сам вернулся через crash recovery → `pg_rewind` |

### Инцидент по ходу задачи

После нескольких failover permanent-слот `audit_slot` на новом лидере остался на позиции с уже удалёнными WAL-сегментами (`restart_lsn 0/12ac6810` при `pg_current_wal_lsn 0/68527200`) — consumer зациклился с `requested WAL segment 00000006... has already been removed`, 3 DML-теста упали. Лечение: `docker compose stop pg-audit-consumer` → на лидере `pg_drop_replication_slot('audit_slot')` + `pg_create_logical_replication_slot('audit_slot','pgoutput')` → `docker compose start pg-audit-consumer`. Зафиксировано в `AGENTS.md` и `docs/replication.md`.

**Протухший слот `shop_sub` + дрейф данных логической реплики.** Тот же симптом у apply-worker `shop_sub` (ошибка «WAL segment has already been removed»), из-за чего логическая реплика отстала на ~6.6 тыс. строк (`flights` 39398 vs 46034). Лечение — полный resync: `pg_drop_replication_slot('shop_sub')` + `pg_create_logical_replication_slot('shop_sub','pgoutput')` на лидере → на реплике `ALTER SUBSCRIPTION shop_sub DISABLE; DROP SUBSCRIPTION shop_sub; DROP SCHEMA bookings CASCADE;` → пересоздание контейнера (ветка `elif` в `entrypoint.sh` пересоздаёт схему и подписку с `copy_data = true`). Важные нюансы: `DROP SUBSCRIPTION` **сам удаляет слот на паблишере** (пришлось пересоздавать его после удаления подписки), а `DROP SUBSCRIPTION ... WITH (FORCE)` эта версия psql не принимает (работает `DISABLE` + обычный `DROP`). После resync счётчики сошлись, лаг ~0. Рецепт внесён в `AGENTS.md` и `docs/maintenance.md`.

**Crash-loop apply-worker на тестовой таблице `bookings.repl_test`.** После каждого прогона тестов логическая реплика падала в цикл: публикация `FOR ALL TABLES` включает новую таблицу, но подписчик **не создаёт её сам** (sync-worker для `repl_test` не запускался) — apply-worker падал с `logical replication target relation "bookings.repl_test" does not exist` на первом INSERT и больше не продвигался. Лечение разового сбоя: создать таблицу на реплике, дать apply-workerу догнать, удалить таблицу. Постоянный фикс: фикстура `test_table` теперь зеркалит `repl_test` и на `pg-logical-replica` (`tests/conftest.py` + `LOGICAL_HOST` в `tests/config.py`, env и `depends_on` в compose) — прогон после фикса прошёл без единой ошибки логической реплики.

## 2026-08-20 — Реорганизация документации

### Изменённые файлы

| Файл | Что изменено |
|------|-------------|
| `README.md` | Переписан как индекс (1020 → ~165 строк): ссылки на `docs/*`, требования с трассировкой (инфраструктурные: Docker/Compose; программные: PG 18, Patroni 4.1.3, etcd 3.5+, HAProxy 2.9+, Java 17, Gradle 8.7 — каждая с указанием где используется и файл-трассировка), первичные требования и статус выполнения (6 пунктов: кластер, лог.репликация, физ.репликация, аудит-лог, временные таблицы, moveusername), быстрый старт, проверка мастера, проверка кластера, остановка |
| `docs/components.md` | **Новый** (~270 строк) — сборка образа Patroni, обновление версии, описание всех компонентов, архитектура, leader election |
| `docs/replication.md` | **Новый** (~250 строк) — DML-репликация (3 пути), аудит-лог (WAL consumer, структура audit-таблиц), восстановление слотов при смене лидера |
| `docs/maintenance.md` | **Новый** (~190 строк) — сводная таблица DML/DDL/обслуживания по 4 категориям БД (+pg-audit-log), таблица «Что разрешено и запрещено» с разделением pg-audit-log на «любые таблицы кроме bookings.*» и «bookings.* — аудит-таблицы» (⚠️), DDL (таблицы, поля, индексы), обслуживание индексов, восстановление логической реплики |
| `docs/monitoring.md` | **Новый** (~220 строк) — ключевые метрики, SQL-запросы мониторинга репликации (включая `pg_last_xact_replay_timestamp()` для задержки на физической реплике), `moveusername` (известные ограничения), fsync на Windows |
| `docs/issues.md` | **Новый** (~60 строк) — проблемы физической реплики (hot standby: временные таблицы, DML, хранимые процедуры + решение в Postgres Pro Enterprise 18.4.1), имя пользователя в аудит-логе (pgoutput v1 не передаёт role, таблица доступных полей, рабочее решение `modified_by TEXT DEFAULT current_user`, альтернативы) |

### Структура

```
README.md (~165 строк — индекс с навигацией, трассировкой требований и статусом выполнения)
docs/
├── components.md   — компоненты, архитектура, сборка
├── replication.md  — репликация данных, аудит-лог, слоты
├── maintenance.md  — DDL, индексы, восстановление реплики
├── monitoring.md   — метрики, ограничения, Windows
└── issues.md       — проблемы hot standby, аудит-лог (имя пользователя)
```

### Причина

README.md вырос до 1020 строк — в одном файле компоненты, репликация, обслуживание, мониторинг и проблемы Windows. Разбиение на 4 модульных файла упрощает навигацию и поддержку.

## 2026-07-22 — PostgreSQL 17 → 18

**Задача:** backlog/03 - done/008-upgrade-postgres18.md

### Изменённые файлы

| Файл | Что изменено |
|------|-------------|
| `patroni-cluster/patroni/Dockerfile` | `FROM postgres:17` → `FROM postgres:18`, комментарий заголовка |
| `patroni-cluster/replica-physical/Dockerfile` | `FROM postgres:17` → `FROM postgres:18`, комментарий заголовка |
| `patroni-cluster/replica-logical/Dockerfile` | `FROM postgres:17` → `FROM postgres:18`, комментарий заголовка |
| `patroni-cluster/pg-audit-log/Dockerfile` | `FROM postgres:17` → `FROM postgres:18` |
| `patroni-cluster/docker-compose.yml` | Заголовок: `PostgreSQL 17` → `PostgreSQL 18` |
| `patroni-cluster/replica-logical/entrypoint.sh` | Комментарий: `PostgreSQL 17` → `PostgreSQL 18` |
| `AGENTS.md` | `PostgreSQL 17 managed by Patroni` → `PostgreSQL 18 managed by Patroni` |

### Не изменялось

| Файл/компонент | Причина |
|----------------|---------|
| `patroni/Dockerfile` (PATRONI_VERSION) | Версия Patroni 4.1.3 совместима с PG 18 |
| `pg-audit-consumer/Dockerfile` | Java 17/JRE — не зависит от версии PostgreSQL |
| `load-generator/Dockerfile` | Java-приложение, подключается по JDBC — не зависит от версии PG |
| `docker-compose.yml` (services/env/ports) | Конфигурация кластера, порты, переменные — без изменений |
| `patroni/init.sh` | SQL-скрипт инициализации — совместим с PG 18 |
| `replica-physical/entrypoint.sh` | pg_basebackup / streaming replication — совместимо с PG 18 |
| `replica-logical/entrypoint.sh` | initdb / CREATE SUBSCRIPTION — совместимо с PG 18 |
| `pg-audit-log/entrypoint.sh` | initdb / psql — совместимо с PG 18 |
| `haproxy/haproxy.cfg` | Балансировщик на уровне TCP — не зависит от версии PG |
| `pgadmin/servers.json` | Конфигурация серверов — без изменений |

### Причина

PostgreSQL 18 — stable (октябрь 2025). Мажорный апгрейд, все компоненты обновлены одновременно. При полной пересборке (`docker compose down -v && docker compose build && docker compose up -d`) данные инициализируются заново — `pg_upgrade` не требуется.

### Результаты верификации (2026-07-22)

| Компонент | Статус | Детали |
|-----------|--------|--------|
| Кластер Patroni | OK | 1 Leader (patroni3) + 2 Replica (patroni1/2), streaming, lag 0 |
| PostgreSQL версия | OK | `PostgreSQL 18.4 (Debian 18.4-1.pgdg13+1)` |
| Физическая реплика | OK | `pg_is_in_recovery = true`, данные синхронизированы |
| Логическая реплика | OK | Subscription `shop_sub` active, данные реплицируются |
| Audit slot | OK | 4 слота активны: patroni1/2 (physical), audit_slot, shop_sub (logical) |
| Audit consumer | OK | 1308 bookings + 1872 segments в аудит-логе |
| Load generator | OK | DML-операции (INSERT/UPDATE/DELETE) работают |
| Все контейнеры | OK | 20/20 контейнеров Up |

**Известная проблема (non-fatal):** Patroni 4.1.3 логирует ошибку `column "checkpoints_timed" does not exist` — в PG 18 колонки `pg_stat_bgwriter` были перемещены в `pg_stat_checkpointer`. Это не влияет на работу кластера, ожидается исправление в Patroni 4.2+.
