#!/usr/bin/env bash
#
# ==============================================================================
#  Name         : awx-auto-heal.sh
#  Project      : DevOps Lab Automation
#  Module       : AWX
#
#  Description  :
#      Checks the health of two AWX Kubernetes clusters.
#
#      If at least one cluster is available, no action is taken.
#
#      If both clusters are unavailable:
#          1. Try to start the preferred AWX cluster.
#          2. If recovery fails, fall back to the secondary cluster.
#
#      Only one AWX cluster should be active at a time.
#
#  Version      : 1.0.0
#
#  Compatibility:
#      - Red Hat Enterprise Linux 8 / 9 / 10
#
#  Usage:
#      chmod +x awx-auto-heal.sh
#      ./awx-auto-heal.sh
#
#  Exit codes:
#      0 = At least one AWX cluster is operational
#      1 = Configuration / status check error
#      2 = Recovery failed on both clusters
#
# ==============================================================================

set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


# ==============================================================================
# CONFIGURATION
# ==============================================================================

LOG_FILE="/var/log/awx-auto-heal.log"
LOCK_FILE="/tmp/awx-auto-heal.lock"

AWX_FIRST_CONTEXT="kind-awx-130"
AWX_SECOND_CONTEXT="kind-awx-134"

AWX_FIRST_STATUS_SCRIPT="/etc/zabbix/zabbix-awx-130-status.sh"
AWX_SECOND_STATUS_SCRIPT="/etc/zabbix/zabbix-awx-134-status.sh"

SWITCH_SCRIPT="/usr/local/bin/switch-awx.sh"

#
# Preferred recovery order:
#
#   AWX_SECOND_CONTEXT -> first attempt
#   AWX_FIRST_CONTEXT  -> fallback
#

PREFERRED_CLUSTER="second"

RECOVERY_WAIT_SECONDS=15


# ==============================================================================
# FUNCTIONS
# ==============================================================================

log()
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}


run_status_script()
{
    local SCRIPT="$1"
    local RESULT

    if [[ ! -x "$SCRIPT" ]]; then

        log "ERROR: status script missing or not executable: $SCRIPT"

        echo "ERROR"
        return 1
    fi


    RESULT="$(
        "$SCRIPT" 2>/dev/null \
        | tr -d '[:space:]'
    )"


    case "$RESULT" in

        0|1)
            echo "$RESULT"
            return 0
            ;;

        *)
            log "ERROR: unexpected value returned by $SCRIPT: '$RESULT'"

            echo "ERROR"
            return 1
            ;;

    esac
}


finish()
{
    local RC="$1"

    log "===== End awx-auto-heal ====="

    exit "$RC"
}


# ==============================================================================
# LOCK
# ==============================================================================

exec 200>"$LOCK_FILE"

if ! flock -n 200; then

    log "Another awx-auto-heal execution is already running. Exiting."

    exit 0
fi


# ==============================================================================
# START
# ==============================================================================

echo >> "$LOG_FILE"
echo "-------------------------------------------------------------" >> "$LOG_FILE"

log "===== Start awx-auto-heal ====="


# ==============================================================================
# PRECHECKS
# ==============================================================================

if [[ ! -x "$SWITCH_SCRIPT" ]]; then

    log "ERROR: cluster switch script missing or not executable: $SWITCH_SCRIPT"

    finish 1
fi


# ==============================================================================
# CURRENT CLUSTER STATUS
# ==============================================================================

FIRST_STATUS="$(
    run_status_script "$AWX_FIRST_STATUS_SCRIPT"
)"

SECOND_STATUS="$(
    run_status_script "$AWX_SECOND_STATUS_SCRIPT"
)"


log "Cluster status $AWX_FIRST_CONTEXT  : $FIRST_STATUS"
log "Cluster status $AWX_SECOND_CONTEXT : $SECOND_STATUS"


"$SWITCH_SCRIPT" status \
    >> "$LOG_FILE" \
    2>&1


if [[ "$FIRST_STATUS" == "ERROR" \
      || "$SECOND_STATUS" == "ERROR" ]]
then

    log "ERROR: unable to determine AWX cluster status. No failover attempted."

    finish 1
fi


# ==============================================================================
# NORMAL STATE
# ==============================================================================

if [[ "$FIRST_STATUS" == "1" \
      || "$SECOND_STATUS" == "1" ]]
then

    log "At least one AWX cluster is UP. No action required."

    finish 0
fi


# ==============================================================================
# BOTH CLUSTERS DOWN
# ==============================================================================

log "CRITICAL: both AWX clusters are DOWN."
log "Starting automatic recovery procedure."


# ==============================================================================
# FIRST RECOVERY ATTEMPT - PREFERRED CLUSTER
# ==============================================================================

if [[ "$PREFERRED_CLUSTER" == "second" ]]; then

    log "Recovery attempt #1: switch to $AWX_SECOND_CONTEXT"

    "$SWITCH_SCRIPT" second \
        >> "$LOG_FILE" \
        2>&1

    RC_SECOND=$?


    sleep "$RECOVERY_WAIT_SECONDS"


    FIRST_STATUS_AFTER="$(
        run_status_script "$AWX_FIRST_STATUS_SCRIPT"
    )"

    SECOND_STATUS_AFTER="$(
        run_status_script "$AWX_SECOND_STATUS_SCRIPT"
    )"


    log "After recovery attempt:"
    log "$AWX_FIRST_CONTEXT=$FIRST_STATUS_AFTER"
    log "$AWX_SECOND_CONTEXT=$SECOND_STATUS_AFTER"


    if [[ "$RC_SECOND" -eq 0 \
          && "$SECOND_STATUS_AFTER" == "1" ]]
    then

        log "SUCCESS: preferred cluster $AWX_SECOND_CONTEXT recovered."

        log "Final cluster state:"

        "$SWITCH_SCRIPT" status \
            >> "$LOG_FILE" \
            2>&1

        finish 0
    fi


    # ==========================================================================
    # FALLBACK
    # ==========================================================================

    log "Preferred cluster recovery failed."
    log "Fallback attempt: switch to $AWX_FIRST_CONTEXT"


    "$SWITCH_SCRIPT" first \
        >> "$LOG_FILE" \
        2>&1

    RC_FIRST=$?


    sleep "$RECOVERY_WAIT_SECONDS"


    FIRST_STATUS_FINAL="$(
        run_status_script "$AWX_FIRST_STATUS_SCRIPT"
    )"

    SECOND_STATUS_FINAL="$(
        run_status_script "$AWX_SECOND_STATUS_SCRIPT"
    )"


    log "Fallback result:"
    log "$AWX_FIRST_CONTEXT=$FIRST_STATUS_FINAL"
    log "$AWX_SECOND_CONTEXT=$SECOND_STATUS_FINAL"


    if [[ "$RC_FIRST" -eq 0 \
          && "$FIRST_STATUS_FINAL" == "1" ]]
    then

        log "SUCCESS: fallback cluster $AWX_FIRST_CONTEXT recovered."

        log "Final cluster state:"

        "$SWITCH_SCRIPT" status \
            >> "$LOG_FILE" \
            2>&1

        finish 0
    fi

fi


# ==============================================================================
# RECOVERY FAILED
# ==============================================================================

log "CRITICAL: no AWX cluster recovered after all recovery attempts."

log "Final cluster state:"

"$SWITCH_SCRIPT" status \
    >> "$LOG_FILE" \
    2>&1


finish 2