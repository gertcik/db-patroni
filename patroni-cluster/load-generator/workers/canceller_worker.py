import logging
from .base import BaseWorker, retry_on_disconnect

logger = logging.getLogger(__name__)


class CancellerWorker(BaseWorker):
    def __init__(self, pool, stats, **kwargs):
        super().__init__(pool, stats, "CancellerWorker", **kwargs)

    @retry_on_disconnect()
    def work(self):
        book_ref = None
        with self.pool.conn() as cn:
            with cn.cursor() as cur:
                cur.execute(
                    "SELECT book_ref FROM bookings.bookings ORDER BY random() LIMIT 1"
                )
                row = cur.fetchone()
                if not row:
                    return
                book_ref = row[0]
                cur.execute(
                    "DELETE FROM bookings.boarding_passes "
                    "WHERE ticket_no IN (SELECT ticket_no FROM bookings.tickets WHERE book_ref = %s)",
                    (book_ref,)
                )
                cur.execute(
                    "DELETE FROM bookings.segments "
                    "WHERE ticket_no IN (SELECT ticket_no FROM bookings.tickets WHERE book_ref = %s)",
                    (book_ref,)
                )
                cur.execute(
                    "DELETE FROM bookings.tickets WHERE book_ref = %s",
                    (book_ref,)
                )
                cur.execute(
                    "DELETE FROM bookings.bookings WHERE book_ref = %s",
                    (book_ref,)
                )
        if book_ref:
            self.stats.count("bookings", "DELETE")
