import logging
import random
import time
import threading
from psycopg2 import OperationalError, InterfaceError
from psycopg2.extras import execute_values

logger = logging.getLogger(__name__)


def retry_on_disconnect(max_attempts=10, delay=2):
    def decorator(fn):
        def wrapper(*args, **kwargs):
            for attempt in range(max_attempts):
                try:
                    return fn(*args, **kwargs)
                except (OperationalError, InterfaceError) as e:
                    logger.warning("%s failed (attempt %d/%d): %s", fn.__name__, attempt + 1, max_attempts, e)
                    time.sleep(delay)
            logger.error("%s exhausted retries", fn.__name__)
            return None
        return wrapper
    return decorator


class BaseWorker(threading.Thread):
    def __init__(self, pool, stats, name, sleep_range=(0.1, 0.5)):
        super().__init__(daemon=True)
        self.pool = pool
        self.stats = stats
        self.name = name
        self.sleep_range = sleep_range

    def execute(self, sql, params=None, table=None, op=None):
        with self.pool.conn() as cn:
            cn.autocommit = True
            with cn.cursor() as cur:
                cur.execute(sql, params)
        if table and op:
            self.stats.count(table, op)

    def execute_all(self, statements):
        with self.pool.conn() as cn:
            cn.autocommit = True
            with cn.cursor() as cur:
                for sql, params in statements:
                    cur.execute(sql, params)

    def write_batch(self, statements):
        """statements: список (sql, rows) — multi-row вставки в ОДНОЙ транзакции (один коммит)."""
        with self.pool.conn() as cn:
            try:
                cn.autocommit = False
                with cn.cursor() as cur:
                    for sql, rows in statements:
                        execute_values(cur, sql, rows, page_size=100)
                cn.commit()
            except Exception:
                cn.rollback()
                raise

    def count_bulk(self, table, op, n):
        for _ in range(n):
            self.stats.count(table, op)

    def fetch_one(self, sql, params=None):
        with self.pool.conn() as cn:
            with cn.cursor() as cur:
                cur.execute(sql, params)
                return cur.fetchone()

    def fetch_all(self, sql, params=None):
        with self.pool.conn() as cn:
            with cn.cursor() as cur:
                cur.execute(sql, params)
                return cur.fetchall()

    def run(self):
        while True:
            try:
                self.work()
            except Exception as e:
                logger.exception("%s: unhandled error: %s", self.name, e)
                self.stats.error()
            time.sleep(random.uniform(*self.sleep_range))

    def work(self):
        raise NotImplementedError
