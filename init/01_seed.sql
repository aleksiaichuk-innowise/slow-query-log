-- Расширения
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Таблицы
CREATE TABLE customers (
    id          serial PRIMARY KEY,
    email       text NOT NULL,
    created_at  timestamp NOT NULL DEFAULT now()
);

CREATE TABLE orders (
    id              serial PRIMARY KEY,
    customer_email  text NOT NULL,
    amount          numeric(10,2) NOT NULL,
    status          text NOT NULL,
    created_at      timestamp NOT NULL DEFAULT now()
);

-- Данные: 50k клиентов, 5 млн заказов (для реалистичных цифр)
INSERT INTO customers (email)
SELECT 'user' || i || '@example.com'
FROM generate_series(1, 50000) AS i;

INSERT INTO orders (customer_email, amount, status, created_at)
SELECT
    'user' || (1 + floor(random() * 50000))::int || '@example.com',
    round((random() * 1000)::numeric, 2),
    (ARRAY['new','paid','shipped','cancelled'])[1 + floor(random() * 4)],
    now() - (random() * interval '365 days')
FROM generate_series(1, 5000000) AS i;

ANALYZE customers;
ANALYZE orders;