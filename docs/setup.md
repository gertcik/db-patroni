# Инструкция по развёртыванию (setup checklist)

Пошаговый чек-лист: с нуля поднять кластер Patroni + HA, настроить PostgreSQL для репликации и развернуть аудит-реплику с WAL consumer'ом. Значения — из `docker-compose.yml` (источник истины). Контекст компонентов — `components.md`, эксплуатация — `maintenance.md`, мониторинг — `monitoring.md`.

> Все команды — из `patroni-cluster/`. У всех ролей PostgreSQL пароль `secret`; учётные записи и порты сведены в §7.

---

## 1. Предварительные требования

| # | Требование | Проверка |
|---|-----------|----------|
| 1 | Docker Engine 24+, Compose v2 | `docker compose version` |
| 2 | Host Docker API ≥ 1.44 (для failover-теста; mount `/var/run/docker.sock`) | `docker version --format '{{.Server.APIVersion}}'` |
| 3 | Свободные порты: `80, 2379, 3000, 5432, 5433, 5434, 5435, 5436, 7000, 8080, 9090` | `netstat -ano \| findstr :5432` |
| 4 | Windows: NTFS bind mounts — медленный fsync (см. Заметки в конце) | — |

---

## 2. Patroni + HA

### 2.1 DCS: etcd (1 сервис в `docker-compose.yml`)

- [ ] Образ `etcd:3.5.15`, флаг `--enable-v2=true` (Patroni использует etcd v2 API).
- [ ] `--listen-client-urls=http://0.0.0.0:2379`, peer `:2380`, `--initial-cluster-token patroni-etcd`.

### 2.2 Patroni-узлы (patroni1/2/3, `build: ./patroni`)

Конфигурация передаётся целиком через env `PATRONI_CONFIGURATION` (YAML в переменной). Чек-лист ключевых блоков для **каждого** leader-capable узла:

- [ ] `scope: patroni_cluster` — имя кластера (общее для всех узлов).
- [ ] `name:` — уникальное имя узла (`patroni1` / `patroni2` / `patroni3`).
- [ ] `restapi:` — `listen 0.0.0.0:8008`, `connect_address <узел>:8008` (по этому адресу HAProxy проверяет готовность), `metrics: true` (экспорт `/metrics` для Prometheus).
- [ ] `postgresql.listen 0.0.0.0:5432`, `connect_address <узел>:5432`, `data_dir: /data/pgdata` (volume `./data/pgdataN:/data`).
- [ ] **`postgresql.authentication`** — две учётные записи (создаются Patroni автоматически при bootstrap):
  - `superuser: postgres / secret`
  - `replication: replicator / replicator`
- [ ] `pg_hba`: локальные trust; удалённые `host all all 0.0.0.0/0 md5`; `host replication replicator 0.0.0.0/0 md5`.
- [ ] `bootstrap.dcs`: `ttl: 30`, `loop_wait: 10`, `retry_timeout: 10`, `maximum_lag_on_failover: 1048576`, `master_start_timeout: 300`, `synchronous_mode: false`.
- [ ] `bootstrap.dcs.postgresql.use_pg_rewind: true` — бывший лидер автоматически возвращается в строй репликой.
- [ ] `bootstrap.dcs.postgresql.parameters`: `wal_level: logical`, `max_worker_processes: 8` (см. §3).
- [ ] `bootstrap.dcs.slots` — постоянные слоты (см. §5, блок общий для patroni1/2/3).
- [ ] `bootstrap.post_bootstrap: /scripts/init.sh` — инициализация БД (см. §4). Выполняется один раз на узле, который стал лидером при первом bootstrap.
- [ ] Postgres-пользователь внутри контейнера — `USER postgres` (`patroni/Dockerfile`); Patroni 4.1.3 (`ARG PATRONI_VERSION`, переопределить: `docker compose build --build-arg PATRONI_VERSION=4.1.5`).

**patroni4_readonly** (физическая реплика-член кластера, никогда не лидер):

- [ ] Тот же образ `./patroni`, `name: patroni4_readonly`, порты хоста `5436:5432`.
- [ ] `tags.nofailover: true` — узел исключается из выборов.
- [ ] Блоки `bootstrap.dcs.*` и `post_bootstrap` — **отсутствуют** (схема приходит через WAL; init на новой реплике выполняет сам Patroni через pg_basebackup).

### 2.3 HAProxy (`haproxy/haproxy.cfg`)

- [ ] `listen :5432` — единая R/W точка: бекенд только patroni1/2/3 (patroni4_readonly и реплики снаружи не в бекенде).
- [ ] Health-check: `option http-check`, `http-check send meth GET uri /master expect status 200` на REST :8008 — 200 отвечает только лидер.
- [ ] Stats: `listen :7000` (страница http://localhost:7000 — мастер подсвечен).

### 2.4 Запуск и проверка HA

```bash
docker compose build
docker compose up -d
```

- [ ] `docker compose exec patroni1 patronictl list` — 1 Leader + 3 Replica (одна с `nofailover: true`), все `streaming`, лаг 0 (bootstrap занимает 1–3 мин).
- [ ] Обращение через HAProxy всегда на лидер: `psql -h localhost -p 5432 -U postgres -d shop -c "SELECT inet_server_addr();"` (пароль `secret`).
- [ ] Failover: `docker compose stop patroni1` → через TTL/loop_wait лидером становится patroni2 или patroni3 → `:5432` продолжает работать. Убедиться, что новый лидер НЕ `patroni4_readonly`. Вернуть: `docker compose start patroni1`.
- [ ] HAProxy stats: http://localhost:7000.

---

## 3. Настройки PostgreSQL

**Важно: PostgreSQL настраивается только через `PATRONI_CONFIGURATION`** (блок `bootstrap.dcs.postgresql.parameters` в compose). Ручные правки `postgresql.conf` на нодах Patroni затираются — Patroni управляет конфигурацией через DCS.

| # | Параметр | Где | Зачем |
|---|----------|-----|-------|
| 1 | `wal_level = logical` | `bootstrap.dcs.postgresql.parameters` на patroni1/2/3 | Логическая репликация: публикация `shop_pub`, слот `audit_slot`, WAL consumer |
| 2 | `max_worker_processes = 8` | там же | Запас под логическую репликацию: walsender'ы для подписки/consumer + apply workers |
| 3 | `use_pg_rewind: true` | `bootstrap.dcs.postgresql` | Бывший лидер после failover возвращается репликой без полного re-sync |
| 4 | synchronous_mode: false | `bootstrap.dcs` | Асинхронная репликация: failover без ожидания подтверждения всех реплик |
| 5 | `pg_hba` строки (см. §2.2) | pg_hba в конфиге Patroni | Если добавить сервис, которому нужен md5/chapportal — дополнить список |
| 6 | `REPLICA IDENTITY FULL` | `patroni/init.sh` | Для UPDATE/DELETE-аудита: таблицы `bookings.seats`, `bookings.segments` уже покрыты; **новая таблица = ADD yourself** (см. §6.Шаг 6) |
| 7 | Хост-порты — только у read-only узлов | docker-compose.yml | patroni1/2/3 без хост-портов: доступ через HAProxy/pgAdmin/docker exec |

**Не надо трогать вручную:** `postgresql.conf`, `postgresql.auto.conf`, `standby.signal`, слоты через `pg_drop_replication_slot` (это делает Patroni DCS).

---

## 4. SQL-скрипты и манипуляции, которые происходят автоматически

| Файл | Где/когда выполняется | Что делает |
|------|----------------------|------------|
| `patroni/init.sh` (post_bootstrap) | Один раз: узел, ставший лидером при первой инициализации кластера | `CREATE DATABASE shop;` → `\i /scripts/demo-airlines.sql` (9 таблиц схемы `bookings` + demo-данные) → `ALTER TABLE bookings.seats REPLICA IDENTITY FULL;` → то же для `bookings.segments` → `DO $$ IF NOT EXISTS (SELECT FROM pg_publication WHERE pubname='shop_pub') THEN CREATE PUBLICATION shop_pub FOR ALL TABLES; END IF; $$;` |
| `pg-audit-log/init-audit.sql` | `pg-audit-log/entrypoint.sh`, один раз при первом initdb (чистый volume) | `CREATE DATABASE shop` (`\gexec`) → `CREATE SCHEMA bookings;` → 9 `CREATE TABLE` **с зеркальными типами** (`CHAR(3)`, `INTEGER`, `INTEGER[]`, `TIME`, `INTERVAL`, `TIMESTAMPTZ`, `NUMERIC(10,2)`, `BOOLEAN`, `TEXT`; NULL, без NOT NULL/констрейнтов) + 4 служебных колонки аудита (`movedate`, `moveusername`, `moveaction`, `id_identity`) |
| `replica-logical/entrypoint.sh` → `setup_subscription()` | Один раз при первом initdb **или** повторно при существующем PGDATA без маркера `/tmp/.subscription_created` (создаёт только недостающее) | `CREATE DATABASE shop` → `CREATE SCHEMA IF NOT EXISTS bookings` + 9 таблиц (с ограничениями как на мастере) → ожидание публикации `shop_pub` на мастере → `CREATE SUBSCRIPTION shop_sub CONNECTION 'host=haproxy port=5432 dbname=shop user=postgres password=secret' PUBLICATION shop_pub WITH (copy_data = true, create_slot = false);` → `touch /tmp/.subscription_created` |
| `replica-physical/entrypoint.sh` | pg-physical-replica при старте | Чистый PGDATA → `pg_basebackup` через haproxy (user=`replicator`), `standby.signal`; существующий → идемпотентное добавление `primary_conninfo` + `primary_slot_name='pg_physical_replica'` в `postgresql.auto.conf` |
| `pg-audit-consumer` | Контейнер, живой цикл | SQL-скриптов нет: при первом изменении по каждой таблице **сам выравнивает типы** аудит-таблицы по источнику (`CREATE TABLE` / `ALTER COLUMN ... TYPE ... USING` / `ADD COLUMN`; удалённые на мастере таблицы — `[WARN]` и пропуск) |

---

## 5. Слоты репликации (обязательная настройка)

Слоты объявлены в `bootstrap.dcs.slots` (один и тот же блок на patroni1/2/3) — Patroni создаёт их на каждом мастере и **воссоздаёт на новом лидере после failover**:

```yaml
slots:
  pg_physical_replica:
    type: physical            # pg-physical-replica (вне Patroni) стримит через него
  shop_sub:
    type: logical
    database: shop
    plugin: pgoutput          # для подписки shop_sub (pg-logical-replica)
  audit_slot:
    type: logical
    database: shop
    plugin: pgoutput          # для WAL consumer (pg-audit-consumer)
```

- [ ] `create_slot = false` в `CREATE SUBSCRIPTION` — слот уже создан Patroni (перманентный), подписка его подхватывает.
- [ ] `pg_physical_replica` имеет `type: physical` — не удалять: из этого слота стримит plain-реплика.
- [ ] Проверка на лидере:

```sql
SELECT slot_name, slot_type, plugin, active FROM pg_replication_slots ORDER BY slot_name;
-- ждём: pg_physical_replica (physical), shop_sub (logical/pgoutput), audit_slot (logical/pgoutput)
```

- [ ] Соответствие потребитель ↔ слот: `shop_sub` → pg-logical-replica (:5434), `audit_slot` → pg-audit-consumer, `pg_physical_replica` → pg-physical-replica (:5433).

**Резервный путь (если DCS-слота нет на текущем мастере, например после серии failover'ов):**

```sql
SELECT pg_create_logical_replication_slot('audit_slot', 'pgoutput');
```

Полные рецепты восстановления (в т.ч. `requested WAL segment ... has already been removed`) — `maintenance.md`.

---

## 6. Аудит-реплика + audit consumer (пошагово)

### Шаг 1. БД приёмника: pg-audit-log

```bash
docker compose build pg-audit-log
docker compose up -d pg-audit-log
```

Что произойдёт автоматически (`pg-audit-log/entrypoint.sh` при чистом volume `./data/pg_auditlog`):
- `initdb` с пользователем `postgres` (пароль из env `POSTGRES_PASSWORD=secret`)
- `pg_hba`: `host all all 0.0.0.0/0 md5`
- `psql -f /sql/init-audit.sql` → БД `shop`, схема `bookings`, 9 таблиц с зеркальными типами.

- [ ] Проверка: `docker compose exec -e PGPASSWORD=secret pg-audit-log psql -U postgres -d shop -c "\dt bookings.*"` — 9 таблиц.

### Шаг 2. Consumer: pg-audit-consumer

```bash
docker compose build pg-audit-consumer
docker compose up -d pg-audit-consumer
```

Переменные окружения (все — в `docker-compose.yml`, менять при переносе топологии):

| Переменная | Значение | Смысл |
|-----------|----------|-------|
| `SOURCE_HOST` / `SOURCE_PORT` / `SOURCE_DB` | `haproxy` / `5432` / `shop` | Откуда читать WAL (всегда через HAProxy — на лидер) |
| `SOURCE_USER` / `SOURCE_PASSWORD` | `postgres` / `secret` | Суперюзер источника (replication-протокол + metadata-соединение) |
| `SLOT_NAME` | `audit_slot` | Permanent slot из §5 |
| `PUBLICATION_NAME` | `shop_pub` | Публикация `FOR ALL TABLES` |
| `TARGET_HOST` / `TARGET_PORT` / `TARGET_DB` | `pg-audit-log` / `5432` / `shop` | Куда писать аудит |
| `TARGET_USER` / `TARGET_PASSWORD` | `postgres` / `secret` | Суперюзер приёмника (права на CREATE/ALTER таблин по зеркалу) |

- [ ] Проверка логов: `docker compose logs pg-audit-consumer` — ждём цепочку: `[INFO] Slot 'audit_slot' is ready` → `[INFO] Replication stream started from LSN: ...` → `[INFO] Applied N changes at LSN ...`.
- [ ] Java 17 + Gradle 8.7 внутри Docker (`pg-audit-consumer/Dockerfile`: `gradle:8.7-jdk17` → `eclipse-temurin:17-jre`); локально — `cd pg-audit-consumer && gradle test` (нужен JDK 17+).

### Шаг 3. Проверка end-to-end

- [ ] На мастере (через HAProxy) сделать DML в любой из 9 таблиц:

```sql
INSERT INTO bookings.airports_data (airport_code, name, city, country, timezone)
VALUES ('ZZ0', 'Test Airport', 'Test City', 'Testland', 'Asia/Test');
```

- [ ] В pg-audit-log появилась строка `moveaction = 'i'`:

```sql
SELECT airport_code, name, city, movedate, moveusername, moveaction
FROM bookings.airports_data WHERE airport_code = 'ZZ0';
```

- [ ] Типы зеркальны (равенство `src=audit` по всем колонкам):

```sql
-- на мастере:
SELECT a.attname, format_type(a.atttypid, a.atttypmod) FROM pg_attribute a
WHERE a.attrelid = 'bookings.airports_data'::regclass AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum;
-- то же на pg-audit-log — сравнить списки 1:1
```

- [ ] `UPDATE`/`DELETE` той же строки → в аудите ещё две записи с `moveaction = 'u'` / `'d'` (к таблицам, для которых установлен `REPLICA IDENTITY FULL`, обновление/удаление попадает в аудит целиком; на остальных — только ключ). Удалить таблицу на мастере → в audit-логе `[WARN]` и пропуск, а не падение.

### Шаг 4. Замечания

1. `wal_level: logical` обязателен (§3), иначе нельзя создать слот/публикацию.
2. Таблица на мастере, которая должна попадать под аудит, **обязательно** с `REPLICA IDENTITY FULL` обновления будут дублироваться — иначе `UPDATE`/`DELETE` упадут в audit без полной информации.
3. Служебные колонки аудита (`movedate`, `moveusername`, `moveaction`, `id_identity`) в таблицах-зеркалах не трогаются consumer'ом.
4. Полные recipes изменений/восстановления — `maintenance.md`.

---

## 7. Учётные данные и порты (сводка)

| Компонент | Учётка | Порт |
|-----------|--------|------|
| PostgreSQL (кластер, все реплики) | `postgres / secret` (superuser), `replicator / replicator` (replication) | HAProxy `:5432` (R/W), `:5433` phys, `:5434` logical, `:5435` audit, `:5436` patroni4_readonly |
| pgAdmin | `admin@admin.com / admin` | http://localhost:80 |
| Grafana | `admin / admin` | http://localhost:3000 |
| Prometheus | — | http://localhost:9090 |
| HAProxy stats | — | http://localhost:7000 |
| cAdvisor | — | http://localhost:8080 |

---

## 8. Финальный чек-лист готовности

- [ ] `patronictl list`: 1 Leader + 3 Replicas, `nofailover` у patroni4_readonly, лаг 0.
- [ ] `:5432` → лидер (`SELECT inet_server_addr();`), запись проходит.
- [ ] Физические реплики read-only: `pg_is_in_recovery()` = `t` на `:5433` и `:5436`.
- [ ] Три permanent слота на лидере (§5) активны, потребители на связи.
- [ ] `pg_stat_subscription` на логической реплике содержит строку `shop_sub` (worker типа `apply`).
- [ ] Audit: consumer прикладывает изменения, типы audit-таблиц зеркальны с мастером.
- [ ] Тесты: `docker compose run --rm replication-tests` — 4/4 passed (отчёт в `data_tests/reports/`).
- [ ] Мониторинг: Prometheus targets `up`, Grafana дашборды с данными.

## Заметки для Windows

- Bind mounts NTFS: медленный fsync; известный kill-loop при crash-recovery (`Cancelling long running task doing crash recovery...`) вылечивается пересозданием каталога ноды: `docker compose stop <нод>`, удалить её каталог из `data/`, `docker compose start <нод>` (re-join через pg_basebackup, 3–5 мин).
- Медленный слив большого логического lag: временно `ALTER DATABASE shop SET synchronous_commit = off;` на pg-audit-log, после догоняния `ALTER DATABASE shop RESET synchronous_commit;`.
- Полный сброс: `docker compose down -v` **плюс удаление `patroni-cluster/data/`** (bind mounts `-v` не удаляет) — `patroni-cluster/_clean_data.cmd`.
