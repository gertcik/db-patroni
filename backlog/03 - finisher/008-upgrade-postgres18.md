# Переход на PostgreSQL 18

**Статус:** finisher
**Приоритет:** medium
**Создана:** 2026-07-22
**Дедлайн:**

## Описание

Обновить кластер с PostgreSQL 17 на PostgreSQL 18. Задействованы все компоненты, использующие образ PostgreSQL:

| Компонент | Текущий образ | Что нужно изменить |
|-----------|--------------|-------------------|
| patroni1-3 | `patroni` (PostgreSQL 17) | Обновить `PATRONI_POSTGRESQL_DATA_DIR`, Dockerfile / base image |
| pg-physical-replica | PostgreSQL 17 | Обновить base image |
| pg-logical-replica | PostgreSQL 17 | Обновить base image |
| pg-audit-log (WAL consumer) | Java 17 + PG 17 WAL | Проверить совместимость WAL формата, обновить PG-клиент |

### Ключевые моменты

- **Мажорный апгрейд** (17 → 18): requires `pg_upgrade` или пересоздание данных с нуля (patroni/bootstrap + replica entrypoint заново инициализируют PGDATA)
- **Logical replication**: PG 18 вносит изменения в WAL формат — логическая реплика и слоты (`shop_sub`, `audit_slot`) могут потребовать пересоздания
- **Patroni**: проверить совместимость текущей версии Patroni с PG 18 ( Patroni ≥ 4.x должна поддерживать)
- **pgBasebackup / WAL shipping**: убедиться, что физическая реплика корректно стартует с PG 18

## Критерии готовности (DoD)

- [x] Все Docker-образы используют PostgreSQL 18
- [x] Кластер Patroni (3 ноды) корректно бутстрапится и выбирает лидера
- [x] Физическая реплика делает `pg_basebackup` и стримит WAL от нового мастера
- [x] Логическая реплика (`shop_sub`) работает корректно — данные реплицируются без ошибок
- [x] Слот `audit_slot` работает — WAL consumer получает аудит-события
- [x] pgAdmin подключается ко всем серверам и видит данные
- [x] Тестовые данные (`bookings.*`) доступны для чтения/записи через HAProxy
- [x] `docker compose build && docker compose up -d` работает «из коробки»

## Шаги выполнения

1. Проверить доступность официального образа PostgreSQL 18 в Docker Hub
2. Проверить совместимость текущей версии Patroni с PG 18 (CHANGELOG / GitHub issues)
3. Обновить base image во всех Dockerfile / docker-compose.yml сервисах
4. Пересобрать образы: `docker compose build`
5. Удалить старые volume: `docker compose down -v`
6. Запустить кластер: `docker compose up -d`
7. Проверить состояние кластера: `patronictl list`
8. Проверить физическую репликацию
9. Проверить логическую репликацию (восстановить `shop_sub` если нужно пересоздавать)
10. Проверить аудит-консьюмер
11. Запустить тестовые запросы через HAProxy

## Заметки

- Дата выхода PG 18: октябрь 2025 (сейчас stable). Проверить latest tag в Docker Hub.
- Если Patroni ещё не поддерживает PG 18 — подождать обновления Patroni или использовать патч.
- При пересоздании кластера с нуля логическая реплика пересоздаётся автоматически (entrypoint), слоты создаются через `bootstrap.dcs.slots`.
