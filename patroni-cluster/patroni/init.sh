#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# post_bootstrap — выполняется Patroni ОДИН раз после выбора
# первого лидера и инициализация кластера.
# Создаёт прикладную БД shop + таблицы + демо-данные + publication.
# ═══════════════════════════════════════════════════════════════
set -e

# ─── База данных ───
psql -U postgres -c "CREATE DATABASE shop;"

# ─── Демо-БД «Авиаперевозки» (схема bookings) ───
# На основе PostgresPRO demo-small (адаптировано)
psql -U postgres -d shop -f /scripts/demo-airlines.sql

# ─── Публикация для логической репликации ───
# Включает таблицы shop + все таблицы авиаперевозок
psql -U postgres -d shop -c "
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'shop_pub') THEN
        CREATE PUBLICATION shop_pub FOR ALL TABLES;
    END IF;
END
\$\$;
"
