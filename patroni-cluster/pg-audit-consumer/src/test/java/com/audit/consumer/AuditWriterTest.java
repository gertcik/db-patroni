package com.audit.consumer;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

import java.util.List;

class AuditWriterTest {

    private final AuditWriter writer = new AuditWriter();

    @Test
    void buildInsertSqlBasic() {
        var change = new PgOutputDecoder.Change(
                "bookings", "airplanes_data",
                List.of("airplane_code", "model"),
                List.of("773", "Boeing 777"),
                "i"
        );
        String sql = writer.buildInsertSql(change);
        assertEquals(
                "INSERT INTO \"bookings\".\"airplanes_data\" (\"airplane_code\", \"model\", movedate, moveusername, moveaction) VALUES (?, ?, now(), 'wal_consumer', ?)",
                sql);
    }

    @Test
    void buildInsertSqlWithSpecialChars() {
        var change = new PgOutputDecoder.Change(
                "book\"ings", "test\"table",
                List.of("col\"umn"),
                List.of("val"),
                "u"
        );
        String sql = writer.buildInsertSql(change);
        assertEquals(
                "INSERT INTO \"book\"\"ings\".\"test\"\"table\" (\"col\"\"umn\", movedate, moveusername, moveaction) VALUES (?, now(), 'wal_consumer', ?)",
                sql);
    }

    @Test
    void buildInsertSqlDeleteAction() {
        var change = new PgOutputDecoder.Change(
                "bookings", "tickets",
                List.of("ticket_no", "passenger_name"),
                List.of("202600000001", "IVAN"),
                "d"
        );
        String sql = writer.buildInsertSql(change);
        assertTrue(sql.contains("moveaction"));
        assertTrue(sql.contains("'wal_consumer'"));
        assertTrue(sql.contains("now()"));
    }

    @Test
    void buildInsertSqlWithTypes() {
        var change = new PgOutputDecoder.Change(
                "bookings", "airplanes_data",
                List.of("airplane_code", "model", "range", "speed"),
                List.of("773", "Boeing 777", "11100", "905"),
                "i"
        );
        String sql = writer.buildInsertSql(
                change,
                List.of("airplane_code", "model", "range", "speed"),
                List.of("character(3)", "text", "integer", "integer")
        );
        assertEquals(
                "INSERT INTO \"bookings\".\"airplanes_data\" (\"airplane_code\", \"model\", \"range\", \"speed\", movedate, moveusername, moveaction)"
                        + " VALUES (CAST(? AS character(3)), CAST(? AS text), CAST(? AS integer), CAST(? AS integer), now(), 'wal_consumer', ?)",
                sql);
    }

    @Test
    void buildInsertSqlTypedWithoutMatchingTypeFallsBackToPlainPlaceholder() {
        var change = new PgOutputDecoder.Change(
                "bookings", "tickets",
                List.of("ticket_no", "extra_col"),
                List.of("202600000001", "X"),
                "i"
        );
        String sql = writer.buildInsertSql(
                change,
                List.of("ticket_no"),
                List.of("text")
        );
        // для колонки без известного типа — обычный ?, для известной — CAST
        assertTrue(sql.contains("\"ticket_no\" CAST" ) || sql.contains("CAST(? AS text)"));
        assertTrue(sql.contains("\"extra_col\""));
        assertTrue(sql.contains(", ?, now(), 'wal_consumer', ?)"));
    }

    @Test
    void quoteIdentEscapesDoubleQuote() {
        assertEquals("\"\"", AuditWriter.quoteIdent(""));
        assertEquals("\"simple\"", AuditWriter.quoteIdent("simple"));
        assertEquals("\"a\"\"b\"", AuditWriter.quoteIdent("a\"b"));
        assertEquals("\"\"\"\"", AuditWriter.quoteIdent("\""));
    }
}
