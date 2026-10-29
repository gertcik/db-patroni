package com.audit.consumer;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

/** Проверки статических хелперов App. */
class AppTest {

    @Test
    void sourceUrlBuildsJdbcUrl() {
        var cfg = new App.Config(
                "haproxy", "5432", "shop",
                "postgres", "secret",
                "audit_slot", "shop_pub",
                "pg-audit-log", "5432", "shop",
                "postgres", "secret"
        );
        assertEquals("jdbc:postgresql://haproxy:5432/shop", App.sourceUrl(cfg));
    }

    @Test
    void envFallsBackToDefaultWhenVarUnset() {
        assertEquals("fallback-value",
                App.env("AUDIT_CONSUMER_TEST_VAR_DEFINITELY_NOT_SET", "fallback-value"));
        assertEquals("5432", App.env("AUDIT_CONSUMER_TEST_EMPTY_PORT", "5432"));
    }

    @Test
    void loadConfigUsesDefaultsWhenNoEnv() {
        // В тестовой JVM переменные окружения consumer не заданы → все значения по умолчанию
        var cfg = App.loadConfig();
        assertEquals("haproxy", cfg.sourceHost());
        assertEquals("5432", cfg.sourcePort());
        assertEquals("shop", cfg.sourceDb());
        assertEquals("audit_slot", cfg.slotName());
        assertEquals("shop_pub", cfg.publicationName());
        assertEquals("pg-audit-log", cfg.targetHost());
        assertEquals("shop", cfg.targetDb());
    }
}
