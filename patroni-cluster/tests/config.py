"""Настройки подключения к компонентам кластера.

Используются переменные окружения (задаются в docker-compose.yml сервиса
replication-tests), по умолчанию — внутренние имена контейнеров сети patroni-net.
"""
import os

# Мастер через HAProxy (R/W) — внутри сети patroni-net на порту 5432
MASTER_HOST = os.environ.get("TEST_MASTER_HOST", "haproxy")
MASTER_PORT = int(os.environ.get("TEST_MASTER_PORT", "5432"))

# Физическая реплика (read-only)
PHYS_HOST = os.environ.get("TEST_PHYS_HOST", "pg-physical-replica")
PHYS_PORT = int(os.environ.get("TEST_PHYS_PORT", "5432"))

# Аудит-лог (pg-audit-log), протокольная БД
AUDIT_HOST = os.environ.get("TEST_AUDIT_HOST", "pg-audit-log")
AUDIT_PORT = int(os.environ.get("TEST_AUDIT_PORT", "5432"))

# Логическая реплика (pg-logical-replica) — подписчик shop_sub
# (publication FOR ALL TABLES не создаёт таблицы на подписчике сама,
#  поэтому фикстура зеркалит тестовую таблицу сюда вручную)
LOGICAL_HOST = os.environ.get("TEST_LOGICAL_HOST", "pg-logical-replica")
LOGICAL_PORT = int(os.environ.get("TEST_LOGICAL_PORT", "5432"))

# Имена узлов Patroni, способных стать лидером (для failover-теста)
LEADER_CAPABLE_NODES = ["patroni1", "patroni2", "patroni3"]

# Узлы Patroni с tags.nofailover=true — никогда не должны становиться лидером.
# (pg-physical-replica — вне Patroni, в DCS не состоит, в список не входит.)
NOFAILOVER_NODES = ["patroni4_readonly"]

DB_NAME = os.environ.get("TEST_DB", "shop")
DB_USER = os.environ.get("TEST_USER", "postgres")
DB_PASSWORD = os.environ.get("TEST_PASSWORD", "secret")

# Тестовая таблица
TEST_SCHEMA = "bookings"
TEST_TABLE = "repl_test"
