import logging
import random
from datetime import datetime, timedelta, timezone, time as dtime
from .base import BaseWorker, retry_on_disconnect

logger = logging.getLogger(__name__)

STATUS_CYCLE = ["Scheduled", "On Time", "Delayed", "Boarding", "Departed", "Arrived"]


class FlightWorker(BaseWorker):
    def __init__(self, pool, stats, **kwargs):
        super().__init__(pool, stats, "FlightWorker", **kwargs)
        self._routes = []

    def load_refs(self):
        self._routes = self.fetch_all(
            "SELECT route_no, departure_airport, arrival_airport, "
            "       airplane_code, scheduled_time, duration "
            "FROM bookings.routes"
        )
        logger.info("FlightWorker: loaded %d routes", len(self._routes))

    @retry_on_disconnect()
    def do_insert(self):
        if not self._routes:
            self.load_refs()
            if not self._routes:
                return

        route = random.choice(self._routes)
        route_no, dep, arr, ac_code, sched_time, duration = route

        now = datetime.now(timezone.utc)
        dep_day = now + timedelta(days=random.randint(-5, 30))
        if isinstance(sched_time, timedelta):
            dep_dt = datetime.combine(dep_day.date(), dtime.min, tzinfo=timezone.utc) + sched_time
        else:
            dep_dt = dep_day.replace(hour=sched_time.hour, minute=sched_time.minute,
                                     second=sched_time.second, microsecond=0)

        arr_dt = dep_dt + duration
        status = random.choice(STATUS_CYCLE[:3])

        self.execute(
            "INSERT INTO bookings.flights "
            "(route_no, status, scheduled_departure, scheduled_arrival) "
            "VALUES (%s, %s, %s, %s)",
            (route_no, status, dep_dt, arr_dt),
            table="flights", op="INSERT"
        )

    @retry_on_disconnect()
    def do_update(self):
        row = self.fetch_one(
            "SELECT flight_id, status FROM bookings.flights "
            "WHERE status != 'Arrived' AND status != 'Cancelled' "
            "ORDER BY random() LIMIT 1"
        )
        if not row:
            return

        flight_id, current_status = row
        try:
            idx = STATUS_CYCLE.index(current_status)
            new_status = STATUS_CYCLE[idx + 1]
        except (ValueError, IndexError):
            new_status = "Arrived"

        params = {"status": new_status, "flight_id": flight_id}

        if new_status in ("Departed", "Arrived"):
            params["actual_departure"] = datetime.now(timezone.utc)
        else:
            params["actual_departure"] = None

        if new_status == "Arrived":
            params["actual_arrival"] = datetime.now(timezone.utc)
        else:
            params["actual_arrival"] = None

        sql = ("UPDATE bookings.flights SET status = %(status)s, "
               "actual_departure = %(actual_departure)s, "
               "actual_arrival = %(actual_arrival)s "
               "WHERE flight_id = %(flight_id)s")

        self.execute(sql, params, table="flights", op="UPDATE")

    def work(self):
        if random.random() < 0.4:
            self.do_insert()
        else:
            self.do_update()
