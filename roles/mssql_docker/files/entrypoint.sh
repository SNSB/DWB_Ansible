#!/bin/bash
set -e

: "${ADMIN_LOGIN:?ADMIN_LOGIN must be set}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD must be set}"
: "${DISABLE_SA:=true}"

# Bind-mounted host folders come in owned by the host UID, not "mssql" (uid 10001).
# Fix that every start, since it's cheap and avoids permission errors.
chown -R mssql:mssql /var/opt/mssql/data /var/opt/mssql/backup /var/opt/mssql/log /var/opt/mssql/secrets || true

# Start SQL Server itself as the unprivileged "mssql" user, in the background.
su mssql -c "/opt/mssql/bin/sqlservr" &
SQLSERVR_PID=$!

# Locate sqlcmd (path differs between mssql-tools and mssql-tools18 images)
if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
    SQLCMD="/opt/mssql-tools18/bin/sqlcmd -C"
elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then
    SQLCMD="/opt/mssql-tools/bin/sqlcmd"
else
    echo "sqlcmd not found" >&2
    exit 1
fi

# --- Wait for the server, authenticating with whichever login currently works ---
# First boot: only "sa" exists yet, so that's what succeeds.
# Later restarts: sa may already be disabled, so ADMIN_LOGIN is what succeeds.
echo "Waiting for SQL Server to come online..."
BOOT_USER=""
BOOT_PASS=""
for i in $(seq 1 90); do
    if $SQLCMD -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Q "SELECT 1" -b >/dev/null 2>&1; then
        BOOT_USER="sa"
        BOOT_PASS="$MSSQL_SA_PASSWORD"
        break
    fi
    if $SQLCMD -S localhost -U "$ADMIN_LOGIN" -P "$ADMIN_PASSWORD" -Q "SELECT 1" -b >/dev/null 2>&1; then
        BOOT_USER="$ADMIN_LOGIN"
        BOOT_PASS="$ADMIN_PASSWORD"
        break
    fi
    sleep 1
done

if [ -z "$BOOT_USER" ]; then
    echo "Could not authenticate with either sa or $ADMIN_LOGIN within the timeout." >&2
    exit 1
fi
echo "Connected as $BOOT_USER."

# --- Ensure the sysadmin management login exists ---
echo "Creating/verifying management login [$ADMIN_LOGIN]..."
$SQLCMD -S localhost -U "$BOOT_USER" -P "$BOOT_PASS" \
    -v AdminLogin="$ADMIN_LOGIN" -v AdminPassword="$ADMIN_PASSWORD" \
    -i /usr/src/app/setup-admin-login.sql

# --- Verify the new login actually works before touching sa ---
ADMIN_OK=0
if $SQLCMD -S localhost -U "$ADMIN_LOGIN" -P "$ADMIN_PASSWORD" -Q "SELECT 1" -b >/dev/null 2>&1; then
    ADMIN_OK=1
    echo "[$ADMIN_LOGIN] verified working."
else
    echo "WARNING: could not authenticate as [$ADMIN_LOGIN] after creation; leaving sa untouched." >&2
fi

# --- Disable sa, only once the replacement login is confirmed working ---
if [ "$ADMIN_OK" = "1" ] && [ "$DISABLE_SA" = "true" ]; then
    SA_ENABLED=$($SQLCMD -S localhost -U "$ADMIN_LOGIN" -P "$ADMIN_PASSWORD" -h -1 \
        -Q "SET NOCOUNT ON; SELECT CASE WHEN is_disabled = 0 THEN 1 ELSE 0 END FROM sys.sql_logins WHERE name = 'sa';" \
        | tr -d '[:space:]')
    if [ "$SA_ENABLED" = "1" ]; then
        $SQLCMD -S localhost -U "$ADMIN_LOGIN" -P "$ADMIN_PASSWORD" -Q "ALTER LOGIN sa DISABLE;"
        echo "sa login disabled. Use toggle-sa.sh to re-enable it temporarily if a tool needs it."
    else
        echo "sa already disabled."
    fi
fi

# --- Run remaining setup (backup job) as the management login where possible ---
if [ "$ADMIN_OK" = "1" ]; then
    RUN_USER="$ADMIN_LOGIN"
    RUN_PASS="$ADMIN_PASSWORD"
else
    RUN_USER="$BOOT_USER"
    RUN_PASS="$BOOT_PASS"
fi

echo "Installing/verifying the daily backup job..."
$SQLCMD -S localhost -U "$RUN_USER" -P "$RUN_PASS" \
    -v AdminLogin="$ADMIN_LOGIN" \
    -i /usr/src/app/setup-backup-job.sql

echo "Setup complete. Handing off to SQL Server process."
wait "$SQLSERVR_PID"
