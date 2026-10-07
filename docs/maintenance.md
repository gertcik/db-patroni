# Обслуживание БД

В кластере четыре категории баз данных, и каждая требует своего подхода:

| Категория | Характеристика | DML (INSERT/UPDATE/DELETE) | DDL (CREATE/ALTER/DROP) | Обслуживание (VACUUM/ANALYZE) |
|-----------|---------------|---------------------------|------------------------|-------------------------------|
| **Patroni-кластер** (patroni1/2/3) | Managed by Patroni, автоfailover | **Да** — только на мастере | **Да** — на мастере, автоматически реплицируется | **Да** — на мастере (autovacuum) |
| **Физические реплики** (patroni4_readonly — член Patroni; pg-physical-replica — вне Patroni) | streaming WAL, read-only | **Нет** — всегда в recovery (`pg_is_in_recovery() = t`) | **Нет** — копия с мастера через WAL | **Нет** — копия с мастера через WAL |
| **Логическая реплика** (pg-logical-replica) | Logical replication, read-only через подписку | **Нет** — apply worker применяет DML из подписки | **Нет** — DDL не реплицируются, нужен ручной DDL | **Нет** — копия с мастера через WAL |
| **pg-audit-log** | Append-only аудит-БД (all TEXT, без ограничений) | **Да** — но НЕ на таблицах `bookings.*` (append-only через WAL consumer) | **Да** — но НЕ на таблицах `bookings.*` (схема фиксирована) | **Да** — autovacuum работает, ANALYZE для статистики |

## Что разрешено и запрещено

| Операция | Patroni-мастер | Patroni-реплики | Физ. реплики (2) | Логическая реплика | pg-audit-log (любые таблицы кроме `bookings.*`) | pg-audit-log (`bookings.*` — аудит-таблицы) |
|----------|---------------|-----------------|-------------------|-------------------|-----------------------------------------------|---------------------------------------------|
| INSERT / UPDATE / DELETE | ✅ | ❌ (read-only) | ❌ (read-only) | ❌ (apply worker) | ✅ | ⚠️ только INSERT через WAL consumer |
| CREATE TABLE / INDEX | ✅ (auto-replicates) | ❌ | ❌ | ⚠️ ручной DDL | ✅ | ❌ |
| ALTER TABLE | ✅ (auto-replicates) | ❌ | ❌ | ⚠️ ручной DDL | ✅ | ❌ |
| DROP TABLE / INDEX | ✅ (auto-replicates) | ❌ | ❌ | ⚠️ ручной DDL | ✅ | ❌ |
| VACUUM / ANALYZE | ✅ (autovacuum) | ❌ | ❌ | ❌ | ✅ | ✅ (autovacuum) |
| TRUNCATE | ✅ | ❌ | ❌ | ❌ | ✅ | ❌ (не реплицируется) |
| Функция/процедура **с изменением данных** (INSERT/UPDATE/DELETE) | ✅ | ❌ (read-only) | ❌ (read-only) | ⚠️ выполнится, но данные не реплицируются | ✅ | ⚠️ только INSERT через WAL consumer |
| Функция/процедура **без изменения данных** (SELECT, временные таблицы) | ✅ | ✅ | ✅ (read-only) | ✅ | ✅ | ✅ (read-only) |
| Временные таблицы (`CREATE TEMP TABLE`) | ✅ | ✅ (session-local) | ❌ (read-only) | ✅ (session-local) | ✅ (session-local) | ✅ (session-local) |

> **pg-audit-log — это отдельный экземпляр PostgreSQL**, а не реплика Patroni. На нём можно выполнять любые DDL/DML операции на произвольных таблицах. Но таблицы схемы `bookings.*` (9 аудит-таблиц) — append-only: их структура и данные управляются только WAL consumer'ом. ⚠️ Любая прямая модификация `bookings.*` (INSERT/UPDATE/DELETE/ALTER/DROP) нарушит целостность аудита и может привести к ошибке consumer'а.

> **Проблемы физической реплики** (ограничения hot standby: временные таблицы, DML, хранимые процедуры) вынесены в отдельный файл: [Известные проблемы](issues.md).

## Как добавлять / удалять таблицы

**Добавление таблицы:**

1. Создать таблицу на **мастере** Patroni:
   ```sql
   CREATE TABLE bookings.categories (
       id SERIAL PRIMARY KEY,
       name VARCHAR(100) NOT NULL
   );
   ```
2. На мастер-кластере таблица появится на всех нодах (streaming replication).
3. Физические реплики получат таблицу автоматически (WAL streaming).
4. Публикация `shop_pub` создана как `FOR ALL TABLES` — новая таблица попадает в неё автоматически, `ALTER PUBLICATION` не нужен.
5. ⚠️ На логической реплике таблицу нужно создать **вручную** (DDL не реплицируется) — тем же `CREATE TABLE ...`, что и на мастере.

**Удаление таблицы:**

1. `DROP TABLE` на мастере — удалится на всех нодах кластера и физических репликах (кроме логической реплики — там удалить вручную).
2. На логической реплике выполнить `DROP TABLE IF EXISTS bookings.categories;`
   (из публикации `FOR ALL TABLES` таблица исчезает автоматически вместе с ней).

## Как добавлять / удалять поля и ограничения

Все DDL выполняются **только на мастере** Patroni:

```sql
-- добавить поле
ALTER TABLE bookings.tickets ADD COLUMN contact_phone VARCHAR(20);

-- удалить поле
ALTER TABLE bookings.tickets DROP COLUMN contact_phone;

-- добавить ограничение
ALTER TABLE bookings.bookings ADD CONSTRAINT chk_amount CHECK (total_amount > 0);

-- удалить ограничение
ALTER TABLE bookings.bookings DROP CONSTRAINT chk_amount;
```

1. **Физическая реплика** — изменения применяются автоматически (WAL streaming).
2. **Логическая реплика** — DDL не реплицируются логической репликацией.
   ⚠️ После ALTER TABLE на мастере нужно **вручную выполнить тот же DDL на логической реплике**, иначе подписка упадёт с ошибкой.
3. Рекомендуется временно отключать подписку на время массовых DDL:
   ```sql
   ALTER SUBSCRIPTION shop_sub DISABLE;
   -- выполнить DDL на мастере и логической реплике
   ALTER SUBSCRIPTION shop_sub ENABLE;
   ```

## Восстановление логической реплики после сбоя

Если на логической реплике удалена таблица, нарушена ссылочная целостность или подписка упала с ошибкой apply, необходимо пересоздать подписку с полной синхронизацией данных.

**Сценарий: удалена таблица `bookings.flights` на логической реплике**

```sql
-- 1. На логической реплике: удалить подписку
ALTER SUBSCRIPTION shop_sub DISABLE;
DROP SUBSCRIPTION shop_sub;

-- 2. На ТЕКУЩЕМ лидере (patronictl list): пересоздать слот shop_sub.
--    DROP SUBSCRIPTION удаляет слот на паблишере, а create_slot = false
--    в шаге 4 ожидает, что слот уже существует.
SELECT pg_create_logical_replication_slot('shop_sub','pgoutput');

-- 3. Создать таблицу заново (такой же DDL, как на мастере)
CREATE TABLE bookings.flights (
    flight_id           SERIAL PRIMARY KEY,
    route_no            TEXT NOT NULL,
    status              TEXT NOT NULL CHECK (status IN ('Scheduled','On Time','Delayed','Boarding','Departed','Arrived','Cancelled')),
    scheduled_departure TIMESTAMPTZ NOT NULL,
    scheduled_arrival   TIMESTAMPTZ NOT NULL CHECK (scheduled_arrival > scheduled_departure),
    actual_departure    TIMESTAMPTZ,
    actual_arrival      TIMESTAMPTZ
);

-- 4. Пересоздать подписку с copy_data = true (скопирует все существующие данные)
CREATE SUBSCRIPTION shop_sub
CONNECTION 'host=haproxy port=5432 dbname=shop user=postgres password=secret'
PUBLICATION shop_pub
WITH (copy_data = true, create_slot = false);
```

**Если испорчено несколько таблиц или вся схема:**

```sql
-- 1. Удалить подписку (заодно удаляется слот shop_sub на паблишере)
DROP SUBSCRIPTION IF EXISTS shop_sub;

-- 2. На ТЕКУЩЕМ лидере пересоздать слот
SELECT pg_create_logical_replication_slot('shop_sub','pgoutput');

-- 3. Удалить и пересоздать всю схему bookings
DROP SCHEMA bookings CASCADE;
-- затем выполнить все CREATE TABLE из patroni-cluster/patroni/demo-airlines.sql
-- (кроме INSERT — данные скопируются через copy_data)

-- 4. Пересоздать подписку
CREATE SUBSCRIPTION shop_sub
CONNECTION 'host=haproxy port=5432 dbname=shop user=postgres password=secret'
PUBLICATION shop_pub
WITH (copy_data = true, create_slot = false);
```

**Быстрый способ — пересоздать контейнер (после шагов 1–3 выше):**
```bash
docker compose rm -sf pg-logical-replica
docker compose up -d pg-logical-replica
```
Контейнер выполнит повторную инициализацию: уже существующий PGDATA сохраняется
(initdb не выполняется), создаются только недостающие таблицы (`IF NOT EXISTS`)
и подписка с `copy_data = true`. Поэтому перед этим нужно удалить старую подписку
и пересоздать слот `shop_sub` на лидере, иначе entrypoint увидит существующую
(сломанную) подписку и ничего не исправит.

**Рекомендации по предотвращению:**

1. **Не выполнять DDL напрямую на логической реплике** — все изменения схемы только на мастере, затем повторять те же DDL на реплике вручную
2. **Перед массовыми DDL** временно отключать подписку (`ALTER SUBSCRIPTION shop_sub DISABLE`), выполнить DDL на мастере и реплике, затем включить (`ENABLE`)
3. **Не записывать данные напрямую** на логическую реплику — они будут перезаписаны при следующем apply или вызовут конфликт первичных ключей
4. **Мониторить статус подписки:**
   ```sql
   SELECT subname, subenabled, subtwophasestate FROM pg_subscription;
   SELECT pid, state, wait_event FROM pg_stat_activity
   WHERE backend_type LIKE '%logical replication%';
   ```
5. **Проверять лаг репликации** после интенсивной записи на мастере

## Как добавлять / удалять индексы

```sql
-- создать индекс (на мастере)
CREATE INDEX idx_flights_status ON bookings.flights(status);

-- удалить индекс
DROP INDEX idx_flights_status;
```

1. Физическая реплика получит изменения индексов через WAL.
2. Логическая реплика НЕ реплицирует DDL индексов — выполнить вручную:
  ```sql
  CREATE INDEX idx_flights_status ON bookings.flights(status);
  ```

## Обслуживание индексов и таблиц

| Операция | Команда | Когда делать |
|----------|---------|-------------|
| VACUUM | `VACUUM (VERBOSE, ANALYZE) bookings.flights;` | При росте мёртвых кортежей (>20%) |
| ANALYZE | `ANALYZE bookings.flights;` | После массовых изменений (>10% строк) |
| REINDEX | `REINDEX INDEX idx_flights_status;` | При разбухании индекса (bloat) |

Autovacuum включён по умолчанию. Наблюдать за статистикой:

```sql
-- мёртвые кортежи
SELECT relname, n_dead_tup, n_live_tup,
       round(n_dead_tup * 100.0 / (n_live_tup + n_dead_tup + 1), 1) AS dead_pct
FROM pg_stat_user_tables WHERE n_dead_tup > 0 ORDER BY n_dead_tup DESC;

-- размер индексов
SELECT indexrelid::regclass, pg_size_pretty(pg_relation_size(indexrelid))
FROM pg_stat_user_indexes ORDER BY pg_relation_size(indexrelid) DESC;
```

VACUUM и ANALYZE можно выполнять на любой реплике (только для чтения статистики). Полноценный VACUUM для освобождения места — только на мастере.
