-- Настройка перед разбором кейсов

SET max_parallel_workers_per_gather = 0;

ALTER SYSTEM SET log_min_duration_statement = 100;
ALTER SYSTEM SET auto_explain.log_min_duration = 100;
SELECT pg_reload_conf();

-- Кейс 1 — LIKE с двумя % (substring-поиск)

SELECT * FROM orders WHERE customer_email LIKE '%25000%';

-- фикс
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_orders_email_trgm ON orders USING GIN (customer_email gin_trgm_ops);

SELECT * FROM orders WHERE customer_email LIKE '%25000%'; -- повтор, сравнить план в логе

-- Кейс 2 — точное совпадение и эффект кэша

CREATE INDEX idx_orders_customer_email ON orders(customer_email);

SELECT * FROM orders WHERE customer_email = 'user25000@example.com'; -- 1й прогон: shared read
SELECT * FROM orders WHERE customer_email = 'user25000@example.com'; -- 2й прогон: shared hit

DROP INDEX idx_orders_customer_email; -- чтобы не влиял на следующий кейс

-- Кейс 3 — фильтр по двум колонкам

SELECT * FROM orders
WHERE customer_email = 'user25000@example.com'
  AND status = 'paid';

-- фикс
CREATE INDEX idx_orders_email_status ON orders(customer_email, status);

SELECT * FROM orders
WHERE customer_email = 'user25000@example.com'
  AND status = 'paid'; -- повтор, сравнить план в логе

-- Кейс 4 — JOIN + агрегация (аналитический запрос)

SELECT c.email, COUNT(o.id) AS order_count, SUM(o.amount) AS total_spent
FROM customers c
JOIN orders o ON c.email = o.customer_email
GROUP BY c.email
ORDER BY total_spent DESC
LIMIT 100;

-- фикс на время отчёта
SET work_mem = '64MB';

-- повторить запрос выше и сравнить план в логе

-- Кейс 5 — ожидание блокировки (log_lock_waits)
-- Выполнять в двух параллельных сессиях psql

-- Сессия A (не коммитить):
BEGIN;
UPDATE orders SET status = 'cancelled' WHERE id = 1;

-- Сессия B (сразу после):
UPDATE orders SET status = 'paid' WHERE id = 1;

-- в сессии A через некоторое время:
COMMIT;

-- pg_stat_statements: слоу-запросы без чтения файла лога

SELECT query, calls, mean_exec_time, total_exec_time
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- Уборка после мастер-класса

DROP INDEX IF EXISTS idx_orders_email_trgm;
DROP INDEX IF EXISTS idx_orders_email_status;

ALTER SYSTEM SET log_min_duration_statement = 200;
ALTER SYSTEM SET auto_explain.log_min_duration = 200;
SELECT pg_reload_conf();
