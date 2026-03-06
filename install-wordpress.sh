#!/bin/bash
# =============================================================================
# WordPress Universal Installer
# Supports: Plesk, cPanel/WHM, DirectAdmin, FastPanel, VestaCP/HestiaCP,
#           CyberPanel, ISPConfig, Webmin, and bare server (no panel)
#
# Usage: cd /path/to/your/webroot/subfolder && bash install-wordpress.sh
# Result: WordPress live at https://yourdomain.com/subfolder — zero input.
# =============================================================================

set -e

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${BLUE}[INFO]${NC}   $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}     $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}   $1"; }
fail()  { echo -e "${RED}[ERROR]${NC}  $1"; exit 1; }
panel() { echo -e "${CYAN}[PANEL]${NC}  $1"; }

[[ "$EUID" -ne 0 ]] && fail "Please run as root: sudo bash install-wordpress.sh"

INSTALL_DIR="$(pwd)"
PANEL_TYPE=""
DOMAIN=""
SUBPATH=""
SCHEME="https"
SITE_URL=""
WEB_USER=""
WEB_GROUP=""
MYSQL_CMD=""

# =============================================================================
# STEP 1 — Detect control panel
# =============================================================================
detect_panel() {
  log "Detecting control panel..."

  if command -v plesk &>/dev/null || [[ -f /etc/psa/.psa.shadow ]]; then
    PANEL_TYPE="plesk"
  elif [[ -d /usr/local/cpanel ]] || command -v whmapi1 &>/dev/null; then
    PANEL_TYPE="cpanel"
  elif [[ -d /usr/local/directadmin ]] || [[ -f /usr/local/directadmin/directadmin ]]; then
    PANEL_TYPE="directadmin"
  elif [[ -d /usr/local/fastpanel ]] || [[ -f /etc/fastpanel/fastpanel.conf ]]; then
    PANEL_TYPE="fastpanel"
  elif [[ -d /usr/local/hestia ]] || { command -v v-list-users &>/dev/null && [[ -f /usr/local/hestia/conf/hestia.conf ]]; }; then
    PANEL_TYPE="hestia"
  elif [[ -d /usr/local/vesta ]] || { command -v v-list-users &>/dev/null && [[ -f /usr/local/vesta/conf/vesta.conf ]]; }; then
    PANEL_TYPE="vesta"
  elif [[ -d /usr/local/CyberCP ]] || command -v cyberpanel &>/dev/null; then
    PANEL_TYPE="cyberpanel"
  elif [[ -d /usr/local/ispconfig ]] || [[ -f /etc/ispconfig/ispconfig.conf ]]; then
    PANEL_TYPE="ispconfig"
  elif command -v webmin &>/dev/null || [[ -d /etc/webmin ]]; then
    PANEL_TYPE="webmin"
  else
    PANEL_TYPE="none"
  fi

  panel "Detected: ${PANEL_TYPE}"
}

# =============================================================================
# STEP 2 — Detect URL from path (panel-aware)
# =============================================================================
detect_ssl() {
  local domain="$1"
  if [[ -d "/etc/letsencrypt/live/${domain}" ]] || \
     [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
    echo "https"; return
  fi
  echo "http"
}

detect_url() {
  log "Detecting site URL from: ${INSTALL_DIR}"

  # ── Plesk: /var/www/vhosts/<domain>/httpdocs/<subpath> ─────────────────────
  if echo "$INSTALL_DIR" | grep -qE '^/var/www/vhosts/[^/]+/httpdocs'; then
    DOMAIN=$(echo "$INSTALL_DIR" | sed 's|^/var/www/vhosts/||' | cut -d'/' -f1)
    WEBROOT="/var/www/vhosts/${DOMAIN}/httpdocs"
    SUBPATH="${INSTALL_DIR#$WEBROOT}"; SUBPATH="${SUBPATH%/}"
    SCHEME=$(detect_ssl "$DOMAIN")
    SITE_URL="${SCHEME}://${DOMAIN}${SUBPATH}"
    panel "Plesk layout → ${SITE_URL}"; return
  fi

  # ── DirectAdmin: /home/<user>/domains/<domain>/public_html/<subpath> ────────
  if echo "$INSTALL_DIR" | grep -qE '^/home/[^/]+/domains/[^/]+/public_html'; then
    DOMAIN=$(echo "$INSTALL_DIR" | sed 's|^/home/[^/]*/domains/||' | cut -d'/' -f1)
    DA_USER=$(echo "$INSTALL_DIR" | sed 's|^/home/||' | cut -d'/' -f1)
    WEBROOT="/home/${DA_USER}/domains/${DOMAIN}/public_html"
    SUBPATH="${INSTALL_DIR#$WEBROOT}"; SUBPATH="${SUBPATH%/}"
    SCHEME=$(detect_ssl "$DOMAIN")
    SITE_URL="${SCHEME}://${DOMAIN}${SUBPATH}"
    panel "DirectAdmin layout → ${SITE_URL}"; return
  fi

  # ── HestiaCP/VestaCP: /home/<user>/web/<domain>/public_html/<subpath> ───────
  if echo "$INSTALL_DIR" | grep -qE '^/home/[^/]+/web/[^/]+/public_html'; then
    DOMAIN=$(echo "$INSTALL_DIR" | sed 's|^/home/[^/]*/web/||' | cut -d'/' -f1)
    HV_USER=$(echo "$INSTALL_DIR" | sed 's|^/home/||' | cut -d'/' -f1)
    WEBROOT="/home/${HV_USER}/web/${DOMAIN}/public_html"
    SUBPATH="${INSTALL_DIR#$WEBROOT}"; SUBPATH="${SUBPATH%/}"
    SCHEME=$(detect_ssl "$DOMAIN")
    SITE_URL="${SCHEME}://${DOMAIN}${SUBPATH}"
    panel "HestiaCP/VestaCP layout → ${SITE_URL}"; return
  fi

  # ── FastPanel: /var/www/<user>/data/www/<domain>/<subpath> ──────────────────
  if echo "$INSTALL_DIR" | grep -qE '^/var/www/[^/]+/data/www/[^/]+'; then
    DOMAIN=$(echo "$INSTALL_DIR" | sed 's|^/var/www/[^/]*/data/www/||' | cut -d'/' -f1)
    FP_USER=$(echo "$INSTALL_DIR" | sed 's|^/var/www/||' | cut -d'/' -f1)
    WEBROOT="/var/www/${FP_USER}/data/www/${DOMAIN}"
    SUBPATH="${INSTALL_DIR#$WEBROOT}"; SUBPATH="${SUBPATH%/}"
    SCHEME=$(detect_ssl "$DOMAIN")
    SITE_URL="${SCHEME}://${DOMAIN}${SUBPATH}"
    panel "FastPanel layout → ${SITE_URL}"; return
  fi

  # ── cPanel/CyberPanel: /home/<user>/public_html/<subpath> ───────────────────
  if echo "$INSTALL_DIR" | grep -qE '^/home/[^/]+/public_html'; then
    CP_USER=$(echo "$INSTALL_DIR" | sed 's|^/home/||' | cut -d'/' -f1)
    WEBROOT="/home/${CP_USER}/public_html"
    SUBPATH="${INSTALL_DIR#$WEBROOT}"; SUBPATH="${SUBPATH%/}"
    # Try to resolve real domain from cPanel user data
    DOMAIN=$(cat "/var/cpanel/userdata/${CP_USER}/main" 2>/dev/null | grep '^main_domain:' | awk '{print $2}' || true)
    [[ -z "$DOMAIN" ]] && DOMAIN=$(hostname -f 2>/dev/null || hostname)
    SCHEME=$(detect_ssl "$DOMAIN")
    SITE_URL="${SCHEME}://${DOMAIN}${SUBPATH}"
    panel "cPanel/CyberPanel layout (user: ${CP_USER}) → ${SITE_URL}"; return
  fi

  # ── ISPConfig: /var/www/clients/clientN/webN/web/<subpath> ──────────────────
  if echo "$INSTALL_DIR" | grep -qE '^/var/www/clients/'; then
    WEBROOT=$(echo "$INSTALL_DIR" | grep -oP '^/var/www/clients/[^/]+/[^/]+/web')
    SUBPATH="${INSTALL_DIR#$WEBROOT}"; SUBPATH="${SUBPATH%/}"
    DOMAIN=$(hostname -f 2>/dev/null || hostname)
    SCHEME=$(detect_ssl "$DOMAIN")
    SITE_URL="${SCHEME}://${DOMAIN}${SUBPATH}"
    panel "ISPConfig layout → ${SITE_URL}"; return
  fi

  # ── Generic / bare metal ────────────────────────────────────────────────────
  for webroot in /var/www/html /var/www /srv/www/htdocs /srv/www /usr/share/nginx/html; do
    if echo "$INSTALL_DIR" | grep -q "^${webroot}"; then
      SUBPATH="${INSTALL_DIR#$webroot}"; SUBPATH="${SUBPATH%/}"
      DOMAIN=$(hostname -f 2>/dev/null || hostname)
      SCHEME=$(detect_ssl "$DOMAIN")
      SITE_URL="${SCHEME}://${DOMAIN}${SUBPATH}"
      panel "Bare server layout → ${SITE_URL}"; return
    fi
  done

  # ── Absolute fallback ───────────────────────────────────────────────────────
  DOMAIN=$(hostname -f 2>/dev/null || hostname)
  SUBPATH="/$(basename "$INSTALL_DIR")"
  SCHEME="http"
  SITE_URL="${SCHEME}://${DOMAIN}${SUBPATH}"
  warn "Could not detect layout. Defaulting to: ${SITE_URL}"
  warn "Override by editing SITE_URL at the top of this script if needed."
}

# =============================================================================
# STEP 3 — Generate credentials
# =============================================================================
generate_credentials() {
  SLUG=$(echo "$SUBPATH" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | head -c10)
  [[ -z "$SLUG" ]] && SLUG="wp"
  DB_NAME="${SLUG}_$(openssl rand -hex 3)"
  DB_USER="u_$(openssl rand -hex 4)"
  DB_PASS="$(openssl rand -base64 18 | tr -cd '[:alnum:]' | head -c22)"
  DB_HOST="localhost"
  WP_ADMIN_USER="admin"
  WP_ADMIN_PASS="$(openssl rand -base64 18 | tr -cd '[:alnum:]' | head -c22)"
  WP_ADMIN_EMAIL="admin@${DOMAIN:-example.com}"
  WP_TITLE="WordPress"
}

# =============================================================================
# STEP 4 — MySQL auth (panel-aware + universal fallbacks)
# =============================================================================
detect_mysql_auth() {
  log "Detecting MySQL authentication..."

  # ── Plesk ──────────────────────────────────────────────────────────────────
  if [[ "$PANEL_TYPE" == "plesk" ]]; then
    if command -v plesk &>/dev/null && plesk db "SELECT 1;" &>/dev/null 2>&1; then
      MYSQL_CMD="plesk db"; ok "MySQL: Plesk CLI"; return
    fi
    if [[ -f /etc/psa/.psa.shadow ]]; then
      PSA_PASS=$(cat /etc/psa/.psa.shadow)
      for u in admin root; do
        if mysql -u "$u" -p"${PSA_PASS}" -e "SELECT 1;" &>/dev/null 2>&1; then
          MYSQL_CMD="mysql -u ${u} -p${PSA_PASS}"; ok "MySQL: Plesk .psa.shadow (${u})"; return
        fi
      done
    fi
  fi

  # ── cPanel ─────────────────────────────────────────────────────────────────
  if [[ "$PANEL_TYPE" == "cpanel" ]]; then
    for f in /root/.my.cnf /etc/my.cnf /usr/local/cpanel/etc/my.cnf; do
      if [[ -f "$f" ]] && mysql --defaults-file="$f" -e "SELECT 1;" &>/dev/null 2>&1; then
        MYSQL_CMD="mysql --defaults-file=${f}"; ok "MySQL: cPanel (${f})"; return
      fi
    done
  fi

  # ── DirectAdmin ─────────────────────────────────────────────────────────────
  if [[ "$PANEL_TYPE" == "directadmin" ]]; then
    DA_CONF="/usr/local/directadmin/conf/mysql.conf"
    if [[ -f "$DA_CONF" ]]; then
      DA_PASS=$(grep -iE 'passwd|password' "$DA_CONF" | head -1 | cut -d'=' -f2 | tr -d ' "')
      DA_USER=$(grep -iE '^user\b' "$DA_CONF" | head -1 | cut -d'=' -f2 | tr -d ' "')
      [[ -z "$DA_USER" ]] && DA_USER="da_admin"
      if mysql -u "$DA_USER" -p"${DA_PASS}" -e "SELECT 1;" &>/dev/null 2>&1; then
        MYSQL_CMD="mysql -u ${DA_USER} -p${DA_PASS}"; ok "MySQL: DirectAdmin conf"; return
      fi
    fi
  fi

  # ── FastPanel ───────────────────────────────────────────────────────────────
  if [[ "$PANEL_TYPE" == "fastpanel" ]]; then
    for f in /etc/fastpanel/db.conf /usr/local/fastpanel/app/config/db.php; do
      if [[ -f "$f" ]]; then
        FP_PASS=$(grep -oP "(?<=['\"]password['\"]\s*=>\s*['\"])[^'\"]+" "$f" 2>/dev/null | head -1 || \
                  grep -oP "(?<=password=)[^\s]+" "$f" 2>/dev/null | head -1 || true)
        FP_USER=$(grep -oP "(?<=['\"]username['\"]\s*=>\s*['\"])[^'\"]+" "$f" 2>/dev/null | head -1 || \
                  grep -oP "(?<=username=)[^\s]+" "$f" 2>/dev/null | head -1 || true)
        [[ -z "$FP_USER" ]] && FP_USER="root"
        if [[ -n "$FP_PASS" ]] && mysql -u "$FP_USER" -p"${FP_PASS}" -e "SELECT 1;" &>/dev/null 2>&1; then
          MYSQL_CMD="mysql -u ${FP_USER} -p${FP_PASS}"; ok "MySQL: FastPanel conf"; return
        fi
      fi
    done
  fi

  # ── HestiaCP ────────────────────────────────────────────────────────────────
  if [[ "$PANEL_TYPE" == "hestia" ]]; then
    for f in /usr/local/hestia/conf/mysql.conf /root/.my.cnf; do
      if [[ -f "$f" ]]; then
        H_PASS=$(grep -iE 'password|passwd' "$f" | head -1 | cut -d'=' -f2 | tr -d "' \"")
        if mysql -u root -p"${H_PASS}" -e "SELECT 1;" &>/dev/null 2>&1; then
          MYSQL_CMD="mysql -u root -p${H_PASS}"; ok "MySQL: HestiaCP conf"; return
        fi
      fi
    done
  fi

  # ── VestaCP ─────────────────────────────────────────────────────────────────
  if [[ "$PANEL_TYPE" == "vesta" ]]; then
    if [[ -f /usr/local/vesta/conf/mysql.conf ]]; then
      V_PASS=$(grep -i 'password' /usr/local/vesta/conf/mysql.conf | head -1 | cut -d'=' -f2 | tr -d "' \"")
      if mysql -u root -p"${V_PASS}" -e "SELECT 1;" &>/dev/null 2>&1; then
        MYSQL_CMD="mysql -u root -p${V_PASS}"; ok "MySQL: VestaCP conf"; return
      fi
    fi
  fi

  # ── CyberPanel ──────────────────────────────────────────────────────────────
  if [[ "$PANEL_TYPE" == "cyberpanel" ]]; then
    CP_CONF="/usr/local/CyberCP/CyberCP/settings.py"
    if [[ -f "$CP_CONF" ]]; then
      CP_PASS=$(grep -A5 "DATABASES" "$CP_CONF" | grep "'PASSWORD'" | cut -d"'" -f4)
      CP_USER=$(grep -A5 "DATABASES" "$CP_CONF" | grep "'USER'" | cut -d"'" -f4)
      [[ -z "$CP_USER" ]] && CP_USER="root"
      if mysql -u "$CP_USER" -p"${CP_PASS}" -e "SELECT 1;" &>/dev/null 2>&1; then
        MYSQL_CMD="mysql -u ${CP_USER} -p${CP_PASS}"; ok "MySQL: CyberPanel conf"; return
      fi
    fi
  fi

  # ── ISPConfig ───────────────────────────────────────────────────────────────
  if [[ "$PANEL_TYPE" == "ispconfig" ]]; then
    ISP_CONF="/usr/local/ispconfig/server/lib/config.inc.php"
    if [[ -f "$ISP_CONF" ]]; then
      ISP_PASS=$(grep 'db_password' "$ISP_CONF" | head -1 | cut -d"'" -f4)
      ISP_USER=$(grep "'db_user'" "$ISP_CONF" | head -1 | cut -d"'" -f4)
      [[ -z "$ISP_USER" ]] && ISP_USER="root"
      if mysql -u "$ISP_USER" -p"${ISP_PASS}" -e "SELECT 1;" &>/dev/null 2>&1; then
        MYSQL_CMD="mysql -u ${ISP_USER} -p${ISP_PASS}"; ok "MySQL: ISPConfig conf"; return
      fi
    fi
  fi

  # ── Universal fallbacks ────────────────────────────────────────────────────
  if [[ -f /root/.my.cnf ]] && mysql --defaults-file=/root/.my.cnf -e "SELECT 1;" &>/dev/null 2>&1; then
    MYSQL_CMD="mysql --defaults-file=/root/.my.cnf"; ok "MySQL: /root/.my.cnf"; return
  fi
  if mysql -u root -e "SELECT 1;" &>/dev/null 2>&1; then
    MYSQL_CMD="mysql -u root"; ok "MySQL: passwordless socket"; return
  fi
  if mysql -u root --password="" -e "SELECT 1;" &>/dev/null 2>&1; then
    MYSQL_CMD="mysql -u root --password=''"; ok "MySQL: empty password"; return
  fi
  for sock in /var/lib/mysql/mysql.sock /tmp/mysql.sock /run/mysqld/mysqld.sock; do
    if [[ -S "$sock" ]] && mysql -u root --socket="$sock" -e "SELECT 1;" &>/dev/null 2>&1; then
      MYSQL_CMD="mysql -u root --socket=${sock}"; ok "MySQL: socket ${sock}"; return
    fi
  done
  for logfile in /var/log/mysqld.log /var/log/mysql/error.log /var/log/mariadb/mariadb.log; do
    if [[ -f "$logfile" ]]; then
      TMP_PASS=$(grep 'temporary password' "$logfile" 2>/dev/null | tail -1 | awk '{print $NF}')
      if [[ -n "$TMP_PASS" ]] && mysql -u root -p"${TMP_PASS}" --connect-expired-password -e "SELECT 1;" &>/dev/null 2>&1; then
        NEW_PASS="$(openssl rand -base64 16 | tr -cd '[:alnum:]' | head -c20)"
        mysql -u root -p"${TMP_PASS}" --connect-expired-password \
          -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_PASS}';" 2>/dev/null || true
        MYSQL_CMD="mysql -u root -p${NEW_PASS}"; ok "MySQL: reset from temp password"; return
      fi
    fi
  done

  fail "Cannot connect to MySQL. Panel: ${PANEL_TYPE}
  Try: mysql -u root -p  OR  cat /root/.my.cnf"
}

run_sql() {
  if [[ "$MYSQL_CMD" == "plesk db" ]]; then
    while IFS= read -r line; do
      [[ -z "${line// }" ]] && continue
      plesk db "$line"
    done <<< "$1"
  else
    echo "$1" | $MYSQL_CMD
  fi
}

# =============================================================================
# STEP 5 — Install missing packages
# =============================================================================
install_deps() {
  log "Checking dependencies..."
  MISSING=()
  command -v php   &>/dev/null || MISSING+=(php)
  command -v mysql &>/dev/null || MISSING+=(mysql)
  command -v wget  &>/dev/null || MISSING+=(wget)
  command -v unzip &>/dev/null || MISSING+=(unzip)
  command -v curl  &>/dev/null || MISSING+=(curl)

  if [[ ${#MISSING[@]} -gt 0 ]]; then
    log "Installing: ${MISSING[*]}"
    if command -v dnf &>/dev/null; then
      dnf install -y "${MISSING[@]}" php-mysqlnd php-curl php-gd php-mbstring php-xml php-zip 2>/dev/null || true
    elif command -v yum &>/dev/null; then
      yum install -y "${MISSING[@]}" php-mysqlnd php-curl php-gd php-mbstring php-xml php-zip 2>/dev/null || true
    elif command -v apt-get &>/dev/null; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING[@]}" \
        php-mysql php-curl php-gd php-mbstring php-xml php-zip 2>/dev/null || true
    fi
  fi
  ok "Dependencies ready."
}

# =============================================================================
# STEP 6 — Create database
# =============================================================================
setup_database() {
  log "Creating database '${DB_NAME}'..."
  run_sql "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  run_sql "CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASS}';"
  run_sql "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${DB_HOST}';"
  run_sql "FLUSH PRIVILEGES;"
  ok "Database ready."
}

# =============================================================================
# STEP 7 — Download & configure WordPress
# =============================================================================
download_wordpress() {
  log "Downloading WordPress..."
  TMP=$(mktemp -d)
  wget -q https://wordpress.org/latest.zip -O "${TMP}/wp.zip"
  unzip -q "${TMP}/wp.zip" -d "${TMP}"
  cp -r "${TMP}/wordpress/." "${INSTALL_DIR}/"
  rm -rf "$TMP"
  ok "WordPress extracted to: ${INSTALL_DIR}"
}

configure_wordpress() {
  log "Writing wp-config.php..."
  cd "$INSTALL_DIR"
  cp wp-config-sample.php wp-config.php

  sed -i "s/database_name_here/${DB_NAME}/"  wp-config.php
  sed -i "s/username_here/${DB_USER}/"        wp-config.php
  sed -i "s/password_here/${DB_PASS}/"        wp-config.php
  sed -i "s|define( 'DB_HOST'.*|define( 'DB_HOST', '${DB_HOST}' );|" wp-config.php

  if [[ -n "$SUBPATH" ]]; then
    cat >> wp-config.php <<WPCONF

/* Subdirectory install — auto-set by installer */
define( 'WP_HOME',    '${SITE_URL}' );
define( 'WP_SITEURL', '${SITE_URL}' );
WPCONF
  fi

  SALTS=$(curl -sf https://api.wordpress.org/secret-key/1.1/salt/ 2>/dev/null || true)
  if [[ -n "$SALTS" ]]; then
    python3 - "$SALTS" <<'PYEOF'
import sys, re
salts = sys.argv[1]
with open('wp-config.php', 'r') as f:
    c = f.read()
c = re.sub(r"define\( 'AUTH_KEY'.*?define\( 'NONCE_SALT'[^)]+\);", salts.strip(), c, flags=re.DOTALL)
with open('wp-config.php', 'w') as f:
    f.write(c)
PYEOF
  fi
  ok "wp-config.php configured."
}

# =============================================================================
# STEP 8 — WP-CLI core install
# =============================================================================
install_wordpress_core() {
  log "Running WordPress core install..."
  WP_CLI=$(mktemp /tmp/wp-cli.XXXXXX)
  curl -sf https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o "$WP_CLI"
  chmod +x "$WP_CLI"

  php "$WP_CLI" core install \
    --path="$INSTALL_DIR" \
    --url="$SITE_URL" \
    --title="$WP_TITLE" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASS" \
    --admin_email="$WP_ADMIN_EMAIL" \
    --allow-root \
    --skip-email

  rm -f "$WP_CLI"
  ok "WordPress core installed."
}

# =============================================================================
# STEP 9 — Fix permissions (panel-aware, no hardcoded usernames)
# =============================================================================
fix_permissions() {
  log "Detecting file ownership..."
  WEB_USER=""; WEB_GROUP=""

  # ── Priority 1: stat() the immediate parent directory ──────────────────────
  # Every panel sets the correct uid:gid on the webroot when creating a site.
  # Walking up from INSTALL_DIR will always land on that panel-managed folder.
  CHECK_DIR="$INSTALL_DIR"
  for _ in 1 2 3; do
    CHECK_DIR=$(dirname "$CHECK_DIR")
    CANDIDATE=$(stat -c '%U' "$CHECK_DIR" 2>/dev/null || true)
    CANDIDATE_G=$(stat -c '%G' "$CHECK_DIR" 2>/dev/null || true)
    if [[ -n "$CANDIDATE" && "$CANDIDATE" != "root" ]]; then
      WEB_USER="$CANDIDATE"; WEB_GROUP="$CANDIDATE_G"
      log "Ownership from ancestor dir (${CHECK_DIR}): ${WEB_USER}:${WEB_GROUP}"
      break
    fi
  done

  # ── Priority 2: running web process (works universally when above fails) ────
  if [[ -z "$WEB_USER" || "$WEB_USER" == "root" ]]; then
    WEB_USER=$(ps -eo user,comm --no-headers 2>/dev/null | \
      grep -E 'httpd|apache2|nginx|php-fpm|litespeed|lshttpd|openlitespeed' | \
      grep -v root | awk '{print $1}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}' || true)
    WEB_GROUP=$(id -gn "$WEB_USER" 2>/dev/null || echo "$WEB_USER")
    [[ -n "$WEB_USER" ]] && log "Ownership from web process: ${WEB_USER}:${WEB_GROUP}"
  fi

  if [[ -z "$WEB_USER" || "$WEB_USER" == "root" ]]; then
    warn "Could not determine web user — leaving as root. You may need to chown manually."
    WEB_USER="root"; WEB_GROUP="root"
  fi

  chown -R "${WEB_USER}:${WEB_GROUP}" "$INSTALL_DIR"
  find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
  find "$INSTALL_DIR" -type f -exec chmod 644 {} \;
  chmod 600 "$INSTALL_DIR/wp-config.php"
  ok "Permissions set → ${WEB_USER}:${WEB_GROUP}"
}

# =============================================================================
# STEP 10 — Write .htaccess
# =============================================================================
write_htaccess() {
  log "Writing .htaccess..."
  REWRITE_BASE="${SUBPATH:-/}/"
  REWRITE_BASE=$(echo "$REWRITE_BASE" | sed 's|//|/|g')

  cat > "$INSTALL_DIR/.htaccess" <<HTACCESS
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase ${REWRITE_BASE}
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . ${REWRITE_BASE}index.php [L]
</IfModule>
# END WordPress
HTACCESS
  ok ".htaccess written (RewriteBase: ${REWRITE_BASE})"
}

# =============================================================================
# STEP 11 — Save credentials
# =============================================================================
save_credentials() {
  CREDS="${INSTALL_DIR}/wordpress-credentials.txt"
  cat > "$CREDS" <<CREDS
=========================================================
  WordPress — Credentials
  Generated : $(date)
  Panel     : ${PANEL_TYPE}
=========================================================

  Site URL    : ${SITE_URL}
  Admin URL   : ${SITE_URL}/wp-admin

  Admin User  : ${WP_ADMIN_USER}
  Admin Pass  : ${WP_ADMIN_PASS}
  Admin Email : ${WP_ADMIN_EMAIL}

---------------------------------------------------------

  DB Name     : ${DB_NAME}
  DB User     : ${DB_USER}
  DB Pass     : ${DB_PASS}
  DB Host     : ${DB_HOST}

  Install Dir : ${INSTALL_DIR}
  File Owner  : ${WEB_USER}:${WEB_GROUP}

=========================================================
CREDS
  chmod 600 "$CREDS"
  ok "Credentials saved → ${CREDS}"
}

# =============================================================================
# MAIN
# =============================================================================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  WordPress Universal Installer${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

detect_panel
detect_url
generate_credentials
install_deps
detect_mysql_auth
setup_database
download_wordpress
configure_wordpress
install_wordpress_core
fix_permissions
write_htaccess
save_credentials

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  ✅  WordPress is live!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  🌐  Visit    : ${YELLOW}${SITE_URL}${NC}"
echo -e "  🔧  Admin    : ${YELLOW}${SITE_URL}/wp-admin${NC}"
echo -e "  👤  User     : ${YELLOW}${WP_ADMIN_USER}${NC}"
echo -e "  🔑  Pass     : ${YELLOW}${WP_ADMIN_PASS}${NC}"
echo -e "  🗄️   Panel    : ${YELLOW}${PANEL_TYPE}${NC}"
echo -e "  📄  Creds    : ${YELLOW}${INSTALL_DIR}/wordpress-credentials.txt${NC}"
echo ""
