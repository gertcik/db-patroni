FROM postgres:17

RUN mkdir -p /sql
COPY init-audit.sql /sql/init-audit.sql
COPY entrypoint.sh /usr/local/bin/audit-entrypoint.sh
RUN chmod +x /usr/local/bin/audit-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/audit-entrypoint.sh"]
CMD ["postgres"]
