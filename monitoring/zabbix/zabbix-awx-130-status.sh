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
#      The script verifies that the main AWX pods are in Running state:
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
    exit 1
fi

if [[ ! -r "$KUBECONFIG" ]]; then
    echo 0
    exit 1
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
# HEALTH CHECK
# ==============================================================================

if echo "$PODS" | grep -qE 'awx-operator-controller-manager.*Running' \
   && echo "$PODS" | grep -qE 'awx-task.*Running' \
   && echo "$PODS" | grep -qE 'awx-web.*Running'
then
    echo 1
    exit 0
else
    echo 0
    exit 1
fi

