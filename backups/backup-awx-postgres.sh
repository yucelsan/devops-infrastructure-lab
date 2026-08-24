#!/usr/bin/env bash
#
# ==============================================================================
#  Name         : backup-awx-postgres.sh
#  Project      : DevOps Lab Automation
#  Module       : AWX / PostgreSQL
#
#  Description  :
#      Creates daily PostgreSQL backups for two AWX environments.
#
#      The script:
#          - Creates compressed PostgreSQL dumps using custom format
#          - Applies secure file permissions
#          - Prevents concurrent executions using flock
#          - Keeps backups for a configurable retention period
#          - Writes execution details to a log file
#
#  Version      : 1.0.0
#
#  Compatibility:
#      - Red Hat Enterprise Linux 8 / 9 / 10
#      - PostgreSQL
#
#  Usage:
#      chmod +x backup-awx-postgres.sh
#      ./backup-awx-postgres.sh
#
#  Suggested schedule:
#      15 2 * * * /usr/local/bin/backup-awx-postgres.sh
#
# ==============================================================================

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


# ==============================================================================
# CONFIGURATION
# ==============================================================================

DATE="$(date '+%Y-%m-%d_%H-%M-%S')"

BACKUP_DIR="${BACKUP_DIR:-/opt/lab/backups/postgres}"

LOG_FILE="${LOG_FILE:-/var/log/backup-awx-postgres.log}"

LOCK_FILE="${LOCK_FILE:-/tmp/backup-awx-postgres.lock}"

PG_USER="${PG_USER:-postgres}"

RETENTION_DAYS="${RETENTION_DAYS:-15}"


# ==============================================================================
# AWX DATABASES
# ==============================================================================

AWX_FIRST_DATABASE="${AWX_FIRST_DATABASE:-awxdb_130}"

AWX_SECOND_DATABASE="${AWX_SECOND_DATABASE:-awxdb_134}"

DATABASES=(
    "$AWX_FIRST_DATABASE"
    "$AWX_SECOND_DATABASE"
)


# ==============================================================================
# LOGGING
# ==============================================================================

log()
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}


# ==============================================================================
# COMMAND VALIDATION
# ==============================================================================

require_cmd()
{
    local CMD="$1"

    if ! command -v "$CMD" >/dev/null 2>&1; then

        echo "ERROR: required command not found: $CMD" >&2

        exit 1
    fi
}


# ==============================================================================
# PRECHECKS
# ==============================================================================

require_cmd pg_dump
require_cmd pg_restore
require_cmd sudo
require_cmd flock
require_cmd find


# ==============================================================================
# DIRECTORY / LOG INITIALIZATION
# ==============================================================================

mkdir -p "$BACKUP_DIR"

touch "$LOG_FILE"


chown root:postgres "$BACKUP_DIR"
chmod 750 "$BACKUP_DIR"

chown root:postgres "$LOG_FILE"
chmod 640 "$LOG_FILE"


# ==============================================================================
# SELINUX CONTEXT RESTORE
# ==============================================================================

if command -v restorecon >/dev/null 2>&1; then

    restorecon -Rv "$BACKUP_DIR" >/dev/null 2>&1 || true
    restorecon -F "$LOG_FILE" >/dev/null 2>&1 || true

fi


# ==============================================================================
# LOCK
# ==============================================================================

exec 200>"$LOCK_FILE"

if ! flock -n 200; then

    log "Another PostgreSQL backup is already running. Exiting."

    exit 0
fi


# ==============================================================================
# START
# ==============================================================================

echo >> "$LOG_FILE"
echo "--------------------------------------------------------------------------" >> "$LOG_FILE"

log "===== Start AWX PostgreSQL backup ====="


# ==============================================================================
# BACKUP DATABASES
# ==============================================================================

for DB in "${DATABASES[@]}"; do

    OUT_FILE="${BACKUP_DIR}/${DB}_${DATE}.dump"

    log "Backing up database $DB -> $OUT_FILE"


    if sudo -u "$PG_USER" \
        pg_dump \
        -Fc \
        "$DB" \
        > "$OUT_FILE"
    then

        chown root:postgres "$OUT_FILE"
        chmod 640 "$OUT_FILE"


        if command -v restorecon >/dev/null 2>&1; then
            restorecon -F "$OUT_FILE" >/dev/null 2>&1 || true
        fi


        # ----------------------------------------------------------------------
        # Integrity check
        # ----------------------------------------------------------------------

        if pg_restore -l "$OUT_FILE" >/dev/null 2>&1; then

            log "OK: backup completed and validated for $DB"

        else

            log "ERROR: backup created but validation failed for $DB"

            rm -f "$OUT_FILE"

            exit 1
        fi

    else

        log "ERROR: backup failed for $DB"

        rm -f "$OUT_FILE"

        exit 1

    fi

done


# ==============================================================================
# RETENTION
# ==============================================================================

log "Removing backups older than ${RETENTION_DAYS} days"


find "$BACKUP_DIR" \
    -type f \
    -name "*.dump" \
    -mtime "+${RETENTION_DAYS}" \
    -print \
    -delete \
    >> "$LOG_FILE" \
    2>&1 \
    || true


# ==============================================================================
# BACKUP LIST
# ==============================================================================

log "Current backups:"


ls -lh "$BACKUP_DIR" \
    >> "$LOG_FILE" \
    2>&1


# ==============================================================================
# END
# ==============================================================================

log "===== End AWX PostgreSQL backup ====="

echo "--------------------------------------------------------------------------" >> "$LOG_FILE"
echo >> "$LOG_FILE"

