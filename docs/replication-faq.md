# Репликация данных (злобные советы).

1. Берём и добавляем таблицу на основную БД, при это на логическую реплику не добавляем.
Наблюдаем ошибки вида:

org.postgresql.util.PSQLException: ERROR: relation "public.accounts1" does not exist
2026-10-20 00:03:19

Видим как растёт лаг репликации

slot_name,slot_type,database,lag_slot_bytes,confirmed_flush_lag,active
audit_slot,logical,shop,537 MB,536 MB,t
shop_sub,logical,shop,510 MB,509 MB,t

SELECT slot_name, slot_type, database,\n       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_slot_bytes,\n       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS confirmed_flush_lag,\n       active\nFROM pg_replication_slots\nWHERE slot_type = 'logical';

2. Добавляем в аудит таблицу такую же как и на Основную БД.
Без полей типа moveDate и т.п.

2026-10-20 00:37:05[ERROR] ERROR: column "movedate" of relation "accounts1" does not exist

Ждём когда лог забьётся.