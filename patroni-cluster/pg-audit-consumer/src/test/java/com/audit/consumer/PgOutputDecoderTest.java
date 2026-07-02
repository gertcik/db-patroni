package com.audit.consumer;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

import java.nio.ByteBuffer;
import java.util.List;

class PgOutputDecoderTest {

    private PgOutputDecoder decoder;

    @BeforeEach
    void setUp() {
        decoder = new PgOutputDecoder();
    }

    @Test
    void relationAndInsert() {
        int oid = 12345;
        var cols = List.of("airplane_code", "model", "range", "speed");
        var vals = List.of("773", "Boeing 777-300ER", "11100", "905");

        decoder.decode(TestUtil.relation(oid, "bookings", "airplanes_data", cols));
        decoder.decode(TestUtil.insert(oid, vals));

        var batch = decoder.getBatch();
        assertEquals(1, batch.size());
        var ch = batch.get(0);
        assertEquals("bookings", ch.schema());
        assertEquals("airplanes_data", ch.table());
        assertEquals(cols, ch.columnNames());
        assertEquals(vals, ch.values());
        assertEquals("i", ch.action());
    }

    @Test
    void update() {
        int oid = 54321;
        var cols = List.of("book_ref", "book_date", "total_amount");
        var vals = List.of("ABC123", "2026-07-01", "25000.00");

        decoder.decode(TestUtil.relation(oid, "bookings", "bookings", cols));
        decoder.decode(TestUtil.update(oid, vals));

        var batch = decoder.getBatch();
        assertEquals(1, batch.size());
        assertEquals("u", batch.get(0).action());
        assertEquals("ABC123", batch.get(0).values().get(0));
    }

    @Test
    void delete() {
        int oid = 999;
        var cols = List.of("ticket_no", "passenger_name");
        var vals = List.of("202600000001", "IVAN PETROV");

        decoder.decode(TestUtil.relation(oid, "bookings", "tickets", cols));
        decoder.decode(TestUtil.delete(oid, vals));

        var batch = decoder.getBatch();
        assertEquals(1, batch.size());
        assertEquals("d", batch.get(0).action());
        assertEquals("IVAN PETROV", batch.get(0).values().get(1));
    }

    @Test
    void nullValues() {
        int oid = 111;
        var cols = List.of("col1", "col2", "col3");
        var vals = java.util.Arrays.asList("hello", null, "world");

        decoder.decode(TestUtil.relation(oid, "public", "test_table", cols));
        decoder.decode(TestUtil.insert(oid, vals));

        var batch = decoder.getBatch();
        assertEquals(1, batch.size());
        assertNull(batch.get(0).values().get(1));
        assertEquals("hello", batch.get(0).values().get(0));
        assertEquals("world", batch.get(0).values().get(2));
    }

    @Test
    void unknownRelationIsSkipped() {
        decoder.decode(TestUtil.insert(777, List.of("val")));
        assertTrue(decoder.getBatch().isEmpty());
    }

    @Test
    void multipleChanges() {
        int oid = 42;
        var cols = List.of("col");

        decoder.decode(TestUtil.relation(oid, "s", "t", cols));
        decoder.decode(TestUtil.insert(oid, List.of("a")));
        decoder.decode(TestUtil.insert(oid, List.of("b")));

        assertEquals(2, decoder.getBatch().size());
    }

    @Test
    void truncateIsSkipped() {
        decoder.decode(TestUtil.truncate());
        assertTrue(decoder.getBatch().isEmpty());
    }

    @Test
    void sameRelationOnceReused() {
        int oid = 1;
        decoder.decode(TestUtil.relation(oid, "s", "t", List.of("x")));
        decoder.decode(TestUtil.insert(oid, List.of("a")));
        decoder.decode(TestUtil.insert(oid, List.of("b")));
        assertEquals(2, decoder.getBatch().size());
        assertEquals("a", decoder.getBatch().get(0).values().get(0));
        assertEquals("b", decoder.getBatch().get(1).values().get(0));
    }

    @Test
    void emptyBufferDoesNotThrow() {
        var buf = ByteBuffer.allocate(0);
        buf.flip();
        decoder.decode(buf);
        assertTrue(decoder.getBatch().isEmpty());
    }

    @Test
    void deleteWithSomeNulls() {
        int oid = 7777;
        var cols = List.of("airplane_code", "seat_no", "fare_conditions");
        var vals = java.util.Arrays.asList("773", "1A", null);
        decoder.decode(TestUtil.relation(oid, "bookings", "seats", cols));
        decoder.decode(TestUtil.delete(oid, vals));
        var batch = decoder.getBatch();
        assertEquals(1, batch.size());
        var ch = batch.get(0);
        assertEquals("d", ch.action());
        assertEquals("773", ch.values().get(0));
        assertEquals("1A", ch.values().get(1));
        assertNull(ch.values().get(2));
    }

    @Test
    void clearBatch() {
        decoder.decode(TestUtil.relation(2, "s", "t", List.of("c")));
        decoder.decode(TestUtil.insert(2, List.of("x")));
        assertEquals(1, decoder.getBatch().size());
        decoder.getBatch().clear();
        assertTrue(decoder.getBatch().isEmpty());
    }
}
