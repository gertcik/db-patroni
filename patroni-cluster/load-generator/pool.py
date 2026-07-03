import logging
import time
from contextlib import contextmanager
from psycopg2.pool import ThreadedConnectionPool
from psycopg2 import OperationalError

logger = logging.getLogger(__name__)


class DbPool:
    def __init__(self, dsn, minconn=4, maxconn=20):
        self.dsn = dsn
        self.minconn = minconn
        self.maxconn = maxconn
        self._pool = None
        self._connect()

    def _connect(self):
        logger.info("Creating connection pool to %s (min=%d, max=%d)", self.dsn, self.minconn, self.maxconn)
        self._pool = ThreadedConnectionPool(self.minconn, self.maxconn, self.dsn)

    @contextmanager
    def conn(self):
        cn = None
        for attempt in range(10):
            try:
                cn = self._pool.getconn()
                yield cn
                return
            except OperationalError:
                if cn:
                    self._pool.putconn(cn, close=True)
                logger.warning("Connection failed (attempt %d/10), retrying in 2s...", attempt + 1)
                time.sleep(2)
                try:
                    self._connect()
                except OperationalError:
                    continue
            finally:
                if cn:
                    self._pool.putconn(cn)
