"""Тесты репликации DML-операций (INSERT / UPDATE / DELETE).

Проверяют:
1. INSERT в кластер Patroni -> строка на физической реплике + запись 'i' в аудит-БД
2. DELETE в кластере Patroni -> строка удалена с физической реплики + запись 'd'
3. UPDATE в кластере Patroni -> строка обновлена на физической реплике + запись 'u'
"""
import config
import db
import logging_utils as log
from conftest import audit_actions, phys_exists


def test_insert_replicates(test_table, row_key):
    log.step(1, "INSERT в кластер Patroni (мастер через HAProxy)")
    key = row_key
    payload = f"insert-{key}"
    log.info(f"INSERT {payload} -> {test_table} (test_id={key})")
    db.execute(
        config.MASTER_HOST,
        config.MASTER_PORT,
        f"INSERT INTO {test_table} (test_id, payload) VALUES (%s, %s)",
        (key, payload),
    )

    # Появилась на физической реплике
    log.step(2, f"Проверяю, что строка {key} появилась на физической реплике")
    db.wait_until(
        lambda: phys_exists(test_table, key),
        timeout=30,
        description=f"строка {key} на физической реплике",
    )
    assert phys_exists(test_table, key)

    # Появилась запись 'i' в аудит-БД
    log.step(3, f"Проверяю запись 'i' (INSERT) для {key} в аудит-БД")
    def audit_seen():
        return any(a == "i" for a, _ in audit_actions(test_table, key))

    db.wait_until(audit_seen, timeout=30, description=f"запись 'i' для {key} в аудит-БД")
    actions = audit_actions(test_table, key)
    assert ("i", payload) in [(a, p) for a, p in actions]
    log.ok(f"INSERT реплицировался: phys + audit 'i' payload={payload}")


def test_update_replicates(test_table, row_key):
    log.step(1, "INSERT исходной строки для последующего UPDATE")
    key = row_key
    initial = f"before-{key}"
    updated = f"after-{key}"
    log.info(f"INSERT {initial} -> {test_table} (test_id={key})")
    db.execute(
        config.MASTER_HOST,
        config.MASTER_PORT,
        f"INSERT INTO {test_table} (test_id, payload) VALUES (%s, %s)",
        (key, initial),
    )
    db.wait_until(
        lambda: phys_exists(test_table, key),
        timeout=30,
        description=f"вставка {key} на физической реплике",
    )

    log.step(2, f"UPDATE строки {key} на мастере")
    log.info(f"UPDATE payload={updated} WHERE test_id={key}")
    db.execute(
        config.MASTER_HOST,
        config.MASTER_PORT,
        f"UPDATE {test_table} SET payload = %s WHERE test_id = %s",
        (updated, key),
    )

    # Обновилась на физической реплике
    log.step(3, f"Проверяю, что UPDATE применился на физической реплике")
    def phys_updated():
        rows = db.query(
            config.PHYS_HOST,
            config.PHYS_PORT,
            f"SELECT payload FROM {test_table} WHERE test_id = %s",
            (key,),
        )
        return bool(rows) and rows[0][0] == updated

    db.wait_until(phys_updated, timeout=30, description=f"UPDATE {key} на физической реплике")
    assert phys_updated()

    # Запись 'u' в аудит-БД
    log.step(4, f"Проверяю запись 'u' (UPDATE) для {key} в аудит-БД")
    def audit_seen():
        return ("u", updated) in [(a, p) for a, p in audit_actions(test_table, key)]

    db.wait_until(audit_seen, timeout=30, description=f"запись 'u' для {key} в аудит-БД")
    log.ok(f"UPDATE реплицировался: phys + audit 'u' payload={updated}")


def test_delete_replicates(test_table, row_key):
    log.step(1, "INSERT исходной строки для последующего DELETE")
    key = row_key
    log.info(f"INSERT delete-{key} -> {test_table} (test_id={key})")
    db.execute(
        config.MASTER_HOST,
        config.MASTER_PORT,
        f"INSERT INTO {test_table} (test_id, payload) VALUES (%s, %s)",
        (key, f"delete-{key}"),
    )
    db.wait_until(
        lambda: phys_exists(test_table, key),
        timeout=30,
        description=f"вставка {key} на физической реплике",
    )

    log.step(2, f"DELETE строки {key} на мастере")
    db.execute(
        config.MASTER_HOST,
        config.MASTER_PORT,
        f"DELETE FROM {test_table} WHERE test_id = %s",
        (key,),
    )

    # Удалена с физической реплики
    log.step(3, f"Проверяю, что строка {key} удалена с физической реплики")
    db.wait_until(
        lambda: not phys_exists(test_table, key),
        timeout=30,
        description=f"удаление {key} с физической реплики",
    )
    assert not phys_exists(test_table, key)

    # Запись 'd' в аудит-БД
    log.step(4, f"Проверяю запись 'd' (DELETE) для {key} в аудит-БД")
    def audit_seen():
        return any(a == "d" for a, _ in audit_actions(test_table, key))

    db.wait_until(audit_seen, timeout=30, description=f"запись 'd' для {key} в аудит-БД")
    log.ok(f"DELETE реплицировался: строка удалена с физической реплики + audit 'd'")
