# Мониторинг — Prometheus + Grafana + Exporters

**Статус:** wait
**Приоритет:** high
**Создана:** 2026-07-03
**Дедлайн:**

## Описание

Развернуть полноценный мониторинг всей инфраструктуры кластера. Вывести следующие метрики:

| Группа | Метрики | Источник | Порог тревоги |
|--------|---------|----------|--------------|
| **Кластер Patroni** | Состояние лидера, число нод, лаг репликации | Patroni `/metrics` (:8008) | Смена лидера ≠ ожидаемый, < 3 нод, лаг > 50 MB |
| **PostgreSQL** | Connections, dead tuples, cache hit ratio, xact rate, replication lag, размер БД | postgres_exporter | Connections > 80%, dead tuples > 20%, hit ratio < 95% |
| **HAProxy** | Статус бэкендов, активные сессии, request rate | HAProxy stats (`:7000`) / prometheus-exporter | Любой бэкенд DOWN, sessions > 80% |
| **Система** | CPU, RAM, Disk, сеть каждого контейнера | cadvisor или node_exporter | CPU > 80%, RAM < 10%, Disk < 20% |
| **Audit consumer** | Lag аудита (LSN), статус | `pg_replication_slots` через postgres_exporter | Lag > 100 MB |
| **Стриминг репликация** | Физический/логический лаг, статус apply worker | postgres_exporter | Любая реплика не в `streaming` |

### Предлагаемое решение

```
┌──────────────────────────────────────────────────────────┐
│                   Docker Compose                          │
│                                                           │
│  prometheus (pull metrics)                                │
│    ├── postgres_exporter → patroni1/2/3 (:9187)           │
│    ├── postgres_exporter → pg-physical-replica (:9187)    │
│    ├── postgres_exporter → pg-logical-replica (:9187)     │
│    ├── postgres_exporter → pg-audit-log (:9187)           │
│    ├── Patroni API → patroni1/2/3 (:8008/metrics)         │
│    ├── HAProxy stats (:7000)                              │
│    └── cadvisor → каждый контейнер                        │
│         │                                                 │
│         ▼                                                 │
│  grafana                                                  │
│    ├── Dashboards: PG, Patroni, HAProxy, System           │
│    ├── Datasource: prometheus                             │
│    ├── Alerts: Slack / Telegram / Webhook                 │
│    └── Port :3000 (admin/admin)                           │
└──────────────────────────────────────────────────────────┘
```

## Архитектура

### Prometheus

Pull-based сборщик метрик. Скрапит:
- `postgres_exporter` — PostgreSQL (все экземпляры: 3 Patroni + 3 реплики)
- `patroniN:8008/metrics` — встроенные метрики Patroni (включить через `restapi.metrics`)
- `haproxy:7000/haproxy?stats;csv` — HAProxy stats в CSV (или включить `prometheus-exporter`)
- `cadvisor:8080/metrics` — метрики Docker-контейнеров (CPU, RAM, disk, network)

### postgres_exporter

Один контейнер `prometheuscommunity/postgres-exporter` с несколькими таргетами (через `DATA_SOURCE_NAME` с переменными), либо отдельные экземпляры для каждой БД.

`DATA_SOURCE_NAME` для каждого PG:
- `postgresql://postgres:secret@patroni1:5432/shop?sslmode=disable`
- `postgresql://postgres:secret@patroni2:5432/shop?sslmode=disable`
- ... и т.д.

### Patroni /metrics

В `docker-compose.yml` в `PATRONI_CONFIGURATION.restapi` добавить:
```yaml
restapi:
  listen: 0.0.0.0:8008
  connect_address: patroniX:8008
  metrics: true
```

После этого Patroni отдаёт метрики: `patroni_lag`, `patroni_master`, `patroni_replica`, `patroni_xlog_location` и др.

### HAProxy Prometheus exporter

Включить в `haproxy.cfg` модуль `prometheus-exporter`:
```
frontend prometheus
  bind *:8405
  mode http
  http-request use-service prometheus-exporter if { path /metrics }
```

Либо использовать `haproxytech/prometheus-exporter` как sidecar (но это сложнее).

### Grafana

Предустановленные дашборды:
1. **PostgreSQL Dashboard** — ID 9628 (или кастомный): connections, transactions, replication lag, cache hit ratio, dead tuples
2. **Patroni Dashboard** — кастомный на основе метрик `/metrics`: роль ноды, лаг, число нод в кластере
3. **HAProxy Dashboard** — ID 2578 (или кастомный): статус бэкендов, sessions
4. **Docker Container Dashboard** — ID 11926 (или cadvisor dashboard): CPU, RAM, сети по контейнерам

Дашборды импортируются через `provisioning/dashboards/` (YAML-файлы).

### Alerting (опционально, но желательно)

Правила в Prometheus (`rules/patroni.yml`):
```yaml
groups:
  - name: patroni
    rules:
      - alert: PatroniMasterDown
        expr: patroni_master == 0
        for: 30s
        labels: { severity: critical }
      - alert: PatroniNodeDown
        expr: up{job="patroni"} < 3
        for: 30s
        labels: { severity: critical }
      - alert: ReplicationLagHigh
        expr: pg_stat_replication_lag > 52428800  # 50 MB
        for: 1m
        labels: { severity: warning }
      - alert: AuditConsumerLag
        expr: pg_replication_slot_lag{slot="audit_slot"} > 104857600  # 100 MB
        for: 5m
        labels: { severity: warning }
```

### Точки подключения

| Компонент | Куда подключается | Порт (внутри Docker) |
|-----------|------------------|---------------------|
| postgres_exporter | patroni1/2/3 (PG) | 5432 |
| postgres_exporter | pg-physical-replica | 5432 |
| postgres_exporter | pg-logical-replica | 5432 |
| postgres_exporter | pg-audit-log | 5432 |
| Prometheus | Patroni REST API | 8008 |
| Prometheus | postgres_exporter | 9187 |
| Prometheus | cadvisor | 8080 |
| Grafana | Prometheus | 9090 |
| Пользователь | Grafana Web UI | 3000 |

## DoD

- [ ] Prometheus собирает метрики со всех Patroni-нод (`/metrics`)
- [ ] postgres_exporter собирает метрики со всех 7 экземпляров PostgreSQL
- [ ] HAProxy отдаёт метрики в Prometheus (через встроенный prometheus-exporter)
- [ ] cadvisor собирает метрики со всех контейнеров
- [ ] Grafana показывает дашборды: PostgreSQL, Patroni, HAProxy, Container Resources
- [ ] Поведение кластера (failover, лаг, нагрузка) отражается на дашбордах в реальном времени
- [ ] Всё разворачивается одной командой `docker compose up -d` (новые сервисы)
- [ ] Не требуется ручная настройка после запуска (autoprovisioning)

## Структура файлов

```
patroni-cluster/
├── docker-compose.yml              # + prometheus, grafana, postgres_exporter, cadvisor
├── prometheus/
│   ├── prometheus.yml              # конфигурация scrape
│   └── rules/
│       └── patroni.yml             # alerting rules
├── grafana/
│   ├── grafana.ini                 # настройки (опционально)
│   ├── provisioning/
│   │   ├── datasources/
│   │   │   └── prometheus.yml      # авто-подключение Prometheus
│   │   └── dashboards/
│   │       ├── dashboard.yml        # авто-импорт дашбордов
│   │       ├── postgres.json        # дашборд PostgreSQL
│   │       ├── patroni.json         # дашборд Patroni
│   │       ├── haproxy.json         # дашборд HAProxy
│   │       └── containers.json      # дашборд Docker-контейнеров
│   └── dashboards/                  # (опционально) дополнительные
└── haproxy/
    └── haproxy.cfg                  # + prometheus-exporter frontend
```

## Шаги выполнения

1. Создать `prometheus/prometheus.yml` — конфигурация scrape для всех таргетов
2. Включить `restapi.metrics: true` в `PATRONI_CONFIGURATION` всех трёх Patroni-нод
3. Добавить `prometheus-exporter` frontend в `haproxy.cfg`
4. Создать `grafana/provisioning/datasources/prometheus.yml` — авто-подключение
5. Экспортировать или создать дашборды для Grafana (PG, Patroni, HAProxy, Containers)
6. Добавить сервисы в `docker-compose.yml`: prometheus, grafana, postgres_exporter, cadvisor
7. Собрать: `docker compose build` → `docker compose up -d`
8. Проверить, что все таргеты в Prometheus UP (http://localhost:9090/targets)
9. Проверить дашборды в Grafana (http://localhost:3000, admin/admin)
10. Выполнить тест: запустить load-generator, наблюдать изменение метрик на дашбордах

## Примечания

- cadvisor требует монтирования `/var/run/docker.sock` и `/sys/fs/cgroup` — нужны права root на хосте
- Для Windows Docker Desktop cadvisor работает, но может ограниченно показывать метрики (native Linux контейнеры)
- Альтернатива cadvisor — `prometheus/node-exporter` только для хостовых метрик (не контейнеров)
- Все экспортеры не имеют авторизации — только внутренняя сеть Docker
- Для продакшена добавить basic auth в Prometheus и Grafana
