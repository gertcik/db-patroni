# Известные проблемы

## 1. Проблемы физической реплики

В upstream PostgreSQL 17/18 физическая реплика (hot standby) работает в **read-only** режиме, что создаёт ряд ограничений:

1. **Временные таблицы** — `CREATE TEMP TABLE` запрещён, потому что DDL требует обновления системного каталога, а транзакции на standby не получают XID.
2. **DML во временных таблицах** — даже если временная таблица уже существует, `INSERT`/`UPDATE`/`DELETE` в ней невозможны (read-only транзакции).
3. **Вызов хранимых процедур** — если процедура модифицирует данные (INSERT/UPDATE/DELETE), она не выполнится на standby. Даже процедуры без явного DML могут потребовать записей в WAL, что невозможно в read-only режиме.

Эти ограничения описаны в документации PostgreSQL: [Hot Standby — Caveats](https://www.postgresql.org/docs/18/hot-standby.html#STANDBY-CAVEATS).

### Решение в Postgres Pro Enterprise 18.4.1

Временные таблицы, последовательности, представления и временные функции работают на репликах при включённых параметрах:

```
enable_standby_temp_tables = on
enable_temp_memory_catalog = on
hot_standby = on
```

Подробнее: [Релиз Postgres Pro Enterprise 18.4.1](https://habr.com/ru/companies/postgrespro/news/1056090/).

## 2. Имя пользователя в аудит-логе

### Проблема

WAL consumer (`pg-audit-consumer`) использует replication-протокол PostgreSQL (`pgoutput v1`) для чтения логического слота `audit_slot`. Протокол pgoutput v1 **не передаёт имя пользователя**, выполнившего транзакцию — в WAL-потоке доступны только LSN, timestamp и данные строк.

Колонка `moveusername` в audit-таблицах заполняется жёстко как `'wal_consumer'` (имя подключения consumer'а), а не оригинальным пользователем БД.

### Что поступает в WAL consumer

| Поле | Доступно | Комментарий |
|------|----------|-------------|
| LSN (Log Sequence Number) | ✅ | `decodeBegin()` — `finalLsn`, `endLsn` |
| Timestamp транзакции | ✅ | `decodeBegin()` — `ts` |
| Таблица (schema + name) | ✅ | `decodeRelation()` |
| Данные строк (старые + новые) | ✅ | `decodeInsert/Update/Delete()` |
| Имя пользователя (role) | ❌ | pgoutput v1 не включает это поле |
| OID пользователя | ❌ | Не передаётся в pgoutput v1 |

### Рабочее решение

Добавить в каждую таблицу на мастере колонку `modified_by TEXT DEFAULT current_user`:

```sql
ALTER TABLE bookings.airplanes ADD COLUMN modified_by TEXT DEFAULT current_user;
```

При INSERT/UPDATE/DELeTE значение `current_user` автоматически подставляется как значение колонки и попадает в WAL как обычное данные строки. Consumer записывает его в audit-таблицу.

**Недостаток:** требует DDL на мастере + миграция данных.

### Альтернативы (не реализованы)

1. **Хранимая процедура** — все DML через процедуру, которая логирует `current_user` в отдельную таблицу.
2. **pg_audit extension** — логирование всех DML с пользователем (внешний лог, не в формате audit-таблиц).
3. **session_replication_role + триггеры** — на логической реплике триггеры подставляют `current_user` при apply (неприменимо для audit-log — там нет подписки, только WAL consumer).

Подробнее: [monitoring.md — `moveusername` всегда `'wal_consumer'`](monitoring.md#moveusername-всегда-wal_consumer).
