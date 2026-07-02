-- ═══════════════════════════════════════════════════════════════
-- Демо-БД «Авиаперевозки» (на основе PostgresPRO demo-small)
-- Схема: bookings (в БД shop)
-- Адаптировано: без multi-language jsonb, без спец. функций
-- ═══════════════════════════════════════════════════════════════

CREATE SCHEMA IF NOT EXISTS bookings;

-- ─── Самолёты ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bookings.airplanes_data (
    airplane_code CHAR(3) PRIMARY KEY,
    model         TEXT NOT NULL,
    range         INTEGER NOT NULL CHECK (range > 0),
    speed         INTEGER NOT NULL CHECK (speed > 0)
);

INSERT INTO bookings.airplanes_data (airplane_code, model, range, speed) VALUES
    ('773', 'Boeing 777-300ER',      11100, 905),
    ('763', 'Boeing 767-300ER',       9400, 850),
    ('738', 'Boeing 737-800',         5765, 830),
    ('73H', 'Boeing 737-800 (WL)',    5765, 830),
    ('320', 'Airbus A320-200',        6150, 840),
    ('321', 'Airbus A321-200',        5950, 840),
    ('333', 'Airbus A330-300',       11750, 870),
    ('359', 'Airbus A350-900',       15000, 910),
    ('388', 'Airbus A380-800',       15200, 900),
    ('SU9', 'Sukhoi Superjet 100',    3048, 830),
    ('CR2', 'Bombardier CRJ-200',     3046, 790),
    ('E95', 'Embraer RJ-195',         2900, 820);

-- ─── Аэропорты ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bookings.airports_data (
    airport_code CHAR(3) PRIMARY KEY,
    name         TEXT NOT NULL,
    city         TEXT NOT NULL,
    country      TEXT NOT NULL,
    timezone     TEXT NOT NULL
);

INSERT INTO bookings.airports_data (airport_code, name, city, country, timezone) VALUES
    ('SVO', 'Sheremetyevo International',        'Moscow',   'Russia',  'Europe/Moscow'),
    ('DME', 'Domodedovo International',           'Moscow',   'Russia',  'Europe/Moscow'),
    ('VKO', 'Vnukovo International',              'Moscow',   'Russia',  'Europe/Moscow'),
    ('LED', 'Pulkovo Airport',                    'St. Petersburg', 'Russia', 'Europe/Moscow'),
    ('KZN', 'Kazan International',                'Kazan',    'Russia',  'Europe/Moscow'),
    ('AER', 'Sochi International',                'Sochi',    'Russia',  'Europe/Moscow'),
    ('SVX', 'Koltsovo International',             'Yekaterinburg', 'Russia', 'Asia/Yekaterinburg'),
    ('OVB', 'Tolmachevo Airport',                 'Novosibirsk', 'Russia', 'Asia/Novosibirsk'),
    ('KJA', 'Yemelyanovo International',          'Krasnoyarsk', 'Russia', 'Asia/Krasnoyarsk'),
    ('VVO', 'Vladivostok International',          'Vladivostok', 'Russia', 'Asia/Vladivostok'),
    ('IKT', 'Irkutsk International',              'Irkutsk',  'Russia',  'Asia/Irkutsk'),
    ('LHR', 'London Heathrow',                    'London',   'UK',      'Europe/London'),
    ('CDG', 'Charles de Gaulle',                  'Paris',    'France',  'Europe/Paris'),
    ('FRA', 'Frankfurt am Main',                  'Frankfurt','Germany', 'Europe/Berlin'),
    ('AMS', 'Amsterdam Schiphol',                 'Amsterdam','Netherlands','Europe/Amsterdam'),
    ('BCN', 'Barcelona El Prat',                  'Barcelona','Spain',   'Europe/Madrid'),
    ('IST', 'Istanbul Airport',                   'Istanbul', 'Turkey',  'Europe/Istanbul'),
    ('DXB', 'Dubai International',                'Dubai',    'UAE',     'Asia/Dubai'),
    ('SIN', 'Singapore Changi',                   'Singapore','Singapore','Asia/Singapore'),
    ('NRT', 'Narita International',               'Tokyo',    'Japan',   'Asia/Tokyo'),
    ('JFK', 'John F. Kennedy International',      'New York', 'USA',     'America/New_York');

-- ─── Схема салона ─────────────────────────────────────────────
-- Места для каждого типа самолёта
CREATE TABLE IF NOT EXISTS bookings.seats (
    airplane_code   CHAR(3) NOT NULL REFERENCES bookings.airplanes_data(airplane_code),
    seat_no         TEXT NOT NULL,
    fare_conditions TEXT NOT NULL CHECK (fare_conditions IN ('Economy', 'Comfort', 'Business')),
    PRIMARY KEY (airplane_code, seat_no)
);

-- Boeing 777-300ER (773): бизнес 48, эконом 322
INSERT INTO bookings.seats (airplane_code, seat_no, fare_conditions)
SELECT '773', 'A' || n, 'Business' FROM generate_series(1, 4) AS n
UNION ALL
SELECT '773', 'C' || n, 'Business' FROM generate_series(1, 4) AS n
UNION ALL
SELECT '773', 'D' || n, 'Economy' FROM generate_series(10, 40) AS n
UNION ALL
SELECT '773', 'E' || n, 'Economy' FROM generate_series(10, 40) AS n
UNION ALL
SELECT '773', 'F' || n, 'Economy' FROM generate_series(10, 40) AS n;

-- Airbus A320 (320): бизнес 20, эконом 150
INSERT INTO bookings.seats (airplane_code, seat_no, fare_conditions)
SELECT '320', 'A' || n, 'Business' FROM generate_series(1, 5) AS n
UNION ALL
SELECT '320', 'C' || n, 'Business' FROM generate_series(1, 5) AS n
UNION ALL
SELECT '320', 'D' || n, 'Economy' FROM generate_series(5, 30) AS n
UNION ALL
SELECT '320', 'F' || n, 'Economy' FROM generate_series(5, 30) AS n;

-- Sukhoi Superjet 100 (SU9): бизнес 12, эконом 87
INSERT INTO bookings.seats (airplane_code, seat_no, fare_conditions)
SELECT 'SU9', 'A' || n, 'Business' FROM generate_series(1, 3) AS n
UNION ALL
SELECT 'SU9', 'C' || n, 'Business' FROM generate_series(1, 3) AS n
UNION ALL
SELECT 'SU9', 'D' || n, 'Economy' FROM generate_series(5, 25) AS n
UNION ALL
SELECT 'SU9', 'F' || n, 'Economy' FROM generate_series(5, 25) AS n;

-- ─── Маршруты ─────────────────────────────────────────────────
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

INSERT INTO bookings.routes (route_no, departure_airport, arrival_airport, airplane_code, days_of_week, scheduled_time, duration) VALUES
    ('SU100', 'SVO', 'LED', '320', ARRAY[1,2,3,4,5,6,7], '08:00', '01:15'::INTERVAL),
    ('SU101', 'LED', 'SVO', '320', ARRAY[1,2,3,4,5,6,7], '10:00', '01:15'::INTERVAL),
    ('SU200', 'SVO', 'AER', '320', ARRAY[1,2,3,4,5,6,7], '09:30', '03:30'::INTERVAL),
    ('SU201', 'AER', 'SVO', '320', ARRAY[1,2,3,4,5,6,7], '14:00', '03:30'::INTERVAL),
    ('SU300', 'SVO', 'KZN', 'SU9', ARRAY[1,2,3,4,5,6,7], '07:00', '01:30'::INTERVAL),
    ('SU301', 'KZN', 'SVO', 'SU9', ARRAY[1,2,3,4,5,6,7], '12:00', '01:30'::INTERVAL),
    ('SU400', 'SVO', 'SVX', '738', ARRAY[1,2,3,4,5,6],   '11:00', '02:30'::INTERVAL),
    ('SU401', 'SVX', 'SVO', '738', ARRAY[1,2,3,4,5,6],   '15:00', '02:30'::INTERVAL),
    ('SU500', 'SVO', 'OVB', '738', ARRAY[1,2,3,4,5,6,7], '19:00', '04:00'::INTERVAL),
    ('SU501', 'OVB', 'SVO', '738', ARRAY[1,2,3,4,5,6,7], '05:00', '04:00'::INTERVAL),
    ('SU600', 'SVO', 'VVO', '773', ARRAY[1,3,5,7],       '00:30', '08:30'::INTERVAL),
    ('SU601', 'VVO', 'SVO', '773', ARRAY[2,4,6],         '11:00', '08:30'::INTERVAL),
    ('SU700', 'SVO', 'LHR', '333', ARRAY[1,2,3,4,5,6,7], '10:00', '04:00'::INTERVAL),
    ('SU701', 'LHR', 'SVO', '333', ARRAY[1,2,3,4,5,6,7], '15:00', '03:30'::INTERVAL),
    ('SU800', 'SVO', 'CDG', '333', ARRAY[1,2,3,4,5,6,7], '10:30', '03:45'::INTERVAL),
    ('SU801', 'CDG', 'SVO', '333', ARRAY[1,2,3,4,5,6,7], '15:30', '03:30'::INTERVAL),
    ('SU900', 'SVO', 'IST', '321', ARRAY[1,2,3,4,5,6,7], '08:30', '03:30'::INTERVAL),
    ('SU901', 'IST', 'SVO', '321', ARRAY[1,2,3,4,5,6,7], '13:00', '03:30'::INTERVAL),
    ('SU1000', 'SVO', 'DXB', '773', ARRAY[1,2,3,4,5,6,7],'11:00', '05:00'::INTERVAL),
    ('SU1001', 'DXB', 'SVO', '773', ARRAY[1,2,3,4,5,6,7],'18:00', '05:00'::INTERVAL),
    ('SU1100', 'SVO', 'JFK', '359', ARRAY[2,4,6],        '12:00', '10:00'::INTERVAL),
    ('SU1101', 'JFK', 'SVO', '359', ARRAY[3,5,7],        '16:00', '09:30'::INTERVAL),
    ('SU1200', 'LED', 'BCN', '321', ARRAY[1,3,5,7],      '09:00', '04:30'::INTERVAL),
    ('SU1201', 'BCN', 'LED', '321', ARRAY[2,4,6],        '15:00', '04:00'::INTERVAL);

-- ─── Рейсы ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bookings.flights (
    flight_id          SERIAL PRIMARY KEY,
    route_no           TEXT NOT NULL,
    status             TEXT NOT NULL CHECK (status IN ('Scheduled', 'On Time', 'Delayed', 'Boarding', 'Departed', 'Arrived', 'Cancelled')),
    scheduled_departure TIMESTAMPTZ NOT NULL,
    scheduled_arrival   TIMESTAMPTZ NOT NULL CHECK (scheduled_arrival > scheduled_departure),
    actual_departure    TIMESTAMPTZ,
    actual_arrival      TIMESTAMPTZ
);

INSERT INTO bookings.flights (route_no, status, scheduled_departure, scheduled_arrival, actual_departure, actual_arrival) VALUES
    -- Прошедшие рейсы (выполнены)
    ('SU100', 'Arrived',  '2026-06-01 08:00:00+03', '2026-06-01 09:15:00+03', '2026-06-01 08:05:00+03', '2026-06-01 09:20:00+03'),
    ('SU101', 'Arrived',  '2026-06-01 10:00:00+03', '2026-06-01 11:15:00+03', '2026-06-01 10:10:00+03', '2026-06-01 11:20:00+03'),
    ('SU200', 'Arrived',  '2026-06-01 09:30:00+03', '2026-06-01 13:00:00+03', '2026-06-01 09:35:00+03', '2026-06-01 13:05:00+03'),
    ('SU700', 'Arrived',  '2026-06-01 10:00:00+03', '2026-06-01 14:00:00+03', '2026-06-01 10:15:00+03', '2026-06-01 14:10:00+03'),
    ('SU800', 'Arrived',  '2026-06-01 10:30:00+03', '2026-06-01 14:15:00+03', '2026-06-01 10:30:00+03', '2026-06-01 14:20:00+03'),
    ('SU1000','Arrived',  '2026-06-01 11:00:00+03', '2026-06-01 16:00:00+03', '2026-06-01 11:20:00+03', '2026-06-01 16:10:00+03'),
    ('SU300', 'Departed', '2026-06-02 07:00:00+03', '2026-06-02 08:30:00+03', '2026-06-02 07:05:00+03', '2026-06-02 08:35:00+03'),
    ('SU400', 'Departed', '2026-06-02 11:00:00+03', '2026-06-02 13:30:00+03', '2026-06-02 11:10:00+03', NULL),
    ('SU500', 'Departed', '2026-06-02 19:00:00+03', '2026-06-02 23:00:00+03', '2026-06-02 19:05:00+03', NULL),
    -- Сегодняшние рейсы
    ('SU100', 'On Time',  '2026-07-02 08:00:00+03', '2026-07-02 09:15:00+03', NULL, NULL),
    ('SU101', 'Scheduled','2026-07-02 10:00:00+03', '2026-07-02 11:15:00+03', NULL, NULL),
    ('SU200', 'On Time',  '2026-07-02 09:30:00+03', '2026-07-02 13:00:00+03', NULL, NULL),
    ('SU300', 'Scheduled','2026-07-02 07:00:00+03', '2026-07-02 08:30:00+03', NULL, NULL),
    ('SU400', 'Scheduled','2026-07-02 11:00:00+03', '2026-07-02 13:30:00+03', NULL, NULL),
    ('SU500', 'Scheduled','2026-07-02 19:00:00+03', '2026-07-02 23:00:00+03', NULL, NULL),
    ('SU700', 'On Time',  '2026-07-02 10:00:00+03', '2026-07-02 14:00:00+03', NULL, NULL),
    ('SU800', 'Delayed',  '2026-07-02 10:30:00+03', '2026-07-02 14:15:00+03', NULL, NULL),
    ('SU900', 'Scheduled','2026-07-02 08:30:00+03', '2026-07-02 12:00:00+03', NULL, NULL),
    ('SU1000','Scheduled','2026-07-02 11:00:00+03', '2026-07-02 16:00:00+03', NULL, NULL),
    ('SU300', 'On Time',  '2026-07-02 07:00:00+03', '2026-07-02 08:30:00+03', NULL, NULL),
    -- Будущие рейсы
    ('SU1100','Scheduled','2026-07-04 12:00:00+03', '2026-07-04 22:00:00+03', NULL, NULL),
    ('SU1200','Scheduled','2026-07-05 09:00:00+03', '2026-07-05 13:30:00+03', NULL, NULL),
    ('SU1000','Scheduled','2026-07-06 11:00:00+03', '2026-07-06 16:00:00+03', NULL, NULL),
    ('SU600', 'Scheduled','2026-07-07 00:30:00+03', '2026-07-07 09:00:00+03', NULL, NULL),
    ('SU601', 'Scheduled','2026-07-08 11:00:00+03', '2026-07-08 19:30:00+03', NULL, NULL);

-- ─── Бронирования ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bookings.bookings (
    book_ref      CHAR(6) PRIMARY KEY,
    book_date     TIMESTAMPTZ NOT NULL,
    total_amount  NUMERIC(10,2) NOT NULL
);

INSERT INTO bookings.bookings (book_ref, book_date, total_amount) VALUES
    ('ABC123', '2026-05-01 10:00:00+03',  25000.00),
    ('DEF456', '2026-05-05 14:30:00+03',  48000.00),
    ('GHI789', '2026-05-10 09:15:00+03',  12500.00),
    ('JKL012', '2026-05-15 16:45:00+03',  89000.00),
    ('MNO345', '2026-05-20 11:00:00+03',  32000.00),
    ('PQR678', '2026-06-01 08:00:00+03',  156000.00),
    ('STU901', '2026-06-05 12:30:00+03',  42000.00),
    ('VWX234', '2026-06-10 15:00:00+03',  95000.00),
    ('YZA567', '2026-06-15 10:30:00+03',  21000.00),
    ('BCD890', '2026-06-20 09:00:00+03',  73000.00);

-- ─── Билеты ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bookings.tickets (
    ticket_no      TEXT PRIMARY KEY,
    book_ref       CHAR(6) NOT NULL REFERENCES bookings.bookings(book_ref),
    passenger_id   TEXT NOT NULL,
    passenger_name TEXT NOT NULL,
    outbound       BOOLEAN NOT NULL
);

INSERT INTO bookings.tickets (ticket_no, book_ref, passenger_id, passenger_name, outbound) VALUES
    ('202600000001', 'ABC123', 'RF123456', 'IVAN PETROV',     true),
    ('202600000002', 'ABC123', 'RF123456', 'IVAN PETROV',     false),
    ('202600000003', 'DEF456', 'RF234567', 'OLGA SMIRNOVA',   true),
    ('202600000004', 'DEF456', 'RF234567', 'OLGA SMIRNOVA',   false),
    ('202600000005', 'GHI789', 'RF345678', 'SERGEY KUZNETSOV', true),
    ('202600000006', 'JKL012', 'RF456789', 'ANNA POPOVA',     true),
    ('202600000007', 'JKL012', 'RF567890', 'DMITRY VOLKOV',   true),
    ('202600000008', 'JKL012', 'RF456789', 'ANNA POPOVA',     false),
    ('202600000009', 'MNO345', 'RF678901', 'EKATERINA SOKOLOVA', true),
    ('202600000010', 'PQR678', 'RF789012', 'MIKHAIL FEDOROV', true),
    ('202600000011', 'PQR678', 'RF890123', 'TATYANA MOROZOVA', true),
    ('202600000012', 'PQR678', 'RF789012', 'MIKHAIL FEDOROV',  false),
    ('202600000013', 'STU901', 'RF901234', 'ALEXEY NOVIKOV',   true),
    ('202600000014', 'VWX234', 'RF012345', 'NATALYA ROMANOVA', true),
    ('202600000015', 'VWX234', 'RF123456', 'IVAN PETROV',      true),
    ('202600000016', 'YZA567', 'RF234567', 'OLGA SMIRNOVA',    true),
    ('202600000017', 'BCD890', 'RF345678', 'SERGEY KUZNETSOV', true),
    ('202600000018', 'BCD890', 'RF456789', 'ANNA POPOVA',      true);

-- ─── Сегменты перелётов (связь билет → рейс) ──────────────────
CREATE TABLE IF NOT EXISTS bookings.segments (
    ticket_no       TEXT NOT NULL,
    flight_id       INTEGER NOT NULL,
    fare_conditions TEXT NOT NULL CHECK (fare_conditions IN ('Economy', 'Comfort', 'Business')),
    price           NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    PRIMARY KEY (ticket_no, flight_id)
);

INSERT INTO bookings.segments (ticket_no, flight_id, fare_conditions, price) VALUES
    ('202600000001', 1,  'Economy',  12500.00),
    ('202600000002', 2,  'Economy',  12500.00),
    ('202600000003', 3,  'Business', 24000.00),
    ('202600000004', 4,  'Business', 24000.00),
    ('202600000005', 6,  'Economy',  12500.00),
    ('202600000006', 5,  'Business', 15000.00),
    ('202600000007', 5,  'Business', 15000.00),
    ('202600000008', 4,  'Economy',  25000.00),
    ('202600000009', 3,  'Economy',  16000.00),
    ('202600000010', 6,  'Business', 48000.00),
    ('202600000011', 6,  'Business', 48000.00),
    ('202600000012', 4,  'Business', 30000.00),
    ('202600000013', 7,  'Economy',  14000.00),
    ('202600000014', 8,  'Economy',  21000.00),
    ('202600000015', 9,  'Economy',  25000.00),
    ('202600000016', 1,  'Economy',  10500.00),
    ('202600000017', 10, 'Economy',  18000.00),
    ('202600000018', 4,  'Economy',  22000.00);

-- ─── Посадочные талоны ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bookings.boarding_passes (
    ticket_no     TEXT NOT NULL,
    flight_id     INTEGER NOT NULL,
    seat_no       TEXT NOT NULL,
    boarding_no   INTEGER NOT NULL,
    boarding_time TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (ticket_no, flight_id)
);

INSERT INTO bookings.boarding_passes (ticket_no, flight_id, seat_no, boarding_no, boarding_time) VALUES
    ('202600000001', 1, 'D10',  1, '2026-06-01 07:15:00+03'),
    ('202600000002', 2, 'D11',  2, '2026-06-01 09:15:00+03'),
    ('202600000003', 3, 'A1',   1, '2026-06-01 08:45:00+03'),
    ('202600000005', 6, 'D15',  5, '2026-06-01 10:15:00+03'),
    ('202600000006', 5, 'C1',   3, '2026-06-01 09:45:00+03'),
    ('202600000007', 5, 'C2',   4, '2026-06-01 09:50:00+03'),
    ('202600000010', 6, 'A1',   2, '2026-06-01 10:00:00+03'),
    ('202600000011', 6, 'A2',   6, '2026-06-01 10:20:00+03'),
    ('202600000013', 7, 'D20',  1, '2026-06-02 06:15:00+03'),
    ('202600000014', 8, 'D25',  2, '2026-06-02 10:15:00+03'),
    ('202600000015', 9, 'D30',  3, '2026-06-02 18:15:00+03'),
    ('202600000016', 1, 'D12',  2, '2026-06-01 07:20:00+03');
