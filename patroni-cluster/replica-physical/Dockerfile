# ═══════════════════════════════════════════════════════════════
# Физическая реплика PostgreSQL 18
# Кастомный entrypoint: pg_basebackup + symlink + streaming standby
# ═══════════════════════════════════════════════════════════════
FROM postgres:18

COPY entrypoint.sh /usr/local/bin/replica-entrypoint.sh
RUN chmod +x /usr/local/bin/replica-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/replica-entrypoint.sh"]
CMD ["postgres"]
