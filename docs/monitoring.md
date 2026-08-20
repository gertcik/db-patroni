# Мониторинг и известные ограничения

## Ключевые метрики

| Группа | Метрика | Что показывает | Порог тревоги |
|--------|---------|---------------|--------------|
| **Кластер** | Состояние лидера | Какая нода мастер | Любое изменение ≠ ожидаемый мастер |
| **Кластер** | Число нод в `running` | Все ли ноды живы | < 3 |
| **Кластер** | Replication lag | Отставание реплик (байты) | > 50 MB |
| **Patroni** | `patroni.clocks.ts` | Timestamp API | Не обновляется > 30s |
| **PG** | Connections (`numbackends`) | Активные соединения | > 80% от max_connections |
| **PG** | Dead tuples (`n_dead_tup`) | Мусор в таблицах | > 20% живых кортежей |
| **PG** | Cache hit ratio (`blks_hit / blks_read`) | Эффективность кэша | < 95% |
| **PG** | Transaction rate (`xact_commit + xact_rollback`) | Активность БД | Резкое падение → проблема |
| **OS** | CPU, RAM, Disk | Ресурсы хоста | CPU > 80%, RAM < 10%, Disk < 20% |

## Откуда брать метрики

1. **Patroni REST API** (`GET /cluster`, `GET /health`) — состояние лидера, лаг реплик
2. **pg_stat_*** представления — статистика PostgreSQL
3. **HAProxy stats** (`:7000`) — состояние бэкендов, количество сессий
4. **Docker** (`docker stats`) — ресурсы контейнеров

## Мониторинг репликации

### Физическая репликация (WAL streaming)

На **мастере** — общий лаг всех физических реплик через WAL:

```sql
-- лаг всех физических подписчиков WAL
SELECT application_name, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag_bytes,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_raw
FROM pg_stat_replication;
```

На **физической реплике** — насколько её replay отстаёт от полученного WAL:

```sql
-- лаг apply на самой реплике
SELECT pg_size_pretty(pg_wal_lsn_diff(
    pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()
)) AS apply_lag;
```

### Логическая репликация (PUB/SUB)

На **мастере** — сколько WAL не забрал логический слот:

```sql
-- отставание слота shop_sub
SELECT slot_name, slot_type, database,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_slot_bytes,
       pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS confirmed_flush_lag_raw,
       active
FROM pg_replication_slots
WHERE slot_name IN ('shop_sub', 'audit_slot');
```

На **логической реплике** — статус подписки и отставание apply worker:

```sql
-- отставание apply (разница между последним полученным LSN из WAL мастера
-- и последним применённым на логической реплике)
SELECT subname,
       latest_end_lsn,
       application_lsn,
       pg_size_pretty(pg_wal_lsn_diff(latest_end_lsn, application_lsn)) AS apply_lag_bytes
FROM pg_stat_subscription;

-- статус apply worker
SELECT pid, state, wait_event,
       backend_type,
       pg_size_pretty(
           pg_wal_lsn_diff(pg_stat_get_activity(pid)::pg_lsn, pg_last_wal_replay_lsn())
       ) AS worker_lag
FROM pg_stat_activity
WHERE backend_type LIKE '%logical replication%';
```

### Audit consumer (WAL consumer)

Отставание чтения WAL consumer'ом — через слот `audit_slot` на мастере:

```sql
-- отставание consumer
SELECT slot_name,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS consumer_lag,
       confirmed_flush_lsn,
       pg_current_wal_lsn() AS current_wal
FROM pg_replication_slots
WHERE slot_name = 'audit_slot';
```

Если `confirmed_flush_lsn` не обновляется длительное время — WAL consumer упал или завис.

### Единый запрос (на мастере)

```sql
WITH
phys AS (
    SELECT 'physical' AS type, application_name,
           pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag
    FROM pg_stat_replication
),
slots AS (
    SELECT 'logical:'||slot_name AS type,
           pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag
    FROM pg_replication_slots
    WHERE slot_type = 'logical'
)
SELECT type,
       CASE WHEN lag IS NULL THEN 'no data' ELSE pg_size_pretty(lag) END AS lag,
       lag AS lag_raw
FROM (
    SELECT type, lag FROM phys
    UNION ALL
    SELECT type, lag FROM slots
) x
ORDER BY lag DESC NULLS LAST;
```

## Рекомендуемые проверки

```sql
-- лаг репликации (на мастере) — физические подписчики WAL
SELECT application_name, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag
FROM pg_stat_replication;

-- лаг логических слотов (shop_sub, audit_slot)
SELECT slot_name,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag
FROM pg_replication_slots WHERE slot_type = 'logical';

-- здоровье Patroni
-- GET http://localhost:8008/health

-- активность (на мастере)
SELECT pid, state, wait_event, query_start, left(query, 60)
FROM pg_stat_activity WHERE state != 'idle' ORDER BY query_start;
```

## Известные ограничения

### `moveusername` всегда `'wal_consumer'`

WAL consumer (`pg-audit-consumer`) использует replication-протокол PostgreSQL для чтения логического слота `audit_slot`. В этом режиме подключение выполняется от системного пользователя репликации (`replicator`), а не от того пользователя, который выполнил DML-операцию на мастере.

**Следствие:** колонка `moveusername` в audit-таблицах всегда содержит значение `'wal_consumer'` — оригинальный пользователь БД (например, `postgres` или `alice`) теряется.

**Когда это может быть важно:**
1. Аудит требует идентификации, кто именно выполнил изменение (INSERT/UPDATE/DELETE)
2. Расследование инцидентов: нужно знать, какой пользователь удалил запись

**Варианты решения (не реализованы):**
1. **Дополнительная колонка на мастере** — добавить в каждую таблице колонку `modified_by TEXT DEFAULT current_user`, тогда оригинальный пользователь попадёт в WAL как обычное значение колонки.
2. **Хранимая процедура** — все DML через процедуру, которая логирует `current_user` в отдельную таблицу.
3. **pg_audit extension** — включить `pg_audit` для логирования всех DML с пользователем (но это внешний лог, не в формате строк audit-таблиц).
4. **session_replication_role + триггеры** — на логической реплике добавить триггеры, которые при apply подставляют `current_user` (неприменимо для audit-log — там нет подписки, только WAL consumer).

**Текущее состояние:** `moveusername` — константа `'wal_consumer'`. Если требуется точное имя пользователя — использовать вариант 1 (колонка на мастере).

## Проблемы на Windows

### Медленный fsync и crash recovery

PostgreSQL при старте после аварийного завершения (dirty shutdown) выполняет **crash recovery** — проверку и восстановление данных. Часть этого процесса — `fsync` (сброс данных с файлового кэша ОС на диск) для каждого файла в data directory.

На **Linux** (ext4/xfs) fsync выполняется за миллисекунды. На **Windows с Docker bind mount** (NTFS через виртуальный диск Docker Desktop) fsync одного файла может занимать **~10 секунд**. В data directory с тысячами файлов crash recovery затягивается на минуты.

**Симптомы:**

1. Patroni убивает процесс PostgreSQL через 60 секунд (`Cancelling long running task doing crash recovery in a single user mode`)
2. PostgreSQL завершается с `code=1`
3. Patroni видит "PostgreSQL is not running" и запускает заново
4. PostgreSQL снова начинает crash recovery → бесконечный цикл

**Пример логов:**

```
syncing data directory (fsync), elapsed time: 10.15 s, current path: ./base/1/2668
syncing data directory (fsync), elapsed time: 20.04 s, current path: ./base/1/3603_vm
syncing data directory (fsync), elapsed time: 30.01 s, current path: ./base/16384/1417
...
Cancelling long running task doing crash recovery in a single user mode
Crash recovery finished with code=1
```

**Решение:**

1. **Удалить данные и пересоздать ноду:**
   ```bash
   docker compose stop patroni1
   Remove-Item -Path "data\pgdata1\*" -Recurse -Force
   docker compose start patroni1
   ```
   Нода сделает `pg_basebackup` с текущего мастера и войдёт в кластер как реплика.

2. **Использовать Docker volumes вместо bind mount** — виртуальные тома Docker работают быстрее, чем bind mount на NTFS:
   ```yaml
   # вместо ./data/pgdata1:/data
   volumes:
     - pgdata1:/data
   ```

3. **Запускать кластер на Linux** — fsync на native filesystem работает в сотни раз быстрее.

### Медленный pg_basebackup

Аналогичная проблема — `pg_basebackup` при инициализации реплики пишет тысячи файлов на диск. На Windows bind mount это может занять **3–5 минут** вместо 10–20 секунд на Linux. Кластер в итоге работает, но старт занимает значительно больше времени.
