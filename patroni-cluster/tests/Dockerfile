FROM python:3.12-slim

# docker CLI для failover-теста (управление контейнерами через host-сокет)
# Версия должна поддерживать API сервера (>= 1.44). Pin статический бинарник.
ARG DOCKER_VERSION=27.4.1
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" -o docker.tgz \
    && tar -xzf docker.tgz \
    && mv docker/docker /usr/local/bin/docker \
    && rm -rf docker docker.tgz \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tests

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN chmod +x run.sh

ENTRYPOINT ["./run.sh"]
