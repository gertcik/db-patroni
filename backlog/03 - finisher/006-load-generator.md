# Load Generator — многопоточный генератор DML-нагрузки

**Статус:** wait
**Приоритет:** high
**Создана:** 2026-07-03

## Описание

Приложение на Python 3 в отдельном контейнере, генерирующее DML-нагрузку на Patroni через HAProxy (`:5432`). Все типы и число воркеров настраиваются через env vars.

### Воркеры

| Воркер | Таблицы | Операции |
|--------|---------|----------|
| **BookingWorker** (N потоков) | `bookings` → `tickets` → `segments` → `boarding_passes` | INSERT |
| **FlightWorker** (M потоков) | `flights` | INSERT, UPDATE (статус) |
| **Canceller** (K потоков) | `bookings` | DELETE (каскадно) |
| **MassUpdater** (0/1 поток) | `flights`, `bookings` | Массовый UPDATE (статусы рейсов, суммы) |

### Env-конфиг

```yaml
DB_HOST=haproxy
DB_PORT=5432
DB_NAME=shop
DB_USER=postgres
DB_PASSWORD=secret

THREADS_BOOKING=3
THREADS_FLIGHT=2
THREADS_CANCELLER=1
THREADS_MASS_UPDATER=1
POOL_MIN=4
POOL_MAX=20
SLEEP_MIN_MS=100
SLEEP_MAX_MS=500
STATS_INTERVAL_SEC=10
LOG_LEVEL=INFO
```

### Статистика

Каждые N секунд — таблица ops/sec по таблицам и тип ошибок.

## DoD

- [ ] Контейнер собирается и запускается через `docker compose up`
- [ ] BookingWorker создаёт цепочку bookings→tickets→segments→boarding_passes
- [ ] FlightWorker создаёт рейсы и обновляет их статус
- [ ] Canceller удаляет случайные бронирования
- [ ] MassUpdater выполняет массовые UPDATE с настраиваемым интервалом
- [ ] Число потоков каждого типа настраивается через env
- [ ] Статистика в консоль с настраиваемым интервалом
- [ ] При failover воркеры автоматически переподключаются
- [ ] Ссылочные таблицы (airplanes_data, airports_data, routes) не изменяются

## Структура файлов

```
patroni-cluster/load-generator/
├── Dockerfile
├── requirements.txt          # psycopg2-binary
├── main.py                   # точка входа
├── pool.py                   # ThreadedConnectionPool
├── stats.py                  # агрегация и вывод
├── workers/
│   ├── __init__.py
│   ├── base.py               # базовый класс воркера
│   ├── booking_worker.py
│   ├── flight_worker.py
│   ├── canceller_worker.py
│   └── mass_updater.py
└── data/
    ├── __init__.py
    └── names.py
```

## Шаги

1. Создать файлы load-generator/
2. Добавить сервис в docker-compose.yml
3. `docker compose build load-generator && docker compose up -d`
4. Проверить логи и наличие данных во всех репликах

## Заметки

- Все воркеры используют общий `ThreadedConnectionPool` к `haproxy:5432`
- Каждая операция — отдельный auto-commit
- Ссылочные данные читаются при старте из БД
- MassUpdater: `UPDATE flights SET status = 'Cancelled' WHERE scheduled_departure < now() AND status = 'Scheduled'`
- Failover: `OperationalException` → retry через 2s
