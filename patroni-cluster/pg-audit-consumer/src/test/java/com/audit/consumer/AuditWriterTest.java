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
    void quoteIdentEscapesDoubleQuote() {
        assertEquals("\"\"", AuditWriter.quoteIdent(""));
        assertEquals("\"simple\"", AuditWriter.quoteIdent("simple"));
        assertEquals("\"a\"\"b\"", AuditWriter.quoteIdent("a\"b"));
        assertEquals("\"\"\"\"", AuditWriter.quoteIdent("\""));
    }
}
