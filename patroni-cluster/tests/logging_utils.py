"""Логирование шагов тестов.

Даёт единообразный, читаемый вывод того, что делает каждый тест.
Вывод идёт через print (виден в stdout pytest и попадает в отчёты).
Уровни: [STEP n], [INFO], [OK], [WARN], [ERROR], [DEBUG].
DEBUG включается переменной окружения TEST_DEBUG (по умолчанию выключен).
"""
import os
import sys

_ENABLED = True
# Отладочный вывод по умолчанию выключен; включить через TEST_DEBUG=1
_DEBUG = os.environ.get("TEST_DEBUG", "").strip() not in ("", "0", "false", "no")


def _emit(prefix, msg):
    if not _ENABLED:
        return
    print(f"[{prefix}] {msg}", flush=True)


def info(msg):
    _emit("INFO", msg)


def step(n, msg):
    _emit(f"STEP {n}", msg)


def ok(msg):
    _emit("OK", msg)


def warn(msg):
    _emit("WARN", msg)


def error(msg):
    _emit("ERROR", msg)


def debug(msg):
    if _DEBUG:
        _emit("DEBUG", msg)
