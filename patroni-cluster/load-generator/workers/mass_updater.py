import logging
import random
import time
from datetime import datetime, timezone
from .base import BaseWorker, retry_on_disconnect

logger = logging.getLogger(__name__)


class MassUpdater(BaseWorker):
    def __init__(self, pool, stats, interval_sec=60, **kwargs):
        super().__init__(pool, stats, "MassUpdater", **kwargs)
        self.interval_sec = interval_sec

    @retry_on_disconnect()
    def work(self):
        scenario = random.choice(["cancel_old_flights", "update_bookings"])

        if scenario == "cancel_old_flights":
            now = datetime.now(timezone.utc).isoformat()
            self.execute(
                "UPDATE bookings.flights SET status = 'Cancelled' "
                "WHERE scheduled_departure < %s::timestamptz "
                "AND status NOT IN ('Arrived', 'Cancelled')",
                (now,),
                table="flights", op="UPDATE"
            )

        elif scenario == "update_bookings":
            self.execute(
                "UPDATE bookings.bookings SET total_amount = total_amount * 1.05",
                table="bookings", op="UPDATE"
            )

        logger.info("MassUpdater: completed scenario=%s, next run in %ds", scenario, self.interval_sec)
        time.sleep(self.interval_sec)
