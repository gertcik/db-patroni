package com.audit.consumer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * Writes decoded WAL changes to the audit database.
 * Inserts every change as a new row with audit metadata.
 */
public class AuditWriter implements AutoCloseable {

    private final Connection conn;
    private final Map<String, String> tableCache = new java.util.concurrent.ConcurrentHashMap<>();

    public AuditWriter(String url, String user, String password) throws SQLException {
        this.conn = DriverManager.getConnection(url, user, password);
        this.conn.setAutoCommit(false);
    }

    AuditWriter() {
        this.conn = null;
    }

    public void writeBatch(List<PgOutputDecoder.Change> changes) throws SQLException {
        for (var change : changes) {
            writeChange(change);
        }
        conn.commit();
    }

    private void writeChange(PgOutputDecoder.Change change) throws SQLException {
        var rel = change;
        String fullName = rel.schema() + "." + rel.table();
        String sql = tableCache.get(fullName);
        if (sql == null) {
            sql = buildInsertSql(rel);
            tableCache.put(fullName, sql);
        }

        try (var stmt = conn.prepareStatement(sql)) {
            int idx = 1;
            for (int i = 0; i < rel.columnNames().size(); i++) {
                stmt.setString(idx++, rel.values().get(i));
            }
            stmt.setString(idx, change.action());
            stmt.executeUpdate();
        }
    }

    String buildInsertSql(PgOutputDecoder.Change change) {
        String cols = change.columnNames().stream()
                .map(AuditWriter::quoteIdent)
                .collect(Collectors.joining(", "));
        String placeholders = change.columnNames().stream()
                .map(c -> "?")
                .collect(Collectors.joining(", "));
        return "INSERT INTO " + quoteIdent(change.schema()) + "." + quoteIdent(change.table())
                + " (" + cols + ", movedate, moveusername, moveaction) VALUES ("
                + placeholders + ", now(), 'wal_consumer', ?)";
    }

    static String quoteIdent(String ident) {
        return "\"" + ident.replace("\"", "\"\"") + "\"";
    }

    @Override
    public void close() throws SQLException {
        if (conn != null && !conn.isClosed()) conn.close();
    }
}
