# текущие настройки

SHOW log_min_duration_statement;
SHOW auto_explain.log_min_duration;

# отключение параллельных воркеров 
SET max_parallel_workers_per_gather = 0;


# снижаем порог slow query log
ALTER SYSTEM SET log_min_duration_statement = 100;
ALTER SYSTEM SET auto_explain.log_min_duration = 100;
SELECT pg_reload_conf();

#

SELECT * FROM orders WHERE customer_email LIKE '%25000%';

## решение
-- Создаём расширение
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Создаём GIN индекс для LIKE с wildcard
CREATE INDEX idx_orders_email_trgm ON orders USING GIN (customer_email gin_trgm_ops);

или 
CREATE INDEX idx_orders_customer_email ON orders(customer_email);

###  Проверка скорости, когда индекс пустой
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM orders WHERE customer_email = 'user25000@example.com';

DROP INDEX idx_orders_customer_email;


SET max_parallel_workers_per_gather = 0;

SELECT * FROM orders 
WHERE customer_email = 'user25000@example.com' 
  AND status = 'paid';

CREATE INDEX idx_orders_email_status ON orders(customer_email, status);


-------------------------------------------------------


SET max_parallel_workers_per_gather = 0;

SELECT c.email, COUNT(o.id) as order_count, SUM(o.amount) as total_spent
FROM customers c
JOIN orders o ON c.email = o.customer_email
GROUP BY c.email
ORDER BY total_spent DESC
LIMIT 100;






