"""Хелперы подключения к БД и ожидания репликации."""
import time

import psycopg2
import psycopg2.extras

import config
import logging_utils as log


def connect(host, port, autocommit=True):
    """Открыть соединение к PostgreSQL."""
    conn = psycopg2.connect(
        host=host,
        port=port,
        dbname=config.DB_NAME,
        user=config.DB_USER,
        password=config.DB_PASSWORD,
        connect_timeout=5,
    )
    conn.autocommit = autocommit
    return conn


def query(host, port, sql, params=None, fetch=True):
    """Выполнить SELECT и вернуть строки (list) или None, если fetch=False."""
    with connect(host, port) as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        if not fetch:
            return None
        return cur.fetchall()


def execute(host, port, sql, params=None):
    """Выполнить оператор (INSERT/UPDATE/DELETE/DDL) на мастере."""
    with connect(host, port) as conn, conn.cursor() as cur:
        cur.execute(sql, params)


def wait_until(predicate, timeout=30, interval=1.0, description=""):
    """Ждать, пока predicate() вернёт истину."""
    log.info(f"Ожидание: {description} (таймаут {timeout}s, интервал {interval}s)")
    deadline = time.time() + timeout
    last = None
    ticks = 0
    while time.time() < deadline:
        try:
            res = predicate()
        except Exception as exc:  # noqa: BLE001
            last = exc
            res = None
        if res:
            elapsed = int(time.time() - (deadline - timeout))
            log.ok(f"Дождались: {description} (за {elapsed}s)")
            return True
        ticks += 1
        if ticks % max(1, int(10 / max(interval, 0.1))) == 0:
            log.info(f"  ...{description}: ещё не готово (прошло "
                     f"{int(time.time() - (deadline - timeout))}s)")
        time.sleep(interval)
    log.error(f"Не дождались условия: {description} (last={last!r})")
    raise AssertionError(f"Не дождались условия: {description} (last={last!r})")


def is_replica(host):
    """True, если узел — реплика (в recovery)."""
    rows = query(host, config.MASTER_PORT, "SELECT pg_is_in_recovery()")
    return bool(rows[0][0])
