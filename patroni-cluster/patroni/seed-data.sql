-- ═══════════════════════════════════════════════════════════════
-- Тестовые данные для БД shop (схема public)
-- Магазин: пользователи, товары, заказы
-- ═══════════════════════════════════════════════════════════════

-- Пользователи
INSERT INTO users (name, email) VALUES
    ('Alice',     'alice@example.com'),
    ('Bob',       'bob@example.com'),
    ('Charlie',   'charlie@example.com'),
    ('Diana',     'diana@example.com'),
    ('Edward',    'edward@example.com'),
    ('Fiona',     'fiona@example.com'),
    ('George',    'george@example.com'),
    ('Hannah',    'hannah@example.com'),
    ('Ivan',      'ivan@example.com'),
    ('Julia',     'julia@example.com');

-- Товары
INSERT INTO products (name, price, stock) VALUES
    ('Laptop',       1200.00,  10),
    ('Mouse',          25.00,  50),
    ('Keyboard',       75.00,  30),
    ('Monitor',       350.00,  15),
    ('Webcam',         85.00,  25),
    ('Headphones',    120.00,  20),
    ('USB-C Hub',      45.00,  40),
    ('External SSD',  110.00,  18),
    ('Graphics Card', 650.00,   5),
    ('RAM 32GB',      160.00,  12),
    ('Mechanical Keyboard', 150.00, 8),
    ('Mouse Pad',      20.00,  60);

-- Заказы
INSERT INTO orders (user_id, product_id, quantity) VALUES
    (1,  1, 1),
    (1,  2, 2),
    (2,  3, 1),
    (3,  1, 1),
    (3,  3, 1),
    (4,  4, 2),
    (4,  6, 1),
    (5,  8, 1),
    (5,  9, 1),
    (6,  5, 2),
    (7,  7, 3),
    (7, 12, 2),
    (8, 10, 1),
    (9, 11, 1),
    (9,  2, 5),
    (10, 4, 1),
    (10, 6, 2);
