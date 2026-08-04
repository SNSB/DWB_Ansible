#!/bin/bash
# Temporarily enable or disable the sa login. Run from the host via:
#   docker exec -it mssql-server /usr/src/app/toggle-sa.sh enable
#   docker exec -it mssql-server /usr/src/app/toggle-sa.sh disable
#   docker exec -it mssql-server /usr/src/app/toggle-sa.sh status
set -e

ACTION="$1"
if [[ "$ACTION" != "enable" && "$ACTION" != "disable" && "$ACTION" != "status" ]]; then
    echo "Usage: $0 [enable|disable|status]" >&2
    exit 1
fi

if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
    SQLCMD="/opt/mssql-tools18/bin/sqlcmd -C"
elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then
    SQLCMD="/opt/mssql-tools/bin/sqlcmd"
else
    echo "sqlcmd not found" >&2
    exit 1
fi

if [ -z "$ADMIN_LOGIN" ] || [ -z "$ADMIN_PASSWORD" ]; then
    echo "ADMIN_LOGIN / ADMIN_PASSWORD not set in the container environment" >&2
    exit 1
fi

case "$ACTION" in
    status)
        $SQLCMD -S localhost -U "$ADMIN_LOGIN" -P "$ADMIN_PASSWORD" -h -1 \
            -Q "SET NOCOUNT ON; SELECT CASE WHEN is_disabled = 0 THEN 'ENABLED' ELSE 'DISABLED' END FROM sys.sql_logins WHERE name = 'sa';"
        ;;
    enable)
        $SQLCMD -S localhost -U "$ADMIN_LOGIN" -P "$ADMIN_PASSWORD" -Q "ALTER LOGIN sa ENABLE;"
        echo "sa ENABLED. Disable it again once the tool is done:"
        echo "  docker exec -it mssql-server /usr/src/app/toggle-sa.sh disable"
        ;;
    disable)
        $SQLCMD -S localhost -U "$ADMIN_LOGIN" -P "$ADMIN_PASSWORD" -Q "ALTER LOGIN sa DISABLE;"
        echo "sa DISABLED."
        ;;
esac
