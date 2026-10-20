# Проблемы реплики

**Статус:** done ✅
**Приоритет:** high
**Создана:** 2026-10-20
**Закрыта:** 2026-10-20

## Описание

1. как понять сколько отставание по логической репликации? Какой запрос?
2. на audit реплике (pg-audit-log) почему-то в таблицах-получателях информации все поля текстовые. Выяснить причину и сделать так, чтобы были типы зеркальные с целевыми.

Вот таблица на получателе:
CREATE TABLE IF NOT EXISTS bookings.airplanes_data (
    airplane_code TEXT,
    model         TEXT,
    range         TEXT,
    speed         TEXT,
    movedate      TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername   TEXT DEFAULT 'wal_consumer',
    moveaction    TEXT,
    id_identity   BIGINT GENERATED ALWAYS AS IDENTITY
);

А вот исходная таблица:
CREATE TABLE IF NOT EXISTS bookings.airplanes_data (
    airplane_code CHAR(3) PRIMARY KEY,
    model         TEXT NOT NULL,
    range         INTEGER NOT NULL CHECK (range > 0),
    speed         INTEGER NOT NULL CHECK (speed > 0)
);

Нужно, чтобы таблица в БД получателе была такая, также как и все остальные таблицы на БД получателе (то есть типы сохраняются, кроме IDENTITY и DEFAULT и NOT NULL):
CREATE TABLE IF NOT EXISTS bookings.airplanes_data (
    airplane_code CHAR(3) NULL,
    model         TEXT NULL,
    range         INTEGER NULL,
    speed         INTEGER NULL,
    movedate      TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername   TEXT DEFAULT 'wal_consumer',
    moveaction    TEXT,
    id_identity   BIGINT GENERATED ALWAYS AS IDENTITY
);

Если требуется доработа pg-audit-consumer - сделай её

## Выполнение (2026-10-20)

### 1. Отставание по логической репликации — какой запрос

Основной индикатор — `confirmed_flush_lsn` логического слота на **мастере** (сколько WAL ещё не «подтверждено» потребителем):

```sql
SELECT slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_slot_bytes,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS confirmed_flush_lag
FROM pg_replication_slots
WHERE slot_type = 'logical';   -- 'shop_sub' и 'audit_slot'
```

Дополнительно на логической реплике — жив ли apply worker (`pg_stat_subscription`; в PG18 колонки `application_lsn` нет):

```sql
SELECT subname, worker_type,
       pg_size_pretty(pg_wal_lsn_diff(latest_end_lsn, received_lsn)) AS apply_lag
FROM pg_stat_subscription;
```

Полный набор мониторинга: `docs/monitoring.md` (запросы актуализированы во время этой задачи).

### 2. Причина TEXT-типов в аудит-БД

Причина: `pg-audit-log/init-audit.sql` создавал все таблицы с колонками `TEXT` (упрощённое зеркало), а consumer просто делал `INSERT` с `setString` по всем колонкам, не проверяя схему приёмника.

### Решение

**pg-audit-consumer** (доработка `AuditWriter.java` + `App.java`):

- при первом появлении таблицы в WAL-потоке consumer читает типы колонок **источника** через `pg_catalog.format_type` (отдельное JDBC-соединение к мастеру через HAProxy) и приводит audit-таблицу к ним:
  - таблица отсутствует → `CREATE TABLE` с зеркальными типами (NULL, без NOT NULL/DEFAULT/CONSTRAINT) + 4 служебные колонки (`movedate`, `moveusername`, `moveaction`, `id_identity`);
  - тип колонки отличается (наследие `TEXT`) → `ALTER COLUMN ... TYPE ... USING (col::тип)` — существующие данные конвертируются;
  - колонка добавлена на мастере → `ADD COLUMN`;
  - таблица удалена на мастере → изменения пропускаются с `[WARN]` (не crash-loop на исторических WAL-записях);
- INSERT'ы строятся с явными кастами по колонкам: `CAST(? AS INTEGER)`, `CAST(? AS TIMESTAMPTZ)` и т.д. — строковые WAL-значения попадают в реальные типы;
- выравнивание выполняется один раз на процесс consumer (кэш SQL на таблицу); DDL коммитится сразу, независимо от успеха последующего батча.

**pg-audit-log/init-audit.sql**: переписан — те же зеркальные типы (`CHAR(3)`, `INTEGER`, `INTEGER[]`, `TIME`, `INTERVAL`, `TIMESTAMPTZ`, `NUMERIC(10,2)`, `BOOLEAN`, `TEXT`), для чистой установки БД аудита.

**Оперативные детали проверки**: backlog логического слота после 8 ч простоя (488 MB) сливался дольше на Windows bind mount — временно ставил `ALTER DATABASE shop SET synchronous_commit = off` на pg-audit-log (скорость слива выросла ~5 раз), после догоняния вернул `RESET`. load-generator на время слива останавливался и запускался обратно.

### Проверка (live)

- Старая БД аудита (все `TEXT`, bind-тяжёлые данные) мигрировала автоматически: consumer после пересборки переименовал все 42 колонки (`ALTER ... USING`), сравнение типов мастер↔аудит: **42/42 OK** (скрипт-проверка).
- Данные типизированы: `range`/`speed` — `integer`, `days_of_week` — `{1,3,5}` (`integer[]`), `scheduled_time` — `time`, `duration` — `interval` и т.д.
- replication-tests: **4/4 passed** (DML mirroring + failover).

## Итог

Задача закрыта. Query-ответ добавлен в задачу и актуализирован в `docs/monitoring.md`; зеркальные типы — в `pg-audit-log/init-audit.sql` + авто-выравнивание в `pg-audit-consumer`.
