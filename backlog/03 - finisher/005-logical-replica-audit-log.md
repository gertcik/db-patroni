# Аудит-лог через WAL consumer (Java 17)

**Статус:** finisher
**Ограничение:** NOT RESOLVED — `moveusername` всегда `'wal_consumer'`, оригинальный пользователь БД не передаётся. См. «Известные ограничения» в README.
**Приоритет:** high
**Создана:** 2026-07-02
**Дедлайн:**

## Описание

Реализовать append-only аудит-лог через отдельный Java 17 WAL consumer (`pg-audit-consumer`), который стримит изменения из WAL Patroni-кластера через слот `audit_slot` и пишет их в свою БД (`pg-audit-log`) в формате: каждая операция (INSERT/UPDATE/DELETE) → новая строка с мета-полями.

### Архитектура

```
patroni master (walsender + pgoutput)
    │ слот "audit_slot" (permanent в DCS Patroni)
    ▼
pg-audit-consumer (Java 17, отдельный контейнер)
    ├── Читает WAL через pgoutput → парсит бинарный протокол
    ├── INSERT → 'i', UPDATE → 'u', DELETE → 'd'
    └── Пишет INSERT в pg-audit-log
         │
         ▼
pg-audit-log (PostgreSQL 17, отдельный контейнер)
    └── Таблицы bookings.* с audit-полями, без PK/UK/FK
```

### Преимущества подхода
- Не требует replica identity (consumer сам решает, как обработать событие)
- Не требует триггеров/rules на подписчике (обходим `session_replication_role = replica`)
- Нет ограничений встроенной логической репликации
- Полный контроль над трансформацией данных

### Трансформация

| Событие | Действие consumer | moveaction |
|---------|-------------------|------------|
| INSERT  | INSERT в audit-таблицу | `'i'` |
| UPDATE  | INSERT в audit-таблицу | `'u'` |
| DELETE  | INSERT в audit-таблицу | `'d'` |

### moveusername
Фиксированное значение `'wal_consumer'` (не передаём оригинального пользователя).

## Критерии готовности (DoD)
- [ ] `audit_slot` добавлен в Patroni DCS (bootstrap.dcs.slots) — переживает failover
- [ ] `pg-audit-log` — PostgreSQL с пустыми таблицами `bookings.*` + поля `movedate`, `moveusername`, `moveaction`, `id_identity` + без PK/UK/FK
- [ ] `pg-audit-consumer` — Java 17 контейнер, подключается к мастеру через HAProxy, стримит WAL
- [ ] INSERT в исходной БД → новая строка в pg-audit-log с moveaction='i'
- [ ] UPDATE в исходной БД → новая строка с moveaction='u' (старая строка не меняется)
- [ ] DELETE в исходной БД → новая строка с moveaction='d' (строка не удаляется)
- [ ] `id_identity` автоинкрементируется на каждой вставке (GENERATED ALWAYS AS IDENTITY)
- [ ] После failover consumer переподключается к новому мастеру, слот сохраняется

## Шаги выполнения
1. Добавить `audit_slot` в `bootstrap.dcs.slots` всех трёх Patroni-нод (docker-compose.yml)
2. Создать `pg-audit-log/` — Dockerfile + entrypoint.sh (initdb + пустые audit-таблицы)
3. Создать `pg-audit-consumer/` — Dockerfile + Maven-проект:
   - `App.java` — main, управление слотами, цикл стриминга, реконнект
   - `PgOutputDecoder.java` — парсер pgoutput v1 (relation, insert, update, delete)
   - `AuditWriter.java` — запись в pg-audit-log с audit-полями
4. Добавить сервисы в docker-compose.yml
5. Собрать и запустить: `docker compose build && docker compose up -d`
6. Протестировать INSERT/UPDATE/DELETE в исходной БД

## Файлы
- `patroni-cluster/docker-compose.yml` — сервисы pg-audit-log, pg-audit-consumer + audit_slot
- `patroni-cluster/pg-audit-log/Dockerfile`, `entrypoint.sh`
- `patroni-cluster/pg-audit-consumer/Dockerfile`, `pom.xml`, `src/main/java/com/audit/consumer/*.java`

## Заметки
- Парсинг pgoutput v1: binary protocol с сообщениями Begin, Relation, Insert, Update, Delete, Commit
- Consumer держит два подключения: management (создание слота) и replication (стриминг WAL)
- Все `days_of_week` (INTEGER[]) и другие специализированные типы передаются pgoutput как текст ('t') в не-binary режиме
- Все колонки в audit-таблицах — TEXT (consumer вставляет строковые представления)
- `id_identity` — `GENERATED ALWAYS AS IDENTITY` (не входит в INSERT)
- `movedate` — `DEFAULT CURRENT_DATE`
