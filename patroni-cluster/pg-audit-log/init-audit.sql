SELECT 'CREATE DATABASE shop'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'shop')\gexec

\c shop

CREATE SCHEMA IF NOT EXISTS bookings;

CREATE TABLE IF NOT EXISTS bookings.airplanes_data (
    airplane_code TEXT,
    model         TEXT,
    range         TEXT,
    speed         TEXT,
    movedate      TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername   TEXT DEFAULT 'wal_consumer',
    moveaction    TEXT,
    id_identity   BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.airports_data (
    airport_code TEXT,
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
    airplane_code   TEXT,
    seat_no         TEXT,
    fare_conditions TEXT,
    movedate        TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername     TEXT DEFAULT 'wal_consumer',
    moveaction      TEXT,
    id_identity     BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.routes (
    route_no           TEXT,
    departure_airport  TEXT,
    arrival_airport    TEXT,
    airplane_code      TEXT,
    days_of_week       TEXT,
    scheduled_time     TEXT,
    duration           TEXT,
    movedate           TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername        TEXT DEFAULT 'wal_consumer',
    moveaction         TEXT,
    id_identity        BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.flights (
    flight_id           TEXT,
    route_no            TEXT,
    status              TEXT,
    scheduled_departure TEXT,
    scheduled_arrival   TEXT,
    actual_departure    TEXT,
    actual_arrival      TEXT,
    movedate            TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername         TEXT DEFAULT 'wal_consumer',
    moveaction          TEXT,
    id_identity         BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.bookings (
    book_ref      TEXT,
    book_date     TEXT,
    total_amount  TEXT,
    movedate      TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername   TEXT DEFAULT 'wal_consumer',
    moveaction    TEXT,
    id_identity   BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.tickets (
    ticket_no      TEXT,
    book_ref       TEXT,
    passenger_id   TEXT,
    passenger_name TEXT,
    outbound       TEXT,
    movedate       TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername    TEXT DEFAULT 'wal_consumer',
    moveaction     TEXT,
    id_identity    BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.segments (
    ticket_no       TEXT,
    flight_id       TEXT,
    fare_conditions TEXT,
    price           TEXT,
    movedate        TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername     TEXT DEFAULT 'wal_consumer',
    moveaction      TEXT,
    id_identity     BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE TABLE IF NOT EXISTS bookings.boarding_passes (
    ticket_no      TEXT,
    flight_id      TEXT,
    seat_no        TEXT,
    boarding_no    TEXT,
    boarding_time  TEXT,
    movedate       TIMESTAMP DEFAULT CURRENT_DATE,
    moveusername    TEXT DEFAULT 'wal_consumer',
    moveaction     TEXT,
    id_identity    BIGINT GENERATED ALWAYS AS IDENTITY
);
