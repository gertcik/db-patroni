package com.audit.consumer;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Decodes pgoutput v1 logical replication protocol messages.
 */
public class PgOutputDecoder {

    public record RelationInfo(String schema, String table, List<String> columnNames) {}
    public record Change(String schema, String table, List<String> columnNames, List<String> values, String action) {}

    private final Map<Integer, RelationInfo> relations = new HashMap<>();
    private final List<Change> batch = new ArrayList<>();

    public List<Change> getBatch() { return batch; }

    public void decode(ByteBuffer buf) {
        while (buf.remaining() > 0) {
            int raw = buf.get() & 0xFF;
            byte msgType = (byte) (raw >= 'A' && raw <= 'Z' ? raw | 0x20 : raw);
            try {
                switch (msgType) {
                    case 'b' -> decodeBegin(buf);
                    case 'r' -> decodeRelation(buf);
                    case 'i' -> decodeInsert(buf);
                    case 'u' -> decodeUpdate(buf);
                    case 'd' -> decodeDelete(buf);
                    case 'c' -> decodeCommit(buf);
                    case 'y' -> decodeOrigin(buf);
                    case 't' -> {
                        int cnt = buf.getInt();
                        buf.getInt();
                        for (int i = 0; i < cnt; i++) buf.getInt();
                    }
                    default -> {
                        byte[] all = new byte[Math.min(buf.remaining(), 128)];
                        buf.get(all);
                        buf.position(buf.limit());
                    }
                }
            } catch (java.nio.BufferUnderflowException e) {
                buf.position(buf.limit());
            }
        }
    }

    private void decodeBegin(ByteBuffer buf) {
        long lsn = buf.getLong();
        long endLsn = buf.getLong();
        int ts = buf.getInt();
        System.out.println("[DEBUG] Begin: finalLsn=" + lsn + " endLsn=" + endLsn + " ts=" + ts);
    }

    private void decodeRelation(ByteBuffer buf) {
        int oid = buf.getInt();
        String schema = readCString(buf);
        String table = readCString(buf);
        buf.get();
        int colCount = buf.getShort() & 0xFFFF;
        List<String> names = new ArrayList<>(colCount);
        for (int i = 0; i < colCount; i++) {
            buf.get();
            names.add(readCString(buf));
            buf.getInt(); buf.getInt();
        }
        relations.put(oid, new RelationInfo(schema, table, names));
        System.out.println("[DEBUG] Relation: oid=" + oid + " " + schema + "." + table + " cols=" + names);
    }

    private void decodeInsert(ByteBuffer buf) {
        int oid = buf.getInt();
        buf.get();
        var rel = relations.get(oid);
        if (rel == null) { skipTuple(buf); return; }
        var values = decodeTuple(buf, rel.columnNames().size());
        if (values != null) {
            batch.add(new Change(rel.schema(), rel.table(), rel.columnNames(), values, "i"));
            System.out.println("[DEBUG] Insert: " + rel.schema() + "." + rel.table() + " " + zipCols(rel.columnNames(), values));
        }
    }

    private void decodeUpdate(ByteBuffer buf) {
        int oid = buf.getInt();
        var rel = relations.get(oid);
        if (rel == null) { skipOldTuple(buf); buf.get(); skipTuple(buf); return; }
        skipOldTuple(buf);
        buf.get();
        var values = decodeTuple(buf, rel.columnNames().size());
        if (values != null) {
            batch.add(new Change(rel.schema(), rel.table(), rel.columnNames(), values, "u"));
            System.out.println("[DEBUG] Update: " + rel.schema() + "." + rel.table() + " " + zipCols(rel.columnNames(), values));
        }
    }

    private void decodeDelete(ByteBuffer buf) {
        int oid = buf.getInt();
        var rel = relations.get(oid);
        if (rel == null) { buf.get(); skipTuple(buf); return; }
        byte tupleType = buf.get();
        if (tupleType == 'N') return;
        var values = decodeTuple(buf, rel.columnNames().size());
        if (values != null) {
            batch.add(new Change(rel.schema(), rel.table(), rel.columnNames(), values, "d"));
            System.out.println("[DEBUG] Delete: " + rel.schema() + "." + rel.table() + " " + zipCols(rel.columnNames(), values));
        }
    }

    private void skipTuple(ByteBuffer buf) {
        int colCount = buf.getShort() & 0xFFFF;
        for (int i = 0; i < colCount; i++) {
            skipColumn(buf);
        }
    }

    private void skipOldTuple(ByteBuffer buf) {
        while (buf.remaining() > 0) {
            byte b = buf.get(buf.position());
            if (b == 'N') return;
            buf.get();
            if (b == 'K' || b == 'O') {
                int colCount = buf.getShort() & 0xFFFF;
                for (int i = 0; i < colCount; i++) {
                    skipColumn(buf);
                }
            }
        }
    }

    private List<String> decodeTuple(ByteBuffer buf, int colCount) {
        int actualCols = buf.getShort() & 0xFFFF;
        if (actualCols != colCount) return null;
        var values = new ArrayList<String>(colCount);
        for (int i = 0; i < colCount; i++) {
            values.add(readColumn(buf));
        }
        return values;
    }

    private String readColumn(ByteBuffer buf) {
        byte type = buf.get();
        return switch (type) {
            case 'n' -> null;
            case 't' -> {
                int len = buf.getInt();
                byte[] bytes = new byte[len];
                buf.get(bytes);
                yield new String(bytes, StandardCharsets.UTF_8);
            }
            case 'b' -> {
                int len = buf.getInt();
                buf.position(buf.position() + len);
                yield null;
            }
            case 'u' -> null;
            default -> null;
        };
    }

    private void skipColumn(ByteBuffer buf) {
        byte type = buf.get();
        if (type == 't' || type == 'b') {
            int len = buf.getInt();
            buf.position(buf.position() + len);
        }
    }

    private void decodeCommit(ByteBuffer buf) {
        long flags = buf.getLong();
        long lsn = buf.getLong();
        long endLsn = buf.getLong();
        long ts = buf.getLong();
        System.out.println("[DEBUG] Commit: flags=" + flags + " lsn=" + lsn + " endLsn=" + endLsn + " ts=" + ts);
    }

    private void decodeOrigin(ByteBuffer buf) {
        long originLsn = buf.getLong();
        String originName = readCString(buf);
        System.out.println("[DEBUG] Origin: lsn=" + originLsn + " name=" + originName);
    }

    private String zipCols(List<String> names, List<String> values) {
        var sb = new StringBuilder("{");
        for (int i = 0; i < names.size(); i++) {
            if (i > 0) sb.append(", ");
            sb.append(names.get(i)).append("=").append(values.get(i));
        }
        sb.append("}");
        return sb.toString();
    }

    private String readCString(ByteBuffer buf) {
        int start = buf.position();
        while (buf.get() != 0);
        int end = buf.position() - 1;
        byte[] bytes = new byte[end - start];
        buf.position(start);
        buf.get(bytes);
        buf.get();
        return new String(bytes, StandardCharsets.UTF_8);
    }
}
