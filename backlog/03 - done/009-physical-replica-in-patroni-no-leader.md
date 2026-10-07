# Включить pg-physical-replica в кластер Patroni как 4-й узел, запретив ей становиться Leader

**Статус:** done
**Приоритет:** medium
**Создана:** 2026-08-27
**Дедлайн:** 2026-08-28

## Анализ / Оценка (можно ли сделать)

### Вердикт: частично реализуемо

Требование «добавить `pg-physical-replica` как полноценный узел кластера Patroni, но чтобы ей **нельзя было стать Leader**» реализуемо частично и со специфическими оговорками. Объяснение ниже.

### Как сейчас устроена pg-physical-replica

Текущий сервис `pg-physical-replica` — **автономная** физическая реплика, **вне кластера Patroni**:
- `replica-physical/entrypoint.sh` делает `pg_basebackup -h haproxy` от мастера и настраивает `primary_conninfo` + `standby.signal`
- Она стримит WAL **напрямую с HAProxy** (R/W :5432), не зная о Patroni/DCS
- Не участвует в etcd, не имеет Patroni REST API, не является членом `scope: patroni_cluster`

Это нормальная рабочая схема (см. README/AGENTS.md), но это **не** узел кластера.

### Ключевой вопрос: как «запретить быть Leader» в Patroni

Штатно Patroni **не имеет аппаратного параметра «узел вообще никогда не может быть лидером»**. Есть два уровня ограничения:

| Механизм | Эффект | Ограничения |
|----------|--------|-------------|
| `tags.nofailover: true` | Узел **не участвует в автоматическом failover** (не будет избран новым leader, если мастер падает) | Узел всё ещё можно промоутнуть **вручную** (`patronictl promote`). Это «мягкий» запрет |
| `scope` / не член DCS | Гарантированный запрет роли master | Теряет статус «полноправного узла кластера Patroni» — противоречит требованию |
| `bootstrap.dcs.standby_cluster` | Узел реплицируется из **внешнего** кластера и не кандидат на лидерство | Семантика «другой сценарий»: реплика из внешнего источника, а не из мастера этого же кластера |

**Вывод для планирования:** добиться «ни при каких условиях не станет лидером» **штатными средствами Patroni невозможно для полноправного узла того же кластера** — Patroni автоматически промоутит любую живую и актуальную реплику при failover, если она участвует в выборах (нет `nofailover`). 

Практически гарантированный результат для «полноправного 4-го узла, который не станет лидером при автоматическом failover» достигается комбинацией:
- **`tags.nofailover: true`** → исключает из автоматического выбора лидера
- **`tags.nofailover` + осторожность: не вызывать `patronictl promote`** для этого узла (политика эксплуатации)

Если нужно **абсолютно гарантированно** исключить даже ручной промоут — единственный надёжный путь — не давать узлу прав на запись ключа `/leader` в etcd (RBAC/ACL в DCS). Это усложняет кластер и ломается при стандартной конфигурации etcd. Поэтому в DoD фиксируется целевой уровень: **автоматический failover никогда не изберёт этот узел** + документированный запрет ручного промоута.

### Что значит «полноправный узел»

Чтобы попасть в кластер, 4-й узел должен:
1. Иметь свой `name` в `scope: patroni_cluster` (например `pg-physical-replica` или `patroni4`)
2. Подключиться к тому же **etcd** (DCS)
3. Иметь Patroni REST API (`:8008`) → через него HAProxy health-check сможет учитывать/исключать узел
4. Стримить от мастера через Patroni (а не напрямую `pg_basebackup` от HAProxy), чтобы Patroni отслеживал лаг и репликацию
5. Не исполнять `post_bootstrap` / `init.sh` (это инициализация схемы/данных только на лидере)

## Сравнение подходов (выбор)

### Вариант A — 4-й узел Patroni в том же scope (рекомендуемый)
- Переписать `pg-physical-replica` под `build: ./patroni` (или отдельный образ с Patroni)
- `PATRONI_CONFIGURATION` без `post_bootstrap`, с `tags.nofailover: true`, `restapi`, `etcd: hosts: etcd:2379`
- `bootstrap.dcs` — только если узел будет bootstrap-инициализировать (не будет — берёт basebackup от лидера)
- Patroni сам сделает `pg_basebackup` от текущего мастера (поведение по умолчанию при пустом `data_dir`)
- HAProxy: добавить health-check бэкенда на этот узел (опционально)

**Плюсы:** настоящий член кластера, единая оркестрация, авто-отслеживание лага, failover-безопасность (никогда не лидер).
**Минусы:** не 100% аппаратный запрет ручного промоута (нужна политика).

### Вариант B — оставить автономной, но добавить в проект config со `nofailover`
Противоречит требованию «полноправный узел кластера». Не целевой.

## Критерии готовности (DoD)

- [x] Сервис `pg-physical-replica` становится членом `scope: patroni_cluster` (виден в `patronictl list` как 4-я нода, роль `replica`)
- [x] Узел подключён к тому же etcd; имеет Patroni REST API `:8008`
- [x] Узел имеет `tags.nofailover: true` — при остановке/падении мастера (тест `docker compose stop <master>`) узел **не** становится новым лидером
- [x] Узел не исполняет `post_bootstrap`/`init.sh` (схема и данные берутся физической репликацией, а не повторной инициализацией)
- [x] Физическая репликация работает через Patroni (лаг в `pg_stat_replication` отслеживается; `patronictl list` показывает актуальный лаг)
- [x] HAProxy R/W :5432 продолжает маршрутизировать приложения (при необходимости — без учёта нового узла как мастера)
- [x] Тест failover: узел `pg-physical-replica` остаётся `replica`, лидером становится одна из исходных нод
- [x] Порт 5433 (внешний доступ к физической реплике) сохранён
- [x] Документация (AGENTS.md / docs/replication.md) обновлена: новое поведение 4-го узла и запрет на `patronictl promote <pg-physical-replica>`

## Итог проверки (2026-08-28)

Реализовано и проверено на живом кластере:

- `docker-compose.yml`: сервис `pg-physical-replica` переведён на образ `./patroni` с собственным `PATRONI_CONFIGURATION` (`name: pg-physical-replica`, `scope: patroni_cluster`, `etcd: etcd:2379`, `tags: nofailover: true`, **без** `post_bootstrap`). Volume `./data/pg_physical:/data`, порт `5433:5432`.
- Кластер поднят с 4 нодами: `patroni1/2/3` + `pg-physical-replica`. Узел виден в `patronictl list` как `Replica` с тегом `nofailover: true`, делает NodeBaseBackup от лидера.
- **Тест failover:** остановлен мастер `patroni2` → лидером стал `patroni3`, `pg-physical-replica` **остался `replica`** (лаг 0). Бывший мастер `patroni2` после crash recovery вернулся в кластер как `replica`.
- Данные реплицируются корректно (`bookings.tickets` синхронизирован, лаг ~bytes), узел в `pg_is_in_recovery() = t`.
- Логическая репликация (`shop_sub`, `audit_slot`) и HAProxy/load-generator работают после failover.
- **Дополнительно исправлено (по итогам мониторинга):** `postgres_exporter` v0.15.0 выдавал ошибку `column "checkpoints_timed" does not exist` (колонка `pg_stat_bgwriter` переименована в PG18). У всех 6 экспортеров задан `command: ["--no-collector.stat_bgwriter"]` — ошибка устранена, все targets `UP`.

**Ограничение (осталось осознанным):** полный аппаратный запрет ручного `patronictl promote <pg-physical-replica>` штатно невозможен; гарантирована защита от **автоматического** failover (`nofailover: true`). Ручной промоут — под запретом (политика/документация).

## План работ (по этапам)

### Этап 0. Пре-флайт (подготовка к изменениям)
- [ ] `git status` / `git diff` — чистая рабочая копия, текущие изменения (если есть) учтены/закоммичены
- [ ] Зафиксировать текущее состояние кластера: `docker compose exec patroni1 patronictl list` (3 ноды, мастер известен)
- [ ] Снять бэкап/слепок конфигурации: `docker-compose.yml`, `replica-physical/entrypoint.sh`, `patroni/init.sh`, `haproxy.cfg` (для быстрого отката)
- [ ] Определить целевую роль и имя 4-го узла: `pg-physical-replica` (или `patroni4`). Проверить, что выбранное имя не конфликтует

### Этап 1. Проектирование конфигурации узла
- [ ] Определить `PATRONI_CONFIGURATION` для 4-го узла:
  - `scope: patroni_cluster` (тот же)
  - `name: pg-physical-replica` (свой)
  - `restapi: listen/connect_address/metrics` (`:8008`)
  - `postgresql: listen/connect_address/data_dir`, `authentication` (superuser/replication)
  - `etcd: hosts: etcd:2379`
  - `tags: nofailover: true`
  - **без** `post_bootstrap` (критично — не переинициализировать схему)
- [ ] Решить источник данных при первом старте: авто-`pg_basebackup` Patroni от мастера (рекомендуется) — подтвердить, что Patroni подхватит мастера через DCS и сделает NodeBaseBackup
- [ ] Спроектировать образ: переиспользовать `./patroni` (богатый Patroni+PG) без `post_bootstrap`, или отдельный `./replica-physical-patroni` (минимизировать дублирование)

### Этап 2. Реализация
- [ ] Создать/адаптировать образ и `PATRONI_CONFIGURATION` для узла (см. Этап 1)
- [ ] Обновить сервис `pg-physical-replica` в `docker-compose.yml`:
  - `build: ./patroni` (или `./replica-physical-patroni`)
  - env: `PATRONI_CONFIGURATION` (+ `POSTGRES_PASSWORD`/`PGPASSWORD` если нужны для бэкапов — но Patroni управляет auth сам)
  - volume `./data/pg_physical:/data`
  - `ports: 5433:5432`, сеть `patroni-net`
  - `depends_on: etcd` (+ `haproxy` для источника basebackup при необходимости)
- [ ] Убрать/заменить логику `replica-physical/entrypoint.sh` (ручной `pg_basebackup` + `standby.signal`/`primary_conninfo`) — Patroni управляет репликацией сам
- [ ] Обновить `pg-exporter-physical` DSN (адрес/порт узла, если изменился)
- [ ] Проверить `haproxy.cfg` — решить, учитывать/исключать 4-й узел (R/W должен остаться на мастере)

### Этап 3. Сборка и запуск
- [ ] `docker compose build` (или только нужных сервисов)
- [ ] `docker compose up -d pg-physical-replica`
- [ ] Дождаться, пока узел сделает basebackup и войдёт в кластер
- [ ] Проверить `docker compose exec patroni1 patronictl list` — 4 ноды, узел в статусе `replica`

### Этап 4. Валидация
- [ ] Узел виден в `patronictl list` как `replica` с адекватным лагом
- [ ] Лаг в `pg_stat_replication` на мастере = 0 (или минимальный) для `pg_physical_replica`
- [ ] REST API узла отвечает: `curl http://pg-physical-replica:8008/patroni` (или localhost, если проброшен)
- [ ] Узел не выполнил `post_bootstrap`/`init.sh` (схема `bookings.*` на узле не задваивается — проверить, что таблицы на узле не пересоздавались)

### Этап 5. Тест запрета лидерства (failover)
- [ ] `docker compose stop <текущий-мастер>` (одна из исходных нод)
- [ ] Дождаться failover; убедиться, что **лидером становится исходная нода, а не `pg-physical-replica`**
- [ ] `pg-physical-replica` остаётся `replica` (не промоутится)
- [ ] Поднять бывший мастер обратно, дождаться полной синхронизации
- [ ] Повторить тест, если необходимо, для уверенности
- [ ] (Опционально) зафиксировать, что `patronictl promote pg-physical-replica` вручную не инициируется (политика)

### Этап 6. Регрессия остальных компонентов
- [ ] HAProxy :5432 — приложения продолжают работать (R/W к мастеру)
- [ ] Логическая репликация `shop_sub` и `audit_slot` не затронута
- [ ] `pg-logical-replica`, `pg-audit-log` и consumer в норме
- [ ] Prometheus/Grafana: метрики 4-го узла собираются (если relevant)

### Этап 7. Документация и завершение
- [ ] Обновить `AGENTS.md` / `docs/replication.md`: 4-й узел в составе Patroni, запрет промоута, команды эксплуатации, восстановление при сбое
- [ ] Обновить DoD задачи (отметить выполненные пункты)
- [ ] `docker compose down -v` НЕ выполнять без необходимости (снесутся volume)
- [ ] Перенести задачу в `02 - work/` при начале работ; в `03 - done/` после завершения

## Шаги выполнения

1. Создать отдельный образ/сервис для 4-го узла (на базе `./patroni`, но без `post_bootstrap`), либо адаптировать `pg-physical-replica`:
   - Добавить `PATRONI_CONFIGURATION` с `name`, `scope: patroni_cluster`, `restapi` (`listen`/`connect_address`/`metrics`), `postgresql` (`data_dir`, auth), `etcd: hosts: etcd:2379`
   - Добавить `tags: nofailover: true` в конфигурацию узла
   - Исключить `post_bootstrap` (иначе узел попытается инициализировать схему)
2. В `docker-compose.yml` переоформить сервис `pg-physical-replica`:
   - `build: ./patroni` (или `./replica-physical-patroni`) + env `PATRONI_CONFIGURATION`
   - Оставить volume `./data/pg_physical:/data` (Patroni `data_dir=/data/pgdata`)
   - Оставить `ports: 5433:5432`, подключить к `patroni-net`, `depends_on: etcd` (+ haproxy для basebackup-источника)
   - Обновить `pg-exporter-physical` DSN при необходимости
3. Решить вопрос со стартом узла при первом запуске:
   - Либо полагаться на авто-`pg_basebackup` Patroni от текущего мастера
   - Либо сохранить логику symlink `/data/pgdata → $PGDATA` как в текущем entrypoint
4. Проверить `docker compose up -d`, дождаться, что 4-я нода появится в `patronictl list` как `replica`
5. Тест запрета лидерства: остановить текущий мастер (`docker compose stop <master>`), убедиться, что лидера выбирают из исходных 3-х нод, а `pg-physical-replica` остаётся `replica`
6. Проверить, что физический лаг репликации узла отслеживается (`patronictl list`, `pg_stat_replication`)
7. При необходимости — добавить/убрать health-check в `haproxy.cfg` для нового узла
8. Обновить документацию: 4-й узел, запрет промоута, команды эксплуатации
9. `docker compose build` → `docker compose up -d` → финальная проверка по DoD

## Восстановление реплики при сбое / действия при проблемах

Ниже — как 4-й узел (`pg-physical-replica`) восстанавливается при различных сценариях сбоя и что делать, если что-то пошло не так. Разделено по типам сбоя.

### 1. Временный сбой узла (контейнер упал/перезапущен)

- **Поведение:** контейнер запускается, Patroni внутри обнаруживает существующий `data_dir` (не пустой), проверяет кластер через DCS, подключается к текущему мастеру и продолжает стримить WAL с того места, где остановился.
- **Действия:** `docker compose up -d pg-physical-replica` (или сам `restart`-политикой). Ждать появления в `patronictl list` и снижения лага до нуля.
- **Если не поднялась:** смотреть логи `docker compose logs pg-physical-replica`, проверить доступ к etcd и мастеру.

### 2. Лаг репликации растёт / узел отстаёт

- **Проверка:** `patronictl list` (колонка Lag / Replica) или SQL на мастере:
  ```sql
  SELECT application_name, state, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag
  FROM pg_stat_replication;
  ```
- **Возможные причины:** сетевые проблемы, перегрузка CPU/диска на узле, потеря связи с мастером.
- **Действия:** проверить сеть (`docker network inspect patroni-net`), ресурсы узла (cadvisor/`docker stats`), убедиться что мастер жив. При затяжном отставании Patroni сам не гасит реплику, но узел может недогонять WAL и потребовать `pg_rewind`/пересоздания (см. п.4).

### 3. Потеря связи с мастером (нет лидера в кластере)

- Узел `pg-physical-replica` с `tags.nofailover: true` **не** станет лидером — он останется в `replica` и будет ждать нового мастера через DCS.
- **Действия:** провести штатный failover (Patroni выберет лидера из трёх исходных нод), после чего узел автоматически переподключится к новому мастеру. Проверить, что лаг опустился до нуля.

### 4. Порча данных на реплике / целостность нарушена / кластер вышел из синхронизации

Когда узел не может восстановиться сам (push-клонирование падает, `pg_rewind` неприменим, пришлось вручную править `data_dir`), проще всего **пересоздать узел с нуля**:

```bash
# остановить и удалить контейнер без сноса других сервисов
docker compose rm -sf pg-physical-replica

# (опционально) очистить данные реплики
Remove-Item -Recurse -Force "patroni-cluster/data/pg_physical/*"

# поднять заново — узел сделает чистый NodeBaseBackup от текущего мастера
docker compose up -d pg-physical-replica
```

После пересоздания узел вернётся в кластер как `replica`, вытянет полную копию данных и наверстает WAL. Проверить: `patronictl list`, лаг в `pg_stat_replication` = 0.

### 5. «Застрял» в статусе, отличном от replica, или Patroni не хочет подключаться

- Проверить статус узла: `docker compose exec pg-physical-replica patronictl list` или REST-API `curl http://localhost:8008/patroni`.
- Убедиться, что узел подключён к тому же `scope` и etcd.
- Если узел ошибочно показывает `master`/пытается стать лидером — см. раздел «Главное ограничение»: проверить, что `tags.nofailover: true` применяется, и не вызывать `patronictl promote`.
- При невозможности починить — полное пересоздание по п.4.

### 6. Внешний доступ / порт 5433 не работает

- Проверить, что `ports: 5433:5432` на месте, контейнер в `patroni-net`, узел реально поднят в `replica`.
- Проверить `GET /master` и `/replica` на REST API узла.

## Заметки

- **Главное ограничение (важно для статуса задачи):** Patroni не позволяет штатно сделать полноправного члена кластера, который *никогда ни при каких условиях* не станет лидером. Достижимый целевой уровень — **«не избирается лидером при автоматическом failover»** (`tags.nofailover: true`). Полный/гарантированный запрет, включая ручной `patronictl promote`, штатными средствами не обеспечивается — это либо политика эксплуатации, либо RBAC на ключ `/leader` в DCS.
- Узел не должен выполнять `post_bootstrap=/scripts/init.sh`, иначе будет повторная инициализация схемы `bookings.*` — она должна прийти только через WAL-репликацию.
- Существующий `entrypoint.sh` физической реплики (`pg_basebackup` от HAProxy + `standby.signal`) при переходе к Patroni-учёту заменяется на родную механику Patroni (NodeBaseBackup / bootstrap). Логика `standby.signal`/`primary_conninfo` вручную не требуется — Patroni управляет репликацией.
- Паттерн `bootstrap.dcs.standby_cluster` применять **не** следует — он для репликации из внешнего кластера, а не для роли «реплика внутри того же кластера».
- Порты/топология: `HAProxy :5432` (мастер), узел публично `:5433`. Балансировка на новый узел для чтения не входит в объём задачи.
