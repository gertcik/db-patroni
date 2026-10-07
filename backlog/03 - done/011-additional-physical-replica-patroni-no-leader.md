# Дополнительная физическая реплика: включить в кластер Patroni, запретив ей становиться Leader

**Статус:** done
**Приоритет:** medium
**Создана:** 2026-10-07
**Дедлайн:**

## Описание

Добавить **вторую** физическую реплику (`pg-physical-replica2`) и сделать её **полноправным узлом кластера Patroni** (член `scope: patroni_cluster`, свой REST API `:8008`, учёт в `patronictl list`), при этом она **не должна никогда становиться Leader** — ни при автоматическом failover, ни вручную (политика).

Опорная задача: `009-physical-replica-in-patroni-no-leader.md` — уже реализована и проверена (2026-08-28). Новая реплика делается **по тому же проверенному шаблону**, конфигурация `pg-physical-replica` копируется с изменением имени/тома/порта.

## Анализ / Оценка

### Как сделать — рекомендуемый подход (Variant A, доказан задачей 009)

Скопировать сервис `pg-physical-replica` из `docker-compose.yml` (образ `./patroni`, т.е. **новый Dockerfile не нужен**) с такими отличиями:

| Параметр | Значение | Почему |
|----------|----------|--------|
| `PATRONI_CONFIGURATION.name` | `pg-physical-replica2` | Имя узла уникально в `scope` |
| `scope`, `etcd: hosts: etcd:2379` | как у существующих нод | Членство в кластере |
| `restapi.connect_address` | `pg-physical-replica2:8008` | Свой REST API (health-check/метрики) |
| `tags.nofailover` | `true` | **Ключевое**: исключает узел из автоматического выбора лидера |
| `post_bootstrap` | **отсутствует** (не копировать!) | Схема/данные приходят только через WAL, иначе задвоение `bookings.*` |
| volume | `./data/pg_physical2:/data` (`data_dir=/data/pgdata`) | Свой каталог данных (паттерн `./data/pgdata1..3`) |
| `ports` | `5436:5432` | Свободный хост-порт (5432 haproxy, 5433 replica1, 5434 logical, 5435 audit) |
| `depends_on` | `etcd`, `patroni1` | Как у replica1 |

При первом старте Patroni сам сделает `pg_basebackup` от текущего лидера (пустой `data_dir`) — ручной `entrypoint.sh` с `standby.signal` не используется.

### Отклонённые альтернативы

- **Автономная реплика (`replica-physical/entrypoint.sh`, pg_basebackup от HAProxy)** — работает, но это *не* узел кластера: нет учёта в DCS/`patronictl`, нет REST API. Противоречит требованию «включить в кластер Patroni».
- **`bootstrap.dcs.standby_cluster`** — семантика «реплика из внешнего кластера», не наш случай (как в 009).
- **RBAC/ACL на ключ `/leader` в etcd** — единственный *аппаратный* запрет ручного промоута, но усложняет кластер и ломается со стандартной конфигурацией etcd. Не требуется.

### Ключевое ограничение (осознанное)

`tags.nofailover: true` — «мягкий» запрет: узел **никогда не будет избран** при автоматическом failover, но `patronictl promote pg-physical-replica2` вручную формально возможен. Как и в 009: запрет ручного промоута — **политика эксплуатации + документация** (AGENTS.md/docs).

### Что затронет добавление узла

- **HAProxy `patroni_back` — НЕ трогать**: бэкенд только для leader-capable нод (health-check `GET /master`), реплика там не нужна.
- **Логическая репликация (`shop_sub`, `audit_slot`) — не затрагивается**: слоты permanent в DCS, подписки переподключаются сами; DDL идут через WAL.
- **Мониторинг — требуется добавить таргеты** (и заодно закрыть пробел из задачи 007):
  - сервис `pg-exporter-physical2` (DSN `...@pg-physical-replica2:5432/shop...`);
  - `prometheus.yml`, job `postgresql` → `pg-exporter-physical2:9187`;
  - `prometheus.yml`, job `patroni` → добавить **обе** физические реплики: `pg-physical-replica:8008`, `pg-physical-replica2:8008` (сейчас там только patroni1-3, хотя `restapi.metrics: true` у реплик включён);
  - ⚠️ пока узел делает basebackup, алерт `ReplicationLagHigh` (`patroni_lag > 50MB`) может сработать — это ожидаемо и временно.
- **pgAdmin** — добавить сервер `"5"` в `pgadmin/servers.json` (как «Physical Replica» №2).
- **Тесты** — `tests/config.py` (`LEADER_CAPABLE_NODES`) не трогать; в `test_failover.py` добавить `pg-physical-replica2` в проверку «новый лидер ≠ nofailover-узел» и в маппинг контейнер→сервис (строки с `+ ["pg-physical-replica"]`), иначе тест не проверяет вторую реплику.
- **Windows**: первый `pg_basebackup` на bind mount занимает 3–5 минут (см. `docs/monitoring.md`) — узел будет отставать с большими цифрами лага, это нормально.

## Критерии готовности (DoD)

- [x] Сервис `pg-physical-replica2` в `docker-compose.yml`: образ `./patroni`, свой `PATRONI_CONFIGURATION` (`name: pg-physical-replica2`, `scope: patroni_cluster`, etcd, `restapi :8008`, **без** `post_bootstrap`), volume `./data/pg_physical2`, порт `5436:5432`
- [x] Узел виден в `patronictl list` как 5-я нода со статусом `replica` и тегом `nofailover: true`
- [x] REST API отвечает: `pg-physical-replica2:8008`; `pg_is_in_recovery() = true`
- [x] Узел **не** выполнил `post_bootstrap`/`init.sh` (схема `bookings.*` пришла через WAL, не задвоена)
- [x] Лаг в `pg_stat_replication` на мастере отслеживается и опускается до ~0 после basebackup
- [x] **Тест лидерства**: `docker compose stop <текущий-мастер>` → новым лидером становится одна из `patroni1/2/3`, `pg-physical-replica2` (и replica1) остаются `replica`; бывший мастер возвращён в кластер
- [x] HAProxy `:5432` продолжает маршрутизировать записи на мастера (бэкенд не изменён)
- [x] Экспортер + таргеты Prometheus добавлены, все targets `UP` (включая `job="patroni"` для обеих физических реплик)
- [x] pgAdmin: новый сервер зарегистрирован
- [x] Тест `test_failover.py` обновлён (проверка обеих nofailover-реплик) и проходит: `docker compose run --rm replication-tests -k failover`
- [x] Документация обновлена: `AGENTS.md` (состав нод, порт 5436, запрет промоута), `docs/replication.md`, `docs/components.md`, запись в `changes.md`
- [x] Задача перенесена: `01 - wait/` → `02 - work/` при начале, → `03 - done/` после проверки

## Пошаговый план

### Этап 0. Пре-флайт
1. `git status` — рабочая копия учтена (в т.ч. уже лежащие незакоммиченные `tests/`, `docs/replication-tests.md`).
2. Зафиксировать состояние кластера: `docker compose exec patroni1 patronictl list` (сейчас 4 ноды, мастер известен).
3. Снять «слепок» для отката: `docker-compose.yml`, `pgadmin/servers.json`, `prometheus/prometheus.yml`, `tests/test_failover.py`.

### Этап 1. Конфигурация compose
4. В `docker-compose.yml` добавить сервис `pg-physical-replica2` — копия `pg-physical-replica` с правками из таблицы выше (имя, `connect_address`, volume `./data/pg_physical2`, порт `5436:5432`).
5. Добавить сервис-экспортер `pg-exporter-physical2` (копия `pg-exporter-physical`, DSN → `pg-physical-replica2`).
6. В `pgadmin/servers.json` добавить сервер `"5"`: Name `Physical Replica 2`, Host `pg-physical-replica2`.
7. В `prometheus/prometheus.yml`: `pg-exporter-physical2:9187` в job `postgresql`; `pg-physical-replica:8008` и `pg-physical-replica2:8008` в job `patroni`.
8. Убедиться, что `haproxy/haproxy.cfg` **не** изменяется (backend только patroni1-3).

### Этап 2. Запуск
9. `docker compose up -d pg-physical-replica2 pg-exporter-physical2` (образ `./patroni` уже собирается/в кэше — отдельная сборка не нужна).
10. Ждать basebackup и входа в кластер: `docker compose logs -f pg-physical-replica2` → `docker compose exec patroni1 patronictl list` (5 нод, роль `replica`, тег `nofailover`). На Windows — 3–5 минут.

### Этап 3. Валидация узла
11. `docker compose exec pg-physical-replica2 psql -U postgres -c "SELECT pg_is_in_recovery();"` → `t`.
12. REST: `docker compose exec patroni1 curl -s http://pg-physical-replica2:8008/patroni`.
13. Лаг на мастере: `SELECT application_name, state, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) FROM pg_stat_replication;` → для `pg_physical_replica2` после синхронизации ~0.
14. `post_bootstrap` не запускался: в `docker compose logs pg-physical-replica2` нет следов `init.sh` (`CREATE DATABASE shop`), при этом схема `bookings.*` на узле присутствует и данные совпадают с мастером.
15. Хост-порт: `psql -h localhost -p 5436 -U postgres -d shop` (пароль `secret`).

### Этап 4. Тест запрета лидерства
16. Определить текущий мастер, `docker compose stop <мастер>`.
17. Дождаться failover: новым лидером стала `patroni1/2/3`, **обе** физические реплики остались `replica`.
18. `docker compose start <мастер>` → узел возвращается (`pg_rewind`/rejoin), лаги → 0.
19. Прогнать штатный тест: `docker compose build replication-tests` (если нужно) → `docker compose run --rm replication-tests -k failover` — **после** правки `test_failover.py` (Этап 5, п.20), иначе вторая реплика не проверяется.

### Этап 5. Тесты и мониторинг
20. В `tests/test_failover.py`: расширить проверку «новый лидер ≠ nofailover-узел» на `pg-physical-replica2` и добавить его в маппинг контейнер→сервис (список рядом с `+ ["pg-physical-replica"]`).
21. Полный прогон: `docker compose run --rm replication-tests` (DML + failover), отчёты в `patroni-cluster/data_tests/reports/`.
22. Prometheus: http://localhost:9090/targets — все `UP`, включая новые таргеты; Grafana — лаг/роль новой ноды на дашбордах.

### Этап 6. Регрессия
23. Логическая репликация: `pg_stat_subscription` активна, лаг `shop_sub`/`audit_slot` в норме.
24. `pg-audit-consumer` пишет (`docker compose logs pg-audit-consumer`), `load-generator` работает через `:5432`.

### Этап 7. Документация и завершение
25. `AGENTS.md`: 5 нод в разделе Architecture, порт 5436, запрет `patronictl promote pg-physical-replica2`.
26. `docs/replication.md` + `docs/components.md`: новая нода, схема портов; `changes.md` — датированная запись.
27. Отметить DoD, перенести файл: `01 - wait/` → `02 - work/` → `03 - done/`.

## Заметки

- **Порты хоста сейчас заняты:** 5432 (haproxy), 5433 (replica1), 5434 (logical), 5435 (audit) → для новой реплики берём **5436**.
- `maximum_lag_on_failover: 1048576` (1 ГБ) не мешает: на узел с `nofailover: true` это ограничение не действует — он не участвует в выборах вовсе.
- Имена контейнеров/нод: не использовать `patroni4`/`patroni5` — имя должно отражать роль (`pg-physical-replica2`), чтобы `patronictl list` и логи были самодокументируемыми (и чтобы тесты не путали с leader-capable нодами).
- Восстановление узла при порче данных (пересоздание с чистым basebackup) — тот же паттерн, что в задаче 009, раздел «Восстановление реплики при сбое», п.4: `docker compose rm -sf pg-physical-replica2` → (опц.) очистить `./data/pg_physical2` → `docker compose up -d pg-physical-replica2`.
- `docker compose down -v` bind-mount'ы в `./data/*` не удаляет — полный сброс только с ручной очисткой каталога (см. AGENTS.md, «Full reset»).
