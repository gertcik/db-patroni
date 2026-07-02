package com.audit.consumer;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.List;

public class TestUtil {

    public static ByteBuffer relation(int oid, String schema, String table, List<String> columns) {
        var buf = ByteBuffer.allocate(2048);
        buf.put((byte) 'r');
        buf.putInt(oid);
        writeCString(buf, schema);
        writeCString(buf, table);
        buf.put((byte) 0);
        buf.putShort((short) columns.size());
        for (var col : columns) {
            buf.put((byte) 0);
            writeCString(buf, col);
            buf.putInt(25);
            buf.putInt(-1);
        }
        buf.flip();
        return buf;
    }

    public static ByteBuffer insert(int oid, List<String> values) {
        var buf = ByteBuffer.allocate(2048);
        buf.put((byte) 'i');
        buf.putInt(oid);
        buf.put((byte) 'N');
        writeTuple(buf, values);
        buf.flip();
        return buf;
    }

    public static ByteBuffer update(int oid, List<String> newValues) {
        var buf = ByteBuffer.allocate(2048);
        buf.put((byte) 'u');
        buf.putInt(oid);
        buf.put((byte) 'N');
        writeTuple(buf, newValues);
        buf.flip();
        return buf;
    }

    public static ByteBuffer delete(int oid, List<String> oldValues) {
        var buf = ByteBuffer.allocate(2048);
        buf.put((byte) 'd');
        buf.putInt(oid);
        buf.put((byte) 'O');
        writeTuple(buf, oldValues);
        buf.flip();
        return buf;
    }

    public static ByteBuffer truncate() {
        var buf = ByteBuffer.allocate(16);
        buf.put((byte) 't');
        buf.putInt(1);
        buf.putInt(0);
        buf.putInt(123);
        buf.flip();
        return buf;
    }

    static void writeCString(ByteBuffer buf, String s) {
        byte[] bytes = s.getBytes(StandardCharsets.UTF_8);
        buf.put(bytes);
        buf.put((byte) 0);
    }

    private static void writeTuple(ByteBuffer buf, List<String> values) {
        buf.putShort((short) values.size());
        for (var v : values) {
            if (v == null) {
                buf.put((byte) 'n');
            } else {
                buf.put((byte) 't');
                byte[] bytes = v.getBytes(StandardCharsets.UTF_8);
                buf.putInt(bytes.length);
                buf.put(bytes);
            }
        }
    }
}
