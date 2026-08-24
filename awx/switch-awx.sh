#!/usr/bin/env bash
#
# ==============================================================================
#  Name         : switch-awx.sh
#  Project      : DevOps Lab Automation
#  Module       : AWX
#
#  Description  :
#      Controls failover between two AWX Kubernetes clusters running on Kind.
#
#      Only one cluster is allowed to run at a time.
#
#      Modes:
#
#          first
#              Activates the Kubernetes v1.30 AWX cluster
#              and stops the Kubernetes v1.34 cluster.
#
#          second
#              Activates the Kubernetes v1.34 AWX cluster
#              and stops the Kubernetes v1.30 cluster.
#
#          status
#              Displays the current Docker, Kubernetes and NGINX state.
#
#      During a switch, the script:
#
#          - Stops the inactive cluster containers
#          - Starts the selected cluster containers
#          - Enforces active/standby exclusivity
#          - Waits for the Kubernetes API
#          - Verifies the expected Kubernetes context
#          - Updates the NGINX reverse proxy
#          - Reloads NGINX after configuration validation
#          - Waits for AWX pods to become ready
#
#  Version      : 1.0.0
#
#  Compatibility:
#      - Red Hat Enterprise Linux 8 / 9 / 10
#      - Docker
#      - Kind
#      - Kubernetes
#      - NGINX
#
#  Usage:
#
#      chmod +x switch-awx.sh
#
#      ./switch-awx.sh status
#      ./switch-awx.sh first
#      ./switch-awx.sh second
#
#  Exit codes:
#
#      0 = Success
#      1 = Configuration or switch failure
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

MODE="${1:-}"

NGINX_CONF="${NGINX_CONF:-/etc/nginx/conf.d/awx.conf}"

LOG_TAG="[switch-awx]"


# ==============================================================================
# FIRST AWX CLUSTER
#
# Kubernetes v1.30
# ==============================================================================

AWX_FIRST_CONTEXT="${AWX_FIRST_CONTEXT:-kind-awx-130}"

AWX_FIRST_DOCKER_NODES=(
    "awx130-control-plane"
)

AWX_FIRST_PROXY_PASS="${AWX_FIRST_PROXY_PASS:-https://127.0.0.1:8443}"

AWX_FIRST_KUBE_CMD="${AWX_FIRST_KUBE_CMD:-kubectl}"


# ==============================================================================
# SECOND AWX CLUSTER
#
# Kubernetes v1.34
# ==============================================================================

AWX_SECOND_CONTEXT="${AWX_SECOND_CONTEXT:-kind-awx-134}"

AWX_SECOND_DOCKER_NODES=(
    "awx134-control-plane"
    "awx134-worker"
    "awx134-worker2"
)

#
# Example value.
#
# Override with:
#
# export AWX_SECOND_PROXY_PASS="https://192.0.2.20:30443"
#

AWX_SECOND_PROXY_PASS="${AWX_SECOND_PROXY_PASS:-https://192.0.2.20:30443}"

AWX_SECOND_KUBE_CMD="${AWX_SECOND_KUBE_CMD:-kube-latest}"


# ==============================================================================
# TIMEOUTS
# ==============================================================================

CLUSTER_API_TRIES="${CLUSTER_API_TRIES:-30}"
CLUSTER_API_SLEEP="${CLUSTER_API_SLEEP:-2}"

AWX_POD_TRIES="${AWX_POD_TRIES:-40}"
AWX_POD_SLEEP="${AWX_POD_SLEEP:-3}"

CONTAINER_STATE_TRIES="${CONTAINER_STATE_TRIES:-20}"
CONTAINER_STATE_SLEEP="${CONTAINER_STATE_SLEEP:-2}"


# ==============================================================================
# LOGGING
# ==============================================================================

log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_TAG} $*"
}


# ==============================================================================
# USAGE
# ==============================================================================

usage()
{
    cat <<EOF

Usage:
    $0 {first|second|status}

Modes:

    first
        Activate:
            $AWX_FIRST_CONTEXT

        Stop:
            $AWX_SECOND_CONTEXT


    second
        Activate:
            $AWX_SECOND_CONTEXT

        Stop:
            $AWX_FIRST_CONTEXT


    status
        Display the current AWX cluster state.

EOF

    exit 1
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
# DOCKER FUNCTIONS
# ==============================================================================

container_exists()
{
    local CONTAINER="$1"

    docker ps -a \
        --format '{{.Names}}' \
        | grep -qx "$CONTAINER"
}


container_running()
{
    local CONTAINER="$1"

    docker inspect \
        -f '{{.State.Running}}' \
        "$CONTAINER" \
        2>/dev/null \
        | grep -q '^true$'
}


stop_containers()
{
    local CONTAINER

    for CONTAINER in "$@"; do

        if ! container_exists "$CONTAINER"; then

            log "INFO: container does not exist: $CONTAINER"

            continue
        fi


        if container_running "$CONTAINER"; then

            log "Stopping container: $CONTAINER"

            docker stop "$CONTAINER" >/dev/null

        else

            log "Container already stopped: $CONTAINER"

        fi

    done
}


start_containers()
{
    local CONTAINER

    for CONTAINER in "$@"; do

        if ! container_exists "$CONTAINER"; then

            log "ERROR: required container does not exist: $CONTAINER"

            exit 1
        fi


        if container_running "$CONTAINER"; then

            log "Container already running: $CONTAINER"

        else

            log "Starting container: $CONTAINER"

            docker start "$CONTAINER" >/dev/null

        fi

    done
}


count_running_containers()
{
    local COUNT=0
    local CONTAINER

    for CONTAINER in "$@"; do

        if container_exists "$CONTAINER" \
           && container_running "$CONTAINER"
        then
            COUNT=$((COUNT + 1))
        fi

    done

    echo "$COUNT"
}


# ==============================================================================
# ACTIVE / STANDBY EXCLUSIVITY
# ==============================================================================

assert_exclusive_cluster_state()
{
    local FIRST_RUNNING
    local SECOND_RUNNING

    FIRST_RUNNING="$(
        count_running_containers \
            "${AWX_FIRST_DOCKER_NODES[@]}"
    )"

    SECOND_RUNNING="$(
        count_running_containers \
            "${AWX_SECOND_DOCKER_NODES[@]}"
    )"


    log "Cluster state: first_running=$FIRST_RUNNING second_running=$SECOND_RUNNING"


    if (( FIRST_RUNNING > 0 && SECOND_RUNNING > 0 )); then

        log "ERROR: both AWX clusters have running containers"

        exit 1
    fi


    if (( FIRST_RUNNING == 0 && SECOND_RUNNING == 0 )); then

        log "ERROR: no AWX cluster is currently active"

        exit 1
    fi
}


# ==============================================================================
# NGINX
# ==============================================================================

set_nginx_proxy_pass()
{
    local TARGET="$1"


    if [[ ! -f "$NGINX_CONF" ]]; then

        log "ERROR: NGINX configuration file not found: $NGINX_CONF"

        exit 1
    fi


    log "Updating NGINX proxy_pass -> $TARGET"


    sed -i -E \
        "s#proxy_pass[[:space:]]+https://[^;]+;#proxy_pass ${TARGET};#g" \
        "$NGINX_CONF"


    log "Validating NGINX configuration"


    if ! nginx -t >/dev/null 2>&1; then

        log "ERROR: NGINX configuration validation failed"

        exit 1
    fi


    log "Reloading NGINX"

    systemctl reload nginx
}


# ==============================================================================
# KUBERNETES API WAIT
# ==============================================================================

wait_for_cluster()
{
    local KUBE_CMD="$1"
    local I


    log "Waiting for Kubernetes API..."


    for I in $(seq 1 "$CLUSTER_API_TRIES"); do

        if "$KUBE_CMD" version \
            --request-timeout=5s \
            >/dev/null 2>&1
        then

            log "Kubernetes API available"

            return 0
        fi


        log "Attempt $I/$CLUSTER_API_TRIES..."


        sleep "$CLUSTER_API_SLEEP"

    done


    log "ERROR: Kubernetes API unavailable after timeout"

    return 1
}


# ==============================================================================
# AWX POD READINESS
# ==============================================================================

wait_for_awx_pods()
{
    local KUBE_CMD="$1"

    local I
    local PODS_OUTPUT


    log "Waiting for AWX pods to become Running/Ready..."


    for I in $(seq 1 "$AWX_POD_TRIES"); do

        if "$KUBE_CMD" get pods \
            -n awx \
            --no-headers \
            >/dev/null 2>&1
        then

            PODS_OUTPUT="$(
                "$KUBE_CMD" get pods \
                    -n awx \
                    --no-headers \
                    2>/dev/null \
                | grep -E 'awx-(web|task|operator)' \
                || true
            )"


            if [[ -n "$PODS_OUTPUT" ]]; then

                if echo "$PODS_OUTPUT" \
                    | awk '{print $2, $3}' \
                    | grep -vqE \
                        '^(1/1|2/2|3/3|4/4) Running$'
                then

                    log "Attempt $I/$AWX_POD_TRIES..."

                else

                    log "AWX pods are ready"

                    return 0

                fi

            else

                log "Attempt $I/$AWX_POD_TRIES: AWX pods not visible yet"

            fi

        else

            log "Attempt $I/$AWX_POD_TRIES: AWX namespace unavailable"

        fi


        sleep "$AWX_POD_SLEEP"

    done


    log "ERROR: AWX pods are not ready after timeout"

    return 1
}


# ==============================================================================
# KUBERNETES CONTEXT VALIDATION
# ==============================================================================

verify_context()
{
    local KUBE_CMD="$1"
    local EXPECTED_CONTEXT="$2"

    local CURRENT_CONTEXT


    CURRENT_CONTEXT="$(
        "$KUBE_CMD" config current-context \
            2>/dev/null \
            || true
    )"


    log "Detected Kubernetes context: $CURRENT_CONTEXT"


    if [[ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]]; then

        log "ERROR: unexpected Kubernetes context"
        log "Expected : $EXPECTED_CONTEXT"
        log "Current  : $CURRENT_CONTEXT"

        exit 1
    fi
}


# ==============================================================================
# CONTAINER STATE VALIDATION
# ==============================================================================

verify_container_state()
{
    local CONTAINER="$1"
    local EXPECTED="$2"

    local STATE


    STATE="$(
        docker inspect \
            -f '{{.State.Running}}' \
            "$CONTAINER" \
            2>/dev/null \
            || echo false
    )"


    if [[ "$EXPECTED" == "running" \
          && "$STATE" != "true" ]]
    then

        log "ERROR: $CONTAINER should be running"

        exit 1
    fi


    if [[ "$EXPECTED" == "stopped" \
          && "$STATE" == "true" ]]
    then

        log "ERROR: $CONTAINER should be stopped"

        exit 1
    fi
}


wait_for_container_state()
{
    local CONTAINER="$1"
    local EXPECTED="$2"

    local I
    local STATE


    log "Waiting for container state: $CONTAINER -> $EXPECTED"


    for I in $(seq 1 "$CONTAINER_STATE_TRIES"); do

        STATE="$(
            docker inspect \
                -f '{{.State.Running}}' \
                "$CONTAINER" \
                2>/dev/null \
                || echo false
        )"


        if [[ "$EXPECTED" == "running" \
              && "$STATE" == "true" ]]
        then

            log "$CONTAINER is running"

            return 0
        fi


        if [[ "$EXPECTED" == "stopped" \
              && "$STATE" == "false" ]]
        then

            log "$CONTAINER is stopped"

            return 0
        fi


        log "Attempt $I/$CONTAINER_STATE_TRIES..."


        sleep "$CONTAINER_STATE_SLEEP"

    done


    log "ERROR: expected state not reached for $CONTAINER"

    return 1
}


# ==============================================================================
# VERIFY ALL NODES
# ==============================================================================

verify_cluster_nodes()
{
    local EXPECTED="$1"

    shift

    local CONTAINER


    for CONTAINER in "$@"; do

        verify_container_state \
            "$CONTAINER" \
            "$EXPECTED"

    done
}


wait_cluster_nodes()
{
    local EXPECTED="$1"

    shift

    local CONTAINER


    for CONTAINER in "$@"; do

        wait_for_container_state \
            "$CONTAINER" \
            "$EXPECTED"

    done
}


# ==============================================================================
# SWITCH TO FIRST CLUSTER
# ==============================================================================

switch_to_first()
{
    log "=============================================================="
    log " SWITCHING TO FIRST AWX CLUSTER"
    log " Context: $AWX_FIRST_CONTEXT"
    log "=============================================================="


    log "Enforcing exclusive activation policy"


    stop_containers \
        "${AWX_SECOND_DOCKER_NODES[@]}"


    start_containers \
        "${AWX_FIRST_DOCKER_NODES[@]}"


    assert_exclusive_cluster_state


    wait_cluster_nodes \
        "running" \
        "${AWX_FIRST_DOCKER_NODES[@]}"


    wait_cluster_nodes \
        "stopped" \
        "${AWX_SECOND_DOCKER_NODES[@]}"


    verify_cluster_nodes \
        "running" \
        "${AWX_FIRST_DOCKER_NODES[@]}"


    verify_cluster_nodes \
        "stopped" \
        "${AWX_SECOND_DOCKER_NODES[@]}"


    log "Switching Kubernetes context using $AWX_FIRST_KUBE_CMD"


    "$AWX_FIRST_KUBE_CMD" \
        config use-context \
        "$AWX_FIRST_CONTEXT" \
        >/dev/null


    wait_for_cluster \
        "$AWX_FIRST_KUBE_CMD"


    verify_context \
        "$AWX_FIRST_KUBE_CMD" \
        "$AWX_FIRST_CONTEXT"


    set_nginx_proxy_pass \
        "$AWX_FIRST_PROXY_PASS"


    log "Waiting for AWX application"


    wait_for_awx_pods \
        "$AWX_FIRST_KUBE_CMD"


    "$AWX_FIRST_KUBE_CMD" \
        get pods \
        -n awx


    log "System load after switch"

    uptime
    free -h


    log "SUCCESS: first AWX cluster is active"
}


# ==============================================================================
# SWITCH TO SECOND CLUSTER
# ==============================================================================

switch_to_second()
{
    log "=============================================================="
    log " SWITCHING TO SECOND AWX CLUSTER"
    log " Context: $AWX_SECOND_CONTEXT"
    log "=============================================================="


    log "Enforcing exclusive activation policy"


    stop_containers \
        "${AWX_FIRST_DOCKER_NODES[@]}"


    start_containers \
        "${AWX_SECOND_DOCKER_NODES[@]}"


    assert_exclusive_cluster_state


    wait_cluster_nodes \
        "stopped" \
        "${AWX_FIRST_DOCKER_NODES[@]}"


    wait_cluster_nodes \
        "running" \
        "${AWX_SECOND_DOCKER_NODES[@]}"


    verify_cluster_nodes \
        "stopped" \
        "${AWX_FIRST_DOCKER_NODES[@]}"


    verify_cluster_nodes \
        "running" \
        "${AWX_SECOND_DOCKER_NODES[@]}"


    log "Switching Kubernetes context using $AWX_SECOND_KUBE_CMD"


    "$AWX_SECOND_KUBE_CMD" \
        config use-context \
        "$AWX_SECOND_CONTEXT" \
        >/dev/null


    wait_for_cluster \
        "$AWX_SECOND_KUBE_CMD"


    verify_context \
        "$AWX_SECOND_KUBE_CMD" \
        "$AWX_SECOND_CONTEXT"


    set_nginx_proxy_pass \
        "$AWX_SECOND_PROXY_PASS"


    log "Kubernetes nodes"


    "$AWX_SECOND_KUBE_CMD" \
        get nodes


    log "Waiting for AWX application"


    wait_for_awx_pods \
        "$AWX_SECOND_KUBE_CMD"


    "$AWX_SECOND_KUBE_CMD" \
        get pods \
        -n awx


    log "System load after switch"

    uptime
    free -h


    log "SUCCESS: second AWX cluster is active"
}


# ==============================================================================
# STATUS
# ==============================================================================

show_status()
{
    log "===== AWX CLUSTER STATUS ====="


    echo
    echo "--- Docker ---"

    docker ps -a \
        --format \
        'table {{.Names}}\t{{.Status}}'


    echo
    echo "--- First Kubernetes context ---"

    "$AWX_FIRST_KUBE_CMD" \
        config current-context \
        2>/dev/null \
        || true


    echo
    echo "--- Second Kubernetes context ---"

    "$AWX_SECOND_KUBE_CMD" \
        config current-context \
        2>/dev/null \
        || true


    echo
    echo "--- Current NGINX proxy_pass ---"

    grep -n \
        "proxy_pass" \
        "$NGINX_CONF" \
        || true


    echo
    echo "--- AWX cluster exclusivity ---"

    assert_exclusive_cluster_state


    local FIRST_RUNNING
    local SECOND_RUNNING


    FIRST_RUNNING="$(
        count_running_containers \
            "${AWX_FIRST_DOCKER_NODES[@]}"
    )"


    SECOND_RUNNING="$(
        count_running_containers \
            "${AWX_SECOND_DOCKER_NODES[@]}"
    )"


    echo

    if (( FIRST_RUNNING > 0 )); then

        echo "Active cluster : FIRST"
        echo "Context        : $AWX_FIRST_CONTEXT"

    elif (( SECOND_RUNNING > 0 )); then

        echo "Active cluster : SECOND"
        echo "Context        : $AWX_SECOND_CONTEXT"

    else

        echo "Active cluster : NONE"

    fi
}


# ==============================================================================
# MAIN
# ==============================================================================

main()
{
    require_cmd docker
    require_cmd nginx
    require_cmd sed
    require_cmd grep
    require_cmd systemctl
    require_cmd awk
    require_cmd date
    require_cmd uptime
    require_cmd free
    require_cmd sleep
    require_cmd seq


    case "$MODE" in

        first)

            require_cmd "$AWX_FIRST_KUBE_CMD"

            switch_to_first
            ;;


        second)

            require_cmd "$AWX_SECOND_KUBE_CMD"

            switch_to_second
            ;;


        status)

            require_cmd "$AWX_FIRST_KUBE_CMD"
            require_cmd "$AWX_SECOND_KUBE_CMD"

            show_status
            ;;


        *)

            usage
            ;;

    esac
}


main

