# Репликация данных и аудит-лог

## Репликация DML

DML-операции (INSERT, UPDATE, DELETE) проходят по трём независимым путям репликации:

### 1. Внутри кластера Patroni (patroni1/2/3)

```
Клиент → HAProxy :5432 → Patroni-мастер
                              ↓
                    WAL streaming (синхронный/асинхронный)
                              ↓
                   Patroni-реплики (read-only)
```

1. DML выполняется только на **мастере** (HAProxy направляет все write-запросы на него).
2. Мастер записывает изменения в WAL, реплики получают WAL через **streaming replication** и применяют.
3. Реплики Patroni **read-only** — DML на них не выполняется.
4. Задержка репликации отслеживается через `pg_stat_replication`.

### 2. Физические реплики (patroni4_readonly :5436, pg-physical-replica :5433)

```
Мастер Patroni → Patroni DCS (etcd) → patroni4_readonly   (:5436, член Patroni, nofailover)
                        └──────────→ pg-physical-replica   (:5433, вне Patroni, слот pg_physical_replica)
                                         ↓
                      NodeBaseBackup / pg_basebackup (первый запуск)
                                         ↓
                      WAL streaming (standby, от текущего лидера)
                                         ↓
                      Read-only копия данных
```

1. **`patroni4_readonly`** — полноправный 4-й узел кластера Patroni (`scope: patroni_cluster`, тот же etcd DCS, свой REST API `:8008`). При первом запуске Patroni делает **NodeBaseBackup** от текущего мастера, затем постоянно стримит WAL.
2. **`pg-physical-replica`** — **не член Patroni** (нет etcd/REST, не видна в `patronictl list`). Стандартный `pg_basebackup` через HAProxy + стриминг по **постоянному физическому слоту `pg_physical_replica`**. Слот объявлен в `bootstrap.dcs.slots` (в DCS) и переносится на нового лидера после failover автоматически.
3. Обе реплики никогда не избираются лидером: у `patroni4_readonly` — `tags.nofailover: true`; у `pg-physical-replica` — она вообще вне кластера Patroni (физически не может промоутиться командой Patroni). Оба требования read-only.
4. Все DML с мастера попадают на физические реплики **автоматически**, включая DDL, VACUUM, CREATE INDEX и т.д.
5. Реплики **read-only** — запись заблокирована (`pg_is_in_recovery() = t`).
6. При смене мастера `patroni4_readonly` переключается через DCS; `pg-physical-replica` продолжает читать свой слот `pg_physical_replica` на новом лидере (Patroni создаёт его там) — ручных шагов не нужно.
7. ⚠️ **Нельзя** выполнять `patronictl promote patroni4_readonly`. `pg-physical-replica` — не член кластера, promote к ней неприменим; не включать её в запись никогда.
8. Лаг репликации проверяется как и для остальных узлов:
   ```sql
   SELECT application_name, state,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag
   FROM pg_stat_replication;
   ```

### 3. Логическая реплика (pg-logical-replica :5434)

```
Мастер Patronи → HAProxy :5432 → pg-logical-replica
                                    ↓
                    Logical replication (PUB/SUB)
                    Publication: shop_pub (FOR ALL TABLES, schema bookings)
                    Subscription: shop_sub (слот shop_sub)
                                    ↓
                    DML применяется к соответствующим таблицам
```

1. Логическая реплика подписывается на **публикацию** `shop_pub`, созданную на мастере в `patroni-cluster/patroni/init.sh`.
2. Публикация `shop_pub` создана как `FOR ALL TABLES` — новые таблицы схемы `bookings` попадают в репликацию автоматически.
3. Подписка `shop_sub` использует постоянный слот `shop_sub`, который автоматически создаётся на каждом новом мастере благодаря настройке `bootstrap.dcs.slots` в конфигурации Patroni.
4. **Реплицируется только DML** (INSERT, UPDATE, DELETE) на подписанных таблицах. DDL, индексы, sequences, VACUUM и TRUNCATE **не реплицируются**.
5. Направление репликации — **однонаправленное**: только с мастера на логическую реплику. Изменения на логической реплике **не попадают** обратно на мастер.
6. Таблицы на логической реплике **не read-only** технически (нет `standby.signal`), но запись в них нарушает консистентность:
   1. Данные, записанные напрямую на логической реплике, будут **перезаписаны** при следующем apply из подписки.
   2. Первичные ключи, конфликтующие с данными мастера, приведут к ошибке подписки.

### Сводная таблица

| Операция | Patroni-реплики | Физические реплики (обе) | Логическая реплика |
|----------|----------------|-------------------|-------------------|
| INSERT / UPDATE / DELETE | Да (через WAL) | Да (через WAL) | Да (через PUB/SUB) |
| DDL (ALTER TABLE, CREATE INDEX) | Да (через WAL) | Да (через WAL) | **Нет** |
| VACUUM / TRUNCATE | Да (через WAL) | Да (через WAL) | **Нет** |
| Запись напрямую | Read-only | Read-only | Возможно, но нарушает консистентность |
| Задержка | ms–s | ms–s | ms–min (зависит от `wal_retrieve_retry_interval`) |

### Как проверить, что DML реплицируется

**Физические реплики (pg-physical-replica :5433, patroni4_readonly :5436):**
```sql
-- проверить, что данные есть
SELECT count(*) FROM bookings.flights;

-- проверить статус streaming (на мастере)
SELECT application_name, state, sync_state FROM pg_stat_replication;
```

**Логическая реплика (:5434):**
```sql
-- проверить статус подписки
SELECT subname, subenabled, subtwophasestate FROM pg_subscription;

-- проверить apply worker
SELECT pid, state, wait_event FROM pg_stat_activity
WHERE backend_type LIKE '%logical replication%';

-- проверить последний полученный LSN
SELECT * FROM pg_stat_subscription;
```

### Когда DML может потеряться

1. **Физическая реплика** — риск потери только при повреждении WAL на мастере (pg_rewind / восстановление из бэкапа).
2. **Логическая реплика** — риск потери при:
   1. Достижении `max_slot_wal_keep_size` на мастере (слот удалён) — нужна повторная настройка подписки.
   2. DDL на мастере без соответствующего DDL на логической реплике (подписка падает с ошибкой).
   3. Конфликте primary key (одинаковый PK, разные данные).
3. **Patroni-кластер** — синхронный режим выключен (`synchronous_mode: false`), возможна потеря последних транзакций при жёстком сбое мастера (асинхронный commit).

## Аудит-лог (pg-audit-log :5435)

Аудит-лог — отдельный экземпляр PostgreSQL для **append-only** хранения всех изменений (INSERT, UPDATE, DELETE) с таблиц основного кластера. Изменения доставляются через **WAL consumer** на Java 17, который читает логический слот репликации `audit_slot`.

```
Мастер Patronи → WAL consumer (Java) ← pgoutput v1 → pg-audit-log (append-only)
                     ↓
          Парсинг pgoutput: Relation / Insert / Update / Delete
                     ↓
          INSERT в audit-таблицу + movedate, moveusername, moveaction
```

### Как устроено

| Компонент | Назначение |
|-----------|-----------|
| **pg-audit-log** | PostgreSQL 18 `postgres:18` с initdb и схемой `bookings` (9 таблиц). Каждая таблица — точная копия оригинальной по именам колонок, но все типы колонок — **TEXT**. Добавлены 4 служебных колонки. |
| **pg-audit-consumer** | Java 17 приложение, подключается к HAProxy (:5432), читает слот `audit_slot`, декодирует pgoutput v1 протокол, пишет INSERT-only строки в pg-audit-log. |

### Структура audit-таблиц

Каждая из 9 таблиц схемы `bookings` на pg-audit-log содержит:

1. **Оригинальные колонки** — все `TEXT` (значения преобразуются в строки)
2. **`id_identity BIGINT GENERATED ALWAYS AS IDENTITY`** — уникальный автоинкрементный ID
3. **`movedate DATE DEFAULT CURRENT_DATE`** — дата вставки
4. **`moveusername TEXT DEFAULT 'wal_consumer'`** — источник изменения (всегда 'wal_consumer') ⚠️ см. «Известные ограничения»
5. **`moveaction TEXT`** — тип операции: `'i'` (INSERT), `'u'` (UPDATE), `'d'` (DELETE)

**Нет PK, UK, FK, CHECK, DEFAULT, NOT NULL, UNIQUE, индексов** — audit-таблицы только для вставки, без ограничений целостности.

### Как работает WAL consumer (pg-audit-consumer)

1. **Подключение к HAProxy** (`host=haproxy port=5432 dbname=shop`) по replication-протоколу.
2. **Ожидание слота** `audit_slot` (ждёт до 3 секунд, если слот ещё не создан Patroni, повторяет с паузой 5 секунд).
3. **Чтение pgoutput** версии 1 — бинарные сообщения: `Begin (b)`, `Relation (r)`, `Insert (i)`, `Update (u)`, `Delete (d)`, `Commit (c)`.
4. **Кэширование схем** — OID таблицы → schema, table, колонки (сообщение `Relation`).
5. **Накопление изменений** — все DML внутри одной транзакции (между `Begin` и `Commit`) собираются в батч.
6. **Запись в аудит-БД** — на `Commit` батч пишется одной транзакцией (batch commit).
7. **UPDATE и DELETE** — записываются как INSERT с `moveaction = 'u'` или `'d'`.

### Поток данных

```
Begin (LSN, xid)
  Relation (OID=12345 → bookings.airplanes_data: airplane_code, model, range, speed)
  Insert (OID=12345 → '773', 'Boeing 777-300ER', '11100', '905')
  Relation (OID=54321 → bookings.bookings: book_ref, book_date, total_amount)
  Update (OID=54321 → 'ABC123', '2026-07-01', '25000.00')
Commit
```

Превращается в 2 INSERT-строки:
```sql
INSERT INTO "bookings"."airplanes_data" ("airplane_code", "model", "range", "speed", movedate, moveusername, moveaction)
VALUES ('773', 'Boeing 777-300ER', '11100', '905', CURRENT_DATE, 'wal_consumer', 'i');

INSERT INTO "bookings"."bookings" ("book_ref", "book_date", "total_amount", movedate, moveusername, moveaction)
VALUES ('ABC123', '2026-07-01', '25000.00', CURRENT_DATE, 'wal_consumer', 'u');
```

### Настройка слота аудита

Слот `audit_slot` — **перманентный слот Patroni**, объявленный в `bootstrap.dcs.slots` файла `docker-compose.yml`. Это обеспечивает:

1. Автоматическое создание на каждом новом лидере после failover/switchover.
2. Копирование информации о слоте на standby-ноды через Patroni (`pg_replication_slot_advance()`).
3. Возможность подключения WAL consumer'а к HAProxy без ручного пересоздания слота.

### Сборка WAL consumer

```bash
cd pg-audit-consumer
gradle build          # сборка (включая тесты)
gradle shadowJar      # fat JAR
gradle test           # только тесты
```

В Docker Compose используется multi-stage build на базе `gradle:8.7-jdk17` и `eclipse-temurin:17-jre`.

## Восстановление слотов репликации при смене лидера

При failover или switchover в кластере Patroni меняется мастер-нода. Слоты репликации — `shop_sub` (логическая реплика), `audit_slot` (WAL consumer) и `pg_physical_replica` (plain-физическая реплика) — должны автоматически восстановиться на новом мастере, чтобы downstream-компоненты не потеряли данные.

### Как настроены слоты

Слоты объявлены в `bootstrap.dcs.slots` конфигурации Patroni (`docker-compose.yml`):

```yaml
slots:
  shop_sub:
    type: logical
    database: shop
    plugin: pgoutput
  audit_slot:
    type: logical
    database: shop
    plugin: pgoutput
  pg_physical_replica:
    type: physical
```

Patroni хранит эту конфигурацию в etcd и при каждом выборе нового лидера выполняет следующее.

### Что происходит при смене лидера

1. Старый мастер падает или выводится из кластера.
2. etcd освобождает ключ лидера (после истечения TTL, по умолчанию 30 секунд).
3. Одна из реплик побеждает в выборах и становится новым мастером.
4. Patroni на новом мастере считывает `bootstrap.dcs.slots` из etcd и создаёт слоты `shop_sub`, `audit_slot` и `pg_physical_replica`, если они ещё не существуют.
5. Patroni копирует информацию о слотах на standby-ноды через `pg_replication_slot_advance()`, чтобы при будущем failover позиция слотов была актуальной.

### Поведение каждого слота после failover

| Слот | Кто использует | Автовосстановление | Особенности |
|------|---------------|---------------------|-------------|
| `shop_sub` | pg-logical-replica (apply worker) | **Да** — Patroni создаёт слот на новом мастере | Apply worker автоматически переподключается через HAProxy к новому мастеру. Если через 5 минут `pg_stat_subscription` пуст — перезапустить подписку (DISABLE → ENABLE). |
| `audit_slot` | pg-audit-consumer (Java WAL consumer) | **Да** — Patroni создаёт слот на новом мастере | Consumer переподключается к HAProxy и начинает чтение с позиции слота. Ручное вмешательство не требуется, **кроме** случая протухшего слота (см. «Когда нужно ручное вмешательство»). |
| `pg_physical_replica` | pg-physical-replica (plain replica, вне Patroni) | **Да** — Patroni создаёт слот на новом мастере | `type: physical`. Реплика читает WAL из этого слота, при смене лидера просто продолжает стриминг. Если слот указывает на удалённый WAL (реплика долго стояла) — пересоздать реплику basebackup-ом (слот в DCS не трогать). |

### Физическая репликация

Физические реплики — `patroni4_readonly` `:5436` (**член Patroni**, `tags.nofailover: true`) и `pg-physical-replica` `:5433` (**вне Patroni**, стриминг по физическому слоту `pg_physical_replica`). Они **не используют логические слоты**. Обе никогда не избираются лидером. При смене мастера `patroni4_readonly` переключается через DCS, `pg-physical-replica` — читает слот `pg_physical_replica`, перенесённый Patroni на нового лидера.

При сбое/порче данных реплика восстанавливается пересозданием контейнера:
```bash
# patroni4_readonly (NodeBaseBackup от мастера, данные в ./data/pg_physical2)
docker compose rm -sf patroni4_readonly
docker compose up -d patroni4_readonly

# pg-physical-replica (pg_basebackup через HAProxy, данные в ./data/pg_physical)
docker compose rm -sf pg-physical-replica
Remove-Item -Recurse -Force "patroni-cluster/data/pg_physical/*"   # только при полном сбросе данных
docker compose up -d pg-physical-replica
```

### Когда нужно ручное вмешательство

1. **Apply worker логической реплики не переподключился** — если через 5 минут после failover `pg_stat_subscription` возвращает пустой результат:
   ```sql
   -- на pg-logical-replica
   ALTER SUBSCRIPTION shop_sub DISABLE;
   ALTER SUBSCRIPTION shop_sub ENABLE;
   ```
2. **Слот удалён из-за `max_slot_wal_keep_size`** — если мастер хранил недостаточно WAL и слот был удалён автоматически, логическая реплика требует пересоздания подписки с `copy_data = true`.
3. **Слот указывает на удалённый WAL** — после нескольких failover/смен TL `restart_lsn` permanent-слота может остаться на позиции, чьи WAL-сегменты уже удалены. Признак: consumer/apply worker зациклен с ошибкой `requested WAL segment ... has already been removed`; `pg_replication_slot_advance()` на этом слоте падает с той же ошибкой. Восстановление — пересоздать слот (старая позиция не читается, события между старой и новой позицией теряются):
   ```bash
   docker compose stop pg-audit-consumer
   # на текущем лидере (см. patronictl list):
   docker compose exec patroni3 psql -U postgres -d shop -c \
     "SELECT pg_drop_replication_slot('audit_slot'); SELECT pg_create_logical_replication_slot('audit_slot','pgoutput');"
   docker compose start pg-audit-consumer
   ```
   Для `shop_sub` — то же самое (`pgoutput`), либо пересоздание подписки (см. Logical replica corruption в `AGENTS.md`).

### Проверка слотов после failover

```sql
-- на новом мастере: существуют ли слоты (у физического слота confirmed_flush_lsn отсутствует)
SELECT slot_name, slot_type, database, active
FROM pg_replication_slots
WHERE slot_name IN ('shop_sub', 'audit_slot', 'pg_physical_replica');

-- отставание логических слотов
SELECT slot_name,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag
FROM pg_replication_slots
WHERE slot_name IN ('shop_sub', 'audit_slot');

-- на pg-logical-replica: статус подписки
SELECT subname, subenabled, subtwophasestate FROM pg_subscription;
SELECT pid, state, wait_event FROM pg_stat_activity
WHERE backend_type LIKE '%logical replication%';
```
