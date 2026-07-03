import logging
import threading
import time

logger = logging.getLogger(__name__)


class Stats:
    def __init__(self, interval_sec=10):
        self.interval_sec = interval_sec
        self._lock = threading.Lock()
        self._counts = {}
        self._errors = 0
        self._last_printed = time.monotonic()

    def count(self, table, op):
        with self._lock:
            key = (table, op)
            self._counts[key] = self._counts.get(key, 0) + 1

    def error(self):
        with self._lock:
            self._errors += 1

    def maybe_print(self):
        now = time.monotonic()
        if now - self._last_printed < self.interval_sec:
            return
        with self._lock:
            snapshot = dict(self._counts)
            errs = self._errors
            self._counts.clear()
            self._errors = 0
            self._last_printed = now
        elapsed = self.interval_sec
        if not snapshot and errs == 0:
            return
        tables = sorted(set(k[0] for k in snapshot))
        ops_order = ["INSERT", "UPDATE", "DELETE"]
        logger.info("Stats (last %ds):", elapsed)
        header = f"{'Table':<20}" + "".join(f"{o:>10}" for o in ops_order) + f"{'err/s':>8}"
        logger.info(header)
        for t in tables:
            row = f"{t:<20}"
            for o in ops_order:
                val = snapshot.get((t, o), 0)
                row += f"{val / elapsed:>10.1f}"
            row += f"{errs / elapsed:>8.2f}"
            logger.info(row)
