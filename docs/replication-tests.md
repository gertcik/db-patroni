# Тесты репликации — описание и запуск

Автоматизированный набор тестов для оценки работы репликации на **живом**
кластере Patroni (`patroni-cluster`). Выполняет проверки «запись вставлена /
удалена / обновлена на мастере → появилась/изменилась на физической реплике и
зафиксирована в протокольной (audit-log) БД», а также проверку устойчивости
кластера при остановке лидера (failover).

Тесты написаны на **pytest**, оформлены как **docker-контейнер** и запускаются
через `docker compose`. По итогам формируются отчёты (HTML + Allure + JSON),
выгружаемые в каталог `patroni-cluster/data_tests/reports/` (bind mount в
`docker-compose.yml`; сервис имеет `profiles: ["tests"]` и не стартует при
обычном `docker compose up -d`).

## Быстрый запуск

Кластер должен быть поднят: `docker compose up -d`.

```bash
cd patroni-cluster

# собрать образ тестов (один раз)
docker compose build replication-tests

# запустить все тесты (INSERT/UPDATE/DELETE + failover)
docker compose run --rm replication-tests
```

## Что проверяют тесты

| # | Тест (pytest id) | Проверка |
|---|------------------|----------|
| 1 | `test_replication.py::test_insert_replicates` | INSERT в кластер Patroni → строка появилась на физической реплике + запись типа `i` в протокольную (audit-log) БД |
| 2 | `test_replication.py::test_update_replicates` | UPDATE в кластере Patroni → строка обновилась на физической реплике + запись типа `u` в протокольную БД |
| 3 | `test_replication.py::test_delete_replicates` | DELETE в кластере Patroni → строка удалена с физической реплики + запись типа `d` в протокольную БД |
| 4 | `test_failover.py::test_failover_leader_downtime_and_recovery` | Остановка лидера → кластер временно недоступен → после восстановления SELECT проходит; новый лидер — leader-capable нода и **не** `patroni4_readonly` (узел с `nofailover: true`) |

## Как устроены тесты

### Архитектура

- **Мастер** (запись) — через `HAProxy :5432` (R/W). HAProxy направляет запросы на текущего лидера.
- **Физическая реплика** — `pg-physical-replica` (`:5432` в сети, вне Patroni). Проверяется появление/обновление/удаление строк.
- **Протокольная (audit-log) БД** — `pg-audit-log` (`:5432`). Append-only лог, который заполняет
  WAL-consumer (`pg-audit-consumer`) из слота `audit_slot`. Каждая DML-операция пишется отдельной
  строкой с меткой `moveaction` = `i` / `u` / `d`.
- Так как тесты запускаются в контейнере сети `patroni-net`, подключения идут по внутренним
  именам контейнеров (`haproxy`, `pg-physical-replica`, `pg-audit-log`) на стандартных внутренних
  портах (`5432`).
- **Failover-тест** использует `/var/run/docker.sock` (монтируется в контейнер), чтобы
  останавливать и возвращать контейнер лидера.

### Тестовая таблица

Для детерминированной проверки фикстура `test_table` создаёт на мастере таблицу
`bookings.repl_test`, её зеркало в audit-БД и на логической реплике, а в конце
сессии удаляет их:

```sql
-- мастер
CREATE TABLE bookings.repl_test (test_id text PRIMARY KEY, payload text NOT NULL);
ALTER TABLE bookings.repl_test REPLICA IDENTITY FULL;
-- логическая реплика (зеркало — см. ниже)
CREATE TABLE bookings.repl_test (test_id text PRIMARY KEY, payload text NOT NULL);
ALTER TABLE bookings.repl_test REPLICA IDENTITY FULL;
-- audit-БД (протокольная)
CREATE TABLE bookings.repl_test (
    test_id text, payload text,
    movedate timestamptz DEFAULT now(),
    moveusername text DEFAULT 'wal_consumer',
    moveaction text,
    id_identity bigint GENERATED ALWAYS AS IDENTITY
);
```

Зеркало на `pg-logical-replica` обязательно: publication `shop_pub` — `FOR ALL TABLES`,
однако подписчик **не создаёт новые таблицы сам** (sync-worker не запускается), и без
зеркала apply-worker падает в crash-loop на первом `INSERT` в `bookings.repl_test`
(`logical replication target relation ... does not exist`), после чего вся логическая
реплика встаёт.

`REPLICA IDENTITY FULL` обязателен: только он заставляет pgoutput присылать полный
старый кортеж на UPDATE/DELETE, чтобы WAL-consumer мог записать корректную запись
`u`/`d` в протокольную БД.

Каждая тестовая строка использует уникальный ключ (`test_id` на базе UUID), поэтому
тесты изолированы и не конфликтуют с `load-generator` и между собой. Ожидание
репликации выполняется по принципу «поллинг с таймаутом» (`db.wait_until`).

### Failover-тест (подробнее)

1. Определяет текущего лидера (`pg_is_in_recovery()` на leader-capable узлах
   `patroni1/2/3`), находит его контейнер и останавливает (`docker stop`).
2. Проверяет, что остановленный узел-лидер недоступен — детерминированный признак
   того, что кластер в этот момент не обслуживает запросы через него. (Через HAProxy
   простоев на уровне SQL может почти не быть — он умеет бесшовно переключаться,
   поэтому по HAProxy наличие окна недоступности проверять ненадёжно.)
3. Ждёт восстановления: новый лидер избран, HAProxy переключился, SELECT через
   `:5432` снова проходит.
4. Проверяет, что новый лидер — одна из leader-capable нод и **не** `patroni4_readonly`
   (узел с `nofailover: true`; `pg-physical-replica` вне DCS и в выборах не участвует).
5. Выполняет запись + чтение через HAProxy.
6. Возвращает остановленный узел и ждёт восстановления кластера. Бывший лидер после
   возврата может снова стать лидером (Patroni отдаёт ему lock) либо пройти
   `pg_rewind`/rejoin репликой — ожидание возврата узла является **best-effort**
   (не роняет тест), т.к. полное восстановление бывшего лидера — отдельная операция
   эксплуатации.

### Известная особенность

При остановке лидера через `docker stop` бывший лидер после возврата выполняет
`pg_rewind`/rejoin, что под интенсивной нагрузкой (работает `load-generator`) может
занять несколько минут или потребовать ручного восстановления (оч�истка/пересоздание
данных узла, см. `AGENTS.md`). Это поведение самого кластера, а не теста; тест
документирует это сообщением `[WARN]`.

## Отчёты

После запуска в каталоге `data_tests/reports/` (смонтирован в контейнер):

| Файл | Содержание |
|------|-----------|
| `report.html` | Самодостаточный HTML-отчёт (pytest-html) |
| `allure-results/` | Результаты в формате Allure (JSON), готовые для генерации отчёта Allure |
| `results.json` | Сводка результатов тестов в JSON |

Каталог `patroni-cluster/data_tests/reports/` добавлен в `.gitignore`.

## Варианты запуска

```bash
cd patroni-cluster

# только тесты репликации (без failover)
docker compose run --rm replication-tests -k "not failover"

# только failover-тест
docker compose run --rm replication-tests -k "failover"

# подробный вывод
docker compose run --rm replication-tests -v

# переопределить таймаут ожидания возврата лидера (сек)
docker compose run --rm -e TEST_REJOIN_TIMEOUT=180 replication-tests
```

## Конфигурация (переменные окружения)

Задаются в сервисе `replication-tests` в `docker-compose.yml`:

| Переменная | По умолчанию | Описание |
|-----------|--------------|----------|
| `TEST_MASTER_HOST` | `haproxy` | мастер (HAProxy R/W) |
| `TEST_MASTER_PORT` | `5432` | порт мастера |
| `TEST_PHYS_HOST` | `pg-physical-replica` | физическая реплика (вне Patroni) |
| `TEST_PHYS_PORT` | `5432` | порт физической реплики |
| `TEST_AUDIT_HOST` | `pg-audit-log` | протокольная (audit-log) БД |
| `TEST_AUDIT_PORT` | `5432` | порт протокольной БД |
| `TEST_DB` | `shop` | имя БД |
| `TEST_USER` | `postgres` | пользователь |
| `TEST_PASSWORD` | `secret` | пароль |
| `REPORTS_DIR` | `/reports` | каталог отчётов внутри контейнера |
| `TEST_REJOIN_TIMEOUT` | `120` | сек ожидания возврата лидера в строй (best-effort) |

## Структура каталога `tests/`

```
tests/
├── Dockerfile          # python:3.12 + psycopg2 + pytest + allure/pytest-html + docker CLI
├── dockerignore        # исключаем reports/ и кэши из образа
├── requirements.txt    # зависимости Python
├── pytest.ini          # конфиг pytest
├── run.sh              # entrypoint: запуск pytest + генерация отчётов
├── config.py           # настройки подключения (из env)
├── db.py               # подключение к БД, ожидания репликации
├── docker_cli.py       # управление docker (для failover-теста)
├── conftest.py         # фикстуры: test_table (создание/удаление), row_key
├── test_replication.py # тесты INSERT/UPDATE/DELETE
└── test_failover.py    # тест устойчивости (failover)
```

## Требования

- Docker с доступным host-сокетом (`/var/run/docker.sock`) — нужен для failover-теста.
- Версия host Docker API >= 1.44 (образ использует static docker CLI 27.x).
- Кластер должен быть поднят и здоров (`docker compose up -d`), иначе тесты
  не подключатся.
