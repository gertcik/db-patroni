# Changelog

## 2026-10-23 — pg-physical-replica: пересборка после TL-дрейфа (TL 10 → 15) + попутно восстановление patroni2

### Что случилось

- `pg-physical-replica` перестал стартовать: `FATAL: requested timeline 12 does not contain minimum recovery point 1/3DFC5040 on timeline 10`. Реплика остановилась 2026-10-21 в состоянии TL 10 — с тех пор кластер пережил несколько смен timeline (на момент восстановления — TL 14+, лидер уже не patroni2): WAL-сегменты нужных форков давно переработаны. Обычная реплика вне Patroni не умеет pg_rewind — единственный путь, полный pg_basebackup по процедуре AGENTS.md.
- При `docker compose up -d pg-physical-replica` compose пересоздал вместе с зависимостями patroni1-3; лидер patroni2 застрял в `doing crash recovery in a single user mode` на Windows bind mount (известный gotcha AGENTS.md).

### Шаги восстановления

1. Wipe PGDATA реплики: `docker compose rm -sf pg-physical-replica` + очистка `data/pg_physical/*` + `docker compose up -d pg-physical-replica` — entrypoint дожидается мастера и делает pg_basebackup через HAProxy (3–5 мин).
2. Лидер patroni2 петлился в crash recovery > 2 мин → по процедуре того же gotcha: `docker compose stop patroni2` → wipe `data/pgdata2/*` → `start` → узел пересобрался (`bootstrap from leader 'patroni1'`, ~3 мин).
3. На время простоя patroni2 кластер сам выбрал нового лидера: **patroni1 — лидер TL 15** (failover сработал без ручного вмешательства).

### Результат

- `patronictl list`: patroni1 — leader TL 15; patroni2/3/4_readonly — streaming, лаг 0.
- Слоты на лидере: все 6 (patroni2/3/4_readonly + `pg_physical_replica` + `shop_sub` + `audit_slot`), все активные.
- `pg-physical-replica` восстановлен: redo завершилось, стриминг по TL 15, отставание 0 байт (`pg_stat_replication`).
- Аудит не задет: `audit_slot` активен, лаг 0 байт, consumer работает (на log4j).

## 2026-10-23 — pg-audit-consumer: логирование через log4j 2 (INFO по умолчанию) + unit-тесты логирования

### Что сделано

- Все `System.out.println` / `System.err.println` (App, PgOutputDecoder, AuditWriter) заменены на log4j 2 (`LogManager.getLogger`): `[INFO]` → `logger.info`, `[ERROR]` → `logger.error` (+stack trace), `[WARN]` → `logger.warn`, per-row debug-печатей декодера (Begin/Relation/Insert/Update/Delete/Commit/Origin) → `logger.debug`. Появилось сообщение-контекст: `%d [LEVEL] %logger: %msg`.
- Конфигурация — `src/main/resources/log4j2.xml`: Console appender (stdout), корневой уровень **INFO по умолчанию**, переопределяется env `AUDIT_LOG_LEVEL` (`${env:AUDIT_LOG_LEVEL:-INFO}`); env добавлен в сервис `pg-audit-consumer` в docker-compose.yml.
- Заодно: hex-дамп WAL-сообщений в App (`logWalMessage`) гейтится `logger.isDebugEnabled()` — на INFO hex не строится вовсе.
- Unit-тесты:
  - **LoggingTest** (6): in-test CapturingAppender через log4j core API — корневой уровень по умолчанию INFO; DEBUG-события декодера логируются на DEBUG и подавляются на INFO; INFO-сообщения проходят через log4j; декодер не пишет в stdout напрямую (capture stdout, уровень OFF); hex-дамп WAL — только на DEBUG.
  - **AppTest** (3): `sourceUrl`, fallback `env()`, дефолты `loadConfig()` без env.
- Тесты прогнаны в контейнере `gradle:8.7-jdk17` (путь запуска: `docker run --rm -v <repo>:/app -w /app gradle:8.7-jdk17 gradle test --no-daemon`) — 26/26 зелёные. `log4j-core` добавлен и в `testImplementation` (нужен тестам: CapturingAppender, Configurator).
- Live-проверка: пересборка образа, рестарт consumer (--no-deps) — логи в формате log4j, DEBUG-шум и hex-дампы исчезли, поток изменений продолжается (Applied … at LSN).

### Изменённые файлы

| Файл | Что изменено |
|------|-------------|
| `patroni-cluster/pg-audit-consumer/build.gradle` | Зависимости log4j-api (implementation), log4j-core (runtimeOnly + testImplementation) |
| `patroni-cluster/pg-audit-consumer/src/main/resources/log4j2.xml` | **Новый** — Console appender, root `INFO` (env `AUDIT_LOG_LEVEL`) |
| `patroni-cluster/pg-audit-consumer/src/main/java/com/audit/consumer/App.java` | Все println → log4j; `logWalMessage` под `isDebugEnabled()` (early return) |
| `patroni-cluster/pg-audit-consumer/src/main/java/com/audit/consumer/PgOutputDecoder.java` | Debug-печатей декодера → `logger.debug` |
| `patroni-cluster/pg-audit-consumer/src/main/java/com/audit/consumer/AuditWriter.java` | INFO/WARN/ERROR → log4j |
| `patroni-cluster/pg-audit-consumer/src/test/java/com/audit/consumer/LoggingTest.java` | **Новый** — 6 тестов логирования (уровни, stdout-чистота) |
| `patroni-cluster/pg-audit-consumer/src/test/java/com/audit/consumer/AppTest.java` | **Новый** — 3 теста хелперов App |
| `patroni-cluster/docker-compose.yml` | env `AUDIT_LOG_LEVEL: INFO` у сервиса pg-audit-consumer |

### Известный остаток

- `[INFO] Applied … at LSN` печатается на каждое WAL-сообщение (фактически на каждую строку) — на INFO при высокой скорости это всё ещё заметный stdout-поток; следует троттлить до ~1/сек или печатать size>1 только при батч-флаше (см. план оптимизации consumer: кэш PreparedStatement + flush по границе транзакции).

## 2026-10-23 — Протухший audit_slot: диагностика, восстановление, документация

### Что сделано

- Симптом: `pg-audit-consumer` зациклен (`requested WAL segment 000000070000000100000028 has already been removed`, переподключение каждые 5 с), слот `audit_slot` неактивен, `restart_lsn` отставал на 772 МБ — WAL сегментов протухшего слота переработан (established кейс AGENTS.md): lag consumer'а при 1000 op/с + несколько failover'ов/TL (6→13).
- Восстановление по штатной процедуре: stop consumer → на лидере `pg_drop_replication_slot('audit_slot')` + `pg_create_logical_replication_slot('audit_slot','pgoutput')` (новая позиция `1/587FCCB8`) → start consumer. События между протухшим `restart_lsn` и моментом пересоздания невосстановимы (WAL удалён) — в аудит-таблицах дыра за этот период. Проверено: слот `active = t`, лаг 0 байт, поток реплицируется.
- Документация: в `docs/replication.md` добавлен раздел «Ошибка `requested WAL segment ... has already been removed`: значение и реакция» — расшифровка имени сегмента (timeline + сегмент), значение (слот запрашивает переработанный WAL; данные не повреждены, позиция нечитаема, `pg_replication_slot_advance` тоже падает), диагностика (SQL по `restart_lag`), реакции для `audit_slot` (drop+create) и `shop_sub` (полный resync, `DROP SUBSCRIPTION` удаляет слот на паблишере), что теряется безвозвратно, профилактика (мониторинг лага слотов, не останавливать consumer надолго при активном load-generator, ускорение consumer).

### Изменённые файлы

| Файл | Что изменено |
|------|-------------|
| `docs/replication.md` | Новый подраздел «Ошибка requested WAL segment …: значение и реакция»; пункт 3 в «Когда нужно ручное вмешательство» превращён в ссылку на него |
| Кластер (не в git) | Слот `audit_slot` пересоздан на текущем лидере (pos `1/587FCCB8`), consumer запущен |

## 2026-10-21 — Разгон load-generator до ~1000 записей/с (батч-вставки вместо autocommit)

### Что сделано

- Причина низкой производительности: каждый INSERT = отдельный autocommit (fsync + round-trip через HAProxy), пауза 100–500 мс на цикл → 5–8 op/с.
- BookingWorker переписан на батч: `BATCH_BOOKINGS` бронирований за ОДНУ транзакцию через `execute_values` (psycopg2.extras) — multi-row INSERT.
- `ON CONFLICT DO NOTHING` на всех 4 таблицах — коллизии случайных `book_ref`/`ticket_no` при высокой скорости не роняют пакет.
- Rate-limit: `TARGET_OPS_PER_SEC` (по workers_booking, 0 = без лимита) — sleep после пакета пропорционален строкам.
- Настройки PG (мастер): `ALTER ROLE postgres SET synchronous_commit = off` (устойчиво, живёт в каталоге); `ALTER SYSTEM max_wal_size=2GB`, `checkpoint_completion_target=0.9` + `pg_reload_conf()`.
- docker compose: после изменения env load-generator пересоздал и patroni1-3/haproxy (dependent tree) — ожидаемо, кластер перезапустился сам (TL 6→7).

### Результаты верификации (2026-10-21)

- Цепочка bookings: ~1000 INSERT/с суммарно (bookings ≈ 140/с, tickets/segments/boarding_passes ≈ 285/с каждый) + flights ~190 ins/300 upd/с; err/s = 0.00.
- Физические реплики streaming, лаг ≤ 5.5 МБ; shop_sub — 6.5 КБ (apply worker успевает).
- ⚠️ audit_slot копит лаг (~270 КБ/мин): однопоточный pg-audit-consumer медленнее 1000/с — контейнер на связи, применяется, но WAL держится слотом → при длительной работе на 1000/с диск заполнится; снижать TARGET_OPS_PER_SEC или периодически син историческую часть.

### Изменённые файлы

| Файл | Что изменено |
|------|-------------|
| `patroni-cluster/load-generator/workers/booking_worker.py` | Батч-версия: multi-row VALUES, 1 транзакция/пакет, ON CONFLICT DO NOTHING, per-worker rate-limit |
| `patroni-cluster/load-generator/workers/base.py` | `write_batch()` (execute_values + rollback при ошибке, autocommit=False), `count_bulk()` |
| `patroni-cluster/load-generator/main.py` | env `BATCH_BOOKINGS`, `TARGET_OPS_PER_SEC` (бюджет на worker) |
| `patroni-cluster/docker-compose.yml` | env: THREADS_BOOKING=12, THREADS_FLIGHT=4, BATCH_BOOKINGS=10, TARGET_OPS_PER_SEC=1000, POOL 20/40, SLEEP 0–5 мс |
| Настройки кластера (не в git) | роль postgres: `synchronous_commit=off`; мастер: `max_wal_size=2GB`, `checkpoint_completion_target=0.9` |

## 2026-10-20 — Инструкция по развёртыванию (docs/setup.md) + актуализация доков после задачи 012

### Что сделано

- Новый документ **`docs/setup.md`** — пошаговый чек-лист развёртывания с нуля: (1) Patroni + HA (etcd, PATRONI_CONFIGURATION, HAProxy health-check `/master`), (2) настройки PostgreSQL (только через DCS: `wal_level=logical`, `max_worker_processes`, `use_pg_rewind`, REPLICA IDENTITY FULL), (3) аудит-реплика + pg-audit-consumer пошагово (build/up, env-таблица consumer, end-to-end проверка с SQL), плюс перечень всех SQL-скриптов с описанием, блок permanent-слотов, сводка учёток/портов, финальный чек-лист и Windows-заметки.
- README.md: `docs/setup.md` первым в списке документации; AGENTS.md: добавлен в перечень docs/.

### Изменённые файлы

| Файл | Что изменено |
|------|-------------|
| `docs/setup.md` | **Новый** — чек-лист развёртывания (Patroni+HA / настройки PostgreSQL / аудит-реплика+consumer) |
| `docs/components.md` | Раздел pg-audit-log: убрано «все колонки TEXT», описаны зеркальные типы + авто-выравнивание consumer'ом |
| `docs/maintenance.md` | Таблица категорий: pg-audit-log «all TEXT» → «типы зеркальны с мастером» |
| `README.md`, `AGENTS.md` | Ссылки на `docs/setup.md` |

## 2026-10-20 — Задача 012: зеркальные типы колонок в аудит-БД (pg-audit-consumer + init-audit.sql), актуализация запросов лага репликации

### Что сделано

- Причина «всё TEXT» в pg-audit-log: `init-audit.sql` создавал таблицы с колонками `TEXT`, а consumer писал `setString` по всем колонкам без проверки схемы приёмника.
- Задача из backlog: [012-problem-replicar.md](backlog/03%20-%20done/012-problem-replicar.md) (статус done).

### Изменённые файлы

| Файл | Что изменено |
|------|-------------|
| `patroni-cluster/pg-audit-consumer/src/main/java/com/audit/consumer/AuditWriter.java` | Зеркалирование схемы: при первом появлении таблицы в WAL читаются типы колонок источника (`pg_catalog.format_type` через отдельное JDBC-соединение к мастеру) и приводится audit-таблица: `CREATE TABLE` (нет таблицы), `ALTER COLUMN ... TYPE ... USING (col::тип)` (тип отличается), `ADD COLUMN` (колонка добавлена у источника); таблицы, удалённые из источника, пропускаются с `[WARN]` (не crash-loop). INSERT'ы с явными кастами по колонкам `CAST(? AS <тип>)`. DDL коммитится сразу, кэш SQL на таблицу. |
| `patroni-cluster/pg-audit-consumer/src/main/java/com/audit/consumer/App.java` | `connectTarget(cfg, sourceUrl)` — доп. соединение к источнику для метаданных зеркала |
| `patroni-cluster/pg-audit-consumer/src/test/java/com/audit/consumer/AuditWriterTest.java` | Тесты `buildInsertSqlWithTypes` (CAST по типам) и fallback на `?` для колонок без известного типа |
| `patroni-cluster/pg-audit-log/init-audit.sql` | Зеркальные типы вместо TEXT: `CHAR(3)`, `INTEGER`, `INTEGER[]`, `TIME`, `INTERVAL`, `TIMESTAMPTZ`, `NUMERIC(10,2)`, `BOOLEAN` — NULL, без NOT NULL/DEFAULT/констрейнтов (служебные `movedate`/`moveusername`/`moveaction`/`id_identity` — как было) |
| `docs/replication.md` | Раздел про аудит: зеркальные типы, авто-выравнивание consumer'ом, примеры INSERT с CAST |
| `docs/monitoring.md` | Запрос `pg_stat_subscription` актуализирован под PG18 (колонки `application_lsn` нет — через `latest_end_lsn`/`received_lsn`; полный лаг по слоту на мастере) |
| `AGENTS.md` | Помечено авто-зеркалирование типов аудита + корректный запрос лага apply worker |
| `backlog/03 - done/012-problem-replicar.md` | Задача закрыта: причина, решение, live-проверка (42/42 колонки OK, 4/4 replication-tests passed) |

### Результаты верификации (2026-10-20)

| Проверка | Статус | Детали |
|----------|--------|--------|
| Юнит-тесты consumer | OK | 17/17 (gradle:8.7-jdk17 в docker) |
| Миграция живой БД аудита | OK | существующие TEXT-таблицы выровнены ALTER'ами автоматически после пересборки/пересоздания consumer |
| Сравнение типов мастер↔аудит (9 таблиц, 42 колонки) | OK | 42/42 OK (`character(3)`, `integer`, `integer[]`, `time`, `interval`, `timestamptz`, `numeric(10,2)`, `boolean`, `text`) |
| Данные типизированы | OK | `days_of_week` = `{1,3,5}`, `duration` = `01:30:00`, `price` = `numeric(10,2)` и т.д. |
| replication-tests | OK | 4/4 passed (DML i/u/d + failover), отчёт в `data_tests/reports/` |
| Логи consumer | OK | Aligned/Create/ WARN как ожидается, без ERROR |

## 2026-10-07 — Перерисовка диаграммы, чистка backlog, алерты Prometheus, пометка об альтернативах компонентов

### Изменённые файлы

| Файл | Что изменено |
|------|-------------|
| `patroni-cluster/architecture.dot` | Добавлены группа «Мониторинг» (Prometheus/Grafana/cAdvisor/7 × postgres_exporter) и узел load-generator с рёбрами; у логической реплики проставлен `subscription: shop_sub`; группа прокси → «Proxy / Admin / Load» |
| `images/diagram.png` | Перерисован из `architecture.dot` (graphviz 12.2.1, 1675×1179, 230 KB) — полная актуальная топология; содержимое подписей проверено через SVG-рендер |
| `patroni-cluster/prometheus/rules/patroni.yml` | Исправлены 3 алерта, ссылавшихся на несуществующие метрики (`patroni_master` → `max(patroni_primary) == 0`; `patroni_lag` → `pg_stat_replication_pg_wal_lsn_diff` с исключением JDBC-walsender из-за NaN; `haproxy_server_up` → `sum(haproxy_server_status{state="UP"}) == 0` — в `patroni_back` только лидер проходит чек `/master`, DOWN у реплик это норма); все 5 правил health=ok, активных алертов нет |
| `backlog/007-monitoring.md`, `backlog/010-replication-tests.md` | Статус `wait` → `done`, DoD отмечен по результатам живой проверки (13/13 target UP, 4 дашборда, `4 passed`, отчёты в `data_tests/reports/`), добавлен «Итог проверки»; перенесены в `backlog/03 - done/` вместе с `009` (статус уже был `done`, но файл лежал в `01 - wait/`) |
| `docs/components.md` | Новый блок «Альтернативные компоненты»: `pg-physical-replica` ↔ `patroni4_readonly` (два способа физ. read-only копии) и `pg-logical-replica` ↔ `pg-audit-consumer` (два способа логической репликации: копия данных ↔ журнал операций) |
| `AGENTS.md`, `README.md` | Короткие пометки об этих парах-альтернативах (Architecture / после таблицы требований) |

## 2026-10-07 — Реорганизация топологии: patroni4_readonly (член Patroni) + pg-physical-replica (вне Patroni)

Вторая физическая реплика переведена из автономной standby (`pg-physical-replica2`) в **член кластера Patroni** `patroni4_readonly` (`tags.nofailover: true`), а `pg-physical-replica` возвращена в статус **plain-реплики вне Patroni** (нет etcd/REST, стриминг через постоянный физический слот `pg_physical_replica`). Хост-порты: `pg-physical-replica` `:5433`, `patroni4_readonly` `:5436`.

### Изменённые файлы

| Файл | Что изменено |
|------|-------------|
| `patroni-cluster/docker-compose.yml` | `pg-physical-replica2` → `patroni4_readonly` (имя/connect_address/volume `./data/pg_physical2`, `5436:5432`, `nofailover: true`, образ `./patroni`); `pg-physical-replica` → `build: ./replica-physical`, env `PGPASSWORD: replicator`, **`PGDATA: /var/lib/postgresql/data`** (в postgres:18 иначе бекап уходит в анонимный volume и падает `Permission denied`), `5433:5432`; `pg_physical_replica` (`type: physical`) добавлен в `bootstrap.dcs.slots` на patroni1/2/3; `pg-exporter-physical2` → `pg-exporter-patroni4` (DSN patroni4_readonly); pgadmin volume → named `pgadmin-data` (bind-mount на Windows не переживал `chown`) |
| `patroni-cluster/replica-physical/entrypoint.sh` | Переписан: guard от записи не туда при `PGDATA != /data/pgdata`; свежий PGDATA → `pg_basebackup` через haproxy + `standby.signal`; существующий PGDATA → идемпотентное добавление `primary_conninfo` (`application_name=pg_physical_replica`) и `primary_slot_name = 'pg_physical_replica'` в `postgresql.auto.conf` |
| `patroni-cluster/pgadmin/servers.json` | Сервер `"5"`: Patroni4 readonly → `patroni4_readonly`; переимпорт серверов — через wipe named volume `patroni-cluster_pgadmin-data` (не `data/pgadmin`) |
| `patroni-cluster/prometheus/prometheus.yml` | job `patroni`: 4 цели (patroni1/2/3 + `patroni4_readonly:8008`); job `postgresql`: `pg-exporter-patroni4:9187` (7 целей); `pg-physical-replica:8008` из job `patroni` убран (нет REST) |
| `patroni-cluster/architecture.dot` | Панель 4 членов Patroni (+nofailover), `pg-physical-replica` в отдельной группе с пометкой слота; добавлены группа «Мониторинг» (Prometheus/Grafana/cAdvisor/7 × postgres_exporter), load-generator и рёбра мониторинга |
| `images/diagram.png` | Перерисован из `patroni-cluster/architecture.dot` (graphviz 12.2.1, 1675×1179) — актуальная топология: 4 члена Patroni + plain-реплика по слоту, pgAdmin-сервер `patroni4_readonly`, мониторинг |
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
