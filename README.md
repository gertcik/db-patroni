# Patroni Cluster — PostgreSQL 17 + Patroni + pgAdmin

Отказоустойчивый кластер PostgreSQL 17 (3 ноды) с Patroni, etcd, haproxy и pgAdmin в Docker Compose.

## Требования

- Docker Engine 24+
- Docker Compose v2

## Сборка образа Patroni

Образ строится на основе `postgres:17` (Debian Bookworm, ~620 MB). В него добавляется Python и Patroni:

```dockerfile
FROM postgres:17

RUN apt-get install -y python3 python3-pip python3-psycopg2 && \
    pip3 install --no-cache-dir --break-system-packages patroni[etcd]
```

### Почему образ большой (~1.18 GB)

| Компонент | Размер |
|-----------|--------|
| `postgres:17` (Debian) | ~620 MB |
| Python 3.13 + pip + apt-зависимости | ~66 MB |
| `python3-psycopg2` (C-extension libpq) | ~40 MB (в составе apt) |
| pip-пакеты (patroni, etcd, requests, PyYAML и др.) | ~22 MB |
| apt-кэш (чистится) | 0 MB |
| **Итого** | **~1.18 GB** |

Основные причины размера:
- **Debian, не Alpine** — `postgres:17` на Debian (~620 MB) вместо `postgres:17-alpine` (~250 MB). Alpine экономит ~370 MB, но Patroni (через `python-etcd`) работает стабильнее на glibc.
- **Полный Python 3.13** — интерпретатор, pip, зависимости (~66 MB). Для сравнения: сама patroni — всего ~600 KB кода, но тянет 20 зависимостей.
- **psycopg2 из apt** — компилируется под конкретную версию libpq, что добавляет ~40 MB системных библиотек.

### Сравнение с альтернативами

| Подход | Размер | Плюсы | Минусы |
|--------|--------|-------|--------|
| postgres:17 + pip patroni (текущий) | ~1.18 GB | Стабильность, glibc | Большой образ |
| postgres:17-alpine + pip patroni | ~500 MB | Маленький образ | musl → потенциальные проблемы с python-etcd |
| Готовый zalando/patroni | ~300 MB | Оптимизирован, малый размер | Чужая версия PostgreSQL, сложно кастомизировать |

## Обновление Patroni

Версия Patroni задаётся через build-arg `PATRONI_VERSION` в `patroni-cluster/patroni/Dockerfile` (по умолчанию `4.1.3`).

### Посмотреть текущую версию

```bash
docker run --rm --entrypoint bash patroni-cluster-patroni1 -c "patroni --version"
```

### Обновить до конкретной версии

```bash
docker compose build --build-arg PATRONI_VERSION=4.1.5
docker compose up -d
```

### Обновить версию по умолчанию

Изменить `ARG PATRONI_VERSION=...` в `patroni-cluster/patroni/Dockerfile`.

При обновлении Patroni также стоит проверить совместимость с PostgreSQL в `FROM postgres:17` — Patroni 4.x поддерживает PG 12–17.

## Быстрый старт

```bash
git clone <repo>
cd patroni-cluster

docker compose build
docker compose up -d
```

## Компоненты

| Компонент | Роль | Порт (хост) | Зависит от |
|-----------|------|-------------|------------|
| etcd | Хранилище состояния кластера (DCS) | 2379 | — |
| patroni1 | Нода БД #1 | 5001 (Patroni API) | etcd |
| patroni2 | Нода БД #2 | 5002 (Patroni API) | etcd |
| patroni3 | Нода БД #3 | 5003 (Patroni API) | etcd |
| haproxy | R/W балансировщик к мастеру | 5432 (PG), 7000 (stats) | patroni1-3 (:8008) |
| pgAdmin | Веб-интерфейс управления БД | 80 | haproxy (:5432) |
| pg-physical-replica | Физическая standby (полная копия, WAL streaming) | 5433 | haproxy (:5432) |
| pg-logical-replica | Логическая реплика (PUB/SUB, подмножество таблиц) | 5434 | haproxy (:5432) |
| pg-audit-log | Аудит-БД (append-only, без ограничений целостности) | 5435 | — |
| pg-audit-consumer | WAL consumer (Java 17, pgoutput v1) | — | haproxy (:5432), pg-audit-log (:5435) |

### etcd

Распределённое key-value хранилище — **единственная точка координации** для Patroni. Хранит:

- **Leader lock** — ключ `/service/patroni_cluster/leader`, который захватывает текущий мастер. Если мастер перестаёт обновлять TTL (ttl=30s), etcd освобождает ключ, инициируя выборы нового лидера.
- **Конфигурацию кластера** — параметры PostgreSQL, bootstrap.dcs.slots, режимы синхронизации.
- **Членство нод** — каждая нода Patroni регистрирует себя с TTL и регулярно его продлевает.

Без etcd Patroni не может определить, кто лидер — весь кластер становится недоступен для записи.

### patroni1 / patroni2 / patroni3

Каждая нода запускает два процесса внутри одного контейнера:

1. **PostgreSQL 17** — слушает порт 5432 (внутри сети Docker). На мастере принимает запись, на репликах — read-only.
2. **Patroni** — управляет жизненным циклом PostgreSQL: запуск, остановка, рестарт, promotion/demotion. REST API на порту 8008 (внутри Docker, проброшен на хост как 5001/5002/5003).

**Как Patroni управляет PG:**

- При старте Patroni проверяет, есть ли в etcd ключ лидера. Если нет — пытается стать лидером.
- Если стал лидером — запускает PostgreSQL в режиме `hot_standby = off` (принимает запись).
- Если не стал лидером — запускает PostgreSQL в режиме `hot_standby = on` (read-only) и настраивает `primary_conninfo` на текущего мастера через streaming replication.
- Каждые ~10 секунд Patroni проверяет здоровье PG (`GET /health`) и обновляет TTL в etcd.
- Если мастер не ответил на health-check, Patroni на репликах инициирует выборы нового лидера.

**Health-check через REST API:**

Patroni слушает порт 8008 (внутри Docker) для проверок:

- `GET /master` — 200 OK, если нода мастер; 503, если нет
- `GET /replica` — 200 OK, если нода реплика; 503, если нет
- `GET /health` — 200 OK, если PostgreSQL жив и репликация работает
- `GET /cluster` — JSON со списком всех нод, их ролями и состоянием

### haproxy

Единая точка входа в кластер — **все клиенты подключаются только через HAProxy**.

**Как маршрутизирует запросы:**

- Порт **5432** (PostgreSQL) — проверяет каждую Patroni-ноду через `httpchk GET /master` на порту 8008. Если нода ответила 200 — помечает её как `UP` и направляет трафик. Если 503 — нода в пуле реплик, трафик на неё не идёт.
- Порт **7000** (HTTP stats) — веб-страница со списком всех нод, их статусом (`UP`/`DOWN`), активными сессиями и количеством запросов.

**Почему HAProxy, а не Patroni-native балансировка:**

- Единый порт для клиентов (:5432) — клиенту не нужно знать, какая нода мастер.
- Прозрачный failover — при смене мастера HAProxy переключается за ~2 секунды (проверка каждые 1s, 2 failed checks = мастер недоступен). Клиент просто переподключается.
- WAL-routing — физическая реплика подключается к `host=haproxy port=5432`, не зная адреса текущего мастера.

### pgAdmin

Веб-интерфейс для управления PostgreSQL на базе `dpage/pgadmin4`.

- Авторизация: `admin@admin.com` / `admin`
- При старте автоматически импортирует серверы из `pgadmin/servers.json`:
  - **Patroni Cluster (via haproxy)** — подключение к `haproxy:5432`, база `shop`
  - **pg-physical-replica** — подключение к `pg-physical-replica:5432`, база `shop`
  - **pg-logical-replica** — подключение к `pg-logical-replica:5432`, база `shop`
  - **pg-audit-log** — подключение к `pg-audit-log:5432`, база `postgres`

### pg-physical-replica

Полная физическая копия кластера PostgreSQL — **streaming WAL standby**.

**Как инициализируется:**

1. При первом запуске выполняет `pg_basebackup` через HAProxy (`host=haproxy port=5432`), получает полную копию данных текущего мастера.
2. Создаёт `standby.signal` — переводит PG в режим hot standby (read-only).
3. Настраивает `primary_conninfo` на `host=haproxy port=5432` — реплика постоянно стримит WAL с текущего мастера, не зная его адреса.
4. При рестарте (второй и последующие запуски) пропускает `pg_basebackup` и сразу запускает standby.

**Какие данные реплицируются:** все базы, таблицы, индексы, DDL, VACUUM, sequence changes — через двоичный WAL. Полная идентичность мастеру.

**Для чего используется:**
- Offload тяжёлых SELECT-запросов (отчёты, аналитика) с мастера.
- Резервное копирование (pg_dump, pg_basebackup с реплики не нагружает мастер).
- Hot standby для быстрого переключения при отказе мастера.

**Ограничение:** только чтение — `standby.signal` блокирует любую запись.

### pg-logical-replica

Логическая реплика, подписанная на публикацию `shop_pub` — **реплицируется только DML на выбранных таблицах**.

**Как инициализируется:**

1. При первом запуске выполняет `initdb` (чистая база, не `pg_basebackup`).
2. Создаёт схему `bookings` и таблицы (только структура, без данных).
3. Создаёт подписку `shop_sub` с `copy_data = true` — PostgreSQL сам копирует все существующие данные из публикации и начинает стримить изменения.
4. При рестарте проверяет, существует ли подписка; если нет — создаёт заново.

**Что реплицируется:** только INSERT, UPDATE, DELETE на таблицах, включённых в публикацию `shop_pub`.

**Что НЕ реплицируется:** DDL (ALTER TABLE, CREATE INDEX), sequences, VACUUM, TRUNCATE, системные таблицы.

**Особенности:**
- Технически таблицы не read-only — можно писать напрямую. Но такие изменения будут перезаписаны при следующем apply из подписки.
- Первичные ключи должны совпадать — если на логической реплике есть строка с тем же PK, что пришёл с мастера, подписка упадёт с ошибкой duplicate key.
- DDL на мастере требует ручного повторения на логической реплике, иначе apply сломается.
- Для добавления новой таблицы в репликацию: `ALTER PUBLICATION shop_pub ADD TABLE ...;` на мастере — подписка подхватит автоматически.

### pg-audit-log

Отдельный экземпляр PostgreSQL, предназначенный только для **append-only** хранения аудита изменений.

**Как устроена БД:**

- Единственная схема `bookings` с 9 таблицами, повторяющими структуру таблиц основного кластера.
- **Все колонки приведены к TEXT** — чтобы DDL на мастере (ALTER TABLE, изменение типов) не ломали аудит.
- Каждая таблица дополнена 4 служебными колонками:
  - `id_identity BIGINT GENERATED ALWAYS AS IDENTITY` — уникальный автоинкрементный ID
  - `movedate DATE DEFAULT CURRENT_DATE` — дата вставки записи
   - `moveusername TEXT DEFAULT 'wal_consumer'` — имя источника (всегда `wal_consumer`) ⚠️ см. «Известные ограничения»
  - `moveaction TEXT` — тип исходной операции: `'i'` (INSERT), `'u'` (UPDATE), `'d'` (DELETE)
- **Нет PK, UK, FK, CHECK, DEFAULT (кроме служебных), NOT NULL, UNIQUE, индексов** — никакие ограничения целостности не накладываются, чтобы INSERT никогда не упал с ошибкой.

**Почему TEXT для всех колонок:**
- Изменение типа колонки на мастере (например, `INT → BIGINT`) не требует изменений в audit-схеме.
- Значения, не помещающиеся в целевой тип (например, слишком длинная строка), не блокируют аудит.
- Все значения приводятся к строке на стороне WAL consumer'а, pg-audit-log просто принимает строки.

### pg-audit-consumer

Java 17 приложение, которое читает логический слот репликации `audit_slot` и пишет изменения в `pg-audit-log`.

**Полный цикл обработки:**

1. **Подключение к мастеру** — коннектится к HAProxy (`host=haproxy port=5432 dbname=shop`) по replication-протоколу PostgreSQL.
2. **Ожидание слота** — если слот `audit_slot` ещё не создан Patroni, ждёт до 3 секунд и повторяет попытки с паузой 5 секунд.
3. **Чтение pgoutput v1** — двоичный протокол логической репликации. Сообщения:
   - `Begin (b)` — начало транзакции (LSN, xid, timestamp)
   - `Relation (r)` — описание таблицы (OID, schema, table, колонки с типами)
   - `Insert (i)` — вставка строки (тупл со значениями)
   - `Update (u)` — обновление строки (старый + новый тупл)
   - `Delete (d)` — удаление строки (старый тупл или only key)
   - `Commit (c)` — фиксация транзакции
4. **Кэширование схем** — OID таблицы → (schema, table, список колонок). Сброс кэша при переподключении.
5. **Накопление батча** — все сообщения внутри одной транзакции (Begin..Commit) собираются в буфер.
6. **Запись в аудит-БД** — на Commit открывается транзакция в pg-audit-log и пишутся все накопленные строки одним batch INSERT.
7. **Трансформация операций** — UPDATE и DELETE записываются как INSERT с `moveaction = 'u'` или `'d'`, чтобы сохранить историю изменений и удалений.
8. **Обновление слота** — после успешного Commit в аудите подтверждается LSN слота (`confirmed_flush_lsn`), чтобы при перезапуске не перечитывать те же данные.

**Как обрабатываются NULL и REPLICA IDENTITY:**
- Если колонка в WAL содержит NULL, consumer пишет `\N` (текстовое представление NULL).
- Для DELETE без полного тупла (режим `REPLICA IDENTITY DEFAULT`) используется только значение первичного ключа; остальные колонки заполняются `\N`.
- Для корректного логирования всех колонок при DELETE у таблиц `seats` и `segments` установлен `REPLICA IDENTITY FULL`.

**Retry при недоступности аудит-БД:**
- Если pg-audit-log временно недоступен, consumer не пересоздаёт replication stream (избегая потери данных), а повторяет попытки записи с exponential backoff.
- При переподключении к мастеру (например, после failover) слот `audit_slot` уже существует на новом мастере (permanent slot в Patroni), consumer просто перезапускает чтение.

**Сборка:** Gradle 8.7, Java 17, fat JAR (`shadowJar`). Multi-stage Docker build.

## Архитектура

![Диаграмма кластера](images/diagram.png)

Стек состоит из четырёх уровней:

1. **DCS (etcd)** — координация кластера, leader election
2. **Patroni (3 ноды)** — управление PostgreSQL, автоматический failover
3. **HAProxy** — единая точка входа (always-on мастер), health-check через REST API
4. **Реплики** — внешние экземпляры PostgreSQL для разных задач

## Как работает кластер

Кластер использует **Patroni** для управления PostgreSQL и **etcd** как DCS (Distributed Configuration Store).

### Выбор мастера (leader election)

1. Все три ноды Patroni регистрируются в etcd.
2. Нода, которая первой успешно создаёт ключ `/service/patroni_cluster/leader`, становится **мастером** (принимает запись).
3. Остальные ноды становятся **репликами** (только чтение) и запускают `pg_basebackup` с мастера, после чего начинают стриминг WAL.
4. Если мастер падает, Patroni через etcd определяет потерю лидера, и одна из реплик автоматически повышается до мастера.

### Маршрутизация через HAProxy

- HAProxy настроен на **read-write** через порт **5432** — запросы идут только на мастер-ноду.
- HAProxy проверяет каждую ноду через `httpchk GET /master` на порту 8008 (REST API Patroni). Если нода — мастер, она помечается `UP`.
- Клиент всегда подключается к мастеру через `localhost:5432`, не зная, какая именно нода сейчас мастер.

## Как узнать, кто сейчас мастер

### 1. Через HAProxy (самый простой)

Подключитесь к БД через HAProxy и выполните:

```sql
SELECT inet_server_addr();
```

Если нужно только имя хоста:

```sql
SELECT pg_read_file('/etc/hostname');
```

### 2. Через Patroni REST API (любая нода)

```bash
docker compose exec patroni2 python3 -c "
import urllib.request, json
d = json.loads(urllib.request.urlopen('http://127.0.0.1:8008/cluster').read())
for m in d['members']:
    print(m['name'], '→', m['role'], '(' + m['state'] + ')')
"
```

Вывод:
```
patroni1    → replica   (running)
patroni2    → leader    (running)
patroni3    → replica   (running)
```

### 3. Через patronictl

```bash
docker compose exec patroni2 patronictl list
```

### 4. Через HAProxy stats (браузер)

Открой http://localhost:7000 — в строке `patroni_cluster` зелёным подсвечена активная мастер-нода.

## Проверка кластера

### Статус Patroni

```bash
# любой нодой
curl -s http://localhost:5001/patroni | jq .

# кластер
docker exec patroni-cluster-patroni1-1 patronictl list
```

### Подключение к БД

```bash
# через haproxy (всегда на мастер)
psql -h localhost -p 5432 -U postgres -d shop

# напрямую к ноде (patroni1 — 5001, patroni2 — 5002, patroni3 — 5003)
psql -h localhost -p 5001 -U postgres -d shop
```

Пароль: `secret`

### Тестовые данные

```sql
SELECT * FROM users;
SELECT * FROM products;
SELECT * FROM orders;
```

### pgAdmin

Открой http://localhost:80

- **Email:** admin@admin.com
- **Password:** admin

Сервер `Patroni Cluster (via haproxy)` уже зарегистрирован.

### Тест отказоустойчивости

```bash
# остановить мастер-ноду
docker compose stop patroni1

# через несколько секунд haproxy переключится на другую ноду
# проверить, кто стал мастером
curl -s http://localhost:7000 | grep -o 'patroni[0-9]'

# подключение к БД продолжает работать
psql -h localhost -p 5432 -U postgres -d shop -c "SELECT inet_server_addr();"

# вернуть ноду
docker compose start patroni1
```

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

- DML выполняется только на **мастере** (HAProxy направляет все write-запросы на него).
- Мастер записывает изменения в WAL, реплики получают WAL через **streaming replication** и применяют.
- Реплики Patroni **read-only** — DML на них не выполняется.
- Задержка репликации отслеживается через `pg_stat_replication`.

### 2. Физическая реплика (pg-physical-replica :5433)

```
Мастер Patroni → HAProxy :5432 → pg-physical-replica
                                    ↓
                          WAL streaming (standby)
                                    ↓
                          Read-only копия данных
```

- После `pg_basebackup` реплика подключается к HAProxy (`host=haproxy port=5432`) с `primary_conninfo` и постоянно стримит WAL.
- Все DML с мастера попадают на физическую реплику **автоматически**, включая DDL, VACUUM, CREATE INDEX и т.д.
- Реплика **read-only** — запись заблокирована на уровне `standby.signal`.
- Лаг репликации можно проверить:
  ```sql
  SELECT application_name, state,
         pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag
  FROM pg_stat_replication;
  ```

### 3. Логическая реплика (pg-logical-replica :5434)

```
Мастер Patroni → HAProxy :5432 → pg-logical-replica
                                    ↓
                    Logical replication (PUB/SUB)
                    Publication: shop_pub (таблицы users, products, orders)
                    Subscription: shop_sub (слот shop_sub)
                                    ↓
                    DML применяется к соответствующим таблицам
```

- Логическая реплика подписывается на **публикацию** `shop_pub`, созданную на мастере в `patroni-cluster/patroni/init.sh:49-57`.
- Публикация включает таблицы: `users`, `products`, `orders`.
- Подписка `shop_sub` использует постоянный слот `shop_sub`, который автоматически создаётся на каждом новом мастере благодаря настройке `bootstrap.dcs.slots` в конфигурации Patroni.
- **Реплицируется только DML** (INSERT, UPDATE, DELETE) на подписанных таблицах. DDL, индексы, sequences, VACUUM и TRUNCATE **не реплицируются**.
- Направление репликации — **однонаправленное**: только с мастера на логическую реплику. Изменения на логической реплике **не попадают** обратно на мастер.
- Таблицы на логической реплике **не read-only** технически (нет `standby.signal`), но запись в них нарушает консистентность:
  - Данные, записанные напрямую на логической реплике, будут **перезаписаны** при следующем apply из подписки.
  - Первичные ключи, конфликтующие с данными мастера, приведут к ошибке подписки.

### Сводная таблица

| Операция | Patroni-реплики | Физическая реплика | Логическая реплика |
|----------|----------------|-------------------|-------------------|
| INSERT / UPDATE / DELETE | Да (через WAL) | Да (через WAL) | Да (через PUB/SUB) |
| DDL (ALTER TABLE, CREATE INDEX) | Да (через WAL) | Да (через WAL) | **Нет** |
| VACUUM / TRUNCATE | Да (через WAL) | Да (через WAL) | **Нет** |
| Запись напрямую | Read-only | Read-only | Возможно, но нарушает консистентность |
| Задержка | ms–s | ms–s | ms–min (зависит от `wal_retrieve_retry_interval`) |

### Как проверить, что DML реплицируется

**Физическая реплика (:5433):**
```sql
-- проверить, что данные есть
SELECT count(*) FROM shop.users;

-- проверить статус streaming
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
   - Достижении `max_slot_wal_keep_size` на мастере (слот удалён) — нужна повторная настройка подписки.
   - DDL на мастере без соответствующего DDL на логической реплике (подписка падает с ошибкой).
   - Конфликте primary key (одинаковый PK, разные данные).
3. **Patroni-кластер** — синхронный режим выключен (`synchronous_mode: false`), возможна потеря последних транзакций при жёстком сбое мастера (асинхронный commit).

## 4. Аудит-лог (pg-audit-log :5435)

Аудит-лог — отдельный экземпляр PostgreSQL для **append-only** хранения всех изменений (INSERT, UPDATE, DELETE) с таблиц основного кластера. Изменения доставляются через **WAL consumer** на Java 17, который читает логический слот репликации `audit_slot`.

```
Мастер Patroni → WAL consumer (Java) ← pgoutput v1 → pg-audit-log (append-only)
                     ↓
          Парсинг pgoutput: Relation / Insert / Update / Delete
                     ↓
          INSERT в audit-таблицу + movedate, moveusername, moveaction
```

### Как устроено

| Компонент | Назначение |
|-----------|-----------|
| **pg-audit-log** | PostgreSQL 17 `postgres:17` с initdb и схемой `bookings` (9 таблиц). Каждая таблица — точная копия оригинальной по именам колонок, но все типы колонок — **TEXT**. Добавлены 4 служебных колонки. |
| **pg-audit-consumer** | Java 17 приложение, подключается к HAProxy (:5432), читает слот `audit_slot`, декодирует pgoutput v1 протокол, пишет INSERT-only строки в pg-audit-log. |

### Структура audit-таблиц

Каждая из 9 таблиц схемы `bookings` на pg-audit-log содержит:

- **Оригинальные колонки** — все `TEXT` (значения преобразуются в строки)
- **`id_identity BIGINT GENERATED ALWAYS AS IDENTITY`** — уникальный автоинкрементный ID
- **`movedate DATE DEFAULT CURRENT_DATE`** — дата вставки
- **`moveusername TEXT DEFAULT 'wal_consumer'`** — источник изменения (всегда 'wal_consumer') ⚠️ см. «Известные ограничения»
- **`moveaction TEXT`** — тип операции: `'i'` (INSERT), `'u'` (UPDATE), `'d'` (DELETE)

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

- Автоматическое создание на каждом новом лидере после failover/switchover.
- Копирование информации о слоте на standby-ноды через Patroni (`pg_replication_slot_advance()`).
- Возможность подключения WAL consumer'а к HAProxy без ручного пересоздания слота.

### Сборка WAL consumer

```bash
cd pg-audit-consumer
gradle build          # сборка (включая тесты)
gradle shadowJar      # fat JAR
gradle test           # только тесты
```

В Docker Compose используется multi-stage build на базе `gradle:8.7-jdk17` и `eclipse-temurin:17-jre`.

## Обслуживание БД

В кластере есть три категории баз данных, и каждая требует своего подхода при изменениях схемы:

| Категория | Характеристика | Запись | DDL |
|-----------|---------------|--------|-----|
| **Patroni-кластер** (patroni1/2/3) | Managed by Patroni, автоfailover | Только мастер | На мастере, автоматически реплицируется |
| **Физическая реплика** (pg-physical-replica) | Streaming WAL, read-only | Нет | Нет (копия с мастера) |
| **Логическая реплика** (pg-logical-replica) | Logical replication, read-only через подписку | Нет | Нет (копия через publication) |

### Как добавлять / удалять таблицы

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

### Как добавлять / удалять поля и ограничения

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

- **Физическая реплика** — изменения применяются автоматически (WAL streaming).
- **Логическая реплика** — DDL не реплицируются логической репликацией.
  ⚠️ После ALTER TABLE на мастере нужно **вручную выполнить тот же DDL на логической реплике**, иначе подписка упадёт с ошибкой.
- Рекомендуется временно отключать подписку на время массовых DDL:
   ```sql
   ALTER SUBSCRIPTION shop_sub DISABLE;
   -- выполнить DDL на мастере и логической реплике
   ALTER SUBSCRIPTION shop_sub ENABLE;
   ```

### Восстановление логической реплики после сбоя

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

- **Не выполнять DDL напрямую на логической реплике** — все изменения схемы только на мастере, затем повторять те же DDL на реплике вручную
- **Перед массовыми DDL** временно отключать подписку (`ALTER SUBSCRIPTION shop_sub DISABLE`), выполнить DDL на мастере и реплике, затем включить (`ENABLE`)
- **Не записывать данные напрямую** на логическую реплику — они будут перезаписаны при следующем apply или вызовут конфликт первичных ключей
- **Мониторить статус подписки:**
  ```sql
  SELECT subname, subenabled, subtwophasestate FROM pg_subscription;
  SELECT pid, state, wait_event FROM pg_stat_activity
  WHERE backend_type LIKE '%logical replication%';
  ```
- **Проверять лаг репликации** после интенсивной записи на мастере

### Как добавлять / удалять индексы

```sql
-- создать индекс (на мастере)
CREATE INDEX idx_users_email ON shop.users(email);

-- удалить индекс
DROP INDEX idx_users_email;
```

- Физическая реплика получит изменения индексов через WAL.
- Логическая реплика НЕ реплицирует DDL индексов — выполнить вручную:
  ```sql
  CREATE INDEX idx_users_email ON shop.users(email);
  ```

### Обслуживание индексов и таблиц

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

## Мониторинг (концепция)

### Ключевые метрики

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

### Откуда брать метрики

- **Patroni REST API** (`GET /cluster`, `GET /health`) — состояние лидера, лаг реплик
- **pg_stat_*** представления — статистика PostgreSQL
- **HAProxy stats** (`:7000`) — состояние бэкендов, количество сессий
- **Docker** (`docker stats`) — ресурсы контейнеров

### Мониторинг репликации

#### Физическая репликация (WAL streaming)

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

#### Логическая репликация (PUB/SUB)

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

#### Audit consumer (WAL consumer)

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

#### Единый запрос (на мастере)

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

### Рекомендуемые проверки

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
- Аудит требует идентификации, кто именно выполнил изменение (INSERT/UPDATE/DELETE)
- Расследование инцидентов: нужно знать, какой пользователь удалил запись

**Варианты решения (не реализованы):**
1. **Дополнительная колонка на мастере** — добавить в каждую таблице колонку `modified_by TEXT DEFAULT current_user`, тогда оригинальный пользователь попадёт в WAL как обычное значение колонки.
2. **Хранимая процедура** — все DML через процедуру, которая логирует `current_user` в отдельную таблицу.
3. **pg_audit extension** — включить `pg_audit` для логирования всех DML с пользователем (но это внешний лог, не в формате строк audit-таблиц).
4. **session_replication_role + триггеры** — на логической реплике добавить триггеры, которые при apply подставляют `current_user` (неприменимо для audit-log — там нет подписки, только WAL consumer).

**Текущее состояние:** `moveusername` — константа `'wal_consumer'`. Если требуется точное имя пользователя — использовать вариант 1 (колонка на мастере).

## Остановка

```bash
docker compose down        # остановить
docker compose down -v     # остановить и удалить данные
```
