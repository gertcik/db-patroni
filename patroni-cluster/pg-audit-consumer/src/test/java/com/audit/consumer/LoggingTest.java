package com.audit.consumer;

import org.apache.logging.log4j.Level;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.apache.logging.log4j.core.LogEvent;
import org.apache.logging.log4j.core.LoggerContext;
import org.apache.logging.log4j.core.appender.AbstractAppender;
import org.apache.logging.log4j.core.config.Configuration;
import org.apache.logging.log4j.core.config.Property;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Проверки log4j-конфигурации: уровень по умолчанию INFO, DEBUG-сообщения
 * декодера управляются уровнем, и после переработки в коде не осталось
 * прямых System.out.println.
 */
class LoggingTest {

    /** In-test appender: копит все дошедшие до корневого логгера события. */
    static final class CapturingAppender extends AbstractAppender {
        final List<LogEvent> events = new CopyOnWriteArrayList<>();

        CapturingAppender() {
            super("capturing", null, null, true, Property.EMPTY_ARRAY);
            start();
        }

        @Override
        public void append(LogEvent event) {
            events.add(event.toImmutable());
        }
    }

    private CapturingAppender appender;

    private LoggerContext ctx() {
        return (LoggerContext) LogManager.getContext(false);
    }

    @BeforeEach
    void setUp() {
        appender = new CapturingAppender();
        Configuration config = ctx().getConfiguration();
        config.addAppender(appender);
        config.getRootLogger().addAppender(appender, null, null);
        ctx().updateLoggers();
    }

    @AfterEach
    void tearDown() {
        // возвращаем заводское поведение: корневой уровень INFO, appender удалён
        org.apache.logging.log4j.core.config.Configurator.setLevel(
                LogManager.getRootLogger().getName(), Level.INFO);
        removeAppender();
    }

    private void removeAppender() {
        Configuration config = ctx().getConfiguration();
        config.getRootLogger().removeAppender("capturing");
        ctx().updateLoggers();
    }

    private void setLevel(Level level) {
        org.apache.logging.log4j.core.config.Configurator.setLevel(
                LogManager.getRootLogger().getName(), level);
    }

    private static void decodeTestInsert() {
        var decoder = new PgOutputDecoder();
        decoder.decode(TestUtil.relation(1, "public", "test_table", List.of("x")));
        decoder.decode(TestUtil.insert(1, List.of("a")));
    }

    @Test
    void defaultRootLevelIsInfo() {
        assertEquals(Level.INFO, LogManager.getRootLogger().getLevel(),
                "log4j2.xml должен задавать корневой уровень INFO по умолчанию");
    }

    @Test
    void debugLoggedWhenDebugEnabled() {
        setLevel(Level.DEBUG);
        decodeTestInsert();

        assertTrue(appender.events.stream().anyMatch(e ->
                        e.getLevel() == Level.DEBUG && e.getMessage().getFormattedMessage().contains("Insert: public.test_table")),
                "на уровне DEBUG событие Insert должно попадать в лог");
    }

    @Test
    void debugSuppressedAtInfoLevel() {
        setLevel(Level.INFO);
        decodeTestInsert();

        assertFalse(appender.events.stream().anyMatch(e -> e.getLevel() == Level.DEBUG),
                "на уровне INFO по умолчанию debug-события декодера не логируются");
    }

    @Test
    void infoMessagesGoThroughLog4j() {
        setLevel(Level.INFO);
        var decoder = new PgOutputDecoder();
        decoder.decode(TestUtil.truncate());
        // TRUNCATE сам по себе ничего не логирует на INFO — проверим INFO-путь на простом событии
        LogManager.getLogger(LoggingTest.class).info("info-{}-probe", "message");
        var dumped = new StringBuilder();
        appender.events.forEach(e -> dumped
                .append(e.getLevel()).append(' ')
                .append(e.getLoggerName()).append(": ")
                .append(e.getMessage().getFormattedMessage()).append('\n'));
        assertTrue(appender.events.stream().anyMatch(e ->
                        e.getLevel() == Level.INFO
                                && "info-message-probe".equals(e.getMessage().getFormattedMessage())
                                && e.getLoggerName().equals(LoggingTest.class.getName())),
                "INFO-сообщения должны проходить через log4j. Получено:\n" + dumped);
    }

    @Test
    void decodeProducesNoDirectSystemOut() {
        setLevel(Level.OFF); // глушим и log4j: в stdout не должно остаться НИЧЕГО

        var out = new ByteArrayOutputStream();
        PrintStream original = System.out;
        System.setOut(new PrintStream(out, true, StandardCharsets.UTF_8));
        try {
            decodeTestInsert();
        } finally {
            System.setOut(original);
        }

        assertEquals("", out.toString(StandardCharsets.UTF_8),
                "декодер не должен писать в stdout напрямую — только через log4j");
    }

    @Test
    void walMessageHexDumpOnlyAtDebug() throws Exception {
        // logWalMessage должен быть бесплатным на уровнях выше DEBUG
        setLevel(Level.INFO);
        var buf = ByteBuffer.allocate(4);
        buf.put((byte) 'r').put((byte) 1).put((byte) 2).put((byte) 3);
        buf.flip();
        App.logWalMessage(buf); // не падает и не пишет в лог
        assertFalse(appender.events.stream().anyMatch(e -> e.getLevel() == Level.DEBUG));

        setLevel(Level.DEBUG);
        App.logWalMessage(buf.duplicate());
        assertTrue(appender.events.stream().anyMatch(e ->
                        e.getLevel() == Level.DEBUG && e.getMessage().getFormattedMessage().contains("WAL msg")),
                "на DEBUG hex-дамп WAL-сообщения логируется");
    }
}
