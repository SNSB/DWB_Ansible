FROM mcr.microsoft.com/mssql/server:2022-latest

USER root

ENV ACCEPT_EULA=Y \
    MSSQL_AGENT_ENABLED=True \
    MSSQL_PID=Developer \
    MSSQL_DATA_DIR=/var/opt/mssql/data \
    MSSQL_BACKUP_DIR=/var/opt/mssql/backup

# Create the mount points up front (compose will bind-mount over these)
RUN mkdir -p /var/opt/mssql/data /var/opt/mssql/backup && \
    chown -R mssql:mssql /var/opt/mssql

# App files: entrypoint wrapper, T-SQL setup scripts, and the sa toggle helper
COPY entrypoint.sh /usr/src/app/entrypoint.sh
COPY setup-admin-login.sql /usr/src/app/setup-admin-login.sql
COPY setup-backup-job.sql /usr/src/app/setup-backup-job.sql
COPY toggle-sa.sh /usr/src/app/toggle-sa.sh
RUN chmod +x /usr/src/app/entrypoint.sh /usr/src/app/toggle-sa.sh

ENTRYPOINT ["/usr/src/app/entrypoint.sh"]
