#!/usr/bin/env bash

#
# ==============================================================================
# DEVOPS LAB - GLOBAL HEALTH CHECK V4
# ==============================================================================
#  Project      : DevOps Lab Automation
#  Script       : devops-lab-healthcheck.sh
#  Description  : Global Linux / DevOps / AWX / Kubernetes health check
#
#  Public note  : Sanitized portfolio version. Hostnames, paths, application
#                 names and environment-specific identifiers were generalized.
#
#  Version      : 4.0.0
#
#  Modes :
#      ./devops-lab-healthcheck.sh
#      ./devops-lab-healthcheck.sh --summary
#
# Vérifie :
#   - Services systemd principaux
#   - Etat AWX
#   - Jenkins
#   - Ansible
#   - Docker
#   - Helm / Kubernetes / Kind
#   - Zabbix Agent 2
#   - Processus applicatifs
#   - Présence des scripts d'administration
#   - Le Crond
#   - Les services web Apache / Nginx
#   - Les services BDD Postgresql / MySQL
#   - Les backups
#   - Application API / Infrastructure API / Terraform
#   - Les espaces disques / RAM / MEM
#   - Les certificats SSL / TLS
#
# Exit codes :
#   0 = OK
#   1 = WARNING
#   2 = CRITICAL
#
# ==============================================================

set -u

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.local/bin

# ==============================================================================
# CONFIGURATION
# ==============================================================================

MODE="full"

case "${1:-}" in
    "")
        MODE="full"
        ;;
    --summary)
        MODE="summary"
        ;;
    -h|--help)
        echo "Usage: $0 [--summary]"
        exit 0
        ;;
    *)
        echo "Usage: $0 [--summary]"
        exit 1
        ;;
esac


HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
DATE_NOW="$(date '+%Y-%m-%d %H:%M:%S')"

OK=0
WARNING=0
CRITICAL=0
INFO=0

# ------------------------------------------------------------------------------
# Seuils
# ------------------------------------------------------------------------------

DISK_WARN=80
DISK_CRIT=90

INODE_WARN=80
INODE_CRIT=90

RAM_WARN=80
RAM_CRIT=90

SWAP_WARN=50

LOAD_WARN_FACTOR=1
LOAD_CRIT_FACTOR=2

TLS_WARN_DAYS=30
TLS_CRIT_DAYS=7

RECENT_RESTART_MINUTES=30

JOURNAL_SINCE="24 hours ago"


# ==============================================================================
# AWX / CLUSTERS
# ==============================================================================

AWX_FIRST_CONTEXT="kind-awx-130"
AWX_SECOND_CONTEXT="kind-awx-134"

AWX_FIRST_NODES=(
    "awx130-control-plane"
)

AWX_SECOND_NODES=(
    "awx134-control-plane"
    "awx134-worker"
    "awx134-worker2"
)

AWX_FIRST_STATUS_SCRIPT="/etc/zabbix/zabbix-awx-130-status.sh"
AWX_SECOND_STATUS_SCRIPT="/etc/zabbix/zabbix-awx-134-status.sh"

ACTIVE_CLUSTER="UNKNOWN"
KUBE_CMD="kubectl"


# ==============================================================================
# BACKUPS
# ==============================================================================

AWX_FULL_BACKUP_DIR="${AWX_FULL_BACKUP_DIR:-/opt/lab/backups/awx}"
AWX_POSTGRES_BACKUP_DIR="${AWX_POSTGRES_BACKUP_DIR:-/opt/lab/backups/postgres}"
TERRAFORM_BACKUP_DIR="${TERRAFORM_BACKUP_DIR:-/opt/lab/backups/terraform}"


# ------------------------------------------------------------------------------
# Applications de démonstration
# ------------------------------------------------------------------------------
#
# Ces valeurs peuvent être surchargées par des variables d'environnement afin
# d'adapter le health-check à un autre lab sans modifier le script.
#

APP_API_SERVICE="${APP_API_SERVICE:-app-api}"
APP_API_URL="${APP_API_URL:-http://127.0.0.1:8000/health}"

INFRA_API_SERVICE="${INFRA_API_SERVICE:-infra-api}"
INFRA_API_URL="${INFRA_API_URL:-http://127.0.0.1:8001/health}"

WORKFLOW_DIR="${WORKFLOW_DIR:-/var/www/workflow}"
WORKFLOW_HTTP_PORT="${WORKFLOW_HTTP_PORT:-8081}"
WORKFLOW_HTTPS_PORT="${WORKFLOW_HTTPS_PORT:-8444}"

JENKINS_URL="${JENKINS_URL:-http://127.0.0.1:8080}"
JENKINS_DEMO_DIR="${JENKINS_DEMO_DIR:-/opt/jenkins-demo}"


# ==============================================================================
# COULEURS
# ==============================================================================

if [[ -t 1 ]]; then
    GREEN="\033[1;32m"
    YELLOW="\033[1;33m"
    RED="\033[1;31m"
    BLUE="\033[1;34m"
    CYAN="\033[1;36m"
    WHITE="\033[1;37m"
    RESET="\033[0m"
else
    GREEN=""
    YELLOW=""
    RED=""
    BLUE=""
    CYAN=""
    WHITE=""
    RESET=""
fi


# ==============================================================================
# ETAT PAR CATEGORIE
# ==============================================================================

declare -A CATEGORY_LEVEL
declare -A CATEGORY_NOTE

CATEGORIES=(
    "SYSTEM"
    "DISK"
    "RAM"
    "DOCKER"
    "KUBERNETES"
    "AWX"
    "POSTGRESQL"
    "JENKINS"
    "APP_API"
    "INFRA_API"
    "WORKFLOW"
    "WEB"
    "BACKUPS"
    "CRON"
    "LOGROTATE"
    "FIREWALL"
    "SELINUX"
    "NTP"
    "TLS"
)

for CAT in "${CATEGORIES[@]}"; do
    CATEGORY_LEVEL["$CAT"]=0
    CATEGORY_NOTE["$CAT"]=""
done


# ==============================================================================
# AFFICHAGE
# ==============================================================================

print_title()
{
    [[ "$MODE" == "summary" ]] && return

    echo
    echo -e "${BLUE}==============================================================${RESET}"
    echo -e "${BLUE} $1${RESET}"
    echo -e "${BLUE}==============================================================${RESET}"
}


detail()
{
    [[ "$MODE" == "summary" ]] && return
    echo "$@"
}


set_category()
{
    local CATEGORY="$1"
    local LEVEL="$2"
    local NOTE="${3:-}"

    local CURRENT="${CATEGORY_LEVEL[$CATEGORY]:-0}"

    if (( LEVEL > CURRENT )); then
        CATEGORY_LEVEL["$CATEGORY"]="$LEVEL"
        CATEGORY_NOTE["$CATEGORY"]="$NOTE"
    elif [[ -z "${CATEGORY_NOTE[$CATEGORY]:-}" && -n "$NOTE" ]]; then
        CATEGORY_NOTE["$CATEGORY"]="$NOTE"
    fi
}


print_ok()
{
    local CATEGORY="$1"
    shift

    ((OK++))
    set_category "$CATEGORY" 0 "$*"

    [[ "$MODE" == "summary" ]] && return

    echo -e "[${GREEN} OK ${RESET}] $*"
}


print_warning()
{
    local CATEGORY="$1"
    shift

    ((WARNING++))
    set_category "$CATEGORY" 1 "$*"

    [[ "$MODE" == "summary" ]] && return

    echo -e "[${YELLOW}WARN${RESET}] $*"
}


print_critical()
{
    local CATEGORY="$1"
    shift

    ((CRITICAL++))
    set_category "$CATEGORY" 2 "$*"

    [[ "$MODE" == "summary" ]] && return

    echo -e "[${RED}CRIT${RESET}] $*"
}


print_info()
{
    local CATEGORY="$1"
    shift

    ((INFO++))

    [[ "$MODE" == "summary" ]] && return

    echo -e "[${CYAN}INFO${RESET}] $*"
}


print_na()
{
    local CATEGORY="$1"
    shift

    [[ "$MODE" == "summary" ]] && return

    echo -e "[${CYAN} N/A ${RESET}] $*"
}


# ==============================================================================
# FONCTIONS GENERIQUES
# ==============================================================================

command_exists()
{
    command -v "$1" >/dev/null 2>&1
}


service_exists()
{
    systemctl list-unit-files \
        --type=service \
        --no-legend \
        2>/dev/null \
        | awk '{print $1}' \
        | grep -qx "${1}.service"
}


check_service_required()
{
    local CATEGORY="$1"
    local SERVICE="$2"

    if ! service_exists "$SERVICE"; then
        print_critical "$CATEGORY" "$SERVICE : service absent"
        return
    fi

    local ACTIVE
    local SUBSTATE
    local PID
    local TYPE

    ACTIVE="$(systemctl show "$SERVICE" -p ActiveState --value 2>/dev/null || true)"
    SUBSTATE="$(systemctl show "$SERVICE" -p SubState --value 2>/dev/null || true)"
    PID="$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || true)"
    TYPE="$(systemctl show "$SERVICE" -p Type --value 2>/dev/null || true)"

    if [[ "$ACTIVE" == "active" ]]; then

        if [[ "$TYPE" == "oneshot" ]]; then
            print_ok "$CATEGORY" "$SERVICE : ACTIVE ($SUBSTATE / oneshot)"
        else
            print_ok "$CATEGORY" "$SERVICE : UP - PID=${PID:-?} ($SUBSTATE)"
        fi

    else
        print_critical \
            "$CATEGORY" \
            "$SERVICE : DOWN - ActiveState=$ACTIVE SubState=$SUBSTATE"
    fi
}


check_service_optional()
{
    local CATEGORY="$1"
    local SERVICE="$2"

    if ! service_exists "$SERVICE"; then
        print_na "$CATEGORY" "$SERVICE : non installé"
        return
    fi

    local ACTIVE
    local SUBSTATE

    ACTIVE="$(systemctl show "$SERVICE" -p ActiveState --value 2>/dev/null || true)"
    SUBSTATE="$(systemctl show "$SERVICE" -p SubState --value 2>/dev/null || true)"

    if [[ "$ACTIVE" == "active" ]]; then
        print_ok "$CATEGORY" "$SERVICE : ACTIVE ($SUBSTATE)"
    else
        print_info "$CATEGORY" "$SERVICE : $ACTIVE/$SUBSTATE"
    fi
}


check_command_required()
{
    local CATEGORY="$1"
    local CMD="$2"

    if command_exists "$CMD"; then
        print_ok "$CATEGORY" "$CMD installé : $(command -v "$CMD")"
    else
        print_warning "$CATEGORY" "$CMD absent du PATH"
    fi
}


check_command_optional()
{
    local CATEGORY="$1"
    local CMD="$2"

    if command_exists "$CMD"; then
        print_ok "$CATEGORY" "$CMD installé : $(command -v "$CMD")"
    else
        print_na "$CATEGORY" "$CMD non installé"
    fi
}


check_file_exec()
{
    local CATEGORY="$1"
    local FILE="$2"

    if [[ ! -e "$FILE" ]]; then
        print_critical "$CATEGORY" "Absent : $FILE"
        return
    fi

    if [[ -x "$FILE" ]]; then
        print_ok "$CATEGORY" "Présent/exécutable : $FILE"
    else
        print_warning "$CATEGORY" "Présent mais non exécutable : $FILE"
    fi
}


human_pct()
{
    awk \
        -v a="$1" \
        -v b="$2" \
        'BEGIN {
            if (b == 0)
                print 0
            else
                printf "%.0f",(a/b)*100
        }'
}


age_hours()
{
    local FILE="$1"

    local NOW
    local MTIME

    NOW="$(date +%s)"
    MTIME="$(stat -c %Y "$FILE" 2>/dev/null || echo 0)"

    echo $(((NOW - MTIME) / 3600))
}


# ==============================================================================
# HEADER
# ==============================================================================

if [[ "$MODE" == "full" ]]; then

    echo
    echo "################################################################"
    echo "#"
    echo "#              DEVOPS LAB HEALTH CHECK V4"
    echo "#"
    echo "################################################################"
    echo
    echo "Serveur : $HOSTNAME_SHORT"
    echo "Date    : $DATE_NOW"

fi


# ==============================================================================
# SERVICES SYSTEMD
# ==============================================================================

print_title "SERVICES SYSTEMD PRINCIPAUX"

check_service_required "SYSTEM" "sshd"
check_service_required "CRON" "crond"
check_service_required "DOCKER" "docker"
check_service_required "JENKINS" "jenkins"
check_service_required "SYSTEM" "zabbix-agent2"


# ==============================================================================
# APPLICATIONS
# ==============================================================================

print_title "SERVICES APPLICATIFS LAB"

check_service_required "APP_API" "$APP_API_SERVICE"
check_service_required "INFRA_API" "$INFRA_API_SERVICE"


# ==============================================================================
# SWITCH AWX
# ==============================================================================

print_title "SWITCH AWX"

if service_exists "switch-awx"; then

    SWITCH_ACTIVE="$(
        systemctl show switch-awx \
            -p ActiveState \
            --value \
            2>/dev/null
    )"

    SWITCH_SUB="$(
        systemctl show switch-awx \
            -p SubState \
            --value \
            2>/dev/null
    )"

    SWITCH_RESULT="$(
        systemctl show switch-awx \
            -p Result \
            --value \
            2>/dev/null
    )"

    SWITCH_EXEC_STATUS="$(
        systemctl show switch-awx \
            -p ExecMainStatus \
            --value \
            2>/dev/null
    )"

    if [[ "$SWITCH_ACTIVE" == "active" \
          && "$SWITCH_EXEC_STATUS" == "0" ]]; then

        print_ok \
            "AWX" \
            "switch-awx : dernière bascule réussie - active/$SWITCH_SUB RC=0"

    elif [[ "$SWITCH_EXEC_STATUS" != "0" ]]; then

        print_critical \
            "AWX" \
            "switch-awx : échec - Result=$SWITCH_RESULT RC=$SWITCH_EXEC_STATUS"

    else

        print_warning \
            "AWX" \
            "switch-awx : état $SWITCH_ACTIVE/$SWITCH_SUB"

    fi


    if [[ "$MODE" == "full" \
          && -f "/var/log/switch-awx-reboot.log" ]]; then

        echo
        echo "Dernières lignes switch-awx :"
        echo

        tail -15 \
            /var/log/switch-awx-reboot.log \
            2>/dev/null \
            | sed 's/^/        /'

    fi

else

    print_warning "AWX" "switch-awx.service absent"

fi


# ==============================================================================
# DETECTION ETAT REEL DES CLUSTERS AWX
# ==============================================================================

print_title "CLUSTERS AWX / EXCLUSIVITE"


container_exists()
{
    docker ps -a \
        --format '{{.Names}}' \
        2>/dev/null \
        | grep -qx "$1"
}


container_running()
{
    docker inspect \
        -f '{{.State.Running}}' \
        "$1" \
        2>/dev/null \
        | grep -q true
}


count_running_containers()
{
    local COUNT=0
    local NODE

    for NODE in "$@"; do

        if container_exists "$NODE" \
           && container_running "$NODE"
        then
            COUNT=$((COUNT + 1))
        fi

    done

    echo "$COUNT"
}


AWX_FIRST_RUNNING="$(count_running_containers "${AWX_FIRST_NODES[@]}")"
AWX_SECOND_RUNNING="$(count_running_containers "${AWX_SECOND_NODES[@]}")"


if (( AWX_FIRST_RUNNING > 0 && AWX_SECOND_RUNNING > 0 )); then

    ACTIVE_CLUSTER="ERROR"

    print_critical \
        "AWX" \
        "Les clusters FIRST et SECOND ont des conteneurs actifs simultanément"

elif (( AWX_FIRST_RUNNING == 0 && AWX_SECOND_RUNNING == 0 )); then

    ACTIVE_CLUSTER="NONE"

    print_critical \
        "AWX" \
        "Aucun cluster AWX actif"

elif (( AWX_FIRST_RUNNING == 1 && AWX_SECOND_RUNNING == 0 )); then

    ACTIVE_CLUSTER="FIRST"
    KUBE_CMD="kubectl"

    print_ok \
        "AWX" \
        "Cluster FIRST actif : $AWX_FIRST_CONTEXT"

    print_info \
        "AWX" \
        "Cluster SECOND arrêté volontairement"

elif (( AWX_FIRST_RUNNING == 0 && AWX_SECOND_RUNNING == ${#AWX_SECOND_NODES[@]} )); then

    ACTIVE_CLUSTER="SECOND"

    if command_exists kube-latest; then
        KUBE_CMD="kube-latest"
    else
        KUBE_CMD="kubectl"
    fi

    print_ok \
        "AWX" \
        "Cluster SECOND actif : $AWX_SECOND_CONTEXT (${AWX_SECOND_RUNNING}/${#AWX_SECOND_NODES[@]} nodes Docker)"

    print_info \
        "AWX" \
        "Cluster FIRST arrêté volontairement"

else

    ACTIVE_CLUSTER="PARTIAL"

    print_critical \
        "AWX" \
        "Etat cluster incohérent FIRST=$AWX_FIRST_RUNNING SECOND=$AWX_SECOND_RUNNING/${#AWX_SECOND_NODES[@]}"

fi


# ==============================================================================
# AWX STATUS SCRIPTS
# ==============================================================================

print_title "AWX STATUS"


get_status_script()
{
    local SCRIPT="$1"

    if [[ ! -x "$SCRIPT" ]]; then
        echo "ERROR"
        return
    fi

    local VALUE

    VALUE="$(
        "$SCRIPT" 2>/dev/null \
        | tail -n1 \
        | tr -d '[:space:]'
    )"

    if [[ "$VALUE" == "0" || "$VALUE" == "1" ]]; then
        echo "$VALUE"
    else
        echo "ERROR"
    fi
}


AWX_FIRST_STATUS="$(get_status_script "$AWX_FIRST_STATUS_SCRIPT")"
AWX_SECOND_STATUS="$(get_status_script "$AWX_SECOND_STATUS_SCRIPT")"


if [[ "$AWX_FIRST_STATUS" == "ERROR" || "$AWX_SECOND_STATUS" == "ERROR" ]]; then

    print_critical \
        "AWX" \
        "Impossible de déterminer l'état AWX 1.30/1.34"

else

    if [[ "$AWX_FIRST_STATUS" == "1" && "$AWX_SECOND_STATUS" == "1" ]]; then

        print_critical \
            "AWX" \
            "Les deux clusters AWX répondent simultanément"

    elif [[ "$AWX_FIRST_STATUS" == "0" && "$AWX_SECOND_STATUS" == "0" ]]; then

        print_critical \
            "AWX" \
            "Les deux clusters AWX sont DOWN"

    elif [[ "$AWX_FIRST_STATUS" == "1" ]]; then

        print_ok "AWX" "AWX 1.30 : ACTIF"
        print_info "AWX" "AWX 1.34 : INACTIF"

    else

        print_ok "AWX" "AWX 1.34 : ACTIF"
        print_info "AWX" "AWX 1.30 : INACTIF"

    fi

fi


# ==============================================================================
# KUBERNETES
# ==============================================================================

print_title "KUBERNETES / KIND / HELM"

check_command_required "KUBERNETES" "kubectl"
check_command_required "KUBERNETES" "kind"
check_command_required "KUBERNETES" "helm"
check_command_optional "KUBERNETES" "k9s"
check_command_optional "KUBERNETES" "kube-latest"


if command_exists "$KUBE_CMD"; then

    if "$KUBE_CMD" cluster-info >/dev/null 2>&1; then

        CURRENT_CONTEXT="$(
            "$KUBE_CMD" config current-context \
                2>/dev/null \
                || echo "?"
        )"

        print_ok \
            "KUBERNETES" \
            "Cluster accessible - contexte=$CURRENT_CONTEXT via $KUBE_CMD"


        if [[ "$ACTIVE_CLUSTER" == "FIRST" \
              && "$CURRENT_CONTEXT" != "$AWX_FIRST_CONTEXT" ]]; then

            print_warning \
                "KUBERNETES" \
                "Contexte inattendu : attendu=$AWX_FIRST_CONTEXT actuel=$CURRENT_CONTEXT"

        elif [[ "$ACTIVE_CLUSTER" == "SECOND" \
                && "$CURRENT_CONTEXT" != "$AWX_SECOND_CONTEXT" ]]; then

            print_warning \
                "KUBERNETES" \
                "Contexte inattendu : attendu=$AWX_SECOND_CONTEXT actuel=$CURRENT_CONTEXT"
        fi


        if [[ "$MODE" == "full" ]]; then

            echo
            echo "Nodes Kubernetes :"
            echo

            "$KUBE_CMD" get nodes -o wide \
                2>/dev/null \
                | sed 's/^/        /'

        fi


        NODE_COUNT="$(
            "$KUBE_CMD" get nodes \
                --no-headers \
                2>/dev/null \
                | wc -l
        )"

        READY_COUNT="$(
            "$KUBE_CMD" get nodes \
                --no-headers \
                2>/dev/null \
                | awk '$2=="Ready"{c++} END{print c+0}'
        )"


        if [[ "$NODE_COUNT" -gt 0 \
              && "$NODE_COUNT" -eq "$READY_COUNT" ]]; then

            print_ok \
                "KUBERNETES" \
                "Nodes : ${READY_COUNT}/${NODE_COUNT} Ready"

        else

            print_critical \
                "KUBERNETES" \
                "Nodes : ${READY_COUNT}/${NODE_COUNT} Ready"

        fi


        if [[ "$MODE" == "full" ]]; then

            echo
            echo "Pods Kubernetes :"
            echo

            "$KUBE_CMD" get pods -A -o wide \
                2>/dev/null \
                | sed 's/^/        /'

        fi


        BAD_PODS="$(
            "$KUBE_CMD" get pods \
                -A \
                --no-headers \
                2>/dev/null \
            | awk '$4 !~ /^(Running|Completed|Succeeded)$/ {print}' \
            || true
        )"


        if [[ -z "$BAD_PODS" ]]; then

            POD_COUNT="$(
                "$KUBE_CMD" get pods \
                    -A \
                    --no-headers \
                    2>/dev/null \
                    | wc -l
            )"

            print_ok \
                "KUBERNETES" \
                "Pods : $POD_COUNT pods OK"

        else

            print_critical \
                "KUBERNETES" \
                "Pods en état anormal"

            [[ "$MODE" == "full" ]] \
                && echo "$BAD_PODS" \
                | sed 's/^/        /'

        fi


        # ----------------------------------------------------------------------
        # RESTARTS KUBERNETES
        # ----------------------------------------------------------------------

        if command_exists jq; then

            RESTART_DATA="$(
                "$KUBE_CMD" get pods \
                    -A \
                    -o json \
                    2>/dev/null \
                | jq -r '
                    .items[] as $pod |
                    ($pod.status.containerStatuses // [])[] |
                    select(.restartCount > 0) |
                    [
                        $pod.metadata.namespace,
                        $pod.metadata.name,
                        .name,
                        (.restartCount|tostring),
                        (.lastState.terminated.finishedAt // "")
                    ] | @tsv
                ' 2>/dev/null \
                || true
            )"


            if [[ -n "$RESTART_DATA" ]]; then

                [[ "$MODE" == "full" ]] && {
                    echo
                    echo "Containers avec historique de restart :"
                    echo
                    printf '%s\n' "$RESTART_DATA" \
                        | sed 's/^/        /'
                }

                NOW_EPOCH="$(date +%s)"

                UPTIME_SECONDS="$(
                    awk '{printf "%.0f",$1}' /proc/uptime
                )"

                RECENT_RESTART_FOUND=0


                while IFS=$'\t' read -r NS POD CONTAINER COUNT FINISHED

                do

                    [[ -z "$FINISHED" ]] && continue

                    FINISHED_EPOCH="$(
                        date -d "$FINISHED" +%s \
                        2>/dev/null \
                        || echo 0
                    )"

                    (( FINISHED_EPOCH == 0 )) && continue

                    AGE_SECONDS=$((NOW_EPOCH - FINISHED_EPOCH))


                    if (( AGE_SECONDS <= RECENT_RESTART_MINUTES * 60 )); then

                        RECENT_RESTART_FOUND=1

                        #
                        # Si le serveur vient lui-même d'être rebooté,
                        # les restarts Kubernetes sont normaux.
                        #

                        if (( UPTIME_SECONDS < 1800 )); then

                            print_info \
                                "KUBERNETES" \
                                "$NS/$POD restart récent après reboot serveur"

                        else

                            print_warning \
                                "KUBERNETES" \
                                "$NS/$POD/$CONTAINER restart récent (${COUNT} total)"

                        fi

                    fi

                done <<< "$RESTART_DATA"


                if (( RECENT_RESTART_FOUND == 0 )); then

                    print_ok \
                        "KUBERNETES" \
                        "Aucun restart Kubernetes récent (< ${RECENT_RESTART_MINUTES} min)"
                fi

            else

                print_ok \
                    "KUBERNETES" \
                    "Aucun container Kubernetes avec restart"

            fi

        fi


        # ----------------------------------------------------------------------
        # METRICS
        # ----------------------------------------------------------------------

        if "$KUBE_CMD" top nodes \
            >/dev/null 2>&1
        then

            print_ok \
                "KUBERNETES" \
                "Metrics Kubernetes disponibles"

            if [[ "$MODE" == "full" ]]; then

                echo
                echo "kubectl top nodes :"
                echo

                "$KUBE_CMD" top nodes \
                    2>/dev/null \
                    | sed 's/^/        /'


                echo
                echo "Top pods :"
                echo

                "$KUBE_CMD" top pods \
                    -A \
                    --sort-by=memory \
                    2>/dev/null \
                    | head -15 \
                    | sed 's/^/        /'

            fi

        else

            print_info \
                "KUBERNETES" \
                "Metrics API non disponible - kubectl top ignoré"

        fi


        if [[ "$MODE" == "full" ]]; then

            echo
            echo "Releases Helm :"
            echo

            helm list -A \
                2>/dev/null \
                | sed 's/^/        /'

        fi

    else

        print_critical \
            "KUBERNETES" \
            "$KUBE_CMD présent mais cluster inaccessible"

    fi

fi


# ==============================================================================
# KIND
# ==============================================================================

if command_exists kind; then

    KIND_CLUSTERS="$(
        kind get clusters \
        2>/dev/null \
        || true
    )"

    if [[ -n "$KIND_CLUSTERS" ]]; then

        print_ok \
            "KUBERNETES" \
            "Clusters Kind configurés : $(echo "$KIND_CLUSTERS" | xargs)"

        if [[ "$MODE" == "full" ]]; then
            echo "$KIND_CLUSTERS" \
                | sed 's/^/        - /'
        fi

    else

        print_warning \
            "KUBERNETES" \
            "Kind installé mais aucun cluster trouvé"

    fi

fi


# ==============================================================================
# DOCKER
# ==============================================================================

print_title "DOCKER"

if command_exists docker; then

    if docker info >/dev/null 2>&1; then

        print_ok "DOCKER" "Docker daemon accessible"


        if [[ "$MODE" == "full" ]]; then

            echo
            echo "Docker ps :"
            echo

            docker ps \
                --format \
                'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' \
                2>/dev/null \
                | sed 's/^/        /'


            echo
            echo "Docker ps -a :"
            echo

            docker ps -a \
                --format \
                'table {{.Names}}\t{{.Image}}\t{{.Status}}' \
                2>/dev/null \
                | sed 's/^/        /'

        fi


        UNHEALTHY="$(
            docker ps \
                --filter health=unhealthy \
                --format '{{.Names}}' \
                2>/dev/null \
                || true
        )"


        if [[ -n "$UNHEALTHY" ]]; then

            print_critical \
                "DOCKER" \
                "Conteneur(s) unhealthy : $(echo "$UNHEALTHY" | xargs)"

        else

            print_ok \
                "DOCKER" \
                "Aucun conteneur unhealthy"

        fi


        # ----------------------------------------------------------------------
        # Conteneurs EXITED intelligents
        # ----------------------------------------------------------------------

        EXITED="$(
            docker ps \
                -a \
                --filter status=exited \
                --format '{{.Names}}' \
                2>/dev/null \
                || true
        )"

        UNEXPECTED_EXITED=""

        while IFS= read -r C

        do

            [[ -z "$C" ]] && continue

            EXPECTED=0


            if [[ "$ACTIVE_CLUSTER" == "SECOND" \
                  && "$C" == "awx130-control-plane" ]]; then

                EXPECTED=1

            elif [[ "$ACTIVE_CLUSTER" == "FIRST" ]]; then

                for SECOND_NODE in "${AWX_SECOND_NODES[@]}"; do

                    if [[ "$C" == "$SECOND_NODE" ]]; then
                        EXPECTED=1
                    fi

                done

            fi


            if (( EXPECTED == 1 )); then

                print_info \
                    "DOCKER" \
                    "$C arrêté volontairement - cluster AWX standby"

            else

                UNEXPECTED_EXITED+="${C}"$'\n'

            fi

        done <<< "$EXITED"


        if [[ -n "${UNEXPECTED_EXITED//[$'\n']/}" ]]; then

            print_warning \
                "DOCKER" \
                "Conteneur(s) arrêté(s) inattendu(s)"

            [[ "$MODE" == "full" ]] \
                && echo "$UNEXPECTED_EXITED" \
                | sed '/^$/d;s/^/        /'

        else

            print_ok \
                "DOCKER" \
                "Aucun conteneur arrêté de manière inattendue"

        fi


        if [[ "$MODE" == "full" ]]; then

            echo
            echo "Docker volume ls :"
            echo

            docker volume ls \
                2>/dev/null \
                | sed 's/^/        /'


            echo
            echo "Docker system df :"
            echo

            docker system df \
                2>/dev/null \
                | sed 's/^/        /'


            echo
            echo "Docker networks :"
            echo

            docker network ls \
                2>/dev/null \
                | sed 's/^/        /'

        fi


        DOCKER_ROOT="$(
            docker info \
                --format '{{.DockerRootDir}}' \
                2>/dev/null \
                || echo "/var/lib/docker"
        )"

        if [[ -d "$DOCKER_ROOT" ]]; then

            DOCKER_SIZE="$(
                du -sh "$DOCKER_ROOT" \
                    2>/dev/null \
                    | awk '{print $1}'
            )"

            print_info \
                "DOCKER" \
                "Stockage Docker : ${DOCKER_SIZE:-?} dans $DOCKER_ROOT"

        fi

    else

        print_critical \
            "DOCKER" \
            "Docker installé mais daemon inaccessible"

    fi

else

    print_critical "DOCKER" "Docker absent"

fi


# ==============================================================================
# DISQUES
# ==============================================================================

print_title "DISQUES / ESPACE / INODES"

if [[ "$MODE" == "full" ]]; then

    echo "Filesystems :"
    echo

    df -hPT \
        -x tmpfs \
        -x devtmpfs \
        -x squashfs \
        -x overlay \
        2>/dev/null \
        | sed 's/^/        /'

fi


while read -r FS TYPE BLOCKS USED AVAIL PCT MOUNT

do

    [[ "$PCT" == "Use%" ]] && continue

    VALUE="${PCT%%%}"

    [[ "$VALUE" =~ ^[0-9]+$ ]] || continue


    if (( VALUE >= DISK_CRIT )); then

        print_critical \
            "DISK" \
            "$MOUNT : ${VALUE}% utilisé"

    elif (( VALUE >= DISK_WARN )); then

        print_warning \
            "DISK" \
            "$MOUNT : ${VALUE}% utilisé"

    else

        print_ok \
            "DISK" \
            "$MOUNT : ${VALUE}% utilisé"

    fi

done < <(
    df -PT \
        -x tmpfs \
        -x devtmpfs \
        -x squashfs \
        -x overlay \
        2>/dev/null
)


if [[ "$MODE" == "full" ]]; then

    echo
    echo "Inodes :"
    echo

    df -hiP \
        -x tmpfs \
        -x devtmpfs \
        -x squashfs \
        -x overlay \
        2>/dev/null \
        | sed 's/^/        /'

fi


while read -r FS INODES IUSED IFREE IPCT MOUNT

do

    [[ "$IPCT" == "IUse%" ]] && continue

    VALUE="${IPCT%%%}"

    [[ "$VALUE" =~ ^[0-9]+$ ]] || continue


    if (( VALUE >= INODE_CRIT )); then

        print_critical \
            "DISK" \
            "Inodes $MOUNT : ${VALUE}% utilisés"

    elif (( VALUE >= INODE_WARN )); then

        print_warning \
            "DISK" \
            "Inodes $MOUNT : ${VALUE}% utilisés"

    fi

done < <(
    df -iP \
        -x tmpfs \
        -x devtmpfs \
        -x squashfs \
        -x overlay \
        2>/dev/null
)


# ==============================================================================
# RAM / SWAP / LOAD
# ==============================================================================

print_title "RAM / SWAP / LOAD"

if [[ "$MODE" == "full" ]]; then
    free -h | sed 's/^/        /'
fi


MEM_TOTAL="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
MEM_AVAILABLE="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"

MEM_USED=$((MEM_TOTAL - MEM_AVAILABLE))

RAM_PERCENT="$(
    human_pct \
        "$MEM_USED" \
        "$MEM_TOTAL"
)"


if (( RAM_PERCENT >= RAM_CRIT )); then

    print_critical \
        "RAM" \
        "RAM : ${RAM_PERCENT}% utilisée"

elif (( RAM_PERCENT >= RAM_WARN )); then

    print_warning \
        "RAM" \
        "RAM : ${RAM_PERCENT}% utilisée"

else

    print_ok \
        "RAM" \
        "RAM : ${RAM_PERCENT}% utilisée"

fi


SWAP_TOTAL="$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"
SWAP_FREE="$(awk '/SwapFree/ {print $2}' /proc/meminfo)"

SWAP_USED=$((SWAP_TOTAL - SWAP_FREE))


if (( SWAP_TOTAL > 0 )); then

    SWAP_PERCENT="$(
        human_pct \
            "$SWAP_USED" \
            "$SWAP_TOTAL"
    )"

    if (( SWAP_PERCENT >= SWAP_WARN )); then

        print_warning \
            "RAM" \
            "SWAP : ${SWAP_PERCENT}% utilisée"

    else

        print_ok \
            "RAM" \
            "SWAP : ${SWAP_PERCENT}% utilisée"

    fi

else

    print_info \
        "RAM" \
        "SWAP non configurée"

fi


CPU_COUNT="$(nproc 2>/dev/null || echo 1)"
LOAD1="$(awk '{print $1}' /proc/loadavg)"

LOAD_WARN="$CPU_COUNT"
LOAD_CRIT=$((CPU_COUNT * LOAD_CRIT_FACTOR))


if awk \
    -v l="$LOAD1" \
    -v c="$LOAD_CRIT" \
    'BEGIN {exit !(l >= c)}'
then

    print_critical \
        "SYSTEM" \
        "Load 1m=$LOAD1 / CPU=$CPU_COUNT"

elif awk \
    -v l="$LOAD1" \
    -v c="$LOAD_WARN" \
    'BEGIN {exit !(l >= c)}'
then

    print_warning \
        "SYSTEM" \
        "Load 1m=$LOAD1 / CPU=$CPU_COUNT"

else

    print_ok \
        "SYSTEM" \
        "Load 1m=$LOAD1 / CPU=$CPU_COUNT"

fi


# ==============================================================================
# SELINUX
# ==============================================================================

print_title "SELINUX"

if command_exists getenforce; then

    SELINUX_STATE="$(getenforce 2>/dev/null)"

    case "$SELINUX_STATE" in

        Enforcing)

            print_ok \
                "SELINUX" \
                "SELinux : Enforcing"
            ;;

        Permissive)

            print_warning \
                "SELINUX" \
                "SELinux : Permissive"
            ;;

        Disabled)

            print_warning \
                "SELINUX" \
                "SELinux : Disabled"
            ;;

        *)

            print_warning \
                "SELINUX" \
                "SELinux : état inconnu ($SELINUX_STATE)"
            ;;

    esac

else

    print_na \
        "SELINUX" \
        "getenforce absent"

fi


# ==============================================================================
# WEB / NGINX / APACHE
# ==============================================================================

print_title "SERVICES WEB"

check_service_required "WEB" "nginx"
check_service_optional "WEB" "httpd"
check_service_optional "WEB" "apache2"
check_service_optional "WEB" "haproxy"


if command_exists nginx; then

    if nginx -t >/dev/null 2>&1; then

        print_ok \
            "WEB" \
            "Configuration nginx valide"

    else

        print_critical \
            "WEB" \
            "nginx -t en erreur"

    fi

fi


if service_exists httpd \
   && systemctl is-active --quiet httpd
then

    if httpd -t >/dev/null 2>&1; then

        print_ok \
            "WEB" \
            "Configuration Apache/httpd valide"

    else

        print_critical \
            "WEB" \
            "Configuration Apache/httpd invalide"

    fi

fi


# ==============================================================================
# WORKFLOW PHP / APACHE
# ==============================================================================

print_title "WORKFLOW"

WORKFLOW_INDEX="$WORKFLOW_DIR/index.php"


if systemctl is-active --quiet httpd; then

    print_ok \
        "WORKFLOW" \
        "Apache/httpd actif"

else

    print_critical \
        "WORKFLOW" \
        "Apache/httpd inactif"

fi


if service_exists php-fpm; then

    if systemctl is-active --quiet php-fpm; then

        print_ok \
            "WORKFLOW" \
            "PHP-FPM actif"

    else

        print_critical \
            "WORKFLOW" \
            "PHP-FPM inactif"

    fi

else

    print_warning \
        "WORKFLOW" \
        "php-fpm.service absent"

fi


if [[ -d "$WORKFLOW_DIR" ]]; then

    print_ok \
        "WORKFLOW" \
        "DocumentRoot présent : $WORKFLOW_DIR"

else

    print_critical \
        "WORKFLOW" \
        "DocumentRoot absent : $WORKFLOW_DIR"

fi


if [[ -f "$WORKFLOW_INDEX" ]]; then

    print_ok \
        "WORKFLOW" \
        "index.php présent"

else

    print_critical \
        "WORKFLOW" \
        "index.php absent"

fi


for PORT in "$WORKFLOW_HTTP_PORT" "$WORKFLOW_HTTPS_PORT"
do

    if ss -lnt \
        2>/dev/null \
        | awk '{print $4}' \
        | grep -qE ":${PORT}$"
    then

        print_ok \
            "WORKFLOW" \
            "Port $PORT en écoute"

    else

        print_warning \
            "WORKFLOW" \
            "Port $PORT non détecté"

    fi

done


check_workflow_http()
{
    local PORT="$1"
    local PROTOCOL="$2"

    local CODE

    CODE="$(
        curl \
            -k \
            -s \
            -o /dev/null \
            -w '%{http_code}' \
            --connect-timeout 3 \
            --max-time 5 \
            "${PROTOCOL}://127.0.0.1:${PORT}/" \
            2>/dev/null \
            || echo "000"
    )"

    case "$CODE" in

        200|301|302|303|307|308)

            print_ok \
                "WORKFLOW" \
                "Workflow ${PROTOCOL^^} :$PORT répond HTTP $CODE"
            ;;

        401|403)

            print_ok \
                "WORKFLOW" \
                "Workflow ${PROTOCOL^^} :$PORT répond HTTP $CODE"
            ;;

        404)

            print_warning \
                "WORKFLOW" \
                "Apache répond sur ${PROTOCOL^^} :$PORT mais retourne 404"
            ;;

        5??)

            print_critical \
                "WORKFLOW" \
                "Workflow ${PROTOCOL^^} :$PORT retourne HTTP $CODE"
            ;;

        *)

            print_critical \
                "WORKFLOW" \
                "Workflow ${PROTOCOL^^} :$PORT inaccessible (HTTP $CODE)"
            ;;

    esac
}

check_workflow_http "$WORKFLOW_HTTP_PORT" http
check_workflow_http "$WORKFLOW_HTTPS_PORT" https


# ==============================================================================
# HTTP APPLICATIONS
# ==============================================================================

print_title "APPLICATION HEALTH HTTP"


check_http()
{
    local CATEGORY="$1"
    local NAME="$2"
    local URL="$3"

    if ! command_exists curl; then
        print_na "$CATEGORY" "$NAME : curl absent"
        return
    fi

    local CODE

    CODE="$(
        curl \
            -k \
            -s \
            -o /dev/null \
            -w '%{http_code}' \
            --connect-timeout 3 \
            --max-time 5 \
            "$URL" \
            2>/dev/null \
            || echo "000"
    )"

    case "$CODE" in

        2??|3??|401|403|404)

            print_ok \
                "$CATEGORY" \
                "$NAME répond : HTTP $CODE"
            ;;

        5??)

            print_warning \
                "$CATEGORY" \
                "$NAME répond mais retourne HTTP $CODE"
            ;;

        *)

            print_critical \
                "$CATEGORY" \
                "$NAME inaccessible : HTTP $CODE"
            ;;

    esac
}

check_http \
    "APP_API" \
    "Application API" \
    "$APP_API_URL"

check_http \
    "INFRA_API" \
    "Infrastructure API" \
    "$INFRA_API_URL"

check_http \
    "JENKINS" \
    "Jenkins" \
    "$JENKINS_URL"


# ==============================================================================
# POSTGRESQL
# ==============================================================================

print_title "POSTGRESQL"

check_service_required \
    "POSTGRESQL" \
    "postgresql"


if command_exists pg_isready; then

    if pg_isready \
        -h 127.0.0.1 \
        -p 5432 \
        >/dev/null 2>&1
    then

        print_ok \
            "POSTGRESQL" \
            "PostgreSQL accepte les connexions sur 127.0.0.1:5432"

    else

        print_critical \
            "POSTGRESQL" \
            "PostgreSQL n'accepte pas les connexions"

    fi

else

    print_warning \
        "POSTGRESQL" \
        "pg_isready absent"

fi


# ==============================================================================
# MYSQL / MARIADB - OPTIONNELS
# ==============================================================================

print_title "BASES DE DONNEES OPTIONNELLES"

check_command_optional \
    "POSTGRESQL" \
    "mysql"

check_service_optional \
    "POSTGRESQL" \
    "mysqld"

check_service_optional \
    "POSTGRESQL" \
    "mariadb"


# ==============================================================================
# FIREWALL
# ==============================================================================

print_title "FIREWALL / PORTS"

if service_exists firewalld; then

    if systemctl is-active --quiet firewalld; then

        print_ok \
            "FIREWALL" \
            "firewalld actif"

        if [[ "$MODE" == "full" ]]; then

            echo
            echo "Zones :"
            echo

            firewall-cmd \
                --get-active-zones \
                2>/dev/null \
                | sed 's/^/        /'


            echo
            echo "Services autorisés :"
            echo

            firewall-cmd \
                --list-services \
                2>/dev/null \
                | sed 's/^/        /'


            echo
            echo "Ports autorisés :"
            echo

            firewall-cmd \
                --list-ports \
                2>/dev/null \
                | sed 's/^/        /'


            echo
            echo "Ports en écoute :"
            echo

            ss -lntup \
                2>/dev/null \
                | sed 's/^/        /'

        fi


        FIREWALL_PORTS="$(
            firewall-cmd \
                --list-ports \
                2>/dev/null \
                || true
        )"


        for P in \
            5432/tcp \
            8000/tcp \
            8001/tcp \
            8080/tcp
        do

            if grep -qw "$P" <<< "$FIREWALL_PORTS"; then

                print_info \
                    "FIREWALL" \
                    "Port applicatif explicitement autorisé : $P"

            fi

        done

    else

        print_warning \
            "FIREWALL" \
            "firewalld installé mais inactif"

    fi

else

    print_na \
        "FIREWALL" \
        "firewalld non installé"

fi


# ==============================================================================
# LOGROTATE
# ==============================================================================

print_title "LOGROTATE"

if command_exists logrotate; then

    print_ok \
        "LOGROTATE" \
        "logrotate installé"

    if systemctl is-active \
        --quiet \
        logrotate.timer
    then

        print_ok \
            "LOGROTATE" \
            "logrotate.timer actif"

    else

        print_critical \
            "LOGROTATE" \
            "logrotate.timer inactif"

    fi


    LOGROTATE_ERRORS="$(
        journalctl \
            -u logrotate.service \
            --since "$JOURNAL_SINCE" \
            -p warning..alert \
            --no-pager \
            2>/dev/null \
        | grep -v '^-- No entries --$' \
        || true
    )"


    if [[ -n "$LOGROTATE_ERRORS" ]]; then

        print_warning \
            "LOGROTATE" \
            "logrotate : erreurs récentes"

        [[ "$MODE" == "full" ]] \
            && echo "$LOGROTATE_ERRORS" \
            | tail -20 \
            | sed 's/^/        /'

    else

        print_ok \
            "LOGROTATE" \
            "Aucune erreur logrotate récente"

    fi


    if [[ "$MODE" == "full" ]]; then

        systemctl list-timers \
            logrotate.timer \
            --no-pager \
            2>/dev/null \
            | sed 's/^/        /'

    fi

else

    print_critical \
        "LOGROTATE" \
        "logrotate absent"

fi


# ==============================================================================
# CRON
# ==============================================================================

print_title "CRON / AUTOMATISATION"

check_service_required \
    "CRON" \
    "crond"


if [[ "$MODE" == "full" ]]; then

    echo
    echo "Crontab root :"
    echo

    crontab -l \
        2>/dev/null \
        | sed 's/^/        /' \
        || echo "        aucune crontab"


    echo
    echo "Systemd timers :"
    echo

    systemctl list-timers \
        --all \
        --no-pager \
        2>/dev/null \
        | sed 's/^/        /'

fi


CRON_ERRORS="$(
    journalctl \
        -u crond \
        --since "$JOURNAL_SINCE" \
        -p warning..alert \
        --no-pager \
        2>/dev/null \
    | grep -v '^-- No entries --$' \
    || true
)"


if [[ -n "$CRON_ERRORS" ]]; then

    print_warning \
        "CRON" \
        "crond : erreurs récentes"

else

    print_ok \
        "CRON" \
        "crond : aucune erreur récente"

fi


# ==============================================================================
# ACTIVITE DES CRONS PAR AGE DES LOGS
# ==============================================================================

check_activity_file()
{
    local NAME="$1"
    local FILE="$2"
    local WARN_HOURS="$3"
    local CRIT_HOURS="$4"

    if [[ ! -f "$FILE" ]]; then

        print_warning \
            "CRON" \
            "$NAME : log absent $FILE"

        return
    fi

    local AGE
    AGE="$(age_hours "$FILE")"


    if (( AGE >= CRIT_HOURS )); then

        print_critical \
            "CRON" \
            "$NAME : aucune activité depuis ${AGE}h"

    elif (( AGE >= WARN_HOURS )); then

        print_warning \
            "CRON" \
            "$NAME : dernière activité il y a ${AGE}h"

    else

        print_ok \
            "CRON" \
            "$NAME : dernière activité il y a ${AGE}h"

    fi
}


check_activity_file \
    "AWX auto-heal" \
    "/var/log/awx-auto-heal.log" \
    2 \
    3

check_activity_file \
    "Terraform kubeconfig" \
    "/var/log/terraform-kubeconfig.log" \
    14 \
    26

check_activity_file \
    "Terraform backup" \
    "/var/log/terraform-backup.log" \
    30 \
    54

check_activity_file \
    "AWX PostgreSQL backup" \
    "/var/log/backup-postgres-awx.log" \
    30 \
    54

check_activity_file \
    "AWX Full backup" \
    "/var/log/backup-awx-full.log" \
    192 \
    240


# ==============================================================================
# BACKUPS
# ==============================================================================

print_title "BACKUPS"


find_latest_file()
{
    local DIR="$1"
    local PATTERN="$2"

    find "$DIR" \
        -maxdepth 4 \
        -type f \
        -name "$PATTERN" \
        -printf '%T@ %p\n' \
        2>/dev/null \
        | sort -nr \
        | head -1 \
        | cut -d' ' -f2-
}


check_backup()
{
    local NAME="$1"
    local DIR="$2"
    local PATTERN="$3"
    local WARN_HOURS="$4"
    local CRIT_HOURS="$5"
    local TYPE="${6:-file}"

    if [[ ! -d "$DIR" ]]; then

        print_critical \
            "BACKUPS" \
            "$NAME : répertoire absent $DIR"

        return
    fi

    local LAST_FILE

    LAST_FILE="$(
        find_latest_file \
            "$DIR" \
            "$PATTERN"
    )"


    if [[ -z "$LAST_FILE" ]]; then

        print_critical \
            "BACKUPS" \
            "$NAME : aucun fichier $PATTERN"

        return
    fi


    local AGE
    local SIZE

    AGE="$(age_hours "$LAST_FILE")"

    SIZE="$(
        du -h "$LAST_FILE" \
            2>/dev/null \
            | awk '{print $1}'
    )"


    if [[ ! -s "$LAST_FILE" ]]; then

        print_critical \
            "BACKUPS" \
            "$NAME : fichier vide"

        return
    fi


    if (( AGE >= CRIT_HOURS )); then

        print_critical \
            "BACKUPS" \
            "$NAME : backup vieux de ${AGE}h"

    elif (( AGE >= WARN_HOURS )); then

        print_warning \
            "BACKUPS" \
            "$NAME : backup vieux de ${AGE}h"

    else

        print_ok \
            "BACKUPS" \
            "$NAME : ${AGE}h / ${SIZE:-?} / $(basename "$LAST_FILE")"

    fi


    # --------------------------------------------------------------------------
    # Vérification minimale d'intégrité
    # --------------------------------------------------------------------------

    case "$TYPE" in

        postgres)

            if command_exists pg_restore; then

                if pg_restore \
                    -l \
                    "$LAST_FILE" \
                    >/dev/null 2>&1
                then

                    print_ok \
                        "BACKUPS" \
                        "$NAME : dump PostgreSQL lisible"

                else

                    print_critical \
                        "BACKUPS" \
                        "$NAME : dump PostgreSQL invalide"

                fi

            fi
            ;;


        zip)

            if command_exists unzip; then

                if unzip \
                    -tq \
                    "$LAST_FILE" \
                    >/dev/null 2>&1
                then

                    print_ok \
                        "BACKUPS" \
                        "$NAME : archive ZIP valide"

                else

                    print_critical \
                        "BACKUPS" \
                        "$NAME : archive ZIP corrompue"

                fi

            fi
            ;;

        tar)

            if command_exists tar; then

                if tar \
                    -tzf \
                    "$LAST_FILE" \
                    >/dev/null 2>&1
                then

                    print_ok \
                        "BACKUPS" \
                        "$NAME : archive TAR.GZ valide"

                else

                    print_critical \
                        "BACKUPS" \
                        "$NAME : archive TAR.GZ corrompue"

                fi

            else

                print_warning \
                    "BACKUPS" \
                    "$NAME : commande tar absente"

            fi
            ;;

    esac
}


#
# AWX FULL : hebdomadaire
#

check_backup \
    "AWX Full" \
    "$AWX_FULL_BACKUP_DIR" \
    "awx-full-backup-*.tar.gz" \
    192 \
    240 \
    "tar"


#
# PostgreSQL AWX 1.30 : quotidien
#
# Exemple :
# awxdb_2026-08-21_02-15-01.dump
#

check_backup \
    "PostgreSQL AWX 1.30" \
    "$AWX_POSTGRES_BACKUP_DIR" \
    "awxdb_130_*.dump" \
    30 \
    54 \
    "postgres"


#
# PostgreSQL AWX 1.34 : quotidien
#
# Exemple :
# awxdb_134_2026-08-21_02-15-01.dump
#

check_backup \
    "PostgreSQL AWX 1.34" \
    "$AWX_POSTGRES_BACKUP_DIR" \
    "awxdb_134_*.dump" \
    30 \
    54 \
    "postgres"


#
# Terraform : quotidien
#

check_backup \
    "Terraform" \
    "$TERRAFORM_BACKUP_DIR" \
    "terraform-*.zip" \
    30 \
    54 \
    "zip"


if [[ "$MODE" == "full" ]]; then

    echo
    echo "Derniers backups PostgreSQL :"
    echo

    find "$AWX_POSTGRES_BACKUP_DIR" \
        -maxdepth 1 \
        -type f \
        -name '*.dump' \
        -printf '%TY-%Tm-%Td %TH:%TM %9s %f\n' \
        2>/dev/null \
        | sort -r \
        | head -10 \
        | sed 's/^/        /'

fi


# ==============================================================================
# OUTILS DEVOPS
# ==============================================================================

print_title "OUTILS DEVOPS / LANGAGES"

check_command_required "SYSTEM" "git"
check_command_required "SYSTEM" "ansible"
check_command_required "SYSTEM" "ansible-playbook"
check_command_required "SYSTEM" "terraform"
check_command_required "SYSTEM" "python3"
check_command_optional "SYSTEM" "php"
check_command_required "SYSTEM" "java"
check_command_required "SYSTEM" "curl"
check_command_required "SYSTEM" "jq"

#
# MySQL volontairement OPTIONNEL :
# son absence n'est PAS un warning.
#

check_command_optional "SYSTEM" "mysql"


if [[ "$MODE" == "full" ]]; then

    echo
    echo "Versions :"
    echo

    command_exists kubectl &&
        echo "        kubectl    : $(kubectl version --client 2>/dev/null | head -1)"

    command_exists kube-latest &&
        echo "        kube-latest: $(kube-latest version --client 2>/dev/null | head -1)"

    command_exists kind &&
        echo "        kind       : $(kind version 2>/dev/null)"

    command_exists helm &&
        echo "        helm       : $(helm version --short 2>/dev/null)"

    command_exists terraform &&
        echo "        terraform  : $(terraform version 2>/dev/null | head -1)"

    command_exists ansible &&
        echo "        ansible    : $(ansible --version 2>/dev/null | head -1)"

    command_exists python3 &&
        echo "        python     : $(python3 --version 2>&1)"

    command_exists php &&
        echo "        php        : $(php -v 2>/dev/null | head -1)"

    command_exists psql &&
        echo "        postgres   : $(psql --version 2>/dev/null)"

    command_exists docker &&
        echo "        docker     : $(docker --version 2>/dev/null)"

    command_exists git &&
        echo "        git        : $(git --version 2>/dev/null)"

fi


# ==============================================================================
# NTP / CHRONY
# ==============================================================================

print_title "NTP / CHRONY"

if service_exists chronyd; then

    if systemctl is-active --quiet chronyd; then

        print_ok \
            "NTP" \
            "chronyd actif"

    else

        print_warning \
            "NTP" \
            "chronyd inactif"

    fi

else

    print_na \
        "NTP" \
        "chronyd non installé"

fi


if command_exists timedatectl; then

    NTP_SYNC="$(
        timedatectl show \
            -p NTPSynchronized \
            --value \
            2>/dev/null \
            || echo "unknown"
    )"

    if [[ "$NTP_SYNC" == "yes" ]]; then

        print_ok \
            "NTP" \
            "Horloge synchronisée"

    else

        print_warning \
            "NTP" \
            "Horloge non synchronisée : $NTP_SYNC"

    fi

fi


if command_exists chronyc \
   && [[ "$MODE" == "full" ]]
then

    echo
    echo "Chrony tracking :"
    echo

    chronyc tracking \
        2>/dev/null \
        | sed 's/^/        /'


    echo
    echo "Chrony sources :"
    echo

    chronyc sources \
        2>/dev/null \
        | sed 's/^/        /'

fi


# ==============================================================================
# TLS / CERTIFICATS NGINX
# ==============================================================================

print_title "TLS / CERTIFICATS"


check_certificate_file()
{
    local CERT_FILE="$1"
    local SERVER_NAME="${2:-unknown}"

    if [[ ! -f "$CERT_FILE" ]]; then

        print_critical \
            "TLS" \
            "Certificat introuvable : $CERT_FILE (server_name=$SERVER_NAME)"

        return
    fi


    local SUBJECT
    local ISSUER
    local SERIAL
    local START_DATE
    local END_DATE
    local CERT_EPOCH
    local NOW_EPOCH
    local DAYS_LEFT


    SUBJECT="$(
        openssl x509 \
            -in "$CERT_FILE" \
            -noout \
            -subject \
            2>/dev/null \
            | sed 's/^subject=//'
    )"


    ISSUER="$(
        openssl x509 \
            -in "$CERT_FILE" \
            -noout \
            -issuer \
            2>/dev/null \
            | sed 's/^issuer=//'
    )"


    SERIAL="$(
        openssl x509 \
            -in "$CERT_FILE" \
            -noout \
            -serial \
            2>/dev/null \
            | cut -d= -f2-
    )"


    START_DATE="$(
        openssl x509 \
            -in "$CERT_FILE" \
            -noout \
            -startdate \
            2>/dev/null \
            | cut -d= -f2-
    )"


    END_DATE="$(
        openssl x509 \
            -in "$CERT_FILE" \
            -noout \
            -enddate \
            2>/dev/null \
            | cut -d= -f2-
    )"


    if [[ -z "$END_DATE" ]]; then

        print_critical \
            "TLS" \
            "Impossible de lire le certificat : $CERT_FILE"

        return
    fi


    CERT_EPOCH="$(
        date -d "$END_DATE" +%s \
        2>/dev/null \
        || echo 0
    )"

    NOW_EPOCH="$(date +%s)"


    if (( CERT_EPOCH == 0 )); then

        print_warning \
            "TLS" \
            "Impossible de calculer l'expiration : $CERT_FILE"

        return
    fi


    DAYS_LEFT=$(( (CERT_EPOCH - NOW_EPOCH) / 86400 ))


    if [[ "$MODE" == "full" ]]; then

        echo
        echo "Certificat :"
        echo "        Server Name : $SERVER_NAME"
        echo "        Fichier     : $CERT_FILE"
        echo "        Subject     : $SUBJECT"
        echo "        Issuer      : $ISSUER"
        echo "        Serial      : $SERIAL"
        echo "        Valide du   : $START_DATE"
        echo "        Valide au   : $END_DATE"
        echo "        Jours reste : $DAYS_LEFT"
        echo

    fi


    if (( DAYS_LEFT < 0 )); then

        print_critical \
            "TLS" \
            "$SERVER_NAME : certificat EXPIRE depuis $(( -DAYS_LEFT )) jour(s) - $CERT_FILE"

    elif (( DAYS_LEFT <= TLS_CRIT_DAYS )); then

        print_critical \
            "TLS" \
            "$SERVER_NAME : certificat expire dans ${DAYS_LEFT} jours - $CERT_FILE"

    elif (( DAYS_LEFT <= TLS_WARN_DAYS )); then

        print_warning \
            "TLS" \
            "$SERVER_NAME : certificat expire dans ${DAYS_LEFT} jours - $CERT_FILE"

    else

        print_ok \
            "TLS" \
            "$SERVER_NAME : certificat valide encore ${DAYS_LEFT} jours - $CERT_FILE"

    fi
}


if command_exists nginx \
   && command_exists openssl
then

    #
    # nginx -T permet de récupérer la configuration réellement chargée,
    # includes compris.
    #

    NGINX_CONFIG="$(
        nginx -T \
            2>/dev/null \
            || true
    )"


    if [[ -z "$NGINX_CONFIG" ]]; then

        print_warning \
            "TLS" \
            "Impossible de lire la configuration nginx"

    else

        CERT_FOUND=0


        while IFS='|' read -r SERVER_NAME CERT_FILE

        do

            [[ -z "$CERT_FILE" ]] && continue

            CERT_FOUND=1

            check_certificate_file \
                "$CERT_FILE" \
                "$SERVER_NAME"

        done < <(
            awk '
                BEGIN {
                    server_name="unknown"
                }

                /^[[:space:]]*server_name[[:space:]]+/ {
                    server_name=$0

                    sub(/^[[:space:]]*server_name[[:space:]]+/, "", server_name)
                    sub(/;[[:space:]]*$/, "", server_name)
                }

                /^[[:space:]]*ssl_certificate[[:space:]]+/ {
                    cert=$0

                    sub(/^[[:space:]]*ssl_certificate[[:space:]]+/, "", cert)
                    sub(/;[[:space:]]*$/, "", cert)

                    print server_name "|" cert
                }
            ' <<< "$NGINX_CONFIG" \
            | sort -u
        )


        if (( CERT_FOUND == 0 )); then

            print_na \
                "TLS" \
                "Aucun ssl_certificate trouvé dans nginx"

        fi

    fi

else

    print_na \
        "TLS" \
        "nginx ou openssl absent"

fi


# ==============================================================================
# SCRIPTS DEVOPS-LAB-01
# ==============================================================================

print_title "SCRIPTS DEVOPS-LAB-01"

SCRIPTS=(
    "/usr/local/bin/awx-auto-heal.sh"
    "/usr/local/bin/backup-awx-full.sh"
    "/usr/local/bin/backup-awx-postgres.sh"
    "/usr/local/bin/backup-terraform.sh"
    "/usr/local/bin/switch-awx.sh"

    "/opt/workflow/cleanup-workflow.sh"
    "/opt/workflow/deploy-workflow.sh"

    "/opt/terraform/generate-token-and-kubeconfig.sh"

    "/etc/zabbix/zabbix-awx-134-status.sh"
    "/etc/zabbix/zabbix-awx-130-status.sh"
)

for SCRIPT in "${SCRIPTS[@]}"; do

    check_file_exec \
        "SYSTEM" \
        "$SCRIPT"

done


# ==============================================================================
# TERRAFORM
# ==============================================================================

print_title "TERRAFORM"

if [[ -f "/opt/terraform/terraform.tfstate" ]]; then

    STATE_SIZE="$(
        du -h \
            /opt/terraform/terraform.tfstate \
            2>/dev/null \
            | awk '{print $1}'
    )"

    print_ok \
        "SYSTEM" \
        "terraform.tfstate présent (${STATE_SIZE})"

else

    print_critical \
        "SYSTEM" \
        "terraform.tfstate absent"

fi


if [[ -f "/opt/terraform/terraform.tfstate.backup" ]]; then

    print_ok \
        "SYSTEM" \
        "terraform.tfstate.backup présent"

else

    print_warning \
        "SYSTEM" \
        "terraform.tfstate.backup absent"

fi


if [[ -f "/opt/terraform/kubeconfig-terraform-lab" ]]; then

    print_ok \
        "SYSTEM" \
        "Kubeconfig Terraform présent"

else

    print_warning \
        "SYSTEM" \
        "Kubeconfig Terraform absent"

fi


# ==============================================================================
# JENKINS
# ==============================================================================

print_title "JENKINS"

if [[ -f "$JENKINS_DEMO_DIR/Jenkinsfile" ]]; then

    print_ok \
        "JENKINS" \
        "Jenkinsfile présent"

else

    print_warning \
        "JENKINS" \
        "Jenkinsfile absent"

fi


if [[ -d "$JENKINS_DEMO_DIR/.git" ]]; then

    print_ok \
        "JENKINS" \
        "Repository Git Jenkins Demo présent"

else

    print_warning \
        "JENKINS" \
        "Repository Git Jenkins Demo absent"

fi


# ==============================================================================
# SYSTEMD FAILED
# ==============================================================================

print_title "SERVICES SYSTEMD FAILED"

FAILED_SERVICES="$(
    systemctl \
        --failed \
        --no-legend \
        --no-pager \
        2>/dev/null \
        || true
)"


if [[ -z "$FAILED_SERVICES" ]]; then

    print_ok \
        "SYSTEM" \
        "Aucun service systemd FAILED"

else

    print_warning \
        "SYSTEM" \
        "Service(s) systemd FAILED"

    [[ "$MODE" == "full" ]] \
        && echo "$FAILED_SERVICES" \
        | sed 's/^/        /'

fi


# ==============================================================================
# JOURNAL SYSTEME
# ==============================================================================

print_title "ERREURS SYSTEME RECENTES"

SYSTEM_JOURNAL_SINCE="${SYSTEM_JOURNAL_SINCE:-30 minutes ago}"

SYSTEM_ERRORS="$(
    journalctl \
        -p err..alert \
        --since "$SYSTEM_JOURNAL_SINCE" \
        --no-pager \
        2>/dev/null \
    | grep -vE \
        'piix4_smbus.*SMBus base address uninitialized|Unmaintained driver is detected|Could not add source .*Already in use|NAME_CONFLICT.*docker-forwarding' \
    | grep -v '^-- No entries --$' \
    | tail -30 \
    || true
)"


if [[ -n "$SYSTEM_ERRORS" ]]; then

    print_warning \
        "SYSTEM" \
        "Erreurs système non filtrées détectées"

    [[ "$MODE" == "full" ]] \
        && echo "$SYSTEM_ERRORS" \
        | sed 's/^/        /'

else

    print_ok \
        "SYSTEM" \
        "Aucune erreur système majeure non connue"

fi


# ==============================================================================
# RESUME
# ==============================================================================

print_summary()
{
    echo

    echo "======================================================================"
    echo " DEVOPS LAB HEALTH SUMMARY"
    echo "======================================================================"

    printf "%-14s %-10s %s\n" \
        "COMPOSANT" \
        "ETAT" \
        "DETAIL"

    echo "----------------------------------------------------------------------"


    for CAT in "${CATEGORIES[@]}"; do

        LEVEL="${CATEGORY_LEVEL[$CAT]:-0}"
        NOTE="${CATEGORY_NOTE[$CAT]:-}"

        case "$LEVEL" in

            0)
                STATUS="${GREEN}OK${RESET}"
                ;;

            1)
                STATUS="${YELLOW}WARNING${RESET}"
                ;;

            2)
                STATUS="${RED}CRITICAL${RESET}"
                ;;

        esac

        printf "%-14s %-18b %s\n" \
            "$CAT" \
            "$STATUS" \
            "$NOTE"

    done


    echo "----------------------------------------------------------------------"
    echo

    echo -e "OK       : ${GREEN}${OK}${RESET}"
    echo -e "INFO     : ${CYAN}${INFO}${RESET}"
    echo -e "WARNING  : ${YELLOW}${WARNING}${RESET}"
    echo -e "CRITICAL : ${RED}${CRITICAL}${RESET}"
    echo


    if (( CRITICAL > 0 )); then

        echo -e "${RED}ETAT GLOBAL : CRITICAL${RESET}"

    elif (( WARNING > 0 )); then

        echo -e "${YELLOW}ETAT GLOBAL : WARNING${RESET}"

    else

        echo -e "${GREEN}ETAT GLOBAL : OK${RESET}"

    fi

    echo
}


print_summary


# ==============================================================================
# EXIT CODE
# ==============================================================================

if (( CRITICAL > 0 )); then
    exit 2

elif (( WARNING > 0 )); then
    exit 1

else
    exit 0
fi

