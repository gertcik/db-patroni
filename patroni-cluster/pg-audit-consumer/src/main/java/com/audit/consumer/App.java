package com.audit.consumer;

import org.postgresql.PGConnection;
import org.postgresql.replication.PGReplicationStream;

import java.nio.ByteBuffer;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.Properties;

/**
 * WAL consumer: reads logical replication changes from the source (Patroni master
 * via HAProxy), transforms UPDATE/DELETE into INSERT, and writes append-only rows
 * with audit metadata to pg-audit-log.
 *
 * The replication slot 'audit_slot' is managed by Patroni as a permanent DCS slot.
 * This consumer only waits for it to exist, then starts streaming.
 */
public class App {

    static final String SOURCE_URL = "jdbc:postgresql://%s:%s/%s?replication=database";
    static final long RECONNECT_DELAY_MS = 5000;
    static final long SLOT_WAIT_DELAY_MS = 3000;

    public static void main(String[] args) {
        var config = loadConfig();
        while (true) {
            try {
                run(config);
            } catch (Exception e) {
                System.err.println("[ERROR] " + e.getMessage());
                e.printStackTrace();
                System.err.println("[INFO] Reconnecting in " + RECONNECT_DELAY_MS + "ms...");
                try { Thread.sleep(RECONNECT_DELAY_MS); } catch (InterruptedException ie) { Thread.currentThread().interrupt(); break; }
            }
        }
    }

    static Config loadConfig() {
        return new Config(
                env("SOURCE_HOST", "haproxy"),
                env("SOURCE_PORT", "5432"),
                env("SOURCE_DB", "shop"),
                env("SOURCE_USER", "postgres"),
                env("SOURCE_PASSWORD", "secret"),
                env("SLOT_NAME", "audit_slot"),
                env("PUBLICATION_NAME", "shop_pub"),
                env("TARGET_HOST", "pg-audit-log"),
                env("TARGET_PORT", "5432"),
                env("TARGET_DB", "shop"),
                env("TARGET_USER", "postgres"),
                env("TARGET_PASSWORD", "secret")
        );
    }

    static String env(String key, String def) {
        var val = System.getenv(key);
        return val != null ? val : def;
    }

    static void run(Config cfg) throws Exception {
        System.out.println("[INFO] Starting WAL consumer...");
        System.out.println("[INFO] Source: " + cfg.sourceHost + ":" + cfg.sourcePort + "/" + cfg.sourceDb);
        System.out.println("[INFO] Slot: " + cfg.slotName);
        System.out.println("[INFO] Target: " + cfg.targetHost + ":" + cfg.targetPort + "/" + cfg.targetDb);

        waitForSlot(cfg);

        var writer = connectTarget(cfg);

        try (writer) {
            var decoder = new PgOutputDecoder();

            String url = String.format(SOURCE_URL, cfg.sourceHost, cfg.sourcePort, cfg.sourceDb);
            var props = new Properties();
            props.setProperty("user", cfg.sourceUser);
            props.setProperty("password", cfg.sourcePassword);
            props.setProperty("assumeMinServerVersion", "18");

            try (var replicationConn = DriverManager.getConnection(url, props)) {
                PGConnection pgConn = replicationConn.unwrap(PGConnection.class);

                PGReplicationStream stream = pgConn.getReplicationAPI()
                        .replicationStream()
                        .logical()
                        .withSlotName(cfg.slotName)
                        .withSlotOption("proto_version", "1")
                        .withSlotOption("publication_names", cfg.publicationName)
                        .start();

                System.out.println("[INFO] Replication stream started from LSN: " + stream.getLastReceiveLSN());

                try (stream) {
                    while (true) {
                        ByteBuffer msg = stream.read();
                        logWalMessage(msg);
                        decoder.decode(msg);

                        var batch = decoder.getBatch();
                        if (!batch.isEmpty()) {
                            writer.writeBatch(batch);
                            System.out.println("[INFO] Applied " + batch.size() + " changes at LSN " + stream.getLastReceiveLSN());
                            batch.clear();
                        }

                        stream.setFlushedLSN(stream.getLastReceiveLSN());
                        stream.forceUpdateStatus();
                    }
                }
            }
        }
    }

    static AuditWriter connectTarget(Config cfg) throws InterruptedException {
        while (true) {
            try {
                return new AuditWriter(
                        "jdbc:postgresql://" + cfg.targetHost + ":" + cfg.targetPort + "/" + cfg.targetDb,
                        cfg.targetUser, cfg.targetPassword
                );
            } catch (SQLException e) {
                System.err.println("[ERROR] Cannot connect to audit target: " + e.getMessage());
                System.out.println("[INFO] Retrying target connection in " + RECONNECT_DELAY_MS + "ms...");
                Thread.sleep(RECONNECT_DELAY_MS);
            }
        }
    }

    static void logWalMessage(ByteBuffer msg) {
        ByteBuffer dup = msg.duplicate();
        byte[] bytes = new byte[dup.remaining()];
        dup.get(bytes);
        var hex = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) hex.append(String.format("%02x", b & 0xFF));
        System.out.println("[DEBUG] WAL msg (" + bytes.length + " bytes): " + hex);
    }

    static void waitForSlot(Config cfg) throws Exception {
        String mgmtUrl = "jdbc:postgresql://" + cfg.sourceHost + ":" + cfg.sourcePort + "/" + cfg.sourceDb;
        while (true) {
            try (var mgmtConn = DriverManager.getConnection(mgmtUrl, cfg.sourceUser, cfg.sourcePassword);
                 var stmt = mgmtConn.createStatement();
                 ResultSet rs = stmt.executeQuery(
                         "SELECT 1 FROM pg_replication_slots WHERE slot_name = '" + cfg.slotName + "'")) {
                if (rs.next()) {
                    System.out.println("[INFO] Slot '" + cfg.slotName + "' is ready");
                    return;
                }
            }
            System.out.println("[INFO] Slot '" + cfg.slotName + "' not yet created by Patroni, retrying in " + SLOT_WAIT_DELAY_MS + "ms...");
            Thread.sleep(SLOT_WAIT_DELAY_MS);
        }
    }

    record Config(
            String sourceHost, String sourcePort, String sourceDb,
            String sourceUser, String sourcePassword,
            String slotName, String publicationName,
            String targetHost, String targetPort, String targetDb,
            String targetUser, String targetPassword
    ) {}
}
