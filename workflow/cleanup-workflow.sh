#!/usr/bin/env bash
#
# ==============================================================================
#  Name         : cleanup-workflow.sh
#  Project      : DevOps Lab Automation
#  Module       : Workflow / Deployment / Linux
#
#  Description  :
#      Removes a previously deployed Workflow application and its associated
#      system configuration.
#
#      The cleanup includes:
#
#          - PostgreSQL application database
#          - PostgreSQL application role
#          - Application files
#          - Apache VirtualHost configuration
#          - PHP configuration override
#          - Self-signed TLS certificate and private key
#          - Firewall rules
#          - SELinux port definitions
#          - SELinux file-context rules
#
#      Supported platforms:
#
#          - Red Hat Enterprise Linux / Rocky / AlmaLinux / Fedora
#          - Debian / Ubuntu
#
#  WARNING:
#      This script performs destructive operations.
#
#      It must be explicitly confirmed with:
#
#          ./cleanup-workflow.sh --yes
#
#  Version      : 2.0.0
#
#  Usage:
#
#      chmod +x cleanup-workflow.sh
#      ./cleanup-workflow.sh --yes
#
# ==============================================================================

set -Eeuo pipefail


# ==============================================================================
# GENERAL CONFIGURATION
# ==============================================================================

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" \
    && pwd
)"

ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

CONFIRM="${1:-}"


# ==============================================================================
# RUNTIME VARIABLES
# ==============================================================================

OS_FAMILY=""

APACHE_SERVICE=""
APACHE_CONF_FILE=""

PHP_INI_OVERRIDE=""

SSL_CERT_FILE=""
SSL_KEY_FILE=""

APACHE_USER=""
APACHE_GROUP=""


# ==============================================================================
# LOGGING
# ==============================================================================

log()
{
    echo "[INFO] $*"
}


warn()
{
    echo "[WARN] $*" >&2
}


err()
{
    echo "[ERROR] $*" >&2
}


# ==============================================================================
# ROOT CHECK
# ==============================================================================

require_root()
{
    if [[ "$EUID" -ne 0 ]]; then

        err "This script must be executed as root."

        exit 1
    fi
}


# ==============================================================================
# SAFETY CONFIRMATION
# ==============================================================================

require_confirmation()
{
    if [[ "$CONFIRM" != "--yes" ]]; then

        cat <<EOF

WARNING: destructive cleanup requested.

This operation may permanently remove:

    - Application files
    - PostgreSQL database
    - PostgreSQL role
    - Apache configuration
    - TLS certificate
    - TLS private key
    - Firewall rules
    - SELinux configuration

To continue, explicitly run:

    $0 --yes

EOF

        exit 1
    fi
}


# ==============================================================================
# COMMAND VALIDATION
# ==============================================================================

require_cmd()
{
    local CMD="$1"

    if ! command -v "$CMD" >/dev/null 2>&1; then

        err "Required command not found: $CMD"

        exit 1
    fi
}


# ==============================================================================
# ENVIRONMENT FILE
# ==============================================================================

load_env()
{
    if [[ ! -f "$ENV_FILE" ]]; then

        err "Environment file not found: $ENV_FILE"

        exit 1
    fi


    set -a

    # shellcheck disable=SC1090
    source "$ENV_FILE"

    set +a


    : "${APP_DIR:?APP_DIR is missing}"
    : "${APP_PORT_HTTP:?APP_PORT_HTTP is missing}"
    : "${APP_PORT_HTTPS:?APP_PORT_HTTPS is missing}"
    : "${DB_NAME:?DB_NAME is missing}"
    : "${DB_USER:?DB_USER is missing}"


    #
    # Safety validation.
    #
    # PostgreSQL database and role identifiers are limited to
    # alphanumeric characters and underscores.
    #

    if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then

        err "Invalid DB_NAME: $DB_NAME"

        exit 1
    fi


    if [[ ! "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]]; then

        err "Invalid DB_USER: $DB_USER"

        exit 1
    fi


    if [[ ! "$APP_PORT_HTTP" =~ ^[0-9]+$ \
          || ! "$APP_PORT_HTTPS" =~ ^[0-9]+$ ]]
    then

        err "Application ports must be numeric."

        exit 1
    fi


    #
    # Protect against dangerous APP_DIR values.
    #

    case "$APP_DIR" in

        ""|"/"|"/var"|"/var/www"|"/opt"|"/home")

            err "Unsafe APP_DIR value: $APP_DIR"

            exit 1
            ;;

    esac
}


# ==============================================================================
# OS DETECTION
# ==============================================================================

detect_os()
{
    if [[ ! -f /etc/os-release ]]; then

        err "/etc/os-release not found."

        exit 1
    fi


    # shellcheck disable=SC1091
    source /etc/os-release


    case "${ID_LIKE:-$ID}" in

        *debian*|*ubuntu*)

            OS_FAMILY="debian"

            APACHE_SERVICE="apache2"

            APACHE_CONF_FILE="/etc/apache2/sites-available/workflow.conf"

            PHP_INI_OVERRIDE="/etc/php/99-workflow.ini"

            SSL_CERT_FILE="/etc/ssl/certs/workflow-selfsigned.crt"

            SSL_KEY_FILE="/etc/ssl/private/workflow-selfsigned.key"

            APACHE_USER="www-data"
            APACHE_GROUP="www-data"
            ;;


        *rhel*|*fedora*|*centos*|*rocky*|*almalinux*)

            OS_FAMILY="redhat"

            APACHE_SERVICE="httpd"

            APACHE_CONF_FILE="/etc/httpd/conf.d/workflow.conf"

            PHP_INI_OVERRIDE="/etc/php.d/99-workflow.ini"

            SSL_CERT_FILE="/etc/pki/tls/certs/workflow-selfsigned.crt"

            SSL_KEY_FILE="/etc/pki/tls/private/workflow-selfsigned.key"

            APACHE_USER="apache"
            APACHE_GROUP="apache"
            ;;


        *)

            err "Unsupported operating system."

            exit 1
            ;;

    esac


    log "Detected OS family: $OS_FAMILY"
}


# ==============================================================================
# DATABASE CLEANUP
# ==============================================================================

drop_database_if_exists()
{
    log "Checking PostgreSQL database: $DB_NAME"


    if sudo -u postgres \
        psql \
        -d postgres \
        -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" \
        | grep -q '^1$'
    then

        log "Database exists: $DB_NAME"


        log "Terminating active connections to $DB_NAME"


        sudo -u postgres \
            psql \
            -d postgres \
            -v ON_ERROR_STOP=1 \
            -c "
                SELECT pg_terminate_backend(pid)
                FROM pg_stat_activity
                WHERE datname = '${DB_NAME}'
                  AND pid <> pg_backend_pid();
            "


        log "Dropping PostgreSQL database: $DB_NAME"


        sudo -u postgres \
            dropdb \
            "$DB_NAME"


        log "Database removed: $DB_NAME"

    else

        warn "Database not found: $DB_NAME"

    fi
}


# ==============================================================================
# POSTGRESQL ROLE CLEANUP
# ==============================================================================

drop_role_if_exists()
{
    log "Checking PostgreSQL role: $DB_USER"


    if sudo -u postgres \
        psql \
        -d postgres \
        -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" \
        | grep -q '^1$'
    then

        log "Dropping PostgreSQL role: $DB_USER"


        sudo -u postgres \
            psql \
            -d postgres \
            -v ON_ERROR_STOP=1 \
            -c "DROP ROLE \"${DB_USER}\";"


        log "Role removed: $DB_USER"

    else

        warn "PostgreSQL role not found: $DB_USER"

    fi
}


# ==============================================================================
# APPLICATION FILES
# ==============================================================================

remove_app_dir()
{
    if [[ -d "$APP_DIR" ]]; then

        log "Removing application directory: $APP_DIR"

        rm -rf -- "$APP_DIR"

    else

        warn "Application directory not found: $APP_DIR"

    fi
}


# ==============================================================================
# APACHE CONFIGURATION
# ==============================================================================

remove_apache_config()
{
    log "Removing Workflow Apache configuration"


    if [[ "$OS_FAMILY" == "debian" ]]; then

        if command -v a2dissite >/dev/null 2>&1; then

            a2dissite workflow.conf \
                >/dev/null 2>&1 \
                || true

        fi

    fi


    if [[ -f "$APACHE_CONF_FILE" ]]; then

        rm -f "$APACHE_CONF_FILE"

        log "Apache configuration removed: $APACHE_CONF_FILE"

    else

        warn "Apache configuration not found: $APACHE_CONF_FILE"

    fi
}


# ==============================================================================
# PHP CONFIGURATION
# ==============================================================================

remove_php_override()
{
    if [[ -f "$PHP_INI_OVERRIDE" ]]; then

        log "Removing PHP override: $PHP_INI_OVERRIDE"

        rm -f "$PHP_INI_OVERRIDE"

    else

        warn "PHP override not found: $PHP_INI_OVERRIDE"

    fi
}


# ==============================================================================
# TLS FILES
# ==============================================================================

remove_ssl_files()
{
    log "Removing Workflow TLS files"


    if [[ -f "$SSL_CERT_FILE" ]]; then

        rm -f "$SSL_CERT_FILE"

        log "TLS certificate removed: $SSL_CERT_FILE"

    else

        warn "TLS certificate not found: $SSL_CERT_FILE"

    fi


    if [[ -f "$SSL_KEY_FILE" ]]; then

        rm -f "$SSL_KEY_FILE"

        log "TLS private key removed: $SSL_KEY_FILE"

    else

        warn "TLS private key not found: $SSL_KEY_FILE"

    fi
}


# ==============================================================================
# FIREWALL
# ==============================================================================

remove_firewall_rules()
{
    log "Removing firewall rules for ports:"
    log "HTTP  : $APP_PORT_HTTP"
    log "HTTPS : $APP_PORT_HTTPS"


    if [[ "$OS_FAMILY" == "redhat" ]]; then

        if command -v firewall-cmd >/dev/null 2>&1 \
           && systemctl is-active --quiet firewalld
        then

            firewall-cmd \
                --permanent \
                --remove-port="${APP_PORT_HTTP}/tcp" \
                >/dev/null 2>&1 \
                || true


            firewall-cmd \
                --permanent \
                --remove-port="${APP_PORT_HTTPS}/tcp" \
                >/dev/null 2>&1 \
                || true


            firewall-cmd \
                --reload \
                >/dev/null

        else

            warn "firewalld is not active."

        fi


    elif [[ "$OS_FAMILY" == "debian" ]]; then

        if command -v ufw >/dev/null 2>&1; then

            ufw delete allow \
                "${APP_PORT_HTTP}/tcp" \
                >/dev/null 2>&1 \
                || true


            ufw delete allow \
                "${APP_PORT_HTTPS}/tcp" \
                >/dev/null 2>&1 \
                || true

        else

            warn "UFW is not installed."

        fi

    fi
}


# ==============================================================================
# SELINUX PORTS
# ==============================================================================

remove_selinux_ports()
{
    [[ "$OS_FAMILY" != "redhat" ]] \
        && return 0


    if ! command -v semanage >/dev/null 2>&1; then

        warn "semanage not installed; SELinux port cleanup skipped."

        return 0
    fi


    log "Removing SELinux HTTP port definitions"


    semanage port \
        -d \
        -t http_port_t \
        -p tcp \
        "$APP_PORT_HTTP" \
        2>/dev/null \
        || true


    semanage port \
        -d \
        -t http_port_t \
        -p tcp \
        "$APP_PORT_HTTPS" \
        2>/dev/null \
        || true
}


# ==============================================================================
# SELINUX FILE CONTEXT
# ==============================================================================

remove_selinux_contexts()
{
    [[ "$OS_FAMILY" != "redhat" ]] \
        && return 0


    if ! command -v semanage >/dev/null 2>&1; then

        return 0
    fi


    log "Removing Workflow SELinux file-context rules"


    semanage fcontext \
        -d \
        "${APP_DIR}(/.*)?" \
        2>/dev/null \
        || true


    semanage fcontext \
        -d \
        "${APP_DIR}/generated-files(/.*)?" \
        2>/dev/null \
        || true
}


# ==============================================================================
# APACHE VALIDATION / RESTART
# ==============================================================================

restart_apache_if_present()
{
    if ! systemctl list-unit-files \
        "${APACHE_SERVICE}.service" \
        --no-legend \
        2>/dev/null \
        | grep -q "${APACHE_SERVICE}.service"
    then

        warn "Apache service not installed: $APACHE_SERVICE"

        return 0
    fi


    #
    # Validate configuration before restarting when possible.
    #

    if [[ "$OS_FAMILY" == "redhat" ]] \
       && command -v httpd >/dev/null 2>&1
    then

        if ! httpd -t >/dev/null 2>&1; then

            err "Apache configuration validation failed after cleanup."

            return 1
        fi

    elif [[ "$OS_FAMILY" == "debian" ]] \
         && command -v apache2ctl >/dev/null 2>&1
    then

        if ! apache2ctl configtest >/dev/null 2>&1; then

            err "Apache configuration validation failed after cleanup."

            return 1
        fi

    fi


    log "Restarting Apache service: $APACHE_SERVICE"


    if systemctl restart "$APACHE_SERVICE"; then

        log "Apache restarted successfully."

    else

        err "Apache restart failed."

        return 1
    fi
}


# ==============================================================================
# FINAL CHECK
# ==============================================================================

final_check()
{
    echo
    log "Final cleanup verification"


    if [[ ! -e "$APP_DIR" ]]; then
        log "OK: application directory removed"
    else
        warn "Application directory still exists: $APP_DIR"
    fi


    if [[ ! -e "$APACHE_CONF_FILE" ]]; then
        log "OK: Apache configuration removed"
    else
        warn "Apache configuration still exists"
    fi


    if [[ ! -e "$SSL_CERT_FILE" \
          && ! -e "$SSL_KEY_FILE" ]]
    then
        log "OK: TLS files removed"
    else
        warn "One or more TLS files still exist"
    fi
}


# ==============================================================================
# MAIN
# ==============================================================================

main()
{
    require_root
    require_confirmation

    require_cmd systemctl
    require_cmd sudo
    require_cmd psql
    require_cmd dropdb
    require_cmd grep
    require_cmd rm

    load_env
    detect_os


    echo
    log "=============================================================="
    log " WORKFLOW CLEANUP START"
    log "=============================================================="
    echo

    log "Application directory : $APP_DIR"
    log "Database              : $DB_NAME"
    log "Database role         : $DB_USER"
    log "HTTP port             : $APP_PORT_HTTP"
    log "HTTPS port            : $APP_PORT_HTTPS"

    echo


    drop_database_if_exists

    drop_role_if_exists

    remove_app_dir

    remove_apache_config

    remove_php_override

    remove_ssl_files

    remove_firewall_rules

    remove_selinux_ports

    remove_selinux_contexts

    restart_apache_if_present

    final_check


    echo
    log "=============================================================="
    log " WORKFLOW CLEANUP COMPLETED"
    log "=============================================================="

    log "The application can now be redeployed using deploy-workflow.sh"
}


main "$@"

