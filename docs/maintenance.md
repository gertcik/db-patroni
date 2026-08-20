# Обслуживание БД

В кластере есть три категории баз данных, и каждая требует своего подхода при изменениях схемы:

| Категория | Характеристика | Запись | DDL |
|-----------|---------------|--------|-----|
| **Patroni-кластер** (patroni1/2/3) | Managed by Patroni, автоfailover | Только мастер | На мастере, автоматически реплицируется |
| **Физическая реплика** (pg-physical-replica) | Streaming WAL, read-only | Нет | Нет (копия с мастера) |
| **Логическая реплика** (pg-logical-replica) | Logical replication, read-only через подписку | Нет | Нет (копия через publication) |

## Как добавлять / удалять таблицы

**Добавление таблицы:**

1. Создать таблицу на **мастере** Patroni:
   ```sql
   CREATE TABLE shop.categories (
       id SERIAL PRIMARY KEY,
       name VARCHAR(100) NOT NULL
   );
   ```
2. На мастер-кластере таблица появится на всех трёх нодах (streaming replication).
3. Физическая реплика получит таблицу автоматически (WAL streaming).
4. Для логической реплики — добавить таблицу в publication:
   ```sql
   ALTER PUBLICATION shop_pub ADD TABLE shop.categories;
   ```
5. На логической реплике таблица появится автоматически (подписка активна).

**Удаление таблицы:**

1. `DROP TABLE` на мастере — удалится везде (кроме логической реплики).
2. Удалить из publication:
   ```sql
   ALTER PUBLICATION shop_pub DROP TABLE shop.categories;
   ```
3. На логической реплике выполнить `DROP TABLE IF EXISTS shop.categories;`

## Как добавлять / удалять поля и ограничения

Все DDL выполняются **только на мастере** Patroni:

```sql
-- добавить поле
ALTER TABLE shop.users ADD COLUMN phone VARCHAR(20);

-- удалить поле
ALTER TABLE shop.users DROP COLUMN phone;

-- добавить ограничение
ALTER TABLE shop.products ADD CONSTRAINT chk_price CHECK (price > 0);

-- удалить ограничение
ALTER TABLE shop.products DROP CONSTRAINT chk_price;
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

-- 2. Создать таблицу заново (такой же DDL, как на мастере)
CREATE TABLE bookings.flights (
    flight_id           SERIAL PRIMARY KEY,
    route_no            TEXT NOT NULL,
    status              TEXT NOT NULL CHECK (status IN ('Scheduled','On Time','Delayed','Boarding','Departed','Arrived','Cancelled')),
    scheduled_departure TIMESTAMPTZ NOT NULL,
    scheduled_arrival   TIMESTAMPTZ NOT NULL CHECK (scheduled_arrival > scheduled_departure),
    actual_departure    TIMESTAMPTZ,
    actual_arrival      TIMESTAMPTZ
);

-- 3. Пересоздать подписку с copy_data = true (скопирует все существующие данные)
CREATE SUBSCRIPTION shop_sub
CONNECTION 'host=haproxy port=5432 dbname=shop user=postgres password=secret'
PUBLICATION shop_pub
WITH (copy_data = true, create_slot = false);
```

**Если испорчено несколько таблиц или вся схема:**

```sql
-- 1. Удалить подписку
DROP SUBSCRIPTION IF EXISTS shop_sub;

-- 2. Удалить и пересоздать всю схему bookings
DROP SCHEMA bookings CASCADE;
-- затем выполнить все CREATE TABLE из patroni-cluster/patroni/demo-airlines.sql
-- (кроме INSERT — данные скопируются через copy_data)

-- 3. Пересоздать подписку
CREATE SUBSCRIPTION shop_sub
CONNECTION 'host=haproxy port=5432 dbname=shop user=postgres password=secret'
PUBLICATION shop_pub
WITH (copy_data = true, create_slot = false);
```

**Быстрый способ — пересоздать контейнер:**
```bash
docker compose rm -sf pg-logical-replica
docker compose up -d pg-logical-replica
```
Контейнер выполнит полную переинициализацию: initdb → создание таблиц → CREATE SUBSCRIPTION с `copy_data = true`.

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
CREATE INDEX idx_users_email ON shop.users(email);

-- удалить индекс
DROP INDEX idx_users_email;
```

1. Физическая реплика получит изменения индексов через WAL.
2. Логическая реплика НЕ реплицирует DDL индексов — выполнить вручную:
  ```sql
  CREATE INDEX idx_users_email ON shop.users(email);
  ```

## Обслуживание индексов и таблиц

| Операция | Команда | Когда делать |
|----------|---------|-------------|
| VACUUM | `VACUUM (VERBOSE, ANALYZE) shop.users;` | При росте мёртвых кортежей (>20%) |
| ANALYZE | `ANALYZE shop.users;` | После массовых изменений (>10% строк) |
| REINDEX | `REINDEX INDEX idx_users_email;` | При разбухании индекса (bloat) |

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
