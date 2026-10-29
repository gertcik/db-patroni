package com.audit.consumer;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Writes decoded WAL changes to the audit database.
 * Inserts every change as a new row with audit metadata.
 *
 * Mirror schema: on first occurrence of a table the writer reads column
 * types from the source database (pg_catalog.format_type) and aligns the
 * audit table (CREATE when missing, ALTER COLUMN TYPE when types diverge),
 * so source column types are mirrored in the audit copy. INSERTs embed
 * per-column casts (CAST(? AS type)) so WAL text values are coerced to the
 * real column types instead of being stored as TEXT.
 */
public class AuditWriter implements AutoCloseable {

    private static final Logger logger = LogManager.getLogger(AuditWriter.class);

    /** Audit metadata columns are never mirrored from the source. */
    static final Set<String> META_COLUMNS = Set.of("movedate", "moveusername", "moveaction", "id_identity");

    private final Connection conn;
    private final Connection metaConn;
    private final Map<String, String> tableCache = new java.util.concurrent.ConcurrentHashMap<>();
    /** Таблицы, отсутствующие в источнике (удалены): изменения пропускаются. */
    private final Set<String> skipCache = java.util.Collections.newSetFromMap(new java.util.concurrent.ConcurrentHashMap<>());

    public AuditWriter(String targetUrl, String targetUser, String targetPassword,
                       String metaUrl, String metaUser, String metaPassword) throws SQLException {
        this.conn = DriverManager.getConnection(targetUrl, targetUser, targetPassword);
        this.conn.setAutoCommit(false);
        this.metaConn = DriverManager.getConnection(metaUrl, metaUser, metaPassword);
    }

    AuditWriter() {
        this.conn = null;
        this.metaConn = null;
    }

    public void writeBatch(List<PgOutputDecoder.Change> changes) throws SQLException {
        for (var change : changes) {
            writeChange(change);
        }
        conn.commit();
    }

    private void writeChange(PgOutputDecoder.Change change) throws SQLException {
        String fullName = change.schema() + "." + change.table();
        if (skipCache.contains(fullName)) return;
        String sql = tableCache.get(fullName);
        if (sql == null) {
            sql = ensureMirrorSchema(change);
            if (sql == null) return; // таблица удалена из источника — пропускаем
            tableCache.put(fullName, sql);
        }

        try (var stmt = conn.prepareStatement(sql)) {
            int idx = 1;
            for (int i = 0; i < change.columnNames().size(); i++) {
                stmt.setString(idx++, change.values().get(i));
            }
            stmt.setString(idx, change.action());
            stmt.executeUpdate();
        }
    }

    /**
     * Aligns the audit table with source column types and returns the ready INSERT SQL
     * with per-column casts. DDL is committed immediately so it survives later failures.
     */
    String ensureMirrorSchema(PgOutputDecoder.Change change) throws SQLException {
        String schema = change.schema();
        String table = change.table();

        List<String> srcColumns = new ArrayList<>();
        List<String> srcTypes = new ArrayList<>();
        readColumns(metaConn, schema, table, srcColumns, srcTypes);
        if (srcColumns.isEmpty()) {
            // Таблица не найдена в источнике (например, уже удалена): пропускаем её изменения,
            // чтобы не зациклиться на исторических записях WAL
            logger.warn("Source table not found, skipping changes: {}.{}", schema, table);
            skipCache.add(schema + "." + table);
            return null;
        }

        Map<String, String> target = readTargetColumns(schema, table);
        if (target == null) {
            String cols = srcColumns.stream()
                    .map(c -> quoteIdent(c) + " " + typeOf(srcTypes, srcColumns, c) + " NULL")
                    .collect(Collectors.joining(", "));
            execDdl("CREATE TABLE IF NOT EXISTS " + quoteIdent(schema) + "." + quoteIdent(table)
                    + " (" + cols
                    + ", movedate TIMESTAMP DEFAULT CURRENT_DATE"
                    + ", moveusername TEXT DEFAULT 'wal_consumer'"
                    + ", moveaction TEXT"
                    + ", id_identity BIGINT GENERATED ALWAYS AS IDENTITY)");
            logger.info("Created mirror table {}.{} ({} source columns)", schema, table, srcColumns.size());
        } else {
            List<String> alter = new ArrayList<>();
            for (int i = 0; i < srcColumns.size(); i++) {
                String col = srcColumns.get(i);
                if (META_COLUMNS.contains(col.toLowerCase())) continue;
                String srcType = srcTypes.get(i);
                String curType = target.get(col.toLowerCase());
                if (curType == null) {
                    alter.add("ADD COLUMN " + quoteIdent(col) + " " + srcType + " NULL");
                } else if (!curType.equalsIgnoreCase(srcType)) {
                    alter.add("ALTER COLUMN " + quoteIdent(col) + " TYPE " + srcType
                            + " USING (" + quoteIdent(col) + "::" + srcType + ")");
                }
            }
            for (String clause : alter) {
                // по одной ALTER на колонку: ошибка одной (например, нечитаемые данные)
                // не блокирует выравнивание остальных колонок
                try {
                    execDdl("ALTER TABLE " + quoteIdent(schema) + "." + quoteIdent(table) + " " + clause);
                    logger.info("Aligned mirror column of {}.{}: {}", schema, table, clause);
                } catch (SQLException e) {
                    logger.error("Cannot align column of {}.{} ({}): {}", schema, table, clause, e.getMessage());
                }
            }
        }

        return buildInsertSql(change, srcColumns, srcTypes);
    }

    private static String typeOf(List<String> types, List<String> columns, String column) {
        int i = columns.indexOf(column);
        return i >= 0 ? types.get(i) : null;
    }

    private static String castPlaceholder(String type) {
        return type != null ? "CAST(? AS " + type + ")" : "?";
    }

    String buildInsertSql(PgOutputDecoder.Change change, List<String> srcColumns, List<String> srcTypes) {
        var names = !change.columnNames().isEmpty() ? change.columnNames() : srcColumns;
        String cols = names.stream()
                .map(AuditWriter::quoteIdent)
                .collect(Collectors.joining(", "));
        String placeholders = names.stream()
                .map(c -> castPlaceholder(typeOf(srcTypes, srcColumns, c)))
                .collect(Collectors.joining(", "));
        return "INSERT INTO " + quoteIdent(change.schema()) + "." + quoteIdent(change.table())
                + " (" + cols + ", movedate, moveusername, moveaction) VALUES ("
                + placeholders + ", now(), 'wal_consumer', ?)";
    }

    String buildInsertSql(PgOutputDecoder.Change change) {
        return buildInsertSql(change, List.of(), List.of());
    }

    private void readColumns(Connection connection, String schema, String table,
                             List<String> outNames, List<String> outTypes) throws SQLException {
        String sql = "SELECT a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod)"
                + " FROM pg_attribute a"
                + " WHERE a.attrelid = to_regclass(format('%s.%s', quote_ident(?), quote_ident(?)))"
                + " AND a.attnum > 0 AND NOT a.attisdropped"
                + " ORDER BY a.attnum";
        try (var ps = connection.prepareStatement(sql)) {
            ps.setString(1, schema);
            ps.setString(2, table);
            try (var rs = ps.executeQuery()) {
                while (rs.next()) {
                    outNames.add(rs.getString(1));
                    outTypes.add(rs.getString(2));
                }
            }
        }
    }

    /** lowercase имя колонки -> тип; null, если таблицы нет. */
    private Map<String, String> readTargetColumns(String schema, String table) throws SQLException {
        List<String> names = new ArrayList<>();
        List<String> types = new ArrayList<>();
        readColumns(conn, schema, table, names, types);
        if (names.isEmpty()) return null;
        var cols = new java.util.LinkedHashMap<String, String>();
        for (int i = 0; i < names.size(); i++) {
            cols.put(names.get(i).toLowerCase(), types.get(i));
        }
        return cols;
    }

    private void execDdl(String sql) throws SQLException {
        try (var stmt = conn.createStatement()) {
            stmt.execute(sql);
        }
        // DDL фиксируем сразу — не завязываем на успех последующих INSERT батча
        conn.commit();
    }

    static String quoteIdent(String ident) {
        return "\"" + ident.replace("\"", "\"\"") + "\"";
    }

    @Override
    public void close() throws SQLException {
        try {
            if (conn != null && !conn.isClosed()) conn.close();
        } finally {
            if (metaConn != null && !metaConn.isClosed()) metaConn.close();
        }
    }
}
