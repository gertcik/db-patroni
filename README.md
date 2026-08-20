# Patroni Cluster — PostgreSQL 18 + Patroni + pgAdmin

Отказоустойчивый кластер PostgreSQL 18 (3 ноды) с Patroni, etcd, haproxy и pgAdmin в Docker Compose.

![Диаграмма кластера](images/diagram.png)

## Документация

1. [Компоненты и архитектура](docs/components.md) — сборка образа, обновление Patroni, описание всех сервисов, как работает кластер
2. [Репликация данных и аудит-лог](docs/replication.md) — DML-репликация, аудит через WAL consumer, восстановление слотов при смене лидера
3. [Обслуживание БД](docs/maintenance.md) — DDL, индексы, восстановление логической реплики
4. [Мониторинг и ограничения](docs/monitoring.md) — метрики, проверки репликации, проблемы на Windows, `moveusername`

## Требования

1. Docker Engine 24+
2. Docker Compose v2

## Быстрый старт

```bash
git clone <repo>
cd patroni-cluster

docker compose build
docker compose up -d
```

## Как узнать, кто сейчас мастер

### 1. Через HAProxy (самый простой)

Подключитесь к БД через HAProxy и выполните:

```sql
SELECT inet_server_addr();
```

Если нужно только имя хоста:

```sql
SELECT pg_read_file('/etc/hostname');
```

### 2. Через Patroni REST API (любая нода)

```bash
docker compose exec patroni2 python3 -c "
import urllib.request, json
d = json.loads(urllib.request.urlopen('http://127.0.0.1:8008/cluster').read())
for m in d['members']:
    print(m['name'], '→', m['role'], '(' + m['state'] + ')')
"
```

Вывод:
```
patroni1    → replica   (running)
patroni2    → leader    (running)
patroni3    → replica   (running)
```

### 3. Через patronictl

```bash
docker compose exec patroni2 patronictl list
```

### 4. Через HAProxy stats (браузер)

Открой http://localhost:7000 — в строке `patroni_cluster` зелёным подсвечена активная мастер-нода.

## Проверка кластера

### Статус Patroni

```bash
# любой нодой
curl -s http://localhost:5001/patroni | jq .

# кластер
docker exec patroni-cluster-patroni1-1 patronictl list
```

### Подключение к БД

```bash
# через haproxy (всегда на мастер)
psql -h localhost -p 5432 -U postgres -d shop

# напрямую к ноде (patroni1 — 5001, patroni2 — 5002, patroni3 — 5003)
psql -h localhost -p 5001 -U postgres -d shop
```

Пароль: `secret`

### Тестовые данные

```sql
SELECT * FROM users;
SELECT * FROM products;
SELECT * FROM orders;
```

### pgAdmin

Открой http://localhost:80

1. **Email:** admin@admin.com
2. **Password:** admin

Сервер `Patroni Cluster (via haproxy)` уже зарегистрирован.

### Тест отказоустойчивости

```bash
# остановить мастер-ноду
docker compose stop patroni1

# через несколько секунд haproxy переключится на другую ноду
# проверить, кто стал мастером
curl -s http://localhost:7000 | grep -o 'patroni[0-9]'

# подключение к БД продолжает работать
psql -h localhost -p 5432 -U postgres -d shop -c "SELECT inet_server_addr();"

# вернуть ноду
docker compose start patroni1
```

## Остановка

```bash
docker compose down        # остановить
docker compose down -v     # остановить и удалить данные
```
