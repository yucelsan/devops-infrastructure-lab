#!/usr/bin/env bash
#
# ==============================================================================
#  Name         : backup-awx-full.sh
#  Project      : DevOps Lab Automation
#  Module       : AWX / Kubernetes / Kind / PostgreSQL / NGINX
#
#  Description  :
#      Creates a full backup of two AWX Kubernetes lab clusters.
#
#      The backup includes:
#
#          - AWX Kubernetes resources
#          - Kubernetes namespaces and nodes
#          - PostgreSQL database dumps
#          - Full PostgreSQL cluster dump
#          - AWX / Kind working directories
#          - NGINX reverse-proxy configuration
#          - AWX cluster switching script
#
#      Only one AWX cluster is active at a time.
#
#      The script:
#
#          1. Detects the currently active AWX cluster.
#          2. Backs up the active cluster.
#          3. Switches to the standby cluster.
#          4. Backs up the second cluster.
#          5. Restores the cluster that was active initially.
#          6. Compresses the backup.
#          7. Removes expired backup archives.
#
#  Version      : 1.0.0
#
#  Compatibility:
#      - Red Hat Enterprise Linux 8 / 9 / 10
#      - Docker
#      - Kind
#      - Kubernetes
#      - PostgreSQL
#      - NGINX
#
#  Usage:
#
#      chmod +x backup-awx-full.sh
#      ./backup-awx-full.sh
#
#  Suggested schedule:
#
#      30 3 * * 0 /usr/local/bin/backup-awx-full.sh
#
# ==============================================================================

set -euo pipefail


# ==============================================================================
# ENVIRONMENT
# ==============================================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"


# ==============================================================================
# GENERAL CONFIGURATION
# ==============================================================================

DATE="$(date '+%Y-%m-%d_%H-%M-%S')"

BASE_BACKUP_DIR="${BASE_BACKUP_DIR:-/opt/lab/backups/awx}"

WORK_DIR="${BASE_BACKUP_DIR}/${DATE}"

SWITCH_SCRIPT="${SWITCH_SCRIPT:-/usr/local/bin/switch-awx.sh}"

NGINX_AWX_CONF="${NGINX_AWX_CONF:-/etc/nginx/conf.d/awx.conf}"

BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"


# ==============================================================================
# FIRST AWX CLUSTER
#
# Kubernetes v1.30
# ==============================================================================

AWX_FIRST_CONTEXT="${AWX_FIRST_CONTEXT:-kind-awx-130}"

AWX_FIRST_KUBE_CMD="${AWX_FIRST_KUBE_CMD:-kubectl}"

AWX_FIRST_DATABASE="${AWX_FIRST_DATABASE:-awxdb_130}"

AWX_FIRST_WORKDIR="${AWX_FIRST_WORKDIR:-/opt/awx-kind-130}"

AWX_FIRST_BACKUP_NAME="awx-130"


# ==============================================================================
# SECOND AWX CLUSTER
#
# Kubernetes v1.34
# ==============================================================================

AWX_SECOND_CONTEXT="${AWX_SECOND_CONTEXT:-kind-awx-134}"

AWX_SECOND_KUBE_CMD="${AWX_SECOND_KUBE_CMD:-kube-latest}"

AWX_SECOND_DATABASE="${AWX_SECOND_DATABASE:-awxdb_134}"

AWX_SECOND_WORKDIR="${AWX_SECOND_WORKDIR:-/opt/awx-kind-134}"

AWX_SECOND_BACKUP_NAME="awx-134"


# ==============================================================================
# RUNTIME STATE
# ==============================================================================

INITIAL_MODE=""
CURRENT_MODE=""


# ==============================================================================
# LOGGING
# ==============================================================================

log()
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
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
# DETECT CURRENT ACTIVE CLUSTER
# ==============================================================================

detect_current_mode()
{
    local STATUS_OUTPUT

    STATUS_OUTPUT="$(
        "$SWITCH_SCRIPT" status \
        2>/dev/null \
        || true
    )"


    if grep -q \
        "Active cluster : FIRST" \
        <<< "$STATUS_OUTPUT"
    then

        echo "first"
        return 0
    fi


    if grep -q \
        "Active cluster : SECOND" \
        <<< "$STATUS_OUTPUT"
    then

        echo "second"
        return 0
    fi


    echo "unknown"
}


# ==============================================================================
# SWITCH CLUSTER
# ==============================================================================

switch_to()
{
    local MODE="$1"

    log "Switching AWX cluster -> $MODE"

    "$SWITCH_SCRIPT" "$MODE" >/dev/null

    CURRENT_MODE="$MODE"
}


# ==============================================================================
# GENERIC KUBERNETES BACKUP
# ==============================================================================

backup_kubernetes_cluster()
{
    local NAME="$1"
    local KUBE_CMD="$2"
    local CONTEXT="$3"
    local DATABASE="$4"

    local DESTINATION="${WORK_DIR}/${NAME}"


    log "Backing up Kubernetes cluster: $CONTEXT"


    mkdir -p "$DESTINATION"


    "$KUBE_CMD" \
        --context="$CONTEXT" \
        get awx \
        -n awx \
        -o yaml \
        > "${DESTINATION}/awx-cr.yaml"


    "$KUBE_CMD" \
        --context="$CONTEXT" \
        get all \
        -n awx \
        -o yaml \
        > "${DESTINATION}/awx-all.yaml"


    "$KUBE_CMD" \
        --context="$CONTEXT" \
        get secret \
        -n awx \
        -o yaml \
        > "${DESTINATION}/awx-secrets.yaml"


    "$KUBE_CMD" \
        --context="$CONTEXT" \
        get configmap \
        -n awx \
        -o yaml \
        > "${DESTINATION}/awx-configmaps.yaml"


    "$KUBE_CMD" \
        --context="$CONTEXT" \
        get ingress \
        -n awx \
        -o yaml \
        > "${DESTINATION}/awx-ingress.yaml"


    "$KUBE_CMD" \
        --context="$CONTEXT" \
        get service \
        -n awx \
        -o yaml \
        > "${DESTINATION}/awx-services.yaml"


    "$KUBE_CMD" \
        --context="$CONTEXT" \
        get namespace \
        -o yaml \
        > "${DESTINATION}/cluster-namespaces.yaml"


    "$KUBE_CMD" \
        --context="$CONTEXT" \
        get nodes \
        -o yaml \
        > "${DESTINATION}/cluster-nodes.yaml" \
        2>/dev/null \
        || true


    log "Dumping PostgreSQL database: $DATABASE"


    sudo -u postgres \
        pg_dump \
        "$DATABASE" \
        > "${DESTINATION}/${DATABASE}.sql"
}


# ==============================================================================
# FIRST CLUSTER BACKUP
# ==============================================================================

backup_first_cluster()
{
    backup_kubernetes_cluster \
        "$AWX_FIRST_BACKUP_NAME" \
        "$AWX_FIRST_KUBE_CMD" \
        "$AWX_FIRST_CONTEXT" \
        "$AWX_FIRST_DATABASE"
}


# ==============================================================================
# SECOND CLUSTER BACKUP
# ==============================================================================

backup_second_cluster()
{
    backup_kubernetes_cluster \
        "$AWX_SECOND_BACKUP_NAME" \
        "$AWX_SECOND_KUBE_CMD" \
        "$AWX_SECOND_CONTEXT" \
        "$AWX_SECOND_DATABASE"
}


# ==============================================================================
# BACKUP WORKING DIRECTORIES
# ==============================================================================

backup_workdirs()
{
    local DESTINATION="${WORK_DIR}/files"

    mkdir -p "$DESTINATION"


    if [[ -d "$AWX_FIRST_WORKDIR" ]]; then

        log "Backing up first AWX working directory"

        rsync \
            -a \
            "${AWX_FIRST_WORKDIR}/" \
            "${DESTINATION}/awx-kind-130/"

    else

        log "INFO: first AWX working directory not found: $AWX_FIRST_WORKDIR"

    fi


    if [[ -d "$AWX_SECOND_WORKDIR" ]]; then

        log "Backing up second AWX working directory"

        rsync \
            -a \
            "${AWX_SECOND_WORKDIR}/" \
            "${DESTINATION}/awx-kind-134/"

    else

        log "INFO: second AWX working directory not found: $AWX_SECOND_WORKDIR"

    fi
}


# ==============================================================================
# BACKUP SYSTEM CONFIGURATION
# ==============================================================================

backup_system_configuration()
{
    local DESTINATION="${WORK_DIR}/system"

    mkdir -p "$DESTINATION"


    if [[ -f "$NGINX_AWX_CONF" ]]; then

        log "Backing up NGINX AWX configuration"

        cp \
            -p \
            "$NGINX_AWX_CONF" \
            "${DESTINATION}/awx.conf"

    else

        log "INFO: NGINX AWX configuration not found: $NGINX_AWX_CONF"

    fi


    if [[ -f "$SWITCH_SCRIPT" ]]; then

        log "Backing up AWX switch script"

        cp \
            -p \
            "$SWITCH_SCRIPT" \
            "${DESTINATION}/switch-awx.sh"

        chmod +x \
            "${DESTINATION}/switch-awx.sh"

    fi
}


# ==============================================================================
# CREATE RESTORE INFORMATION
# ==============================================================================

create_restore_readme()
{
    cat > "${WORK_DIR}/README-restore.txt" <<EOF
AWX Full Backup
===============

Backup date:
    $DATE

Initial active cluster:
    $INITIAL_MODE

Clusters:
    FIRST
        Context  : $AWX_FIRST_CONTEXT
        Database : $AWX_FIRST_DATABASE

    SECOND
        Context  : $AWX_SECOND_CONTEXT
        Database : $AWX_SECOND_DATABASE

Backup directories:
    $AWX_FIRST_BACKUP_NAME/
    $AWX_SECOND_BACKUP_NAME/

Full PostgreSQL dump:
    postgres-full.sql

System files:
    system/awx.conf
    system/switch-awx.sh

Important:
    Secrets contained in Kubernetes Secret objects may be present
    in this backup.

    Backup archives must be protected accordingly.
EOF
}


# ==============================================================================
# BACKUP VALIDATION
# ==============================================================================

validate_backup()
{
    log "Validating generated backup"


    if [[ ! -s "${WORK_DIR}/${AWX_FIRST_BACKUP_NAME}/${AWX_FIRST_DATABASE}.sql" ]]; then

        log "ERROR: first PostgreSQL dump is empty"

        return 1
    fi


    if [[ ! -s "${WORK_DIR}/${AWX_SECOND_BACKUP_NAME}/${AWX_SECOND_DATABASE}.sql" ]]; then

        log "ERROR: second PostgreSQL dump is empty"

        return 1
    fi


    if [[ ! -s "${WORK_DIR}/postgres-full.sql" ]]; then

        log "ERROR: full PostgreSQL dump is empty"

        return 1
    fi


    log "Backup validation successful"
}


# ==============================================================================
# CLEANUP / RESTORE INITIAL CLUSTER
# ==============================================================================

cleanup()
{
    local EXIT_CODE=$?


    if [[ -n "${INITIAL_MODE:-}" \
          && "$INITIAL_MODE" != "unknown" \
          && "${CURRENT_MODE:-}" != "$INITIAL_MODE" ]]
    then

        log "Restoring initial AWX cluster: $INITIAL_MODE"

        "$SWITCH_SCRIPT" \
            "$INITIAL_MODE" \
            >/dev/null 2>&1 \
            || log "WARNING: unable to restore initial cluster"
    fi


    if (( EXIT_CODE != 0 )); then

        log "Backup interrupted or failed (exit code=$EXIT_CODE)"
    else

        log "Backup script completed"
    fi


    exit "$EXIT_CODE"
}


trap cleanup EXIT INT TERM


# ==============================================================================
# MAIN
# ==============================================================================

main()
{
    require_cmd "$AWX_FIRST_KUBE_CMD"
    require_cmd "$AWX_SECOND_KUBE_CMD"

    require_cmd sudo
    require_cmd pg_dump
    require_cmd pg_dumpall
    require_cmd rsync
    require_cmd tar
    require_cmd find

    if [[ ! -x "$SWITCH_SCRIPT" ]]; then

        log "ERROR: AWX switch script not executable: $SWITCH_SCRIPT"

        exit 1
    fi


    mkdir -p "$BASE_BACKUP_DIR"
    mkdir -p "$WORK_DIR"


    INITIAL_MODE="$(detect_current_mode)"
    CURRENT_MODE="$INITIAL_MODE"


    if [[ "$INITIAL_MODE" == "unknown" ]]; then

        log "ERROR: unable to determine active AWX cluster"

        exit 1
    fi


    log "=============================================================="
    log " AWX FULL BACKUP START"
    log "=============================================================="

    log "Initial active cluster: $INITIAL_MODE"


    # ==========================================================================
    # BACKUP BOTH CLUSTERS
    # ==========================================================================

    if [[ "$INITIAL_MODE" == "first" ]]; then

        backup_first_cluster

        switch_to second

        backup_second_cluster

    else

        backup_second_cluster

        switch_to first

        backup_first_cluster

    fi


    # ==========================================================================
    # FULL POSTGRESQL BACKUP
    # ==========================================================================

    log "Creating full PostgreSQL dump"


    sudo -u postgres \
        pg_dumpall \
        > "${WORK_DIR}/postgres-full.sql"


    # ==========================================================================
    # FILESYSTEM BACKUP
    # ==========================================================================

    backup_workdirs


    # ==========================================================================
    # SYSTEM CONFIGURATION
    # ==========================================================================

    backup_system_configuration


    # ==========================================================================
    # RESTORE INFORMATION
    # ==========================================================================

    create_restore_readme


    # ==========================================================================
    # VALIDATION
    # ==========================================================================

    validate_backup


    # ==========================================================================
    # COMPRESS BACKUP
    # ==========================================================================

    local ARCHIVE

    ARCHIVE="${BASE_BACKUP_DIR}/awx-full-backup-${DATE}.tar.gz"


    log "Creating archive: $ARCHIVE"


    tar \
        -czf "$ARCHIVE" \
        -C "$BASE_BACKUP_DIR" \
        "$DATE"


    if [[ ! -s "$ARCHIVE" ]]; then

        log "ERROR: generated archive is empty"

        exit 1
    fi


    # ==========================================================================
    # REMOVE TEMPORARY WORK DIRECTORY
    # ==========================================================================

    log "Removing temporary backup directory"


    rm -rf \
        "$WORK_DIR"


    # ==========================================================================
    # RETENTION
    # ==========================================================================

    log "Removing backup archives older than ${BACKUP_RETENTION_DAYS} days"


    find "$BASE_BACKUP_DIR" \
        -maxdepth 1 \
        -type f \
        -name 'awx-full-backup-*.tar.gz' \
        -mtime "+${BACKUP_RETENTION_DAYS}" \
        -delete


    log "=============================================================="
    log " AWX FULL BACKUP COMPLETED"
    log "=============================================================="
}


main

