#!/usr/bin/env bash
#
# ==============================================================================
#  Name         : deploy-workflow.sh
#  Project      : DevOps Lab Automation
#  Module       : Workflow / Deployment / Linux
#
#  Description  :
#      Deploys a PHP/PostgreSQL web application on Linux.
#
#      The script automatically handles:
#
#          - RHEL / Rocky / AlmaLinux / Fedora
#          - Debian / Ubuntu
#          - Apache installation and configuration
#          - PHP installation and configuration
#          - PostgreSQL installation and initialization
#          - Database and application role creation
#          - SQL schema import
#          - Application configuration generation
#          - Self-signed TLS certificate generation
#          - HTTP -> HTTPS redirection
#          - Firewall configuration
#          - SELinux configuration
#          - Application directory permissions
#          - Deployment validation
#
#  Version      : 2.0.0
#
#  Compatibility:
#      - Red Hat Enterprise Linux 8 / 9 / 10
#      - Rocky Linux
#      - AlmaLinux
#      - Fedora
#      - Debian
#      - Ubuntu
#
#  Usage:
#
#      cp .env.example .env
#      vi .env
#
#      chmod +x deploy-workflow.sh
#      ./deploy-workflow.sh
#
# ==============================================================================

set -Eeuo pipefail


# ==============================================================================
# PATHS
# ==============================================================================

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" \
    && pwd
)"

ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

SOURCE_DIR="${SOURCE_DIR:-${SCRIPT_DIR}/workflow}"

ARCHIVE_FILE="${ARCHIVE_FILE:-${SCRIPT_DIR}/workflow.tar.gz}"

SQL_FILE="${SQL_FILE:-${SCRIPT_DIR}/database/init.sql}"


# ==============================================================================
# OS-SPECIFIC RUNTIME VARIABLES
# ==============================================================================

OS_FAMILY=""

PKG_MANAGER=""

APACHE_SERVICE=""
APACHE_USER=""
APACHE_GROUP=""
APACHE_CONF_FILE=""

PHP_INI_OVERRIDE=""

SSL_CERT_FILE=""
SSL_KEY_FILE=""

POSTGRESQL_SERVICE=""
POSTGRESQL_SERVER_PACKAGE=""
POSTGRESQL_CLIENT_PACKAGE=""

PHP_PACKAGES=()


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
# COMMAND CHECK
# ==============================================================================

require_cmd()
{
    local CMD="$1"

    if ! command -v "$CMD" >/dev/null 2>&1; then

        err "Required command not found: $CMD"

        exit 1
    fi
}


command_exists()
{
    command -v "$1" >/dev/null 2>&1
}


# ==============================================================================
# ENVIRONMENT
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


    # --------------------------------------------------------------------------
    # Application
    # --------------------------------------------------------------------------

    : "${APP_NAME:?APP_NAME is missing}"
    : "${APP_DIR:?APP_DIR is missing}"

    : "${APP_PORT_HTTP:?APP_PORT_HTTP is missing}"
    : "${APP_PORT_HTTPS:?APP_PORT_HTTPS is missing}"

    : "${SERVER_NAME:?SERVER_NAME is missing}"
    : "${DOMAIN_NAME:?DOMAIN_NAME is missing}"


    # --------------------------------------------------------------------------
    # PostgreSQL
    # --------------------------------------------------------------------------

    : "${DB_NAME:?DB_NAME is missing}"
    : "${DB_USER:?DB_USER is missing}"
    : "${DB_PASS:?DB_PASS is missing}"

    : "${DB_HOST:?DB_HOST is missing}"
    : "${DB_PORT:?DB_PORT is missing}"


    # --------------------------------------------------------------------------
    # Application / organization
    # --------------------------------------------------------------------------

    : "${ENTITY_NAME:?ENTITY_NAME is missing}"

    : "${MAIL_CONTACT:?MAIL_CONTACT is missing}"
    : "${MAIL_SUPPORT:?MAIL_SUPPORT is missing}"
    : "${MAIL_APPLICATION:?MAIL_APPLICATION is missing}"

    : "${LOGO_PATH:?LOGO_PATH is missing}"


    # --------------------------------------------------------------------------
    # LDAP
    # --------------------------------------------------------------------------

    : "${LDAP_SERVER:?LDAP_SERVER is missing}"
    : "${DOMAIN_SUFFIX:?DOMAIN_SUFFIX is missing}"


    # --------------------------------------------------------------------------
    # Application accounts
    # --------------------------------------------------------------------------

    : "${WORKFLOW_ADMIN_LOGIN:?WORKFLOW_ADMIN_LOGIN is missing}"

    : "${INITIAL_USER_LOGIN:?INITIAL_USER_LOGIN is missing}"

    : "${INITIAL_USER_ID:?INITIAL_USER_ID is missing}"
    : "${INITIAL_USER_LASTNAME:?INITIAL_USER_LASTNAME is missing}"
    : "${INITIAL_USER_FIRSTNAME:?INITIAL_USER_FIRSTNAME is missing}"
    : "${INITIAL_USER_EMAIL:?INITIAL_USER_EMAIL is missing}"
    : "${INITIAL_USER_START_DATE:?INITIAL_USER_START_DATE is missing}"
    : "${INITIAL_USER_END_DATE:?INITIAL_USER_END_DATE is missing}"
    : "${INITIAL_USER_DEPARTMENT:?INITIAL_USER_DEPARTMENT is missing}"
    : "${INITIAL_USER_MANAGER:?INITIAL_USER_MANAGER is missing}"
    : "${INITIAL_USER_STATUS:?INITIAL_USER_STATUS is missing}"
    : "${INITIAL_USER_GROUPS:?INITIAL_USER_GROUPS is missing}"


    # --------------------------------------------------------------------------
    # Validation
    # --------------------------------------------------------------------------

    if [[ ! "$APP_PORT_HTTP" =~ ^[0-9]+$ \
          || ! "$APP_PORT_HTTPS" =~ ^[0-9]+$ \
          || ! "$DB_PORT" =~ ^[0-9]+$ ]]
    then

        err "Application and database ports must be numeric."

        exit 1
    fi


    if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then

        err "Invalid PostgreSQL database name: $DB_NAME"

        exit 1
    fi


    if [[ ! "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]]; then

        err "Invalid PostgreSQL user: $DB_USER"

        exit 1
    fi


    case "$APP_DIR" in

        ""|"/"|"/var"|"/var/www"|"/opt"|"/home")

            err "Unsafe application directory: $APP_DIR"

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

            PKG_MANAGER="apt-get"

            APACHE_SERVICE="apache2"

            APACHE_USER="www-data"
            APACHE_GROUP="www-data"

            APACHE_CONF_FILE="/etc/apache2/sites-available/workflow.conf"

            PHP_INI_OVERRIDE="/etc/php/99-workflow.ini"

            SSL_CERT_FILE="/etc/ssl/certs/workflow-selfsigned.crt"
            SSL_KEY_FILE="/etc/ssl/private/workflow-selfsigned.key"

            POSTGRESQL_SERVICE="postgresql"

            POSTGRESQL_SERVER_PACKAGE="postgresql"
            POSTGRESQL_CLIENT_PACKAGE="postgresql-client"

            PHP_PACKAGES=(
                php
                php-cli
                php-common
                php-pgsql
                php-ldap
                php-mbstring
                php-xml
                php-curl
                php-zip
                libapache2-mod-php
                openssl
            )
            ;;


        *rhel*|*fedora*|*centos*|*rocky*|*almalinux*)

            OS_FAMILY="redhat"

            if command_exists dnf; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi

            APACHE_SERVICE="httpd"

            APACHE_USER="apache"
            APACHE_GROUP="apache"

            APACHE_CONF_FILE="/etc/httpd/conf.d/workflow.conf"

            PHP_INI_OVERRIDE="/etc/php.d/99-workflow.ini"

            SSL_CERT_FILE="/etc/pki/tls/certs/workflow-selfsigned.crt"
            SSL_KEY_FILE="/etc/pki/tls/private/workflow-selfsigned.key"

            POSTGRESQL_SERVICE="postgresql"

            POSTGRESQL_SERVER_PACKAGE="postgresql-server"
            POSTGRESQL_CLIENT_PACKAGE="postgresql"

            PHP_PACKAGES=(
                php
                php-cli
                php-common
                php-pgsql
                php-ldap
                php-mbstring
                php-xml
                php-curl
                php-zip
                openssl
            )
            ;;


        *)

            err "Unsupported operating system."

            exit 1
            ;;

    esac


    log "Detected operating system family: $OS_FAMILY"
}


# ==============================================================================
# PACKAGE MANAGEMENT
# ==============================================================================

update_repositories()
{
    log "Refreshing package repositories..."


    if [[ "$OS_FAMILY" == "debian" ]]; then

        apt-get update

    else

        "$PKG_MANAGER" makecache -y

    fi
}


install_packages()
{
    if [[ "$OS_FAMILY" == "debian" ]]; then

        apt-get install -y "$@"

    else

        "$PKG_MANAGER" install -y "$@"

    fi
}


install_base_packages()
{
    log "Installing required base packages..."


    install_packages \
        curl \
        wget \
        tar \
        unzip \
        rsync \
        sed \
        grep \
        ca-certificates \
        openssl


    if [[ "$OS_FAMILY" == "redhat" ]]; then

        install_packages \
            policycoreutils-python-utils \
            || true

    fi
}


# ==============================================================================
# SYSTEMD
# ==============================================================================

service_exists()
{
    local SERVICE="$1"

    systemctl list-unit-files \
        --type=service \
        --no-legend \
        2>/dev/null \
        | awk '{print $1}' \
        | grep -qx "${SERVICE}.service"
}


ensure_service_started()
{
    local SERVICE="$1"


    if ! service_exists "$SERVICE"; then

        warn "Service not found: $SERVICE"

        return 1
    fi


    systemctl enable "$SERVICE" >/dev/null 2>&1 || true


    if ! systemctl restart "$SERVICE"; then

        systemctl start "$SERVICE"

    fi
}


# ==============================================================================
# APACHE INSTALLATION
# ==============================================================================

install_apache()
{
    if [[ "$OS_FAMILY" == "debian" ]]; then

        if ! command_exists apache2ctl; then

            log "Installing Apache..."

            install_packages apache2 ssl-cert

        else

            log "Apache already installed."

        fi


        a2enmod rewrite headers ssl \
            >/dev/null


    else

        if ! command_exists httpd; then

            log "Installing Apache..."

            install_packages httpd mod_ssl

        else

            log "Apache already installed."

        fi

    fi


    ensure_service_started "$APACHE_SERVICE"
}


# ==============================================================================
# DEBIAN APACHE DEFAULT SITES
# ==============================================================================

disable_default_apache_sites_debian()
{
    [[ "$OS_FAMILY" != "debian" ]] \
        && return 0


    log "Disabling default Apache sites..."


    a2dissite 000-default.conf \
        >/dev/null 2>&1 \
        || true


    a2dissite default-ssl.conf \
        >/dev/null 2>&1 \
        || true
}


# ==============================================================================
# PHP
# ==============================================================================

install_php()
{
    log "Installing / validating PHP packages..."

    install_packages "${PHP_PACKAGES[@]}"


    if command_exists php; then

        log "PHP version: $(php -v | head -1)"

    else

        err "PHP installation failed."

        exit 1
    fi
}


detect_php_ini_override_debian()
{
    [[ "$OS_FAMILY" != "debian" ]] \
        && return 0


    local PHP_VERSION


    PHP_VERSION="$(
        php -r \
            'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' \
            2>/dev/null \
            || true
    )"


    if [[ -n "$PHP_VERSION" ]]; then

        PHP_INI_OVERRIDE="/etc/php/${PHP_VERSION}/apache2/conf.d/99-workflow.ini"

    fi
}


write_php_ini_override()
{
    log "Writing dedicated PHP configuration..."


    mkdir -p "$(dirname "$PHP_INI_OVERRIDE")"


    cat > "$PHP_INI_OVERRIDE" <<'EOF'
date.timezone = UTC

max_execution_time = 60

memory_limit = 256M

post_max_size = 16M
upload_max_filesize = 16M

display_errors = Off
log_errors = On

session.cookie_httponly = On
session.cookie_samesite = Lax
EOF
}


# ==============================================================================
# POSTGRESQL INSTALLATION
# ==============================================================================

install_postgresql()
{
    log "Installing / validating PostgreSQL..."


    install_packages \
        "$POSTGRESQL_SERVER_PACKAGE" \
        "$POSTGRESQL_CLIENT_PACKAGE"


    if [[ "$OS_FAMILY" == "redhat" ]]; then

        if [[ ! -d /var/lib/pgsql/data/base ]] \
           && ! find /var/lib/pgsql \
                -type d \
                -path '*/data/base' \
                2>/dev/null \
                | grep -q .
        then

            log "Initializing PostgreSQL database cluster..."


            if command_exists postgresql-setup; then

                postgresql-setup --initdb \
                    || true

            fi

        fi

    fi


    ensure_service_started "$POSTGRESQL_SERVICE"


    systemctl restart "$POSTGRESQL_SERVICE" \
        >/dev/null 2>&1 \
        || systemctl restart 'postgresql-*' \
        >/dev/null 2>&1 \
        || true
}


wait_for_postgres()
{
    local I


    log "Waiting for PostgreSQL..."


    for I in {1..20}; do

        if sudo -u postgres \
            psql \
            -d postgres \
            -tAc 'SELECT 1' \
            >/dev/null 2>&1
        then

            log "PostgreSQL is ready."

            return 0
        fi


        sleep 2

    done


    err "PostgreSQL is not responding."

    exit 1
}


# ==============================================================================
# TLS
# ==============================================================================

generate_self_signed_cert()
{
    log "Checking Workflow TLS certificate..."


    mkdir -p \
        "$(dirname "$SSL_CERT_FILE")" \
        "$(dirname "$SSL_KEY_FILE")"


    if [[ ! -f "$SSL_CERT_FILE" \
          || ! -f "$SSL_KEY_FILE" ]]
    then

        log "Generating self-signed TLS certificate..."


        openssl req \
            -x509 \
            -nodes \
            -days "${TLS_VALIDITY_DAYS:-365}" \
            -newkey rsa:2048 \
            -keyout "$SSL_KEY_FILE" \
            -out "$SSL_CERT_FILE" \
            -subj "/C=XX/ST=Lab/L=Lab/O=${ENTITY_NAME}/OU=IT/CN=${SERVER_NAME}" \
            -addext "subjectAltName=DNS:${SERVER_NAME}" \
            -addext "extendedKeyUsage=serverAuth"

    else

        log "TLS certificate already exists."

    fi


    chmod 600 "$SSL_KEY_FILE"
    chmod 644 "$SSL_CERT_FILE"
}


# ==============================================================================
# APPLICATION DIRECTORY
# ==============================================================================

prepare_app_dir()
{
    mkdir -p "$APP_DIR"

    chown \
        "$APACHE_USER:$APACHE_GROUP" \
        "$APP_DIR"
}


deploy_source()
{
    log "Deploying application source..."


    if [[ -d "$SOURCE_DIR" ]]; then

        rsync \
            -a \
            --delete \
            "${SOURCE_DIR}/" \
            "${APP_DIR}/"


    elif [[ -f "$ARCHIVE_FILE" ]]; then

        log "Deploying application archive..."


        find "$APP_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -exec rm -rf -- {} +


        tar \
            -xzf "$ARCHIVE_FILE" \
            -C "$APP_DIR"


    else

        err "No application source found."

        err "Expected either:"
        err "  $SOURCE_DIR"
        err "or:"
        err "  $ARCHIVE_FILE"

        exit 1
    fi


    chown \
        -R \
        "$APACHE_USER:$APACHE_GROUP" \
        "$APP_DIR"


    find "$APP_DIR" \
        -type d \
        -exec chmod 755 {} \;


    find "$APP_DIR" \
        -type f \
        -exec chmod 644 {} \;
}


# ==============================================================================
# WRITABLE DIRECTORY
# ==============================================================================

configure_one_writable_dir()
{
    local DIRECTORY="$1"


    mkdir -p "$DIRECTORY"


    chown \
        -R \
        "$APACHE_USER:$APACHE_GROUP" \
        "$DIRECTORY"


    chmod 775 "$DIRECTORY"
}


configure_writable_dirs()
{
    log "Configuring writable application directories..."


    configure_one_writable_dir \
        "${APP_DIR}/generated-files"
}


# ==============================================================================
# APPLICATION CONFIGURATION
# ==============================================================================

generate_config_php()
{
    local TARGET="${APP_DIR}/inc/Config.php"


    if [[ ! -d "${APP_DIR}/inc" ]]; then

        err "Application configuration directory missing: ${APP_DIR}/inc"

        exit 1
    fi


    log "Generating application Config.php..."


    cat > "$TARGET" <<EOF
<?php

if (!defined('BASE_PATH')) {
    define('BASE_PATH', '/');
}

date_default_timezone_set('UTC');

return [

    // Database
    'db_host' => '${DB_HOST}',
    'db_port' => '${DB_PORT}',
    'db_name' => '${DB_NAME}',
    'db_user' => '${DB_USER}',
    'db_password' => '${DB_PASS}',

    // Application
    'logo_path' => '${LOGO_PATH}',
    'entity_name' => '${ENTITY_NAME}',
    'domain_name' => '${DOMAIN_NAME}',

    // E-mail
    'mail_contact' => '${MAIL_CONTACT}',
    'mail_support' => '${MAIL_SUPPORT}',
    'mail_application' => '${MAIL_APPLICATION}',

    // Directory service
    'ldap_server' => '${LDAP_SERVER}',
    'domain_suffix' => '${DOMAIN_SUFFIX}',

    // Application roles
    'workflow_admin_login' => '${WORKFLOW_ADMIN_LOGIN}',
    'workflow_hr_login' => '${WORKFLOW_HR_LOGIN:-}'
];
EOF


    chown \
        "$APACHE_USER:$APACHE_GROUP" \
        "$TARGET"


    chmod 640 "$TARGET"
}


# ==============================================================================
# DATABASE PHP ADAPTER
# ==============================================================================

patch_database_php()
{
    local FILE="${APP_DIR}/inc/Database.php"


    if [[ ! -f "$FILE" ]]; then

        warn "Database.php not found. Patch skipped."

        return 0
    fi


    log "Installing generic PostgreSQL Database.php..."


    cat > "$FILE" <<'EOF'
<?php

class Database
{
    private string $host;
    private string $port;
    private string $dbname;
    private string $user;
    private string $password;

    private $connection = null;


    public function __construct(
        string $user = "",
        string $password = "",
        string $host = "",
        string $port = "",
        string $dbname = ""
    ) {
        $config = require __DIR__ . '/Config.php';


        $this->host =
            $host !== ""
                ? $host
                : ($config['db_host'] ?? '127.0.0.1');


        $this->port =
            $port !== ""
                ? $port
                : ($config['db_port'] ?? '5432');


        $this->dbname =
            $dbname !== ""
                ? $dbname
                : ($config['db_name'] ?? 'workflow_db');


        $this->user =
            $user !== ""
                ? $user
                : ($config['db_user'] ?? '');


        $this->password =
            $password !== ""
                ? $password
                : ($config['db_password'] ?? '');
    }


    public function connect()
    {
        $connectionString = sprintf(
            'host=%s port=%s dbname=%s user=%s password=%s',
            $this->host,
            $this->port,
            $this->dbname,
            $this->user,
            $this->password
        );


        $this->connection = pg_pconnect($connectionString);


        if (!$this->connection) {
            throw new Exception('Database connection failed.');
        }


        return $this->connection;
    }


    public function query(string $sql)
    {
        $connection =
            $this->connection
            ?? $this->connect();


        $result =
            pg_query(
                $connection,
                $sql
            );


        if (!$result) {

            throw new Exception(
                'SQL query failed: '
                . pg_last_error($connection)
            );
        }


        return $result;
    }


    public function queryParams(
        string $sql,
        array $params
    ) {
        $connection =
            $this->connection
            ?? $this->connect();


        $result =
            pg_query_params(
                $connection,
                $sql,
                $params
            );


        if (!$result) {

            throw new Exception(
                'Parameterized SQL query failed: '
                . pg_last_error($connection)
            );
        }


        return $result;
    }


    public function fetchAllAssoc($result)
    {
        return pg_fetch_all(
            $result,
            PGSQL_ASSOC
        );
    }


    public function fetchOneAssoc($result): ?array
    {
        $row =
            pg_fetch_assoc($result);


        return
            $row === false
                ? null
                : $row;
    }


    public function fetchAssoc($result)
    {
        return pg_fetch_assoc($result);
    }


    public function fetchOneRow($result): ?array
    {
        $row =
            pg_fetch_row($result);


        return
            $row === false
                ? null
                : $row;
    }
}
EOF


    chown \
        "$APACHE_USER:$APACHE_GROUP" \
        "$FILE"


    chmod 640 "$FILE"
}


# ==============================================================================
# APPLICATION LOGIN PATCH
# ==============================================================================

patch_login_configuration()
{
    local FILE="${APP_DIR}/Login-WorkflowResp.php"


    [[ -f "$FILE" ]] \
        || {
            warn "Login-WorkflowResp.php not found. Patch skipped."
            return 0
        }


    log "Applying generic application role configuration..."


    #
    # Public GitHub version intentionally avoids hard-coded
    # usernames.
    #
    # Application-specific code should consume values from Config.php.
    #


    if grep -q '\$adminsIT' "$FILE"; then

        sed -i \
            's/\$adminsIT = \[[^]]*\];/\$adminsIT = array_values(array_filter([\$config["workflow_admin_login"] ?? ""]));/' \
            "$FILE" \
            || true

    fi
}


# ==============================================================================
# POSTGRESQL HELPERS
# ==============================================================================

role_exists()
{
    sudo -u postgres \
        psql \
        -d postgres \
        -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" \
        | grep -q '^1$'
}


database_exists()
{
    sudo -u postgres \
        psql \
        -d postgres \
        -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" \
        | grep -q '^1$'
}


# ==============================================================================
# DATABASE / ROLE CREATION
# ==============================================================================

create_database_and_user()
{
    log "Creating / validating PostgreSQL role and database..."


    if ! role_exists; then

        log "Creating PostgreSQL role: $DB_USER"


        sudo -u postgres \
            psql \
            -d postgres \
            -v ON_ERROR_STOP=1 \
            --set=db_user="$DB_USER" \
            --set=db_pass="$DB_PASS" \
            <<'SQL'
SELECT format(
    'CREATE ROLE %I LOGIN PASSWORD %L',
    :'db_user',
    :'db_pass'
)
\gexec
SQL


    else

        log "Updating PostgreSQL role password: $DB_USER"


        sudo -u postgres \
            psql \
            -d postgres \
            -v ON_ERROR_STOP=1 \
            --set=db_user="$DB_USER" \
            --set=db_pass="$DB_PASS" \
            <<'SQL'
SELECT format(
    'ALTER ROLE %I WITH PASSWORD %L',
    :'db_user',
    :'db_pass'
)
\gexec
SQL

    fi


    if ! database_exists; then

        log "Creating PostgreSQL database: $DB_NAME"


        sudo -u postgres \
            createdb \
            -O "$DB_USER" \
            "$DB_NAME"

    else

        log "Database already exists: $DB_NAME"

    fi
}


# ==============================================================================
# SQL IMPORT SANITIZATION
# ==============================================================================

prepare_init_sql()
{
    local SOURCE="$SQL_FILE"

    local DESTINATION


    DESTINATION="$(
        mktemp \
            /tmp/workflow-init.XXXXXX.sql
    )"


    if [[ ! -f "$SOURCE" ]]; then

        warn "SQL initialization file not found: $SOURCE"

        rm -f "$DESTINATION"

        return 1
    fi


    cp \
        "$SOURCE" \
        "$DESTINATION"


    #
    # Remove environment-specific PostgreSQL ownership and roles.
    #
    # The public version deliberately avoids naming internal roles.
    #

    sed -i \
        -e '/CREATE DATABASE IF NOT EXISTS/d' \
        -e '/^[[:space:]]*SET ROLE /d' \
        -e '/^[[:space:]]*ALTER .* OWNER TO /d' \
        -e '/^[[:space:]]*GRANT .* TO .*;/d' \
        -e '/^[[:space:]]*REVOKE .* FROM .*;/d' \
        "$DESTINATION"


    echo "$DESTINATION"
}


# ==============================================================================
# SQL IMPORT
# ==============================================================================

import_database()
{
    local FIXED_SQL


    FIXED_SQL="$(
        prepare_init_sql
    )" \
        || return 0


    log "Importing application SQL schema..."


    PGPASSWORD="$DB_PASS" \
        psql \
        -v ON_ERROR_STOP=1 \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        -f "$FIXED_SQL"


    rm -f "$FIXED_SQL"
}


# ==============================================================================
# DATABASE PRIVILEGES
# ==============================================================================

grant_application_privileges()
{
    local APP_SCHEMA="${APP_SCHEMA:-app}"


    log "Applying PostgreSQL privileges on schema: $APP_SCHEMA"


    sudo -u postgres \
        psql \
        -v ON_ERROR_STOP=1 \
        -d "$DB_NAME" \
        --set=db_user="$DB_USER" \
        --set=app_schema="$APP_SCHEMA" \
        <<'SQL'

SELECT format(
    'GRANT ALL PRIVILEGES ON DATABASE %I TO %I',
    current_database(),
    :'db_user'
)
\gexec


DO $block$
DECLARE
    target_schema text := :'app_schema';
    target_user   text := :'db_user';
BEGIN

    IF EXISTS (
        SELECT 1
        FROM information_schema.schemata
        WHERE schema_name = target_schema
    ) THEN

        EXECUTE format(
            'GRANT USAGE, CREATE ON SCHEMA %I TO %I',
            target_schema,
            target_user
        );


        EXECUTE format(
            'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA %I TO %I',
            target_schema,
            target_user
        );


        EXECUTE format(
            'GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA %I TO %I',
            target_schema,
            target_user
        );


        EXECUTE format(
            'GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA %I TO %I',
            target_schema,
            target_user
        );

    END IF;

END
$block$;
SQL
}


# ==============================================================================
# SEED INITIAL USER
# ==============================================================================

seed_initial_user()
{
    #
    # The exact application schema is application-specific.
    #
    # The public version uses configurable values and avoids exposing
    # real employee information.
    #

    local APP_SCHEMA="${APP_SCHEMA:-app}"
    local USER_TABLE="${USER_TABLE:-users}"


    log "Checking initial application user..."


    sudo -u postgres \
        psql \
        -v ON_ERROR_STOP=1 \
        -d "$DB_NAME" \
        --set=app_schema="$APP_SCHEMA" \
        --set=user_table="$USER_TABLE" \
        >/dev/null \
        <<'SQL'

SELECT 1;

SQL


    log "Initial application user values are provided through .env."
    log "Application-specific seed SQL can be added in database/init.sql."
}


# ==============================================================================
# APACHE PORT CONFIGURATION - RHEL
# ==============================================================================

configure_apache_ports_redhat()
{
    [[ "$OS_FAMILY" != "redhat" ]] \
        && return 0


    local HTTPD_CONF="/etc/httpd/conf/httpd.conf"


    log "Configuring Apache ports on RHEL-like system..."


    if [[ -f "$HTTPD_CONF" ]]; then

        sed -i \
            's/^[[:space:]]*Listen[[:space:]]\+80$/#Listen 80/' \
            "$HTTPD_CONF" \
            || true


        grep -qE \
            "^Listen[[:space:]]+${APP_PORT_HTTP}$" \
            "$HTTPD_CONF" \
            || echo \
                "Listen ${APP_PORT_HTTP}" \
                >> "$HTTPD_CONF"


        grep -qE \
            "^Listen[[:space:]]+${APP_PORT_HTTPS}$" \
            "$HTTPD_CONF" \
            || echo \
                "Listen ${APP_PORT_HTTPS}" \
                >> "$HTTPD_CONF"

    fi


    if [[ -f /etc/httpd/conf.d/ssl.conf ]]; then

        mv \
            /etc/httpd/conf.d/ssl.conf \
            /etc/httpd/conf.d/ssl.conf.disabled \
            2>/dev/null \
            || true

    fi
}


# ==============================================================================
# APACHE PORT CONFIGURATION - DEBIAN
# ==============================================================================

configure_apache_ports_debian()
{
    [[ "$OS_FAMILY" != "debian" ]] \
        && return 0


    local PORTS_FILE="/etc/apache2/ports.conf"


    log "Configuring Apache ports on Debian-like system..."


    touch "$PORTS_FILE"


    sed -i \
        's/^Listen 80$/#Listen 80/' \
        "$PORTS_FILE" \
        || true


    sed -i \
        's/^Listen 443$/#Listen 443/' \
        "$PORTS_FILE" \
        || true


    grep -qE \
        "^Listen[[:space:]]+${APP_PORT_HTTP}$" \
        "$PORTS_FILE" \
        || echo \
            "Listen ${APP_PORT_HTTP}" \
            >> "$PORTS_FILE"


    grep -qE \
        "^Listen[[:space:]]+${APP_PORT_HTTPS}$" \
        "$PORTS_FILE" \
        || echo \
            "Listen ${APP_PORT_HTTPS}" \
            >> "$PORTS_FILE"
}


# ==============================================================================
# APACHE CONFIGURATION
# ==============================================================================

write_apache_config()
{
    log "Writing Workflow Apache VirtualHost configuration..."


    if [[ "$OS_FAMILY" == "debian" ]]; then

        cat > "$APACHE_CONF_FILE" <<EOF

<VirtualHost *:${APP_PORT_HTTP}>

    ServerName ${SERVER_NAME}

    DocumentRoot ${APP_DIR}


    <Directory "${APP_DIR}">

        Options FollowSymLinks

        AllowOverride All

        Require all granted

    </Directory>


    RewriteEngine On

    RewriteCond %{HTTPS} off

    RewriteRule ^/(.*)$ https://%{SERVER_NAME}:${APP_PORT_HTTPS}/\$1 [R=301,L]


    ErrorLog \${APACHE_LOG_DIR}/${APP_NAME}_error_http.log

    CustomLog \${APACHE_LOG_DIR}/${APP_NAME}_access_http.log combined

</VirtualHost>


<VirtualHost *:${APP_PORT_HTTPS}>

    ServerName ${SERVER_NAME}

    DocumentRoot ${APP_DIR}


    SSLEngine on

    SSLCertificateFile ${SSL_CERT_FILE}

    SSLCertificateKeyFile ${SSL_KEY_FILE}


    <Directory "${APP_DIR}">

        Options FollowSymLinks

        AllowOverride All

        Require all granted

    </Directory>


    DirectoryIndex index.php index.html


    ErrorLog \${APACHE_LOG_DIR}/${APP_NAME}_error_ssl.log

    CustomLog \${APACHE_LOG_DIR}/${APP_NAME}_access_ssl.log combined

</VirtualHost>

EOF


        a2enmod \
            rewrite \
            headers \
            ssl \
            >/dev/null


        a2ensite workflow.conf \
            >/dev/null


        apache2ctl configtest


    else

        cat > "$APACHE_CONF_FILE" <<EOF

<VirtualHost *:${APP_PORT_HTTP}>

    ServerName ${SERVER_NAME}

    DocumentRoot ${APP_DIR}


    <Directory "${APP_DIR}">

        Options FollowSymLinks

        AllowOverride All

        Require all granted

    </Directory>


    RewriteEngine On

    RewriteCond %{HTTPS} off

    RewriteRule ^/(.*)$ https://%{SERVER_NAME}:${APP_PORT_HTTPS}/\$1 [R=301,L]


    ErrorLog /var/log/httpd/${APP_NAME}_error_http.log

    CustomLog /var/log/httpd/${APP_NAME}_access_http.log combined

</VirtualHost>


<VirtualHost *:${APP_PORT_HTTPS}>

    ServerName ${SERVER_NAME}

    DocumentRoot ${APP_DIR}


    SSLEngine on

    SSLCertificateFile ${SSL_CERT_FILE}

    SSLCertificateKeyFile ${SSL_KEY_FILE}


    <Directory "${APP_DIR}">

        Options FollowSymLinks

        AllowOverride All

        Require all granted

    </Directory>


    DirectoryIndex index.php index.html


    ErrorLog /var/log/httpd/${APP_NAME}_error_ssl.log

    CustomLog /var/log/httpd/${APP_NAME}_access_ssl.log combined

</VirtualHost>

EOF


        httpd -t

    fi


    systemctl restart "$APACHE_SERVICE"
}


# ==============================================================================
# SELINUX PORTS
# ==============================================================================

configure_selinux_http_ports()
{
    [[ "$OS_FAMILY" != "redhat" ]] \
        && return 0


    if ! command_exists semanage; then

        warn "semanage not available. SELinux port configuration skipped."

        return 0
    fi


    log "Configuring SELinux HTTP ports..."


    semanage port \
        -a \
        -t http_port_t \
        -p tcp \
        "$APP_PORT_HTTP" \
        2>/dev/null \
        || semanage port \
            -m \
            -t http_port_t \
            -p tcp \
            "$APP_PORT_HTTP"


    semanage port \
        -a \
        -t http_port_t \
        -p tcp \
        "$APP_PORT_HTTPS" \
        2>/dev/null \
        || semanage port \
            -m \
            -t http_port_t \
            -p tcp \
            "$APP_PORT_HTTPS"
}


# ==============================================================================
# SELINUX FILE CONTEXTS
# ==============================================================================

configure_selinux()
{
    [[ "$OS_FAMILY" != "redhat" ]] \
        && return 0


    if ! command_exists getenforce; then

        return 0
    fi


    if [[ "$(getenforce)" == "Disabled" ]]; then

        return 0
    fi


    log "Configuring SELinux contexts..."


    semanage fcontext \
        -a \
        -t httpd_sys_content_t \
        "${APP_DIR}(/.*)?" \
        2>/dev/null \
        || semanage fcontext \
            -m \
            -t httpd_sys_content_t \
            "${APP_DIR}(/.*)?"


    semanage fcontext \
        -a \
        -t httpd_sys_rw_content_t \
        "${APP_DIR}/generated-files(/.*)?" \
        2>/dev/null \
        || semanage fcontext \
            -m \
            -t httpd_sys_rw_content_t \
            "${APP_DIR}/generated-files(/.*)?"


    restorecon \
        -Rv \
        "$APP_DIR"


    setsebool \
        -P \
        httpd_can_network_connect_db \
        1 \
        || true
}


# ==============================================================================
# FIREWALL
# ==============================================================================

configure_firewall()
{
    log "Configuring firewall..."


    if [[ "$OS_FAMILY" == "redhat" ]]; then

        if command_exists firewall-cmd \
           && systemctl is-active \
                --quiet firewalld
        then

            firewall-cmd \
                --permanent \
                --add-port="${APP_PORT_HTTP}/tcp" \
                >/dev/null


            firewall-cmd \
                --permanent \
                --add-port="${APP_PORT_HTTPS}/tcp" \
                >/dev/null


            firewall-cmd \
                --reload \
                >/dev/null


            log "firewalld ports enabled:"
            log "  ${APP_PORT_HTTP}/tcp"
            log "  ${APP_PORT_HTTPS}/tcp"

        else

            warn "firewalld is not active."

        fi


    elif [[ "$OS_FAMILY" == "debian" ]]; then

        if command_exists ufw; then

            if ufw status \
                | grep -q 'Status: active'
            then

                ufw allow \
                    "${APP_PORT_HTTP}/tcp"


                ufw allow \
                    "${APP_PORT_HTTPS}/tcp"

            else

                warn "UFW installed but inactive."

            fi

        else

            warn "UFW not installed."

        fi

    fi
}


# ==============================================================================
# HTTPS HEALTH CHECK
# ==============================================================================

wait_for_https()
{
    local URL="https://${SERVER_NAME}:${APP_PORT_HTTPS}"

    local MAX_TRIES=20

    local I
    local HTTP_CODE


    log "Waiting for application: $URL"


    for ((I=1; I<=MAX_TRIES; I++)); do

        HTTP_CODE="$(
            curl \
                -k \
                -s \
                -o /dev/null \
                -w '%{http_code}' \
                --connect-timeout 3 \
                --max-time 5 \
                "$URL" \
                || echo 000
        )"


        case "$HTTP_CODE" in

            200|301|302|303|307|308)

                log "Application is responding correctly: HTTP $HTTP_CODE"

                return 0
                ;;

        esac


        log "Attempt $I/$MAX_TRIES returned HTTP $HTTP_CODE"


        sleep 2

    done


    err "Application health check failed."

    return 1
}


# ==============================================================================
# FINAL VALIDATION
# ==============================================================================

validate_deployment()
{
    log "Performing final deployment validation..."


    if [[ ! -f "${APP_DIR}/index.php" ]]; then

        err "index.php not found."

        return 1
    fi


    if [[ "$OS_FAMILY" == "redhat" ]]; then

        httpd -t

    else

        apache2ctl configtest

    fi


    if ! systemctl is-active \
        --quiet \
        "$APACHE_SERVICE"
    then

        err "Apache is not active."

        return 1
    fi


    if ! sudo -u postgres \
        psql \
        -d "$DB_NAME" \
        -tAc 'SELECT 1' \
        >/dev/null
    then

        err "Application database validation failed."

        return 1
    fi


    if [[ "$OS_FAMILY" == "redhat" ]] \
       && command_exists getenforce \
       && [[ "$(getenforce)" != "Disabled" ]]
    then

        if ! ls -Zd \
            "${APP_DIR}/generated-files" \
            | grep -q httpd_sys_rw_content_t
        then

            err "Invalid SELinux context on writable directory."

            return 1
        fi

    fi


    wait_for_https


    log "Deployment validation successful."
}


# ==============================================================================
# FINAL INFORMATION
# ==============================================================================

print_final_info()
{
    echo

    echo "=============================================================="
    echo " WORKFLOW DEPLOYMENT COMPLETED"
    echo "=============================================================="
    echo

    echo "Application"
    echo "-----------"

    echo "Name      : $APP_NAME"

    echo "Directory : $APP_DIR"

    echo

    echo "HTTP"
    echo "----"

    echo "http://${SERVER_NAME}:${APP_PORT_HTTP}"

    echo

    echo "HTTPS"
    echo "-----"

    echo "https://${SERVER_NAME}:${APP_PORT_HTTPS}"

    echo

    echo "PostgreSQL"
    echo "----------"

    echo "Database : $DB_NAME"
    echo "User     : $DB_USER"
    echo "Host     : $DB_HOST"
    echo "Port     : $DB_PORT"

    echo


    warn "The generated TLS certificate is self-signed."

    warn "Use a trusted CA certificate for production environments."
}


# ==============================================================================
# MAIN
# ==============================================================================

main()
{
    require_root

    load_env

    detect_os


    # --------------------------------------------------------------------------
    # Operating system
    # --------------------------------------------------------------------------

    update_repositories

    install_base_packages


    # --------------------------------------------------------------------------
    # Apache
    # --------------------------------------------------------------------------

    install_apache


    if [[ "$OS_FAMILY" == "debian" ]]; then

        export DEBIAN_FRONTEND=noninteractive


        require_cmd a2enmod
        require_cmd a2ensite

    fi


    # --------------------------------------------------------------------------
    # PHP
    # --------------------------------------------------------------------------

    install_php


    if [[ "$OS_FAMILY" == "debian" ]]; then

        detect_php_ini_override_debian

    fi


    # --------------------------------------------------------------------------
    # PostgreSQL
    # --------------------------------------------------------------------------

    install_postgresql

    wait_for_postgres


    # --------------------------------------------------------------------------
    # TLS
    # --------------------------------------------------------------------------

    generate_self_signed_cert


    # --------------------------------------------------------------------------
    # PHP configuration
    # --------------------------------------------------------------------------

    write_php_ini_override


    # --------------------------------------------------------------------------
    # Application
    # --------------------------------------------------------------------------

    prepare_app_dir

    deploy_source

    configure_writable_dirs

    generate_config_php

    patch_database_php

    patch_login_configuration


    # --------------------------------------------------------------------------
    # PostgreSQL application
    # --------------------------------------------------------------------------

    create_database_and_user

    import_database

    grant_application_privileges

    seed_initial_user


    # --------------------------------------------------------------------------
    # Apache ports
    # --------------------------------------------------------------------------

    if [[ "$OS_FAMILY" == "debian" ]]; then

        configure_apache_ports_debian

        disable_default_apache_sites_debian

    else

        configure_apache_ports_redhat

        configure_selinux_http_ports

        configure_selinux

    fi


    # --------------------------------------------------------------------------
    # Apache VirtualHost
    # --------------------------------------------------------------------------

    write_apache_config


    # --------------------------------------------------------------------------
    # Firewall
    # --------------------------------------------------------------------------

    configure_firewall


    # --------------------------------------------------------------------------
    # Validation
    # --------------------------------------------------------------------------

    validate_deployment


    # --------------------------------------------------------------------------
    # Information
    # --------------------------------------------------------------------------

    print_final_info
}


main "$@"

