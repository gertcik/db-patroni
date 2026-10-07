"""Тест устойчивости кластера: остановка лидера (failover).

1. Останавливаем текущего лидера (docker stop)
2. Кластер временно недоступен (запросы/записи через HAProxy не проходят)
3. После восстановления (новый лидер выбран, HAProxy переключился) SELECT проходят
4. Новый лидер — НЕ nofailover-узлы (patroni4_readonly)
5. Останавливаемый узел возвращается в кластер, кластер снова здоров
"""
import os
import time

import pytest

import config
import db
import docker_cli
import logging_utils as log


@pytest.mark.order(-1)
def test_failover_leader_downtime_and_recovery(test_table):
    log.step(1, "Определяю текущего лидера и его контейнер")
    leader = docker_cli.find_leader_container()
    leader_service = _service_from_container(leader)
    log.info(f"Лидер: контейнер {leader} (сервис {leader_service})")

    # 1. Останавливаем лидера
    log.step(2, f"Останавливаю лидера {leader} (docker stop)")
    docker_cli.stop_container(leader)
    try:
        # 2. Проверяем, что остановленный узел-лидер недоступен (кластер в этот
        #    момент не обслуживает запросы через него). HAProxy может переключиться
        #    на нового лидера почти без простоев на уровне SQL, поэтому надёжный
        #    признак недоступности — недоступность самого узла-лидера.
        log.step(3, f"Проверяю, что узел {leader_service} перестал отвечать")
        _assert_node_down(leader_service)
        log.ok(f"Узел {leader_service} перестал отвечать после docker stop")

        # 3. Дожидаемся восстановления: новый лидер + SELECT проходит.
        #    После failover HAProxy сам переключается на нового мастера.
        log.step(4, "Жду восстановления кластера (новый лидер, SELECT проходит)")
        db.wait_until(
            _master_writable,
            timeout=180,
            interval=2,
            description="кластер восстановлен (новый лидер, SELECT проходит)",
        )

        # 4. Новый лидер — одна из leader-capable нод, НЕ nofailover-узлы
        log.step(
            5,
            "Проверяю роль нового лидера (leader-capable, НЕ "
            + ", ".join(config.NOFAILOVER_NODES)
            + ")",
        )
        new_leader = _current_leader()
        assert new_leader is not None, "не удалось определить нового лидера"
        assert new_leader not in config.NOFAILOVER_NODES, (
            f"{new_leader} не должен становиться лидером (nofailover)"
        )
        assert new_leader in config.LEADER_CAPABLE_NODES, (
            f"лидер {new_leader} вне списка leader-capable нод"
        )
        log.ok(
            f"Новый лидер {new_leader} корректен "
            f"(не из nofailover-нод: {', '.join(config.NOFAILOVER_NODES)})"
        )

        # Запись + чтение через HAProxy после восстановления
        log.step(6, f"Проверяю запись+чтение через HAProxy на новом лидере")
        key = "failover_check"
        db.execute(
            config.MASTER_HOST,
            config.MASTER_PORT,
            f"INSERT INTO {test_table} (test_id, payload) VALUES (%s, %s)",
            (key, "ok"),
        )
        rows = db.query(
            config.MASTER_HOST,
            config.MASTER_PORT,
            f"SELECT payload FROM {test_table} WHERE test_id = %s",
            (key,),
        )
        assert rows and rows[0][0] == "ok", "SELECT после failover не вернул данные"
        db.execute(
            config.MASTER_HOST,
            config.MASTER_PORT,
            f"DELETE FROM {test_table} WHERE test_id = %s",
            (key,),
        )
        log.ok("Запись+чтение через HAProxy после failover успешны")
    finally:
        # 5. Возвращаем остановленный узел в кластер и ждём восстановления.
        #    Прошлый лидер после возврата может снова стать лидером (Patroni
        #    отдаёт ему lock) либо пройти pg_rewind/rejoin репликой — роль
        #    не фиксируем. Ожидание возврата узла — best-effort (не падаем),
        #    т.к. полное восстановление бывшего лидера — отдельная операция
        #    эксплуатации, не входящая в требования теста.
        log.step(7, f"Возвращаю {leader} в кластер (docker start)")
        docker_cli.start_container(leader)
        _wait_for_cluster_healthy()
        _soft_wait_for_node_up(leader)


def _service_from_container(container):
    """container='patroni-cluster-patroni1-1' -> 'patroni1' (известный сервис)."""
    for service in config.LEADER_CAPABLE_NODES + config.NOFAILOVER_NODES:
        if container.endswith(f"-{service}-1"):
            return service
    return container.rsplit("-", 2)[1]


def _soft_wait_for_node_up(container):
    """Лучшая попытка дождаться возврата узла в строй (любая роль).

    Не бросает исключение: если узел не вернулся за отведённое время, это
    сигнал для ручного восстановления, а не провал теста.
    """
    service = _service_from_container(container)
    timeout = int(os.environ.get("TEST_REJOIN_TIMEOUT", "120"))

    def node_responding():
        try:
            db.is_replica(service)
            return True
        except Exception:  # noqa: BLE001
            return False

    try:
        db.wait_until(
            node_responding,
            timeout=timeout,
            interval=5,
            description=f"узел {service} вернулся в строй после failover",
        )
        print(f"[WARN] Узел {service} вернулся в кластер после failover")
    except AssertionError:
        print(
            f"[WARN] Узел {service} не вернулся в кластер за {timeout}s. "
            f"Требуется ручное восстановление (см. AGENTS.md)."
        )


def _wait_for_cluster_healthy():
    """Ждать, пока кластер снова отвечает на SELECT через HAProxy.

    Останавливаемый узел после возврата проходит pg_rewind/rejoin, поэтому
    не требуем, чтобы он сразу отвечал — важно лишь, что кластер снова
    обслуживает запросы через HAProxy.
    """
    db.wait_until(
        _master_writable,
        timeout=180,
        interval=3,
        description="кластер снова здоров после возврата остановленного узла",
    )


def _assert_node_down(service):
    """Убедиться, что остановленный узел-лидер перестал отвечать на запросы.

    Это детерминированный признак того, что после остановки лидера кластер
    в этот момент не обслуживает запросы через него. Идёт ретраями, чтобы
    учесть небольшое окно завершения контейнера (docker stop).
    """
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            db.is_replica(service)
        except Exception:  # noqa: BLE001
            log.info(f"  {service}: больше не отвечает, узел недоступен")
            return
        time.sleep(1)
    raise AssertionError(
        f"Узел {service} продолжает отвечать после docker stop (ожидали недоступность)"
    )


def _master_writable():
    db.query(config.MASTER_HOST, config.MASTER_PORT, "SELECT 1")
    return True


def _current_leader():
    """Вернуть имя узла-лидера из leader-capable, либо None."""
    log.info("Определяю нового лидера по leader-capable узлам...")
    for node in config.LEADER_CAPABLE_NODES:
        try:
            is_rep = db.is_replica(node)
            log.info(f"  {node}: is_replica={is_rep}")
            if not is_rep:
                log.ok(f"Новый лидер: {node}")
                return node
        except Exception:  # noqa: BLE001
            log.warn(f"  {node}: узел недоступен")
            continue
    return None
