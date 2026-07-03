import logging
import random
import string
from datetime import datetime, timedelta, timezone
from .base import BaseWorker, retry_on_disconnect

logger = logging.getLogger(__name__)


def random_book_ref():
    return ''.join(random.choices(string.ascii_uppercase + string.digits, k=6))


def random_ticket_no():
    return ''.join(random.choices(string.digits, k=13))


def random_passenger():
    from data.names import NAMES
    return random.choice(NAMES)


class BookingWorker(BaseWorker):
    def __init__(self, pool, stats, **kwargs):
        super().__init__(pool, stats, "BookingWorker", **kwargs)
        self._seats = {}
        self._flight_ids = []

    def load_refs(self):
        self._flight_ids = [
            r[0] for r in self.fetch_all(
                "SELECT flight_id FROM bookings.flights ORDER BY random() LIMIT 50"
            )
        ]
        airplanes = self.fetch_all(
            "SELECT airplane_code FROM bookings.airplanes_data"
        )
        for (code,) in airplanes:
            rows = self.fetch_all(
                "SELECT seat_no FROM bookings.seats WHERE airplane_code = %s",
                (code,)
            )
            self._seats[code] = [r[0] for r in rows]
        logger.info(
            "BookingWorker: loaded %d flight_ids, %d airplanes",
            len(self._flight_ids), len(airplanes),
        )

    @retry_on_disconnect()
    def work(self):
        if not self._flight_ids:
            self.load_refs()
            if not self._flight_ids:
                logger.warning("BookingWorker: no flights loaded yet, skipping")
                return

        flight_id = random.choice(self._flight_ids)

        seats = []
        for s in self._seats.values():
            seats.extend(s)
        if not seats:
            return

        total_amount = round(random.uniform(5000, 50000), 2)
        book_ref = random_book_ref()
        now = datetime.now(timezone.utc)

        self.execute(
            "INSERT INTO bookings.bookings (book_ref, book_date, total_amount) "
            "VALUES (%s, %s, %s)",
            (book_ref, now, total_amount),
            table="bookings", op="INSERT"
        )

        num_tickets = random.randint(1, 3)
        for _ in range(num_tickets):
            ticket_no = random_ticket_no()
            passenger = random_passenger()
            outbound = random.choice([True, False])
            self.execute(
                "INSERT INTO bookings.tickets (ticket_no, book_ref, passenger_id, passenger_name, outbound) "
                "VALUES (%s, %s, %s, %s, %s)",
                (ticket_no, book_ref, ticket_no[:10], passenger, outbound),
                table="tickets", op="INSERT"
            )

            fare = random.choice(["Economy", "Comfort", "Business"])
            price = {"Economy": random.uniform(1000, 8000),
                     "Comfort": random.uniform(8000, 15000),
                     "Business": random.uniform(15000, 40000)}[fare]
            price = round(price, 2)

            self.execute(
                "INSERT INTO bookings.segments (ticket_no, flight_id, fare_conditions, price) "
                "VALUES (%s, %s, %s, %s)",
                (ticket_no, flight_id, fare, price),
                table="segments", op="INSERT"
            )

            seat_no = random.choice(seats)
            self.execute(
                "INSERT INTO bookings.boarding_passes (ticket_no, flight_id, seat_no, boarding_no, boarding_time) "
                "VALUES (%s, %s, %s, %s, %s)",
                (ticket_no, flight_id, seat_no, random.randint(1, 300), now + timedelta(hours=2)),
                table="boarding_passes", op="INSERT"
            )
