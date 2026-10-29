import logging
import random
import string
import time
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
    """Батч-генератор бронирований: BATCH_BOOKINGS бронирований за одну транзакцию
    (один коммит вместо autocommit на каждый INSERT)."""

    def __init__(self, pool, stats, batch_size=1, ops_per_sec=0.0, **kwargs):
        super().__init__(pool, stats, "BookingWorker", **kwargs)
        self._seats = {}
        self._flight_ids = []
        self.batch_size = max(1, batch_size)
        self.ops_per_sec = ops_per_sec

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

        seats = []
        for s in self._seats.values():
            seats.extend(s)
        if not seats:
            return

        now = datetime.now(timezone.utc)
        bookings_rows = []
        tickets_rows = []
        segments_rows = []
        boarding_rows = []

        for _ in range(self.batch_size):
            book_ref = random_book_ref()
            total_amount = round(random.uniform(5000, 50000), 2)
            bookings_rows.append((book_ref, now, total_amount))

            flight_id = random.choice(self._flight_ids)
            num_tickets = random.randint(1, 3)
            for _ in range(num_tickets):
                ticket_no = random_ticket_no()
                outbound = random.choice([True, False])
                tickets_rows.append(
                    (ticket_no, book_ref, ticket_no[:10], random_passenger(), outbound)
                )

                fare = random.choice(["Economy", "Comfort", "Business"])
                price = {"Economy": random.uniform(1000, 8000),
                         "Comfort": random.uniform(8000, 15000),
                         "Business": random.uniform(15000, 40000)}[fare]
                price = round(price, 2)
                segments_rows.append((ticket_no, flight_id, fare, price))

                boarding_rows.append(
                    (ticket_no, flight_id, random.choice(seats),
                     random.randint(1, 300), now + timedelta(hours=2))
                )

        self.write_batch([
            ("INSERT INTO bookings.bookings (book_ref, book_date, total_amount) "
             "VALUES %s ON CONFLICT DO NOTHING", bookings_rows),
            ("INSERT INTO bookings.tickets (ticket_no, book_ref, passenger_id, passenger_name, outbound) "
             "VALUES %s ON CONFLICT DO NOTHING", tickets_rows),
            ("INSERT INTO bookings.segments (ticket_no, flight_id, fare_conditions, price) "
             "VALUES %s ON CONFLICT DO NOTHING", segments_rows),
            ("INSERT INTO bookings.boarding_passes (ticket_no, flight_id, seat_no, boarding_no, boarding_time) "
             "VALUES %s ON CONFLICT DO NOTHING", boarding_rows),
        ])

        n = len(bookings_rows) + len(tickets_rows) + len(segments_rows) + len(boarding_rows)
        self.count_bulk("bookings", "INSERT", len(bookings_rows))
        self.count_bulk("tickets", "INSERT", len(tickets_rows))
        self.count_bulk("segments", "INSERT", len(segments_rows))
        self.count_bulk("boarding_passes", "INSERT", len(boarding_rows))

        # Ограничение скорости: n штук каждые n/ops_per_sec секунд (per-worker бюджет)
        if self.ops_per_sec > 0:
            time.sleep(n / self.ops_per_sec)
