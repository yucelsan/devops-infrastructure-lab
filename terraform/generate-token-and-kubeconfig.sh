#!/usr/bin/env bash
#
# ==============================================================================
#  Name         : generate-token-and-kubeconfig.sh
#  Project      : DevOps Lab Automation
#  Module       : Terraform / Kubernetes / AWX
#
#  Description  :
#      Generates a dedicated Kubernetes kubeconfig for Terraform.
#
#      The script:
#          - Switches between two AWX / Kind Kubernetes clusters
#          - Validates the Terraform namespace and ServiceAccount
#          - Generates short-lived ServiceAccount tokens
#          - Extracts Kubernetes API endpoints and CA data
#          - Builds a kubeconfig containing both clusters
#          - Validates the generated kubeconfig
#          - Restores the preferred AWX cluster at the end
#
#      Cluster layout:
#
#          FIRST  -> Kubernetes v1.30
#          SECOND -> Kubernetes v1.34
#
#      The SECOND cluster is considered the preferred cluster and
#      is restored as active when the script finishes.
#
#  Version      : 1.0.0
#
#  Compatibility:
#      - Red Hat Enterprise Linux 8 / 9 / 10
#      - Kubernetes
#      - Kind
#      - Terraform
#
#  Usage:
#
#      chmod +x generate-token-and-kubeconfig.sh
#      ./generate-token-and-kubeconfig.sh
#
#  Suggested schedule:
#
#      0 */12 * * * /opt/terraform/generate-token-and-kubeconfig.sh
#
# ==============================================================================

set -euo pipefail

#
# Newly created files must only be accessible by their owner.
#
umask 077


# ==============================================================================
# ENVIRONMENT
# ==============================================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

ADMIN_KUBECONFIG="${ADMIN_KUBECONFIG:-/root/.kube/config}"

export KUBECONFIG="$ADMIN_KUBECONFIG"


# ==============================================================================
# GENERAL CONFIGURATION
# ==============================================================================

SWITCH_SCRIPT="${SWITCH_SCRIPT:-/usr/local/bin/switch-awx.sh}"

TERRAFORM_NAMESPACE="${TERRAFORM_NAMESPACE:-terraform-lab}"

TERRAFORM_SERVICE_ACCOUNT="${TERRAFORM_SERVICE_ACCOUNT:-terraform-sa}"

TOKEN_DURATION="${TOKEN_DURATION:-24h}"

OUTPUT_KUBECONFIG="${OUTPUT_KUBECONFIG:-/opt/terraform/kubeconfig-terraform-lab}"


# ==============================================================================
# FIRST CLUSTER
#
# Kubernetes v1.30
# ==============================================================================

AWX_FIRST_CONTEXT="${AWX_FIRST_CONTEXT:-kind-awx-130}"

AWX_FIRST_KUBE_CMD="${AWX_FIRST_KUBE_CMD:-kubectl}"

TERRAFORM_FIRST_USER="terraform-sa-130"

TERRAFORM_FIRST_CONTEXT="terraform-lab-130"


# ==============================================================================
# SECOND CLUSTER
#
# Kubernetes v1.34
# ==============================================================================

AWX_SECOND_CONTEXT="${AWX_SECOND_CONTEXT:-kind-awx-134}"

AWX_SECOND_KUBE_CMD="${AWX_SECOND_KUBE_CMD:-kube-latest}"

TERRAFORM_SECOND_USER="terraform-sa-134"

TERRAFORM_SECOND_CONTEXT="terraform-lab-134"


# ==============================================================================
# TEMPORARY FILE
# ==============================================================================

TMP_KUBECONFIG="$(mktemp)"


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
# CLEANUP
# ==============================================================================

cleanup()
{
    local EXIT_CODE=$?

    rm -f "$TMP_KUBECONFIG"

    #
    # Always try to restore the preferred cluster.
    #
    "$SWITCH_SCRIPT" second \
        >/dev/null 2>&1 \
        || true

    exit "$EXIT_CODE"
}


trap cleanup EXIT INT TERM


# ==============================================================================
# KUBERNETES CONFIG HELPERS
# ==============================================================================

get_cluster_server()
{
    local KUBE_CMD="$1"
    local CONTEXT="$2"

    KUBECONFIG="$ADMIN_KUBECONFIG" \
        "$KUBE_CMD" \
        config view \
        --raw \
        -o jsonpath="{.clusters[?(@.name==\"${CONTEXT}\")].cluster.server}"
}


get_cluster_ca_data()
{
    local KUBE_CMD="$1"
    local CONTEXT="$2"

    KUBECONFIG="$ADMIN_KUBECONFIG" \
        "$KUBE_CMD" \
        config view \
        --raw \
        -o jsonpath="{.clusters[?(@.name==\"${CONTEXT}\")].cluster.certificate-authority-data}"
}


create_service_account_token()
{
    local KUBE_CMD="$1"
    local CONTEXT="$2"

    KUBECONFIG="$ADMIN_KUBECONFIG" \
        "$KUBE_CMD" \
        --context "$CONTEXT" \
        -n "$TERRAFORM_NAMESPACE" \
        create token \
        "$TERRAFORM_SERVICE_ACCOUNT" \
        --duration="$TOKEN_DURATION"
}


# ==============================================================================
# CLUSTER PREREQUISITES
# ==============================================================================

check_cluster_prerequisites()
{
    local KUBE_CMD="$1"
    local CONTEXT="$2"

    log "Checking Kubernetes prerequisites on $CONTEXT"


    KUBECONFIG="$ADMIN_KUBECONFIG" \
        "$KUBE_CMD" \
        --context "$CONTEXT" \
        get nodes \
        >/dev/null


    KUBECONFIG="$ADMIN_KUBECONFIG" \
        "$KUBE_CMD" \
        --context "$CONTEXT" \
        get namespace \
        "$TERRAFORM_NAMESPACE" \
        >/dev/null


    KUBECONFIG="$ADMIN_KUBECONFIG" \
        "$KUBE_CMD" \
        --context "$CONTEXT" \
        -n "$TERRAFORM_NAMESPACE" \
        get serviceaccount \
        "$TERRAFORM_SERVICE_ACCOUNT" \
        >/dev/null
}


# ==============================================================================
# TOKEN TTL INFORMATION
# ==============================================================================

print_token_ttl()
{
    local LABEL="$1"
    local TOKEN="$2"

    local PAYLOAD
    local EXP
    local IAT

    PAYLOAD="$(
        echo "$TOKEN" \
            | cut -d. -f2 \
            | tr '_-' '/+' \
            | base64 -d \
            2>/dev/null \
            || true
    )"

    EXP="$(
        echo "$PAYLOAD" \
            | sed -n 's/.*"exp":\([0-9]\+\).*/\1/p'
    )"

    IAT="$(
        echo "$PAYLOAD" \
            | sed -n 's/.*"iat":\([0-9]\+\).*/\1/p'
    )"


    echo
    echo "===== TOKEN TTL : $LABEL ====="


    if [[ -n "$EXP" && -n "$IAT" ]]; then

        echo "Created : $(date -d "@$IAT")"
        echo "Expires : $(date -d "@$EXP")"
        echo "TTL(s)  : $((EXP - IAT))"
        echo "TTL(h)  : $(((EXP - IAT) / 3600))"

    else

        echo "WARNING: unable to decode token TTL"

    fi
}


# ==============================================================================
# VALIDATE GENERATED KUBECONFIG
# ==============================================================================

validate_generated_kubeconfig()
{
    log "Validating generated kubeconfig"


    KUBECONFIG="$TMP_KUBECONFIG" \
        "$AWX_SECOND_KUBE_CMD" \
        config get-contexts


    #
    # Validate connectivity using the preferred cluster.
    #

    KUBECONFIG="$TMP_KUBECONFIG" \
        "$AWX_SECOND_KUBE_CMD" \
        --context "$TERRAFORM_SECOND_CONTEXT" \
        version \
        --request-timeout=5s \
        >/dev/null
}


# ==============================================================================
# PRECHECKS
# ==============================================================================

require_cmd "$AWX_FIRST_KUBE_CMD"
require_cmd "$AWX_SECOND_KUBE_CMD"

require_cmd jq
require_cmd base64
require_cmd sed
require_cmd cut
require_cmd date
require_cmd mktemp

if [[ ! -x "$SWITCH_SCRIPT" ]]; then

    log "ERROR: AWX switch script is missing or not executable: $SWITCH_SCRIPT"

    exit 1
fi


# ==============================================================================
# START
# ==============================================================================

echo
echo "=============================================================="
echo " Terraform Kubernetes kubeconfig refresh"
echo " $(date)"
echo "=============================================================="


# ==============================================================================
# FIRST CLUSTER
# ==============================================================================

echo
echo "===== FIRST CLUSTER : $AWX_FIRST_CONTEXT ====="


"$SWITCH_SCRIPT" first


check_cluster_prerequisites \
    "$AWX_FIRST_KUBE_CMD" \
    "$AWX_FIRST_CONTEXT"


FIRST_SERVER="$(
    get_cluster_server \
        "$AWX_FIRST_KUBE_CMD" \
        "$AWX_FIRST_CONTEXT"
)"


FIRST_CA_DATA="$(
    get_cluster_ca_data \
        "$AWX_FIRST_KUBE_CMD" \
        "$AWX_FIRST_CONTEXT"
)"


FIRST_TOKEN="$(
    create_service_account_token \
        "$AWX_FIRST_KUBE_CMD" \
        "$AWX_FIRST_CONTEXT"
)"


if [[ -z "$FIRST_SERVER" \
      || -z "$FIRST_CA_DATA" \
      || -z "$FIRST_TOKEN" ]]
then

    log "ERROR: FIRST cluster SERVER/CA/TOKEN is empty"

    exit 1
fi


log "FIRST cluster token generated successfully"


KUBECONFIG="$ADMIN_KUBECONFIG" \
    "$AWX_FIRST_KUBE_CMD" \
    --context "$AWX_FIRST_CONTEXT" \
    get --raw='/version' \
    >/dev/null


KUBECONFIG="$ADMIN_KUBECONFIG" \
    "$AWX_FIRST_KUBE_CMD" \
    --context "$AWX_FIRST_CONTEXT" \
    -n "$TERRAFORM_NAMESPACE" \
    get service


# ==============================================================================
# SECOND CLUSTER
# ==============================================================================

echo
echo "===== SECOND CLUSTER : $AWX_SECOND_CONTEXT ====="


"$SWITCH_SCRIPT" second


check_cluster_prerequisites \
    "$AWX_SECOND_KUBE_CMD" \
    "$AWX_SECOND_CONTEXT"


SECOND_SERVER="$(
    get_cluster_server \
        "$AWX_SECOND_KUBE_CMD" \
        "$AWX_SECOND_CONTEXT"
)"


SECOND_CA_DATA="$(
    get_cluster_ca_data \
        "$AWX_SECOND_KUBE_CMD" \
        "$AWX_SECOND_CONTEXT"
)"


SECOND_TOKEN="$(
    create_service_account_token \
        "$AWX_SECOND_KUBE_CMD" \
        "$AWX_SECOND_CONTEXT"
)"


if [[ -z "$SECOND_SERVER" \
      || -z "$SECOND_CA_DATA" \
      || -z "$SECOND_TOKEN" ]]
then

    log "ERROR: SECOND cluster SERVER/CA/TOKEN is empty"

    exit 1
fi


log "SECOND cluster token generated successfully"


KUBECONFIG="$ADMIN_KUBECONFIG" \
    "$AWX_SECOND_KUBE_CMD" \
    --context "$AWX_SECOND_CONTEXT" \
    get --raw='/version' \
    >/dev/null


KUBECONFIG="$ADMIN_KUBECONFIG" \
    "$AWX_SECOND_KUBE_CMD" \
    --context "$AWX_SECOND_CONTEXT" \
    -n "$TERRAFORM_NAMESPACE" \
    get service


# ==============================================================================
# GENERATE TERRAFORM KUBECONFIG
# ==============================================================================

log "Generating Terraform kubeconfig"


cat > "$TMP_KUBECONFIG" <<EOF_KUBECONFIG
apiVersion: v1
kind: Config

clusters:

- name: ${AWX_FIRST_CONTEXT}
  cluster:
    server: ${FIRST_SERVER}
    certificate-authority-data: ${FIRST_CA_DATA}

- name: ${AWX_SECOND_CONTEXT}
  cluster:
    server: ${SECOND_SERVER}
    certificate-authority-data: ${SECOND_CA_DATA}


users:

- name: ${TERRAFORM_FIRST_USER}
  user:
    token: ${FIRST_TOKEN}

- name: ${TERRAFORM_SECOND_USER}
  user:
    token: ${SECOND_TOKEN}


contexts:

- name: ${TERRAFORM_FIRST_CONTEXT}
  context:
    cluster: ${AWX_FIRST_CONTEXT}
    namespace: ${TERRAFORM_NAMESPACE}
    user: ${TERRAFORM_FIRST_USER}

- name: ${TERRAFORM_SECOND_CONTEXT}
  context:
    cluster: ${AWX_SECOND_CONTEXT}
    namespace: ${TERRAFORM_NAMESPACE}
    user: ${TERRAFORM_SECOND_USER}


current-context: ${TERRAFORM_SECOND_CONTEXT}
EOF_KUBECONFIG


chmod 600 "$TMP_KUBECONFIG"


# ==============================================================================
# VALIDATE KUBECONFIG
# ==============================================================================

validate_generated_kubeconfig


# ==============================================================================
# INSTALL KUBECONFIG
# ==============================================================================

log "Installing kubeconfig -> $OUTPUT_KUBECONFIG"


mv \
    "$TMP_KUBECONFIG" \
    "$OUTPUT_KUBECONFIG"


chmod 600 \
    "$OUTPUT_KUBECONFIG"


# ==============================================================================
# TOKEN INFORMATION
# ==============================================================================

print_token_ttl \
    "FIRST / Kubernetes 1.30" \
    "$FIRST_TOKEN"


print_token_ttl \
    "SECOND / Kubernetes 1.34" \
    "$SECOND_TOKEN"


# ==============================================================================
# FINAL VALIDATION
# ==============================================================================

echo
echo "===== FINAL TERRAFORM KUBECONFIG VALIDATION ====="


echo "Generated kubeconfig:"
echo "    $OUTPUT_KUBECONFIG"

echo

echo "Current context:"
KUBECONFIG="$OUTPUT_KUBECONFIG" \
    "$AWX_SECOND_KUBE_CMD" \
    config current-context


echo

echo "Preferred cluster Kubernetes version:"

KUBECONFIG="$OUTPUT_KUBECONFIG" \
    "$AWX_SECOND_KUBE_CMD" \
    --context "$TERRAFORM_SECOND_CONTEXT" \
    version \
    -o json \
    | jq -r '.serverVersion.gitVersion'


echo

echo "Terraform namespace services:"

KUBECONFIG="$OUTPUT_KUBECONFIG" \
    "$AWX_SECOND_KUBE_CMD" \
    --context "$TERRAFORM_SECOND_CONTEXT" \
    -n "$TERRAFORM_NAMESPACE" \
    get service


# ==============================================================================
# RESTORE PREFERRED AWX CLUSTER
# ==============================================================================

trap - EXIT

rm -f "$TMP_KUBECONFIG"


log "Restoring preferred AWX cluster: $AWX_SECOND_CONTEXT"


"$SWITCH_SCRIPT" second


echo
echo "===== ACTIVE AWX CLUSTER ====="


KUBECONFIG="$ADMIN_KUBECONFIG" \
    "$AWX_SECOND_KUBE_CMD" \
    --context "$AWX_SECOND_CONTEXT" \
    version \
    -o json \
    | jq -r '.serverVersion.gitVersion'


log "Terraform kubeconfig refresh completed successfully"

