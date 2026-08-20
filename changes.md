# Changelog

## 2026-08-20 — Реорганизация документации

### Изменённые файлы

| Файл | Что изменено |
|------|-------------|
| `README.md` | Переписан как индекс (1020 → 93 строк): ссылки на `docs/*`, требования, быстрый старт, проверка мастера, проверка кластера, остановка |
| `docs/components.md` | **Новый** (~270 строк) — сборка образа Patroni, обновление версии, описание всех компонентов, архитектура, leader election |
| `docs/replication.md` | **Новый** (~250 строк) — DML-репликация (3 пути), аудит-лог (WAL consumer, структура audit-таблиц), восстановление слотов при смене лидера |
| `docs/maintenance.md` | **Новый** (~170 строк) — DDL (таблицы, поля, индексы), обслуживание индексов, восстановление логической реплики после сбоя |
| `docs/monitoring.md` | **Новый** (~210 строк) — ключевые метрики, SQL-запросы мониторинга репликации, `moveusername` (известные ограничения), fsync на Windows |

### Структура

```
README.md (93 строки — индекс с навигацией)
docs/
├── components.md   — компоненты, архитектура, сборка
├── replication.md  — репликация данных, аудит-лог, слоты
├── maintenance.md  — DDL, индексы, восстановление реплики
└── monitoring.md   — метрики, ограничения, Windows
```

### Причина

README.md вырос до 1020 строк — в одном файле компоненты, репликация, обслуживание, мониторинг и проблемы Windows. Разбиение на 4 модульных файла упрощает навигацию и поддержку.

## 2026-07-22 — PostgreSQL 17 → 18

**Задача:** backlog/03 - finisher/008-upgrade-postgres18.md

### Изменённые файлы

| Файл | Что изменено |
|------|-------------|
| `patroni-cluster/patroni/Dockerfile` | `FROM postgres:17` → `FROM postgres:18`, комментарий заголовка |
| `patroni-cluster/replica-physical/Dockerfile` | `FROM postgres:17` → `FROM postgres:18`, комментарий заголовка |
| `patroni-cluster/replica-logical/Dockerfile` | `FROM postgres:17` → `FROM postgres:18`, комментарий заголовка |
| `patroni-cluster/pg-audit-log/Dockerfile` | `FROM postgres:17` → `FROM postgres:18` |
| `patroni-cluster/docker-compose.yml` | Заголовок: `PostgreSQL 17` → `PostgreSQL 18` |
| `patroni-cluster/replica-logical/entrypoint.sh` | Комментарий: `PostgreSQL 17` → `PostgreSQL 18` |
| `AGENTS.md` | `PostgreSQL 17 managed by Patroni` → `PostgreSQL 18 managed by Patroni` |

### Не изменялось

| Файл/компонент | Причина |
|----------------|---------|
| `patroni/Dockerfile` (PATRONI_VERSION) | Версия Patroni 4.1.3 совместима с PG 18 |
| `pg-audit-consumer/Dockerfile` | Java 17/JRE — не зависит от версии PostgreSQL |
| `load-generator/Dockerfile` | Java-приложение, подключается по JDBC — не зависит от версии PG |
| `docker-compose.yml` (services/env/ports) | Конфигурация кластера, порты, переменные — без изменений |
| `patroni/init.sh` | SQL-скрипт инициализации — совместим с PG 18 |
| `replica-physical/entrypoint.sh` | pg_basebackup / streaming replication — совместимо с PG 18 |
| `replica-logical/entrypoint.sh` | initdb / CREATE SUBSCRIPTION — совместимо с PG 18 |
| `pg-audit-log/entrypoint.sh` | initdb / psql — совместимо с PG 18 |
| `haproxy/haproxy.cfg` | Балансировщик на уровне TCP — не зависит от версии PG |
| `pgadmin/servers.json` | Конфигурация серверов — без изменений |

### Причина

PostgreSQL 18 — stable (октябрь 2025). Мажорный апгрейд, все компоненты обновлены одновременно. При полной пересборке (`docker compose down -v && docker compose build && docker compose up -d`) данные инициализируются заново — `pg_upgrade` не требуется.

### Результаты верификации (2026-07-22)

| Компонент | Статус | Детали |
|-----------|--------|--------|
| Кластер Patroni | OK | 1 Leader (patroni3) + 2 Replica (patroni1/2), streaming, lag 0 |
| PostgreSQL версия | OK | `PostgreSQL 18.4 (Debian 18.4-1.pgdg13+1)` |
| Физическая реплика | OK | `pg_is_in_recovery = true`, данные синхронизированы |
| Логическая реплика | OK | Subscription `shop_sub` active, данные реплицируются |
| Audit slot | OK | 4 слота активны: patroni1/2 (physical), audit_slot, shop_sub (logical) |
| Audit consumer | OK | 1308 bookings + 1872 segments в аудит-логе |
| Load generator | OK | DML-операции (INSERT/UPDATE/DELETE) работают |
| Все контейнеры | OK | 20/20 контейнеров Up |

**Известная проблема (non-fatal):** Patroni 4.1.3 логирует ошибку `column "checkpoints_timed" does not exist` — в PG 18 колонки `pg_stat_bgwriter` были перемещены в `pg_stat_checkpointer`. Это не влияет на работу кластера, ожидается исправление в Patroni 4.2+.
