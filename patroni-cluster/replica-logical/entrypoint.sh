#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Логическая реплика PostgreSQL 17
# Подписывается на publication shop_pub на мастере через subscription shop_sub.
#
# ВАЖНО: мы НЕ используем docker-entrypoint.sh для первичной инициализации
# (не запускаем его в фоне). Официальный entrypoint вызывает
# docker_temp_server_start → init → docker_temp_server_stop,
# и docker_temp_server_stop убивает временный сервер во время
# setup_subscription (race condition). Вместо этого:
#   1. Создаём PGDATA с правильным владельцем
#   2. initdb вручную
#   3. pg_ctl start/stop под своим контролем
#   4. docker-entrypoint.sh только для production-запуска
# ═══════════════════════════════════════════════════════════════
set -e

setup_subscription() {
    # ─── База данных shop (если не существует) ───
    gosu postgres psql -U postgres <<-EOSQL
        SELECT 'CREATE DATABASE shop'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'shop')\gexec
EOSQL

    # ─── Демо-БД «Авиаперевозки» (схема bookings) ───
    gosu postgres psql -U postgres -d shop <<-EOSQL
        CREATE SCHEMA IF NOT EXISTS bookings;

        CREATE TABLE IF NOT EXISTS bookings.airplanes_data (
            airplane_code CHAR(3) PRIMARY KEY,
            model         TEXT NOT NULL,
            range         INTEGER NOT NULL CHECK (range > 0),
            speed         INTEGER NOT NULL CHECK (speed > 0)
        );

        CREATE TABLE IF NOT EXISTS bookings.airports_data (
            airport_code CHAR(3) PRIMARY KEY,
            name         TEXT NOT NULL,
            city         TEXT NOT NULL,
            country      TEXT NOT NULL,
            timezone     TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS bookings.seats (
            airplane_code   CHAR(3) NOT NULL,
            seat_no         TEXT NOT NULL,
            fare_conditions TEXT NOT NULL CHECK (fare_conditions IN ('Economy', 'Comfort', 'Business')),
            PRIMARY KEY (airplane_code, seat_no)
        );

        CREATE TABLE IF NOT EXISTS bookings.routes (
            route_no           TEXT NOT NULL,
            departure_airport  CHAR(3) NOT NULL,
            arrival_airport    CHAR(3) NOT NULL,
            airplane_code      CHAR(3) NOT NULL,
            days_of_week       INTEGER[] NOT NULL,
            scheduled_time     TIME NOT NULL,
            duration           INTERVAL NOT NULL,
            PRIMARY KEY (route_no, departure_airport, arrival_airport, scheduled_time)
        );

        CREATE TABLE IF NOT EXISTS bookings.flights (
            flight_id          SERIAL PRIMARY KEY,
            route_no           TEXT NOT NULL,
            status             TEXT NOT NULL CHECK (status IN ('Scheduled', 'On Time', 'Delayed', 'Boarding', 'Departed', 'Arrived', 'Cancelled')),
            scheduled_departure TIMESTAMPTZ NOT NULL,
            scheduled_arrival   TIMESTAMPTZ NOT NULL CHECK (scheduled_arrival > scheduled_departure),
            actual_departure    TIMESTAMPTZ,
            actual_arrival      TIMESTAMPTZ
        );

        CREATE TABLE IF NOT EXISTS bookings.bookings (
            book_ref      CHAR(6) PRIMARY KEY,
            book_date     TIMESTAMPTZ NOT NULL,
            total_amount  NUMERIC(10,2) NOT NULL
        );

        CREATE TABLE IF NOT EXISTS bookings.tickets (
            ticket_no      TEXT PRIMARY KEY,
            book_ref       CHAR(6) NOT NULL,
            passenger_id   TEXT NOT NULL,
            passenger_name TEXT NOT NULL,
            outbound       BOOLEAN NOT NULL
        );

        CREATE TABLE IF NOT EXISTS bookings.segments (
            ticket_no       TEXT NOT NULL,
            flight_id       INTEGER NOT NULL,
            fare_conditions TEXT NOT NULL CHECK (fare_conditions IN ('Economy', 'Comfort', 'Business')),
            price           NUMERIC(10,2) NOT NULL CHECK (price >= 0),
            PRIMARY KEY (ticket_no, flight_id)
        );

        CREATE TABLE IF NOT EXISTS bookings.boarding_passes (
            ticket_no     TEXT NOT NULL,
            flight_id     INTEGER NOT NULL,
            seat_no       TEXT NOT NULL,
            boarding_no   INTEGER NOT NULL,
            boarding_time TIMESTAMPTZ NOT NULL,
            PRIMARY KEY (ticket_no, flight_id)
        );
EOSQL

    # ─── Ожидание публикации на мастере ───
    # Ждём, пока Patroni выполнит post_bootstrap и создаст shop_pub
    echo "Logical replica: checking publication shop_pub on master..."
    until gosu postgres psql -U postgres -h haproxy -d shop -t -c "SELECT 1 FROM pg_publication WHERE pubname = 'shop_pub'" 2>/dev/null | grep -q 1; do
        sleep 2
    done
    echo "Logical replica: publication shop_pub found, creating subscription..."

    # ─── Создание подписки ───
    # create_slot = false: слот shop_sub уже создан Patroni
    # как permanent slot в bootstrap.dcs.slots — это гарантирует,
    # что после failover слот сохраняется на новом лидере
    sub_exists=$(gosu postgres psql -U postgres -d shop -t -c "SELECT 1 FROM pg_subscription WHERE subname = 'shop_sub'" 2>/dev/null | tr -d ' ')
    if [ "$sub_exists" != "1" ]; then
        gosu postgres psql -U postgres -d shop -c "CREATE SUBSCRIPTION shop_sub CONNECTION 'host=haproxy port=5432 dbname=shop user=postgres password=secret' PUBLICATION shop_pub WITH (copy_data = true, create_slot = false);"
    fi
    touch /tmp/.subscription_created
}

if [ "$1" = 'postgres' ]; then
    if [ ! -s "$PGDATA/PG_VERSION" ]; then
        # ─── Первый запуск: инициализация ───
        # Создаём PGDATA с правами postgres (volume монтируется от root)
        mkdir -p "$PGDATA"
        chown -R postgres:postgres "$PGDATA"

        # initdb с паролем postgres
        echo "$POSTGRES_PASSWORD" > /tmp/pwfile
        gosu postgres initdb -D "$PGDATA" --locale=en_US.utf8 --auth=md5 --username=postgres --pwfile=/tmp/pwfile
        rm -f /tmp/pwfile

        # Разрешаем TCP-подключения с паролем (нужно для pgAdmin, HAProxy и т.д.)
        echo "host all all 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"

        # Запускаем PostgreSQL под своим контролем (не через docker-entrypoint.sh)
        gosu postgres pg_ctl -D "$PGDATA" -l /tmp/pg_init.log start
        until gosu postgres pg_isready -U postgres 2>/dev/null; do
            sleep 1
        done

        setup_subscription

        # Останавливаем — docker-entrypoint.sh запустит заново для production
        gosu postgres pg_ctl -D "$PGDATA" -m fast stop
    elif [ ! -f /tmp/.subscription_created ]; then
        # ─── Повторный запуск: подписка не создана ───
        # (например, после пересборки контейнера)
        gosu postgres pg_ctl -D "$PGDATA" -l /tmp/pg_init.log start
        until gosu postgres pg_isready -U postgres 2>/dev/null; do
            sleep 1
        done

        setup_subscription

        gosu postgres pg_ctl -D "$PGDATA" -m fast stop
    fi
fi

# Разрешаем TCP-подключения с паролем (для pgAdmin, HAProxy и т.д.)
echo "host all all 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"

# Production-запуск: передаём управление официальному entrypoint
exec docker-entrypoint.sh "$@"
