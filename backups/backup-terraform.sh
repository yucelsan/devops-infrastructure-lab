#!/usr/bin/env bash
#
# ==============================================================================
#  Name         : backup-terraform.sh
#  Project      : DevOps Lab Automation
#  Module       : Terraform
#
#  Description  :
#      Creates a compressed backup of a Terraform working directory.
#
#      The script:
#          - Archives Terraform configuration and state-related files
#          - Excludes temporary or regenerable directories
#          - Validates the generated ZIP archive
#          - Applies configurable backup retention
#          - Prevents concurrent executions with flock
#
#  Version      : 1.0.0
#
#  Compatibility:
#      - Red Hat Enterprise Linux 8 / 9 / 10
#
#  Usage:
#      chmod +x backup-terraform.sh
#      ./backup-terraform.sh
#
#  Suggested schedule:
#      0 2 * * * /usr/local/bin/backup-terraform.sh
#
# ==============================================================================

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


# ==============================================================================
# CONFIGURATION
# ==============================================================================

SOURCE_DIR="${SOURCE_DIR:-/opt/terraform}"

BACKUP_DIR="${BACKUP_DIR:-/opt/lab/backups/terraform}"

RETENTION_DAYS="${RETENTION_DAYS:-15}"

LOCK_FILE="${LOCK_FILE:-/tmp/backup-terraform.lock}"

DATE="$(date '+%Y-%m-%d_%H-%M-%S')"

ARCHIVE="${BACKUP_DIR}/terraform-${DATE}.zip"


# ==============================================================================
# LOGGING
# ==============================================================================

log()
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}


# ==============================================================================
# COMMAND VALIDATION
# ==============================================================================

require_cmd()
{
    local CMD="$1"

    if ! command -v "$CMD" >/dev/null 2>&1; then
        log "ERROR: required command not found: $CMD"
        exit 1
    fi
}


# ==============================================================================
# PRECHECKS
# ==============================================================================

require_cmd zip
require_cmd unzip
require_cmd find
require_cmd flock


if [[ ! -d "$SOURCE_DIR" ]]; then
    log "ERROR: Terraform source directory not found: $SOURCE_DIR"
    exit 1
fi


mkdir -p "$BACKUP_DIR"


# ==============================================================================
# LOCK
# ==============================================================================

exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    log "Another Terraform backup is already running. Exiting."
    exit 0
fi


# ==============================================================================
# BACKUP
# ==============================================================================

log "Starting Terraform backup"
log "Source      : $SOURCE_DIR"
log "Destination : $ARCHIVE"


zip -rq \
    "$ARCHIVE" \
    "$SOURCE_DIR" \
    -x \
        "*/.git/*" \
        "*/.terraform/*" \
        "*/node_modules/*" \
        "*/download/*" \
        "*.log" \
        "*.backup" \
        "*.~" \
        "*~"


# ==============================================================================
# VALIDATION
# ==============================================================================

if [[ ! -s "$ARCHIVE" ]]; then
    log "ERROR: generated archive is empty"
    rm -f "$ARCHIVE"
    exit 1
fi


if unzip -tq "$ARCHIVE" >/dev/null 2>&1; then
    log "Archive validation successful"
else
    log "ERROR: ZIP archive validation failed"
    rm -f "$ARCHIVE"
    exit 1
fi


# ==============================================================================
# RETENTION
# ==============================================================================

log "Removing backups older than ${RETENTION_DAYS} days"


find "$BACKUP_DIR" \
    -type f \
    -name 'terraform-*.zip' \
    -mtime "+${RETENTION_DAYS}" \
    -print \
    -delete


# ==============================================================================
# END
# ==============================================================================

ARCHIVE_SIZE="$(
    du -h "$ARCHIVE" \
        2>/dev/null \
        | awk '{print $1}'
)"


log "Terraform backup completed successfully"
log "Archive : $ARCHIVE"
log "Size    : ${ARCHIVE_SIZE:-unknown}"

