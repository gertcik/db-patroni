SELECT 'CREATE DATABASE shop'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'shop')\gexec

\c shop

CREATE SCHEMA IF NOT EXISTS bookings;

-- Зеркало типов исходных таблиц (схема bookings, patroni/demo-airlines.sql).
-- Колонки НЕ Primary Key, без NOT NULL/DEFAULT/CONSTRAINT — только типы.
-- Метаданные аудита (movedate/moveusername/moveaction/id_identity) — свои.
-- pg-audit-consumer дополнительно выравнивает типы при старте (ALTER COLUMN TYPE),
-- поэтому старые TEXT-колонки конвертируются автоматически.

-- audit-consumer доработан и теперь САМ создаёт таблицу и добавляет поля, если видит новые
/*
CREATE TABLE IF NOT EXISTS bookings.airplanes_data (
    airplane_code CHAR(3),
    model         TEXT,
    range         INTEGER,
    speed         INTEGER,
    movedate      TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername   TEXT DEFAULT 'wal_consumer',
    moveaction    TEXT,
    id_identity   BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.airports_data (
    airport_code CHAR(3),
    name         TEXT,
    city         TEXT,
    country      TEXT,
    timezone     TEXT,
    movedate      TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername   TEXT DEFAULT 'wal_consumer',
    moveaction    TEXT,
    id_identity   BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.seats (
    airplane_code   CHAR(3),
    seat_no         TEXT,
    fare_conditions TEXT,
    movedate        TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername     TEXT DEFAULT 'wal_consumer',
    moveaction      TEXT,
    id_identity     BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.routes (
    route_no           TEXT,
    departure_airport  CHAR(3),
    arrival_airport    CHAR(3),
    airplane_code      CHAR(3),
    days_of_week       INTEGER[],
    scheduled_time     TIME,
    duration           INTERVAL,
    movedate           TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername        TEXT DEFAULT 'wal_consumer',
    moveaction         TEXT,
    id_identity        BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.flights (
    flight_id           INTEGER,
    route_no            TEXT,
    status              TEXT,
    scheduled_departure TIMESTAMPTZ,
    scheduled_arrival   TIMESTAMPTZ,
    actual_departure    TIMESTAMPTZ,
    actual_arrival      TIMESTAMPTZ,
    movedate            TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername         TEXT DEFAULT 'wal_consumer',
    moveaction          TEXT,
    id_identity         BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.bookings (
    book_ref      CHAR(6),
    book_date     TIMESTAMPTZ,
    total_amount  NUMERIC(10,2),
    movedate      TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername   TEXT DEFAULT 'wal_consumer',
    moveaction    TEXT,
    id_identity   BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.tickets (
    ticket_no      TEXT,
    book_ref       CHAR(6),
    passenger_id   TEXT,
    passenger_name TEXT,
    outbound       BOOLEAN,
    movedate       TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername    TEXT DEFAULT 'wal_consumer',
    moveaction     TEXT,
    id_identity    BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.segments (
    ticket_no       TEXT,
    flight_id       INTEGER,
    fare_conditions TEXT,
    price           NUMERIC(10,2),
    movedate        TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername     TEXT DEFAULT 'wal_consumer',
    moveaction      TEXT,
    id_identity     BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.boarding_passes (
    ticket_no      TEXT,
    flight_id      INTEGER,
    seat_no        TEXT,
    boarding_no    INTEGER,
    boarding_time  TIMESTAMPTZ,
    movedate       TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername    TEXT DEFAULT 'wal_consumer',
    moveaction     TEXT,
    id_identity    BIGINT GENERATED ALWAYS AS IDENTITY
);
*/