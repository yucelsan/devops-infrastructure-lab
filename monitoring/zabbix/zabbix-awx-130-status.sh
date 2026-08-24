#!/usr/bin/env bash
#
# ==============================================================================
#  Name         : zabbix-awx-130-status.sh
#  Project      : DevOps Lab Automation
#  Module       : AWX / Zabbix
#
#  Description  :
#      Checks whether the AWX application is operational on the
#      Kubernetes v1.30 cluster.
#
#      The script verifies that the main AWX pods are Running and Ready:
#
#          - awx-operator-controller-manager
#          - awx-task
#          - awx-web
#
#  Output:
#      1 = AWX cluster operational
#      0 = AWX cluster unavailable or incomplete
#
#  Compatibility:
#      - Zabbix Agent 2
#      - Kubernetes
#      - AWX Operator
#
# ==============================================================================

set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export KUBECONFIG="${KUBECONFIG:-/var/lib/zabbix/.kube/config}"

# ==============================================================================
# CONFIGURATION
# ==============================================================================

KUBE_CMD="${KUBE_CMD:-/usr/local/bin/kubectl}"
AWX_CONTEXT="${AWX_CONTEXT:-kind-awx-130}"
AWX_NAMESPACE="${AWX_NAMESPACE:-awx}"

# ==============================================================================
# PRECHECKS
# ==============================================================================

if [[ ! -x "$KUBE_CMD" ]]; then
    echo 0
    exit 0
fi

if [[ ! -r "$KUBECONFIG" ]]; then
    echo 0
    exit 0
fi

# ==============================================================================
# POD STATUS
# ==============================================================================

PODS="$(
    "$KUBE_CMD" \
        --context="$AWX_CONTEXT" \
        get pods \
        -n "$AWX_NAMESPACE" \
        --no-headers \
        2>/dev/null \
        || true
)"

# ==============================================================================
# HEALTH CHECK HELPERS
# ==============================================================================

pod_ready()
{
    local PATTERN="$1"

    awk -v pattern="$PATTERN" '
        $1 ~ pattern && $3 == "Running" {
            split($2, ready, "/")
            if (ready[1] == ready[2] && ready[2] > 0) {
                found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' <<< "$PODS"
}

# ==============================================================================
# HEALTH CHECK
# ==============================================================================

if pod_ready '^awx-operator-controller-manager' \
   && pod_ready '^awx-task' \
   && pod_ready '^awx-web'
then
    echo 1
else
    echo 0
fi

# The metric was successfully produced. Zabbix consumes stdout as 0/1.
exit 0
