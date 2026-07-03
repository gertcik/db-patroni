import os
import logging
import sys

from pool import DbPool
from stats import Stats
from workers.booking_worker import BookingWorker
from workers.flight_worker import FlightWorker
from workers.canceller_worker import CancellerWorker
from workers.mass_updater import MassUpdater


def main():
    log_level = os.getenv("LOG_LEVEL", "INFO").upper()
    logging.basicConfig(
        level=getattr(logging, log_level, logging.INFO),
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        stream=sys.stdout,
    )
    logger = logging.getLogger("main")

    db_host = os.getenv("DB_HOST", "haproxy")
    db_port = os.getenv("DB_PORT", "5432")
    db_name = os.getenv("DB_NAME", "shop")
    db_user = os.getenv("DB_USER", "postgres")
    db_password = os.getenv("DB_PASSWORD", "secret")

    threads_booking = int(os.getenv("THREADS_BOOKING", "3"))
    threads_flight = int(os.getenv("THREADS_FLIGHT", "2"))
    threads_canceller = int(os.getenv("THREADS_CANCELLER", "1"))
    threads_mass = int(os.getenv("THREADS_MASS_UPDATER", "1"))
    pool_min = int(os.getenv("POOL_MIN", "4"))
    pool_max = int(os.getenv("POOL_MAX", "20"))
    sleep_min = float(os.getenv("SLEEP_MIN_MS", "100")) / 1000.0
    sleep_max = float(os.getenv("SLEEP_MAX_MS", "500")) / 1000.0
    stats_interval = int(os.getenv("STATS_INTERVAL_SEC", "10"))

    dsn = f"host={db_host} port={db_port} dbname={db_name} user={db_user} password={db_password}"

    logger.info("Connecting to %s:%s/%s as %s", db_host, db_port, db_name, db_user)
    pool = DbPool(dsn, minconn=pool_min, maxconn=pool_max)
    stats = Stats(interval_sec=stats_interval)

    threads = []
    for _ in range(threads_booking):
        w = BookingWorker(pool, stats, sleep_range=(sleep_min, sleep_max))
        w.start()
        threads.append(w)
    for _ in range(threads_flight):
        w = FlightWorker(pool, stats, sleep_range=(sleep_min, sleep_max))
        w.start()
        threads.append(w)
    for _ in range(threads_canceller):
        w = CancellerWorker(pool, stats, sleep_range=(sleep_min, sleep_max))
        w.start()
        threads.append(w)
    for _ in range(threads_mass):
        w = MassUpdater(pool, stats, interval_sec=60, sleep_range=(sleep_min, sleep_max))
        w.start()
        threads.append(w)

    logger.info(
        "Started %d booking, %d flight, %d canceller, %d mass-updater workers",
        threads_booking, threads_flight, threads_canceller, threads_mass,
    )

    try:
        while True:
            stats.maybe_print()
            import time as _time
            _time.sleep(1)
    except KeyboardInterrupt:
        logger.info("Shutting down...")


if __name__ == "__main__":
    main()
