"""Управление Docker-контейнерами через host-сокет (для failover-теста).

Контейнер тестов монтирует /var/run/docker.sock, поэтому имеет доступ
к docker CLI хоста. Имена контейнеров имеют вид <project>-<service>-1.
"""
import subprocess

import config
import logging_utils as log


def docker(*args, timeout=120):
    """Выполнить docker CLI и вернуть stdout."""
    log.info(f"docker {' '.join(args)}")
    cmd = ["docker", *args]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError(f"docker {' '.join(args)} failed:\n{proc.stderr}")
    if proc.stdout.strip():
        log.info(f"  -> {proc.stdout.strip()}")
    return proc.stdout


def container_name(service):
    """Найти имя контейнера по сервису (например patroni1 -> patroni-cluster-patroni1-1).

    Точное совпадение по шаблону docker compose: <project>-<service>-<N>.
    Это исключает ложное совпадение с подстроками (например
    pg-exporter-patroni1-1 не считается за patroni1).
    """
    names = docker("ps", "--format", "{{.Names}}").splitlines()
    names = [n.strip() for n in names if n.strip()]

    # project = общий префикс имени (все <project>-<service>-<N>)
    project = _project_from_names(names)
    if not project:
        raise RuntimeError("Не удалось определить проект docker compose")

    expected = f"{project}-{service}"
    # ищем контейнер <project>-<service>-<N> (обычно N=1)
    for name in names:
        if name == expected or name.startswith(expected + "-"):
            if name[len(expected) :].lstrip("-").isdigit():
                return name
    raise RuntimeError(f"Контейнер для сервиса '{service}' не найден. Доступно: {names}")


def _project_from_names(names):
    """Вывести префикс <project>- из имён вида <project>-<service>-<N>."""
    candidates = [n.rsplit("-", 2)[0] for n in names if n.count("-") >= 2]
    if not candidates:
        return None
    # наиболее частый префикс — это project
    from collections import Counter
    return Counter(candidates).most_common(1)[0][0]


def find_leader_container():
    """Определить текущего лидера из leader-capable узлов и вернуть имя контейнера."""
    log.info("Определяю текущего лидера кластера по leader-capable узлам...")
    for node in config.LEADER_CAPABLE_NODES:
        try:
            is_rep = db_is_replica(node)
            log.info(f"  {node}: is_replica={is_rep}")
            if not is_rep:
                cname = container_name(node)
                log.ok(f"Текущий лидер: {node} (контейнер {cname})")
                return cname
        except Exception:  # noqa: BLE001
            log.warn(f"  {node}: узел недоступен")
            continue
    raise RuntimeError("Не удалось определить лидера кластера")


def db_is_replica(node):
    import db
    return db.is_replica(node)


def stop_container(name):
    log.info(f"Останавливаю контейнер {name} (docker stop)...")
    docker("stop", name, timeout=120)
    log.ok(f"Контейнер {name} остановлен")


def start_container(name):
    log.info(f"Запускаю контейнер {name} (docker start)...")
    docker("start", name, timeout=180)
    log.ok(f"Контейнер {name} запущен")
