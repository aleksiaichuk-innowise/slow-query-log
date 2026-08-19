# Демо-стенд: Slow Query Log в PostgreSQL

Цель мастер-класса — научиться работать со slow query log: читать строку лога и план `auto_explain`, понимать, что именно в них означает "медленно", и по этим данным делать осознанный фикс запроса. Индексы в кейсах — не самоцель, а иллюстрация того, к какому выводу приводит чтение лога.

## Запуск

```bash
docker-compose up -d
# первый старт занимает ~15-20 сек — накатывается 500k строк в orders
docker-compose logs -f postgres   # дождаться "database system is ready to accept connections"
```

Подключение:

```bash
docker exec -it pg-slowlog psql -U workshop -d workshop
```

## Что уже включено в конфиге (`conf/postgresql.conf`)

- `log_min_duration_statement = 200` — в лог пишется текст и время каждого запроса, выполнявшегося дольше 200 мс;
- `auto_explain.log_min_duration = 200` — для таких же запросов сразу пишется план `EXPLAIN ANALYZE`, без ручного запуска `EXPLAIN`;
- `log_lock_waits = on` — в лог пишется, если запрос ждёт блокировку дольше `deadlock_timeout` (по умолчанию 1 с);
- `pg_stat_statements` — агрегированная статистика по всем запросам в памяти, без парсинга текстового лога.

## Смотрим логи в реальном времени

Лог пишется в файл:

```bash
docker exec -it pg-slowlog tail -f /var/log/postgresql/postgresql-$(date +%F).log
```

Также лог можно посмотреть через pgAdmin (http://localhost:8080, логин `admin@workshop.com` / `workshop`):
**Storage Manager** (иконка папки в тулбаре) → `pg_logs/` → `postgresql-YYYY-MM-DD.log` → View/Download.
Это не live-tail — файл открывается статично, для новых строк нужно открыть заново.

> Файл лога держится открытым по дескриптору, а не по имени. Если переименовать его руками, Postgres продолжит писать в него же (под новым именем), а файл с "правильным" именем на сегодня не появится до следующей ротации. Чтобы принудительно начать новый файл: `SELECT pg_rotate_logfile();`

Все команды из разделов ниже собраны одним скриптом в [`scripts/demo-queries.sql`](scripts/demo-queries.sql) — файл лежит вне `init/`, поэтому Postgres не выполняет его автоматически при старте, прогонять нужно руками через `psql`.

## Как читать строку лога

`log_line_prefix = '%m [%p] db=%d,user=%u,app=%a,client=%h '`, поэтому обычная запись выглядит так:

```
2026-07-15 07:12:39.771 GMT [54] db=workshop,user=workshop,app=psql,client=[local] LOG:  duration: 267.777 ms  plan:
	Query Text: SELECT * FROM orders
	WHERE customer_email = 'user25000@example.com'
	  AND status = 'paid';
	Seq Scan on public.orders  (cost=0.00..123942.00 rows=25 width=45) (actual time=44.944..267.567 rows=33 loops=1)
	                                Buffers: shared read=416
```

Что здесь важно уметь читать:
- `%m [%p]` — время и PID backend-процесса, по нему можно сгруппировать все строки одного запроса, если план длинный;
- `db=...,user=...,app=...,client=...` — кто прислал запрос (полезно, когда медленные запросы идут не из psql, а из приложения);
- `duration: N ms  statement: ...` — это `log_min_duration_statement`: сам факт "запрос выполнялся N мс", без плана;
- `duration: N ms  plan: ...` — это `auto_explain`: та же длительность, но с деревом плана под ней (это отдельная запись в логе, а не продолжение предыдущей);
- в плане: `Seq Scan` / `Index Scan` / `Bitmap Heap Scan` — как именно читались данные; `actual time=X..Y` — старт и финиш узла плана в мс; `rows=N` — сколько строк реально нашлось; `Buffers: shared hit=.. read=..` — сколько страниц отдано из кэша (`hit`) и сколько прочитано с диска (`read`).

Дальше в каждом кейсе разбираем: что конкретно из этого набора полей указывает на проблему, и какой вывод из этого следует.

## Настройка перед разбором кейсов

```sql
SHOW log_min_duration_statement;
SHOW auto_explain.log_min_duration;
                                    

SET max_parallel_workers_per_gather = 0;

ALTER SYSTEM SET log_min_duration_statement = 100;
ALTER SYSTEM SET auto_explain.log_min_duration = 100;
SELECT pg_reload_conf();
```

Снижаем порог до 100 мс, чтобы в лог попадали даже небольшие "тормозящие" запросы, и отключаем параллельные воркеры, чтобы у всех участников планы выглядели одинаково.

## Кейсы

Формат разбора один и тот же: выполняем запрос → читаем, что лог показал → делаем вывод → применяем минимальный фикс → повторяем запрос и смотрим, что изменилось в логе.

### Кейс 1 — LIKE с двумя `%` (substring-поиск)

```sql
SELECT * FROM orders WHERE customer_email LIKE '%25000%';
```

**Что показывает лог:** `duration` заметно выше порога; в плане от `auto_explain` — `Seq Scan on orders`, большой `actual time`, `Buffers: shared read=...` — прочитаны почти все страницы таблицы (5 млн строк), при этом в `rows=` — единицы строк.

**Вывод из лога:** план читает всю таблицу целиком ради нескольких совпадений — узкое место не в железе и не в нагрузке, а в том, что для этого условия нет подходящего индекса (маска `%текст%` не позволяет использовать обычный B-tree).

**Фикс:**

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_orders_email_trgm ON orders USING GIN (customer_email gin_trgm_ops);
```

Повторяем запрос — в логе теперь `Bitmap Index Scan` по `idx_orders_email_trgm`, `Buffers` на порядки меньше, `duration` ниже порога (запись может вообще пропасть из лога).

### Кейс 2 — точное совпадение и эффект кэша

```sql
CREATE INDEX idx_orders_customer_email ON orders(customer_email);

SELECT * FROM orders WHERE customer_email = 'user25000@example.com';
```

**Что показывает лог:** первый прогон сразу после создания индекса — `Buffers: shared read=...` (страницы ещё не в `shared_buffers`); второй прогон того же запроса — `shared hit=...` вместо `read`, и `duration` заметно меньше.

**Вывод из лога:** разница между двумя прогонами — это не индекс стал "лучше работать", а страницы попали в кэш буферов. Полезно уметь отличать в логе "стало быстрее из-за плана" от "стало быстрее из-за кэша", прежде чем делать выводы об эффективности фикса.

```sql
DROP INDEX idx_orders_customer_email; -- чтобы не влиял на следующий кейс
```

### Кейс 3 — фильтр по двум колонкам

```sql
SELECT * FROM orders
WHERE customer_email = 'user25000@example.com'
  AND status = 'paid';
```

**Что показывает лог:** в плане `Filter: (status = 'paid')` стоит уже после того, как строки отобраны по email, и рядом — `rows removed by filter` больше нуля: строки сначала читаются, потом часть выбрасывается.

**Вывод из лога:** индекс покрывает только часть условия — второе условие проверяется "постфактум" на уже прочитанных строках.

**Фикс:**

```sql
CREATE INDEX idx_orders_email_status ON orders(customer_email, status);
```

Повторяем запрос — оба условия в плане теперь в `Index Cond`, `rows removed by filter` пропадает.

### Кейс 4 — JOIN + агрегация (аналитический запрос)

```sql
SELECT c.email, COUNT(o.id) AS order_count, SUM(o.amount) AS total_spent
FROM customers c
JOIN orders o ON c.email = o.customer_email
GROUP BY c.email
ORDER BY total_spent DESC
LIMIT 100;
```

**Что показывает лог:** большой `duration` (реально — секунды, см. `pg_logs/postgresql-2026-07-15.log` как пример), в плане — `Hash Join`/`Merge Join` с большим числом строк, узлы `HashAggregate`/`GroupAggregate` и `Sort` перед `LIMIT`. Из-за намеренно маленького `work_mem = 4MB` в плане может встретиться `Sort Method: external merge  Disk: ...kB` или `Batches: N` (N > 1) у `HashAggregate`.

**Вывод из лога:** это признак того, что сортировка/агрегация не поместились в память и ушли на диск — именно это (а не отсутствие индекса) в первую очередь тормозит такие отчётные запросы.

**Фикс на время отчёта:**

```sql
SET work_mem = '64MB';
```

Повторяем запрос — `external merge`/лишние `Batches` в плане пропадают, `duration` падает.

### Кейс 5 — ожидание блокировки (`log_lock_waits`)

Этот кейс не про план запроса, а про отдельный тип записи в логе — открываем две сессии `psql` параллельно.

Сессия A (не коммитим):

```sql
BEGIN;
UPDATE orders SET status = 'cancelled' WHERE id = 1;
```

Сессия B (сразу после):

```sql
UPDATE orders SET status = 'paid' WHERE id = 1;
```

**Что показывает лог:** сессия B зависает, и примерно через `deadlock_timeout` (1 с) в логе появляется отдельная строка вида `LOG:  process N still waiting for ShareLock on transaction M after ... ms`, а не `duration:`/`plan:` — это `log_lock_waits`, а не `auto_explain`. После `COMMIT`/`ROLLBACK` в сессии A следом пишется `LOG: process N acquired ShareLock ...`.

**Вывод из лога:** запрос B "медленный" не из-за плохого плана, а потому что ждёт лока от чужой незакоммиченной транзакции — план тут ни при чём, искать нужно в `pg_locks`/`pg_stat_activity`, кто держит блокировку, и почему транзакция A не закрывается вовремя.

## pg_stat_statements: слоу-запросы без чтения файла

Файл лога хорош для разбора одного конкретного случая, но неудобен, если нужно быстро найти "что вообще у нас самое медленное". Для этого — агрегированная статистика:

```sql
SELECT query, calls, mean_exec_time, total_exec_time
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

`calls` — сколько раз выполнялся запрос, `mean_exec_time` — средняя длительность, `total_exec_time` — суммарный вклад в нагрузку. Разница с текстовым логом: здесь не видно конкретных параметров конкретного вызова и плана, зато сразу видно, какой запрос "съедает" больше всего времени в сумме, а не какой самый долгий по одной записи.

## Уборка после мастер-класса

Если стенд переиспользуется несколько раз подряд:

```sql
DROP INDEX IF EXISTS idx_orders_email_trgm;
DROP INDEX IF EXISTS idx_orders_email_status;

ALTER SYSTEM SET log_min_duration_statement = 200;
ALTER SYSTEM SET auto_explain.log_min_duration = 200;
SELECT pg_reload_conf();
```

## Что почитать

- [Error and Logging Configuration — PostgreSQL Docs](https://www.postgresql.org/docs/current/runtime-config-logging.html) — все параметры логирования, включая `log_line_prefix` и `log_lock_waits`
- [auto_explain — PostgreSQL Docs](https://www.postgresql.org/docs/current/auto-explain.html)
- [Using EXPLAIN — PostgreSQL Docs](https://www.postgresql.org/docs/current/using-explain.html) — как читать план выполнения
- [pg_stat_statements — PostgreSQL Docs](https://www.postgresql.org/docs/current/pgstatstatements.html)
- [PostgreSQL Wiki: Slow Query Questions](https://wiki.postgresql.org/wiki/Slow_Query_Questions) — чеклист, что приложить, разбирая медленный запрос
- [explain.depesz.com](https://explain.depesz.com/) — визуализатор вывода `EXPLAIN ANALYZE`
- [Reading PostgreSQL EXPLAIN and EXPLAIN ANALYZE output](https://dev.to/philip_mcclarence_2ef9475/reading-postgresql-explain-and-explain-analyze-output-3o74)

Если после мастер-класса захочется углубиться именно в индексы: [Use The Index, Luke](https://use-the-index-luke.com/), [pg_trgm — PostgreSQL Docs](https://www.postgresql.org/docs/current/pgtrgm.html).
