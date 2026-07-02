# ═══════════════════════════════════════════════════════════════
# Patroni-узел: PostgreSQL 17 + Patroni + etcd-клиент
# Запускает Patroni, который управляет PostgreSQL:
#   - выбирает лидера среди 3 узлов
#   - выполняет failover при отказе мастера
#   - запускает post_bootstrap скрипт на первом лидере
# ═══════════════════════════════════════════════════════════════
FROM postgres:17

# Версия Patroni — можно переопределить при сборке:
#   docker compose build --build-arg PATRONI_VERSION=4.1.5
ARG PATRONI_VERSION=4.1.3

# Установка Python, pip, psycopg2 и самого Patroni с поддержкой etcd
RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get install -y python3 python3-pip python3-psycopg2 && \
    pip3 install --no-cache-dir --break-system-packages "patroni[etcd]==${PATRONI_VERSION}" && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Директория для данных PostgreSQL (data_dir: /data/pgdata)
RUN mkdir -p /data && chown postgres:postgres /data

# SQL-файлы данных
COPY demo-airlines.sql /scripts/

# Скрипт инициализации (post_bootstrap) — создаёт БД, таблицы, publication
COPY init.sh /scripts/init.sh
RUN chmod +x /scripts/init.sh

# Patroni должен работать от пользователя postgres
USER postgres

ENTRYPOINT ["patroni"]
