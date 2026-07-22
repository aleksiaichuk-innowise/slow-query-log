# Демо-стенд: Slow Query Log в PostgreSQL

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

## Смотрим логи в реальном времени

Лог пишется в файл 

```bash
docker exec -it pg-slowlog tail -f /var/log/postgresql/postgresql-$(date +%F).log
docker exec -it pg-slowlog tail -f /var/log/postgresql/postgresql-$(date +%Y-%m-%d).log
```

### Дополнительно 
https://dev.to/philip_mcclarence_2ef9475/reading-postgresql-explain-and-explain-analyze-output-3o74

