# Тесты репликации (pytest, dockerized)

Набор тестов для оценки корректности работы репликации на **живом** кластере
Patroni (`patroni-cluster`). Тесты оформлены как docker-контейнер и запускаются
через `docker compose`. По итогам формируется HTML-отчёт и Allure-результаты,
выгружаемые в каталог `patroni-cluster/data_tests/reports/` (bind mount в
`docker-compose.yml`; у сервиса `profiles: ["tests"]` — `up -d` его не запускает).

## Что проверяют тесты

| # | Тест | Проверка |
|---|------|----------|
| 1 | `test_insert_replicates` | INSERT в кластер Patroni → строка появилась на физической реплике + запись `'i'` в протокольную (audit-log) БД |
| 2 | `test_update_replicates` | UPDATE в кластере Patroni → строка обновилась на физической реплике + запись `'u'` в протокольную БД |
| 3 | `test_delete_replicates` | DELETE в кластере Patroni → строка удалена с физической реплики + запись `'d'` в протокольную БД |
| 4 | `test_failover_leader_downtime_and_recovery` | Лидер остановлен → кластер кратковременно недоступен → после восстановления SELECT проходит, новый лидер — **не** `patroni4_readonly` (узел `nofailover: true`) |

Технические детали:
- Операции вставляются через **HAProxy R/W (`:5432`)** в схему `bookings`.
- Появление на **физической** реплике проверяется через `pg-physical-replica` (`:5432` внутри сети).
- Записи `i`/`d`/`u` читаются из **audit-log** (`pg-audit-log`, `:5432`) — протокольной
  БД, которую заполняет WAL-consumer из слота `audit_slot`.
- Для детерминированной проверки тесты создают **собственную таблицу**
  `bookings.repl_test` (с `REPLICA IDENTITY FULL`), зеркала в audit-БД и на
  логической реплике, а в конце убирают их. Таблица удаляется/создаётся самой
  фикстурой; зеркало на pg-logical-replica обязательно — `FOR ALL TABLES` не
  создаёт новые таблицы на подписчике, и apply-worker падает без него.
- Тест failover работает через `/var/run/docker.sock` (монтируется в контейнер),
  останавливает и возвращает контейнер лидера; остальные тесты инфраструктуру не трогают.

## Запуск

Перед запуском кластер должен быть поднят (`docker compose up -d`) и доступен.

```bash
cd patroni-cluster

# собрать образ тестов
docker compose build replication-tests

# запустить все тесты
docker compose run --rm replication-tests
```

### Варианты запуска

```bash
# только тесты репликации (без failover)
docker compose run --rm replication-tests -k "not failover"

# только failover-тест
docker compose run --rm replication-tests -k "failover"

# verbose
docker compose run --rm replication-tests -v
```

## Отчёты

После запуска в каталоге `data_tests/reports/` появляются:

- `report.html` — самодостаточный HTML-отчёт (pytest-html)
- `allure-results/` — результаты в формате Allure (для генерации отчёта Allure)
- `results.json` — сводка результатов в JSON

Каталог `patroni-cluster/data_tests/reports/` добавлен в `.gitignore`.

## Требования / окружение

- Docker с docker CLI (host API >= 1.44; для failover-теста нужен доступ к host-сокету).
- Образ собирает `tests/Dockerfile` (python:3.12 + psycopg2 + pytest + allure/pytest-html + docker CLI).
- Настройки подключения задаются переменными окружения в сервисе `replication-tests`
  (сервис `docker-compose.yml`). По умолчанию — внутренние имена контейнеров сети `patroni-net`.
