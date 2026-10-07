"""Фикстуры pytest для тестов репликации."""
import uuid

import pytest
import psycopg2

import config
import db
import logging_utils as log


def _master_conn():
    return db.connect(config.MASTER_HOST, config.MASTER_PORT)


def _audit_conn():
    return db.connect(config.AUDIT_HOST, config.AUDIT_PORT)


def _logical_conn():
    return db.connect(config.LOGICAL_HOST, config.LOGICAL_PORT)


@pytest.fixture(scope="session")
def test_table():
    """Создаёт тестовую таблицу на мастере, зеркало в аудит-БД и на
    логической реплике, затем аккуратно удаляет. Раз в сессию.

    Зеркало на pg-logical-replica обязательно: publication shop_pub —
    FOR ALL TABLES, но подписчик НЕ создаёт новые таблицы сам (auto-sync
    не срабатывает), и apply-worker падает в crash-loop на первом INSERT
    в bookings.repl_test.
    """
    table = f"{config.TEST_SCHEMA}.{config.TEST_TABLE}"
    log.info(f"SESSION SETUP: создаю тестовую таблицу {table} на мастере, в аудит-БД и на логической реплике")
    with _master_conn() as conn, conn.cursor() as cur:
        cur.execute(f"DROP TABLE IF EXISTS {table}")
        cur.execute(
            f"CREATE TABLE {table} (test_id text PRIMARY KEY, payload text NOT NULL)"
        )
        # REPLICA IDENTITY FULL -> DELETE/UPDATE приходят со всеми колонками,
        # чтобы WAL-consumer записывал 'd'/'u' в аудит-БД корректно
        cur.execute(f"ALTER TABLE {table} REPLICA IDENTITY FULL")
    log.ok(f"{table} создана на мастере (REPLICA IDENTITY FULL)")

    with _logical_conn() as conn, conn.cursor() as cur:
        cur.execute(f"DROP TABLE IF EXISTS {table}")
        cur.execute(
            f"CREATE TABLE {table} (test_id text PRIMARY KEY, payload text NOT NULL)"
        )
        cur.execute(f"ALTER TABLE {table} REPLICA IDENTITY FULL")
    log.ok(f"зеркало {table} создано на логической реплике")

    with _audit_conn() as conn, conn.cursor() as cur:
        cur.execute(f"DROP TABLE IF EXISTS {table}")
        cur.execute(
            f"""CREATE TABLE {table} (
                test_id text,
                payload text,
                movedate timestamptz DEFAULT now(),
                moveusername text DEFAULT 'wal_consumer',
                moveaction text,
                id_identity bigint GENERATED ALWAYS AS IDENTITY
            )"""
        )
    log.ok(f"зеркало {table} создано в аудит-БД")

    yield table

    log.info(f"SESSION TEARDOWN: удаляю тестовую таблицу {table}")
    with _master_conn() as conn, conn.cursor() as cur:
        cur.execute(f"DROP TABLE IF EXISTS {table}")
    with _audit_conn() as conn, conn.cursor() as cur:
        cur.execute(f"DROP TABLE IF EXISTS {table}")
    with _logical_conn() as conn, conn.cursor() as cur:
        cur.execute(f"DROP TABLE IF EXISTS {table}")
    log.ok(f"{table} удалена")


@pytest.fixture
def row_key():
    """Уникальный ключ строки для изоляции между запусками тестов."""
    return f"t_{uuid.uuid4().hex[:12]}"


def audit_actions(table, key):
    """Вернуть список moveaction для строки key в аудит-БД в порядке записи."""
    rows = db.query(
        config.AUDIT_HOST,
        config.AUDIT_PORT,
        f"SELECT moveaction, payload FROM {table} WHERE test_id = %s ORDER BY id_identity",
        (key,),
    )
    log.debug(f"audit_actions({key}): {rows}")
    return rows


def phys_exists(table, key):
    """True, если строка есть на физической реплике."""
    rows = db.query(
        config.PHYS_HOST,
        config.PHYS_PORT,
        f"SELECT 1 FROM {table} WHERE test_id = %s",
        (key,),
    )
    log.debug(f"phys_exists({key}): {bool(rows)}")
    return bool(rows)
