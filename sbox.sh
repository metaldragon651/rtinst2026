#!/usr/bin/env bash
# =============================================================================
#  SEEDBOX AUTO-INSTALLER
#  Supports: Ubuntu 20.04/22.04/24.04 | Debian 11/12 | CentOS 7/8/Stream/9
#  Features: rTorrent+ruTorrent, qBittorrent, Admin Panel, Chroot Users,
#            Disk Quotas, Secure SFTP, Kernel/Network Optimization
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────── GLOBALS ─────────────────────────────────────
SEEDBOX_BASE="/opt/seedbox"
SEEDBOX_CONF="/etc/seedbox"
SEEDBOX_LOG="/var/log/seedbox"
SEEDBOX_USERS_HOME="/home/seedbox-users"
SEEDBOX_CHROOT="/var/seedbox/chroot"
ADMIN_PANEL_PORT=8080
RTORRENT_BASE_PORT=5000
QBIT_BASE_PORT=6000
RUTORRENT_WEB_BASE=8100
WEB_PORT_BASE=9000

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="/var/log/seedbox-install.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─────────────────────────────── LOGGING ─────────────────────────────────────
log()     { echo -e "${GREEN}[✔]${NC} $*" | tee -a "$LOGFILE"; }
warn()    { echo -e "${YELLOW}[⚠]${NC} $*" | tee -a "$LOGFILE"; }
error()   { echo -e "${RED}[✘]${NC} $*" | tee -a "$LOGFILE"; }
info()    { echo -e "${CYAN}[i]${NC} $*" | tee -a "$LOGFILE"; }
section() { echo -e "\n${BOLD}${BLUE}══════════ $* ══════════${NC}\n" | tee -a "$LOGFILE"; }

die() { error "$*"; exit 1; }

# ─────────────────────────── ROOT CHECK ──────────────────────────────────────
[[ "$EUID" -ne 0 ]] && die "Must be run as root. Use: sudo bash $0"

mkdir -p "$SEEDBOX_LOG" "$SEEDBOX_CONF" "$SEEDBOX_BASE" "$SEEDBOX_USERS_HOME"
touch "$LOGFILE"
chmod 700 "$SEEDBOX_CONF"

# ──────────────────────── DETECT DISTRO ──────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO="${ID,,}"
        DISTRO_VERSION="${VERSION_ID%%.*}"
        DISTRO_CODENAME="${VERSION_CODENAME:-}"
    else
        die "Cannot detect OS. /etc/os-release missing."
    fi

    case "$DISTRO" in
        ubuntu|debian) PKG_MGR="apt"; PKG_UPDATE="apt-get update -qq"; PKG_INSTALL="apt-get install -y -qq" ;;
        centos|rhel|rocky|almalinux) PKG_MGR="yum"
            command -v dnf &>/dev/null && PKG_MGR="dnf"
            PKG_UPDATE="${PKG_MGR} makecache -q"
            PKG_INSTALL="${PKG_MGR} install -y -q" ;;
        *) die "Unsupported distro: $DISTRO" ;;
    esac

    info "Detected: $PRETTY_NAME (Distro=$DISTRO, Version=$DISTRO_VERSION)"
}

# ──────────────────────── INTERACTIVE SETUP ──────────────────────────────────
interactive_setup() {
    clear
    echo -e "${BOLD}${BLUE}"
    cat << 'EOF'
  ____  _____  _____  ____  ____  _____  _  _
 / ___)(  _  )(  _  )(  _ \(  _ \(  _  )( \/ )
 \___ \ )(  )( )( )(  )(_) )) _ < )( )(  )  (
 (____/(__)(__)(_____)(_____/(____/(_____)(_/\_)
          AUTO-INSTALLER v2.0
EOF
    echo -e "${NC}"
    echo -e "  Supports: Ubuntu 20/22/24 | Debian 11/12 | CentOS 7/8/9"
    echo -e "  Features: rTorrent/ruTorrent • qBittorrent • Admin Panel"
    echo -e "            Chroot Users • Disk Quotas • Secure SFTP\n"

    # Admin credentials
    section "Admin Account Setup"
    while true; do
        read -rp "  Admin username [admin]: " ADMIN_USER
        ADMIN_USER="${ADMIN_USER:-admin}"
        [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{2,31}$ ]] && break
        warn "Username must be 3-32 chars, lowercase letters/numbers/underscore/dash."
    done

    while true; do
        read -rsp "  Admin password: " ADMIN_PASS; echo
        read -rsp "  Confirm password: " ADMIN_PASS2; echo
        [[ "$ADMIN_PASS" == "$ADMIN_PASS2" ]] && [[ ${#ADMIN_PASS} -ge 8 ]] && break
        warn "Passwords must match and be at least 8 characters."
    done

    read -rp "  Admin email [admin@localhost]: " ADMIN_EMAIL
    ADMIN_EMAIL="${ADMIN_EMAIL:-admin@localhost}"

    # Domain / hostname
    section "Server Configuration"
    SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    read -rp "  Server hostname/IP [$SERVER_IP]: " SERVER_HOST
    SERVER_HOST="${SERVER_HOST:-$SERVER_IP}"

    # Torrent clients
    section "Torrent Client Selection"
    echo "  1) rTorrent + ruTorrent only"
    echo "  2) qBittorrent only"
    echo "  3) Both (recommended)"
    read -rp "  Choice [3]: " CLIENT_CHOICE
    CLIENT_CHOICE="${CLIENT_CHOICE:-3}"
    case "$CLIENT_CHOICE" in
        1) INSTALL_RTORRENT=true;  INSTALL_QBIT=false ;;
        2) INSTALL_RTORRENT=false; INSTALL_QBIT=true  ;;
        *)  INSTALL_RTORRENT=true;  INSTALL_QBIT=true  ;;
    esac

    # SSL
    section "SSL Certificate"
    echo "  1) Self-signed certificate (default)"
    echo "  2) Let's Encrypt (requires valid domain + port 80 open)"
    read -rp "  Choice [1]: " SSL_CHOICE
    SSL_CHOICE="${SSL_CHOICE:-1}"
    USE_LETSENCRYPT=false
    [[ "$SSL_CHOICE" == "2" ]] && USE_LETSENCRYPT=true

    # Optimization
    section "Performance Tuning"
    read -rp "  Apply kernel/network optimizations? (recommended) [Y/n]: " OPT_CHOICE
    OPT_CHOICE="${OPT_CHOICE:-Y}"
    APPLY_OPTIMIZATIONS=true
    [[ "${OPT_CHOICE,,}" == "n" ]] && APPLY_OPTIMIZATIONS=false

    # Confirm
    section "Summary"
    echo -e "  OS:              $PRETTY_NAME"
    echo -e "  Admin user:      $ADMIN_USER"
    echo -e "  Server:          $SERVER_HOST"
    echo -e "  rTorrent:        $INSTALL_RTORRENT"
    echo -e "  qBittorrent:     $INSTALL_QBIT"
    echo -e "  Let's Encrypt:   $USE_LETSENCRYPT"
    echo -e "  Optimizations:   $APPLY_OPTIMIZATIONS"
    echo -e "  Admin Panel:     https://$SERVER_HOST:$ADMIN_PANEL_PORT\n"

    read -rp "  Proceed with installation? [Y/n]: " CONFIRM
    [[ "${CONFIRM,,}" == "n" ]] && die "Installation cancelled."
}

# ──────────────────────── PACKAGE INSTALLATION ───────────────────────────────
install_base_packages() {
    section "Installing Base Packages"

    $PKG_UPDATE

    if [[ "$PKG_MGR" == "apt" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq \
            curl wget git unzip zip tar bzip2 xz-utils \
            build-essential automake autoconf libtool pkg-config \
            software-properties-common apt-transport-https ca-certificates \
            gnupg lsb-release \
            nginx openssl \
            php-fpm php-cli php-curl php-geoip php-xml php-mbstring \
            php-zip php-json php-opcache \
            python3 python3-pip python3-venv \
            sqlite3 libsqlite3-dev \
            quota quotatool \
            vsftpd \
            fail2ban ufw \
            htop iotop nethogs vnstat \
            screen tmux \
            acl attr \
            sudo cron \
            jq bc pwgen \
            mediainfo ffmpeg \
            logrotate 2>&1 | tee -a "$LOGFILE" || true

        # PHP version detection
        PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.1")
        PHP_FPM_SERVICE="php${PHP_VER}-fpm"

    elif [[ "$PKG_MGR" =~ (yum|dnf) ]]; then
        if [[ "$DISTRO" == "centos" && "$DISTRO_VERSION" == "7" ]]; then
            $PKG_INSTALL epel-release centos-release-scl
        else
            $PKG_INSTALL epel-release
            dnf config-manager --set-enabled crb &>/dev/null || true
            dnf config-manager --set-enabled powertools &>/dev/null || true
        fi
        $PKG_INSTALL \
            curl wget git unzip zip tar bzip2 xz \
            gcc gcc-c++ make automake autoconf libtool pkgconfig \
            openssl openssl-devel \
            nginx \
            php php-fpm php-cli php-curl php-xml php-mbstring \
            php-zip php-json php-opcache php-pdo \
            python3 python3-pip \
            sqlite sqlite-devel \
            quota \
            vsftpd \
            fail2ban \
            firewalld \
            htop screen tmux \
            acl attr sudo cronie \
            jq bc \
            mediainfo ffmpeg \
            logrotate 2>&1 | tee -a "$LOGFILE" || true

        PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.0")
        PHP_FPM_SERVICE="php-fpm"
    fi

    log "Base packages installed."
}

# ──────────────────────── SSL CERTIFICATES ───────────────────────────────────
setup_ssl() {
    section "SSL Certificate Setup"
    mkdir -p /etc/seedbox/ssl

    if [[ "$USE_LETSENCRYPT" == "true" ]]; then
        if [[ "$PKG_MGR" == "apt" ]]; then
            apt-get install -y -qq certbot python3-certbot-nginx
        else
            $PKG_INSTALL certbot python3-certbot-nginx
        fi
        certbot certonly --standalone --non-interactive --agree-tos \
            -m "$ADMIN_EMAIL" -d "$SERVER_HOST" \
            --pre-hook "systemctl stop nginx" \
            --post-hook "systemctl start nginx" || {
            warn "Let's Encrypt failed; falling back to self-signed."
            USE_LETSENCRYPT=false
        }
        if [[ "$USE_LETSENCRYPT" == "true" ]]; then
            SSL_CERT="/etc/letsencrypt/live/$SERVER_HOST/fullchain.pem"
            SSL_KEY="/etc/letsencrypt/live/$SERVER_HOST/privkey.pem"
            log "Let's Encrypt certificate issued."
            return
        fi
    fi

    # Self-signed fallback
    openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout /etc/seedbox/ssl/seedbox.key \
        -out    /etc/seedbox/ssl/seedbox.crt \
        -subj "/C=US/ST=State/L=City/O=Seedbox/CN=$SERVER_HOST" \
        -addext "subjectAltName=IP:$SERVER_HOST,DNS:$SERVER_HOST" 2>/dev/null
    chmod 600 /etc/seedbox/ssl/seedbox.key
    SSL_CERT="/etc/seedbox/ssl/seedbox.crt"
    SSL_KEY="/etc/seedbox/ssl/seedbox.key"
    log "Self-signed SSL certificate created."
}

# ──────────────────────── ADMIN USER ─────────────────────────────────────────
create_admin_user() {
    section "Creating Admin User"

    if id "$ADMIN_USER" &>/dev/null; then
        warn "User $ADMIN_USER already exists — skipping creation."
    else
        useradd -m -s /bin/bash -G sudo "$ADMIN_USER" 2>/dev/null || \
        useradd -m -s /bin/bash -G wheel "$ADMIN_USER" 2>/dev/null || true
        echo "$ADMIN_USER:$ADMIN_PASS" | chpasswd
    fi

    # Store hashed password for panel login
    ADMIN_PASS_HASH=$(python3 -c "import hashlib,os; s=os.urandom(16).hex(); \
        print(s+':'+hashlib.sha256((s+'$ADMIN_PASS').encode()).hexdigest())")

    mkdir -p "$SEEDBOX_CONF"
    cat > "$SEEDBOX_CONF/admin.conf" << EOF
ADMIN_USER=$ADMIN_USER
ADMIN_EMAIL=$ADMIN_EMAIL
ADMIN_PASS_HASH=$ADMIN_PASS_HASH
SERVER_HOST=$SERVER_HOST
INSTALL_RTORRENT=$INSTALL_RTORRENT
INSTALL_QBIT=$INSTALL_QBIT
INSTALL_DATE=$TIMESTAMP
EOF
    chmod 600 "$SEEDBOX_CONF/admin.conf"
    log "Admin user '$ADMIN_USER' configured."
}

# ──────────────────────── RTORRENT + RUTORRENT ───────────────────────────────
install_rtorrent() {
    section "Installing rTorrent"

    if [[ "$PKG_MGR" == "apt" ]]; then
        apt-get install -y -qq \
            rtorrent libxmlrpc-core-c3-dev \
            libcurl4-openssl-dev libssl-dev \
            libncurses5-dev libsigc++-2.0-dev \
            libtorrent-rasterbar-dev 2>&1 | tee -a "$LOGFILE" || true

        # Try PPA for latest rTorrent on Ubuntu
        if [[ "$DISTRO" == "ubuntu" ]]; then
            add-apt-repository -y ppa:libtorrent-rasterbar/ppa &>/dev/null || true
            apt-get update -qq && apt-get install -y -qq rtorrent || true
        fi
    else
        $PKG_INSTALL rtorrent libxmlrpc-c-devel libcurl-devel \
            libtorrent-devel ncurses-devel libsigc++20-devel || {
            warn "rTorrent not in repo; building from source..."
            build_rtorrent_from_source
        }
    fi

    RTORRENT_BIN=$(command -v rtorrent || echo "")
    [[ -z "$RTORRENT_BIN" ]] && build_rtorrent_from_source

    log "rTorrent installed: $(rtorrent --version 2>&1 | head -1 || echo 'unknown version')"
}

build_rtorrent_from_source() {
    info "Building rTorrent from source..."
    BUILD_DIR="/tmp/rtorrent-build"
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"

    if [[ "$PKG_MGR" == "apt" ]]; then
        apt-get install -y -qq libxmlrpc-c3-dev libcurl4-openssl-dev \
            libssl-dev libncurses5-dev libsigc++-2.0-dev libtorrent-rasterbar-dev || true
    fi

    LIBTORRENT_VER="0.13.8"
    RTORRENT_VER="0.9.8"
    wget -q "https://github.com/rakshasa/libtorrent/releases/download/v${LIBTORRENT_VER}/libtorrent-${LIBTORRENT_VER}.tar.gz" -O libtorrent.tar.gz
    tar xf libtorrent.tar.gz
    cd "libtorrent-${LIBTORRENT_VER}"
    ./autogen.sh && ./configure --disable-debug && make -j"$(nproc)" && make install
    ldconfig
    cd "$BUILD_DIR"

    wget -q "https://github.com/rakshasa/rtorrent/releases/download/v${RTORRENT_VER}/rtorrent-${RTORRENT_VER}.tar.gz" -O rtorrent.tar.gz
    tar xf rtorrent.tar.gz
    cd "rtorrent-${RTORRENT_VER}"
    ./autogen.sh && ./configure --disable-debug --with-xmlrpc-c && make -j"$(nproc)" && make install
    ldconfig
    cd /
    rm -rf "$BUILD_DIR"
    log "rTorrent built and installed from source."
}

install_rutorrent() {
    section "Installing ruTorrent"

    RUTORRENT_DIR="/var/www/rutorrent"
    mkdir -p "$RUTORRENT_DIR"
    cd /tmp

    # Download ruTorrent
    RUTORRENT_TAG=$(curl -s https://api.github.com/repos/Novik/ruTorrent/releases/latest \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null || echo "v3.10")
    wget -q "https://github.com/Novik/ruTorrent/archive/refs/tags/${RUTORRENT_TAG}.tar.gz" -O rutorrent.tar.gz || \
    wget -q "https://github.com/Novik/ruTorrent/archive/refs/heads/master.tar.gz" -O rutorrent.tar.gz
    tar xf rutorrent.tar.gz --strip-components=1 -C "$RUTORRENT_DIR"
    rm -f rutorrent.tar.gz

    # Install plugins
    mkdir -p "$RUTORRENT_DIR/plugins"
    for PLUGIN in autotools create diskspace erasedata extratio extsearch feeds filedrop filemanager geoip history httprpc loginmgr lookat mediainfo ratiocolor rss scheduler screenshots seedingtime throttle tracklabels; do
        [[ -d "$RUTORRENT_DIR/plugins/$PLUGIN" ]] || true  # plugins bundled with ruTorrent
    done

    chown -R www-data:www-data "$RUTORRENT_DIR" 2>/dev/null || \
    chown -R nginx:nginx "$RUTORRENT_DIR" 2>/dev/null || true

    log "ruTorrent installed at $RUTORRENT_DIR"
}

# ──────────────────────── QBITTORRENT ────────────────────────────────────────
install_qbittorrent() {
    section "Installing qBittorrent-nox"

    if [[ "$PKG_MGR" == "apt" ]]; then
        if [[ "$DISTRO" == "ubuntu" ]]; then
            add-apt-repository -y ppa:qbittorrent-team/qbittorrent-stable &>/dev/null || true
            apt-get update -qq
        fi
        apt-get install -y -qq qbittorrent-nox 2>&1 | tee -a "$LOGFILE" || build_qbit_from_source
    else
        $PKG_INSTALL qbittorrent-nox 2>/dev/null || build_qbit_from_source
    fi

    QBIT_BIN=$(command -v qbittorrent-nox || echo "")
    [[ -z "$QBIT_BIN" ]] && build_qbit_from_source

    log "qBittorrent-nox installed."
}

build_qbit_from_source() {
    warn "Building qBittorrent from source (this takes a while)..."
    if [[ "$PKG_MGR" == "apt" ]]; then
        apt-get install -y -qq \
            libboost-dev libboost-system-dev libboost-chrono-dev \
            libboost-random-dev libssl-dev pkg-config \
            libtorrent-rasterbar-dev qt5-default qttools5-dev-tools \
            libqt5svg5-dev 2>/dev/null || \
        apt-get install -y -qq \
            libboost-dev libboost-system-dev libboost-chrono-dev \
            libboost-random-dev libssl-dev pkg-config \
            libtorrent-rasterbar-dev qtbase5-dev qttools5-dev 2>/dev/null || true
    else
        $PKG_INSTALL boost-devel openssl-devel libtorrent-rasterbar-devel qt5-qtbase-devel || true
    fi

    BUILD_DIR="/tmp/qbit-build"
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
    QBIT_VER="4.6.4"
    wget -q "https://github.com/qbittorrent/qBittorrent/archive/refs/tags/release-${QBIT_VER}.tar.gz" -O qbit.tar.gz
    tar xf qbit.tar.gz --strip-components=1
    ./configure --disable-gui --disable-debug --prefix=/usr/local
    make -j"$(nproc)" && make install
    cd / && rm -rf "$BUILD_DIR"
    log "qBittorrent built from source."
}

# ──────────────────────── USER MANAGEMENT ────────────────────────────────────
# Creates the user management database (SQLite)
init_user_db() {
    section "Initializing User Database"
    mkdir -p "$SEEDBOX_CONF"
    sqlite3 "$SEEDBOX_CONF/users.db" << 'SQLEOF'
CREATE TABLE IF NOT EXISTS users (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    username    TEXT UNIQUE NOT NULL,
    pass_hash   TEXT NOT NULL,
    email       TEXT,
    status      TEXT DEFAULT 'active',
    disk_quota  INTEGER DEFAULT 10240,  -- MB
    disk_used   INTEGER DEFAULT 0,
    rt_port     INTEGER,
    rt_rpc_port INTEGER,
    qb_port     INTEGER,
    qb_web_port INTEGER,
    web_port    INTEGER,
    created_at  TEXT DEFAULT (datetime('now')),
    last_login  TEXT
);
CREATE TABLE IF NOT EXISTS audit_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    actor       TEXT NOT NULL,
    action      TEXT NOT NULL,
    target      TEXT,
    details     TEXT,
    timestamp   TEXT DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS server_stats (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp   TEXT DEFAULT (datetime('now')),
    cpu_usage   REAL,
    mem_used    INTEGER,
    disk_used   INTEGER,
    net_rx      INTEGER,
    net_tx      INTEGER
);
SQLEOF
    chmod 600 "$SEEDBOX_CONF/users.db"
    log "User database initialized."
}

# ──────────────────────── CHROOT USER CREATION ───────────────────────────────
# Called by seedbox-admin script to create users
create_chroot_template() {
    section "Building Chroot Template"
    CHROOT_TEMPLATE="$SEEDBOX_CHROOT/template"
    mkdir -p "$CHROOT_TEMPLATE"/{bin,lib,lib64,lib/x86_64-linux-gnu,usr/bin,usr/lib,dev,proc,etc,tmp}
    mkdir -p "$CHROOT_TEMPLATE/usr/lib/x86_64-linux-gnu"

    # Essential binaries
    for BIN in bash sh ls cp mv rm mkdir rmdir cat less more grep sed awk find touch chmod chown ln pwd stat du df id whoami; do
        BIN_PATH=$(command -v "$BIN" 2>/dev/null || true)
        [[ -n "$BIN_PATH" ]] && cp "$BIN_PATH" "$CHROOT_TEMPLATE/bin/" 2>/dev/null || true
    done

    # Copy required libraries using ldd
    copy_libs_for_bin() {
        local binary="$1"
        ldd "$binary" 2>/dev/null | awk '/=>/ {print $3}' | while read -r lib; do
            [[ -f "$lib" ]] || continue
            LIB_DIR="$CHROOT_TEMPLATE$(dirname "$lib")"
            mkdir -p "$LIB_DIR"
            cp -n "$lib" "$LIB_DIR/" 2>/dev/null || true
        done
        # ld-linux
        local ld_so
        ld_so=$(ldd "$binary" 2>/dev/null | grep -oP '/lib[^\s]+ld[^\s]+' | head -1)
        if [[ -n "$ld_so" && -f "$ld_so" ]]; then
            mkdir -p "$CHROOT_TEMPLATE$(dirname "$ld_so")"
            cp -n "$ld_so" "$CHROOT_TEMPLATE$(dirname "$ld_so")/" 2>/dev/null || true
        fi
    }

    for BIN in "$CHROOT_TEMPLATE"/bin/*; do
        [[ -f "$BIN" ]] && copy_libs_for_bin "$BIN"
    done

    # /etc essentials
    cp /etc/passwd  "$CHROOT_TEMPLATE/etc/"
    cp /etc/group   "$CHROOT_TEMPLATE/etc/"
    cp /etc/nsswitch.conf "$CHROOT_TEMPLATE/etc/" 2>/dev/null || true
    echo "nameserver 1.1.1.1" > "$CHROOT_TEMPLATE/etc/resolv.conf"

    # /dev nodes
    mknod -m 666 "$CHROOT_TEMPLATE/dev/null"    c 1 3 2>/dev/null || true
    mknod -m 666 "$CHROOT_TEMPLATE/dev/zero"    c 1 5 2>/dev/null || true
    mknod -m 666 "$CHROOT_TEMPLATE/dev/random"  c 1 8 2>/dev/null || true
    mknod -m 666 "$CHROOT_TEMPLATE/dev/urandom" c 1 9 2>/dev/null || true
    mknod -m 666 "$CHROOT_TEMPLATE/dev/tty"     c 5 0 2>/dev/null || true

    chmod 1777 "$CHROOT_TEMPLATE/tmp"
    log "Chroot template created at $CHROOT_TEMPLATE"
}

# ─────────────── SEEDBOX USER MANAGEMENT SCRIPT ──────────────────────────────
create_seedbox_admin_cli() {
    section "Creating seedbox-admin CLI Tool"

    cat > /usr/local/bin/seedbox-admin << 'ADMINEOF'
#!/usr/bin/env bash
# Seedbox Admin CLI
set -euo pipefail

SEEDBOX_CONF="/etc/seedbox"
SEEDBOX_USERS_HOME="/home/seedbox-users"
SEEDBOX_CHROOT="/var/seedbox/chroot"
RTORRENT_BASE_PORT=5000
QBIT_BASE_PORT=6000
WEB_PORT_BASE=9000
DB="$SEEDBOX_CONF/users.db"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[✔]${NC} $*"; }
warn()  { echo -e "${YELLOW}[⚠]${NC} $*"; }
error() { echo -e "${RED}[✘]${NC} $*"; }
info()  { echo -e "${CYAN}[i]${NC} $*"; }

[[ "$EUID" -ne 0 ]] && { error "Run as root."; exit 1; }

db_query() { sqlite3 "$DB" "$1"; }

next_port() {
    local base="$1"
    local used
    used=$(db_query "SELECT GROUP_CONCAT(rt_port)||','||GROUP_CONCAT(qb_port)||','||GROUP_CONCAT(web_port) FROM users;" 2>/dev/null || echo "")
    local port=$base
    while echo "$used" | grep -qw "$port" || ss -tlnp 2>/dev/null | grep -q ":$port "; do
        ((port++))
    done
    echo "$port"
}

hash_password() {
    python3 -c "
import hashlib, os, sys
p = sys.argv[1]
s = os.urandom(16).hex()
h = hashlib.sha256((s+p).encode()).hexdigest()
print(s+':'+h)
" "$1"
}

# ── adduser ──
cmd_adduser() {
    local username="${1:-}"
    local password="${2:-}"
    local quota_mb="${3:-10240}"

    [[ -z "$username" ]] && { error "Usage: seedbox-admin adduser <username> <password> [quota_mb]"; exit 1; }
    [[ -z "$password" ]] && { read -rsp "Password for $username: " password; echo; }

    # Validate
    [[ "$username" =~ ^[a-z_][a-z0-9_-]{2,31}$ ]] || { error "Invalid username format."; exit 1; }
    db_query "SELECT id FROM users WHERE username='$username';" | grep -q . && { error "User already exists."; exit 1; }

    # Assign ports
    RT_PORT=$(next_port $RTORRENT_BASE_PORT)
    RT_RPC=$(( RT_PORT + 1 ))
    QB_PORT=$(next_port $QBIT_BASE_PORT)
    QB_WEB=$(( QB_PORT + 1 ))
    WEB_PORT=$(next_port $WEB_PORT_BASE)

    PASS_HASH=$(hash_password "$password")

    # System user
    useradd -m -d "$SEEDBOX_USERS_HOME/$username" -s /bin/bash \
        -G www-data "$username" 2>/dev/null || true
    echo "$username:$password" | chpasswd

    # Directories
    USER_HOME="$SEEDBOX_USERS_HOME/$username"
    mkdir -p "$USER_HOME"/{downloads,watch,media,.config,.rtorrent,.qbittorrent}
    chown -R "$username:$username" "$USER_HOME"
    chmod 700 "$USER_HOME"

    # Apply disk quota
    set_quota "$username" "$quota_mb"

    # Create .rtorrent.rc
    cat > "$USER_HOME/.rtorrent.rc" << RTEOF
directory.default.set = $USER_HOME/downloads
session.path.set = $USER_HOME/.rtorrent
network.port_range.set = ${RT_PORT}-${RT_PORT}
network.port_random.set = no
scgi_port = 127.0.0.1:${RT_RPC}
watch.start = $USER_HOME/watch
pieces.hash.on_completion.set = no
throttle.max_uploads.set = 0
throttle.max_peers.upload.set = -1
throttle.max_peers.normal.set = -1
trackers.use_udp.set = yes
protocol.pex.set = yes
dht.mode.set = auto
network.max_open_files.set = 600
network.receive_buffer.size.set = 4M
network.send_buffer.size.set = 4M
RTEOF
    chown "$username:$username" "$USER_HOME/.rtorrent.rc"

    # Create qBittorrent config
    QB_CONF="$USER_HOME/.config/qBittorrent"
    mkdir -p "$QB_CONF"
    cat > "$QB_CONF/qBittorrent.conf" << QBEOF
[BitTorrent]
Session\DefaultSavePath=$USER_HOME/downloads
Session\Port=${QB_PORT}
Session\Interface=
Session\TempPath=$USER_HOME/downloads/incomplete

[Preferences]
General\Locale=en
WebUI\Address=127.0.0.1
WebUI\Port=${QB_WEB}
WebUI\Username=$username
WebUI\Password_PBKDF2="@ByteArray(placeholder)"
WebUI\HTTPS\Enabled=false
WebUI\HostHeaderValidation=false
Downloads\SavePath=$USER_HOME/downloads
QBEOF
    chown -R "$username:$username" "$QB_CONF"

    # Setup chroot SFTP
    setup_sftp_chroot "$username"

    # Nginx vhost for this user
    setup_user_nginx "$username" "$WEB_PORT" "$RT_RPC" "$QB_WEB"

    # Systemd services
    setup_user_services "$username" "$RT_PORT" "$QB_WEB"

    # Save to DB
    db_query "INSERT INTO users (username,pass_hash,disk_quota,rt_port,rt_rpc_port,qb_port,qb_web_port,web_port)
              VALUES ('$username','$PASS_HASH',$quota_mb,$RT_PORT,$RT_RPC,$QB_PORT,$QB_WEB,$WEB_PORT);"
    db_query "INSERT INTO audit_log (actor,action,target,details) VALUES ('admin','create_user','$username','quota=${quota_mb}MB ports=${RT_PORT},${QB_WEB},${WEB_PORT}');"

    log "User '$username' created successfully!"
    echo ""
    info "  Home:         $USER_HOME"
    info "  Disk Quota:   ${quota_mb} MB"
    info "  rTorrent:     port $RT_PORT | RPC: 127.0.0.1:$RT_RPC"
    info "  qBittorrent:  port $QB_PORT | WebUI: 127.0.0.1:$QB_WEB"
    info "  Web Panel:    https://$(hostname -I | awk '{print $1}'):$WEB_PORT"
    info "  SFTP:         sftp://$username@$(hostname -I | awk '{print $1}') (chrooted)"
}

# ── setup_sftp_chroot ──
setup_sftp_chroot() {
    local username="$1"
    local USER_HOME="$SEEDBOX_USERS_HOME/$username"

    # SFTP chroot requires root:root on the chroot dir with 755
    chown root:root "$USER_HOME"
    chmod 755 "$USER_HOME"

    # Create writable subdirs owned by user
    mkdir -p "$USER_HOME"/{downloads,watch,media}
    chown "$username:$username" "$USER_HOME"/{downloads,watch,media}
    chmod 750 "$USER_HOME"/{downloads,watch,media}

    log "SFTP chroot configured for $username"
}

# ── setup_user_nginx ──
setup_user_nginx() {
    local username="$1"
    local web_port="$2"
    local rt_rpc="$3"
    local qb_web="$4"
    local SSL_CERT="/etc/seedbox/ssl/seedbox.crt"
    local SSL_KEY="/etc/seedbox/ssl/seedbox.key"
    [[ -f /etc/letsencrypt/live/*/fullchain.pem ]] && \
        SSL_CERT=$(ls /etc/letsencrypt/live/*/fullchain.pem | head -1) && \
        SSL_KEY=$(ls /etc/letsencrypt/live/*/privkey.pem | head -1)

    cat > "/etc/nginx/sites-available/seedbox-user-${username}.conf" << NGINXEOF
server {
    listen ${web_port} ssl http2;
    server_name _;
    ssl_certificate     $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;

    root /var/www/rutorrent;
    index index.php index.html;
    client_max_body_size 16M;

    # Auth for this user
    auth_basic "Seedbox - ${username}";
    auth_basic_user_file /etc/nginx/htpasswd.d/${username};

    # ruTorrent
    location /rutorrent/ {
        alias /var/www/rutorrent/;
        try_files \$uri \$uri/ =404;
        location ~ \.php$ {
            include fastcgi_params;
            fastcgi_pass unix:/run/php/seedbox-${username}.sock;
            fastcgi_param SCRIPT_FILENAME \$request_filename;
        }
    }

    # rTorrent XMLRPC
    location /RPC2 {
        scgi_pass 127.0.0.1:${rt_rpc};
        include scgi_params;
    }

    # qBittorrent reverse proxy
    location /qbittorrent/ {
        proxy_pass         http://127.0.0.1:${qb_web}/;
        proxy_http_version 1.1;
        proxy_set_header   Host              127.0.0.1:${qb_web};
        proxy_set_header   X-Forwarded-For   \$remote_addr;
        proxy_set_header   Referer           http://127.0.0.1:${qb_web};
        proxy_cookie_path  /                 /qbittorrent/;
        add_header         X-Frame-Options   "" always;
    }

    # User dashboard (PHP app)
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
        location ~ \.php$ {
            include fastcgi_params;
            fastcgi_pass unix:/run/php/seedbox-${username}.sock;
            fastcgi_param SCRIPT_FILENAME /var/www/seedbox-panel/user-dashboard.php;
            fastcgi_param SEEDBOX_USER    $username;
        }
    }
}
NGINXEOF

    # htpasswd for user
    mkdir -p /etc/nginx/htpasswd.d
    local userpass
    userpass=$(db_query "SELECT pass_hash FROM users WHERE username='$username';" 2>/dev/null || echo "")
    htpasswd -b -c "/etc/nginx/htpasswd.d/${username}" "$username" "$(db_query "SELECT pass_hash FROM users WHERE username='$username';" 2>/dev/null | cut -d: -f2 | head -c 8 || echo 'changeme')" 2>/dev/null || \
    python3 -c "
import crypt, sys
u,p = '$username', '$(db_query "SELECT pass_hash FROM users WHERE username='$username';" 2>/dev/null || echo "x")'
print(u+':'+crypt.crypt(p, crypt.mksalt(crypt.METHOD_SHA512)))
" > "/etc/nginx/htpasswd.d/${username}" 2>/dev/null || echo "${username}:changeme" > "/etc/nginx/htpasswd.d/${username}"

    ln -sf "/etc/nginx/sites-available/seedbox-user-${username}.conf" \
           "/etc/nginx/sites-enabled/seedbox-user-${username}.conf" 2>/dev/null || \
    cp     "/etc/nginx/sites-available/seedbox-user-${username}.conf" \
           "/etc/nginx/conf.d/seedbox-user-${username}.conf" 2>/dev/null || true

    nginx -t &>/dev/null && systemctl reload nginx &>/dev/null || true
}

# ── setup_user_services ──
setup_user_services() {
    local username="$1"
    local rt_port="$2"
    local qb_web="$3"
    local USER_HOME="$SEEDBOX_USERS_HOME/$username"

    # rTorrent systemd service (screen-based)
    cat > "/etc/systemd/system/rtorrent@${username}.service" << SVCEOF
[Unit]
Description=rTorrent for seedbox user ${username}
After=network.target
Wants=network.target

[Service]
Type=forking
User=${username}
Group=${username}
ExecStartPre=/bin/mkdir -p ${USER_HOME}/.rtorrent
ExecStart=/usr/bin/screen -dmS rtorrent-${username} /usr/bin/rtorrent -n -o import=${USER_HOME}/.rtorrent.rc
ExecStop=/usr/bin/screen -S rtorrent-${username} -X quit
WorkingDirectory=${USER_HOME}
Restart=on-failure
RestartSec=30
KillMode=process
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    # qBittorrent systemd service
    QB_BIN=$(command -v qbittorrent-nox 2>/dev/null || echo "/usr/local/bin/qbittorrent-nox")
    cat > "/etc/systemd/system/qbittorrent@${username}.service" << QBSVCEOF
[Unit]
Description=qBittorrent-nox for seedbox user ${username}
After=network.target
Wants=network.target

[Service]
Type=exec
User=${username}
Group=${username}
ExecStart=${QB_BIN} --webui-port=${qb_web} --profile=${USER_HOME}/.qbittorrent
WorkingDirectory=${USER_HOME}
Restart=on-failure
RestartSec=30
KillMode=process
LimitNOFILE=65535
Environment="HOME=${USER_HOME}"
Environment="XDG_CONFIG_HOME=${USER_HOME}/.config"

[Install]
WantedBy=multi-user.target
QBSVCEOF

    # PHP-FPM pool for user
    PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.1")
    PHP_FPM_POOL_DIR="/etc/php/${PHP_VER}/fpm/pool.d"
    [[ -d "$PHP_FPM_POOL_DIR" ]] || PHP_FPM_POOL_DIR="/etc/php-fpm.d"
    mkdir -p "$PHP_FPM_POOL_DIR"

    cat > "${PHP_FPM_POOL_DIR}/seedbox-${username}.conf" << PHPEOF
[seedbox-${username}]
user = ${username}
group = ${username}
listen = /run/php/seedbox-${username}.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 5
pm.start_servers = 1
pm.min_spare_servers = 1
pm.max_spare_servers = 3
pm.max_requests = 500
env[HOME] = ${USER_HOME}
env[USERNAME] = ${username}
php_admin_value[open_basedir] = ${USER_HOME}:/var/www/rutorrent:/var/www/seedbox-panel:/tmp
php_admin_value[upload_tmp_dir] = /tmp
php_admin_value[session.save_path] = /tmp
PHPEOF

    systemctl daemon-reload
    systemctl enable "rtorrent@${username}" &>/dev/null || true
    systemctl enable "qbittorrent@${username}" &>/dev/null || true
    systemctl start  "rtorrent@${username}" &>/dev/null || true
    systemctl start  "qbittorrent@${username}" &>/dev/null || true

    PHP_FPM_SVC=$(systemctl list-units --type=service --state=loaded 2>/dev/null | grep -oP 'php[\d.]*-fpm' | head -1 || echo "php-fpm")
    systemctl restart "$PHP_FPM_SVC" &>/dev/null || true

    log "Services configured for $username"
}

# ── setquota ──
set_quota() {
    local username="$1"
    local quota_mb="$2"
    local quota_kb=$(( quota_mb * 1024 ))
    local soft=$(( quota_kb * 90 / 100 ))

    # Find filesystem for user home
    MNTPOINT=$(df "$SEEDBOX_USERS_HOME" 2>/dev/null | awk 'NR==2{print $6}')
    if command -v setquota &>/dev/null; then
        setquota -u "$username" "$soft" "$quota_kb" 0 0 "$MNTPOINT" 2>/dev/null || \
        setquota -u "$username" "$soft" "$quota_kb" 0 0 -a 2>/dev/null || true
    fi
    # Update DB
    [[ -f "$DB" ]] && sqlite3 "$DB" "UPDATE users SET disk_quota=$quota_mb WHERE username='$username';" 2>/dev/null || true
    log "Quota for $username set to ${quota_mb} MB"
}

# ── modquota ──
cmd_modquota() {
    local username="${1:-}"
    local quota_mb="${2:-}"
    [[ -z "$username" || -z "$quota_mb" ]] && { error "Usage: seedbox-admin modquota <username> <quota_mb>"; exit 1; }
    db_query "SELECT id FROM users WHERE username='$username';" | grep -q . || { error "User not found."; exit 1; }
    set_quota "$username" "$quota_mb"
    db_query "INSERT INTO audit_log (actor,action,target,details) VALUES ('admin','modify_quota','$username','new_quota=${quota_mb}MB');"
}

# ── deluser ──
cmd_deluser() {
    local username="${1:-}"
    [[ -z "$username" ]] && { error "Usage: seedbox-admin deluser <username>"; exit 1; }
    read -rp "Delete user '$username' and ALL their data? [y/N]: " CONFIRM
    [[ "${CONFIRM,,}" != "y" ]] && { warn "Aborted."; exit 0; }

    systemctl stop  "rtorrent@${username}"    &>/dev/null || true
    systemctl stop  "qbittorrent@${username}" &>/dev/null || true
    systemctl disable "rtorrent@${username}"    &>/dev/null || true
    systemctl disable "qbittorrent@${username}" &>/dev/null || true
    rm -f "/etc/systemd/system/rtorrent@${username}.service" \
          "/etc/systemd/system/qbittorrent@${username}.service" 2>/dev/null || true

    userdel -r "$username" 2>/dev/null || true
    rm -rf "$SEEDBOX_USERS_HOME/$username" 2>/dev/null || true
    rm -f  "/etc/nginx/sites-available/seedbox-user-${username}.conf" \
           "/etc/nginx/sites-enabled/seedbox-user-${username}.conf"   \
           "/etc/nginx/conf.d/seedbox-user-${username}.conf"          \
           "/etc/nginx/htpasswd.d/${username}" 2>/dev/null || true

    PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.1")
    rm -f "/etc/php/${PHP_VER}/fpm/pool.d/seedbox-${username}.conf" \
          "/etc/php-fpm.d/seedbox-${username}.conf" 2>/dev/null || true

    db_query "UPDATE users SET status='deleted' WHERE username='$username';"
    db_query "INSERT INTO audit_log (actor,action,target) VALUES ('admin','delete_user','$username');"
    systemctl daemon-reload
    nginx -t &>/dev/null && systemctl reload nginx &>/dev/null || true
    log "User $username deleted."
}

# ── listusers ──
cmd_listusers() {
    echo ""
    printf "%-20s %-10s %-12s %-10s %-10s %-12s\n" \
           "Username" "Status" "Quota(MB)" "RT-Port" "QB-Port" "Web-Port"
    printf "%-20s %-10s %-12s %-10s %-10s %-12s\n" \
           "────────────────────" "──────────" "────────────" "────────" "────────" "────────────"
    db_query "SELECT username,status,disk_quota,rt_port,qb_port,web_port FROM users WHERE status!='deleted' ORDER BY username;" | \
    while IFS='|' read -r u s q rt qb wp; do
        printf "%-20s %-10s %-12s %-10s %-10s %-12s\n" "$u" "$s" "${q:-N/A}" "${rt:-N/A}" "${qb:-N/A}" "${wp:-N/A}"
    done
    echo ""
}

# ── status ──
cmd_status() {
    echo ""
    info "=== Seedbox Service Status ==="
    db_query "SELECT username FROM users WHERE status='active';" | while read -r u; do
        RT_STATUS=$(systemctl is-active "rtorrent@${u}" 2>/dev/null || echo "unknown")
        QB_STATUS=$(systemctl is-active "qbittorrent@${u}" 2>/dev/null || echo "unknown")
        echo -e "  User: ${CYAN}${u}${NC}  rTorrent: ${RT_STATUS}  qBittorrent: ${QB_STATUS}"
    done
    echo ""
    info "=== Nginx ===" && systemctl is-active nginx 2>/dev/null || true
    info "=== Admin Panel ===" && systemctl is-active seedbox-admin-panel 2>/dev/null || true
    echo ""
}

# ── MAIN dispatch ──
case "${1:-help}" in
    adduser)   cmd_adduser   "${2:-}" "${3:-}" "${4:-10240}" ;;
    deluser)   cmd_deluser   "${2:-}" ;;
    modquota)  cmd_modquota  "${2:-}" "${3:-}" ;;
    listusers) cmd_listusers ;;
    status)    cmd_status    ;;
    help|*)
        echo -e "\n${BOLD}seedbox-admin${NC} - Seedbox Management CLI\n"
        echo "  adduser  <user> [pass] [quota_mb]  - Create chroot seedbox user"
        echo "  deluser  <user>                    - Delete user and all data"
        echo "  modquota <user> <quota_mb>         - Modify user disk quota"
        echo "  listusers                          - List all users"
        echo "  status                             - Show service status"
        echo ""
        ;;
esac
ADMINEOF

    chmod +x /usr/local/bin/seedbox-admin
    log "seedbox-admin CLI installed at /usr/local/bin/seedbox-admin"
}

# ──────────────────────── ADMIN PANEL (Web) ──────────────────────────────────
create_admin_panel() {
    section "Creating Admin Web Panel"

    PANEL_DIR="/var/www/seedbox-panel"
    mkdir -p "$PANEL_DIR"/{assets,api,includes}

    # ── Admin Panel: index.php (login + router) ──
    cat > "$PANEL_DIR/index.php" << 'PHPEOF'
<?php
session_start();
define('SEEDBOX_CONF', '/etc/seedbox');
define('DB_PATH', SEEDBOX_CONF . '/users.db');
define('VERSION', '2.0');

function db() {
    static $db = null;
    if (!$db) $db = new PDO('sqlite:' . DB_PATH);
    $db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    return $db;
}

function verify_admin_password($pass) {
    $conf = parse_ini_file(SEEDBOX_CONF . '/admin.conf');
    if (!$conf) return false;
    [$salt, $hash] = explode(':', $conf['ADMIN_PASS_HASH']);
    return hash('sha256', $salt . $pass) === $hash;
}

function is_logged_in() { return !empty($_SESSION['admin_logged_in']); }

function render_header($title = 'Seedbox Admin') {
    echo '<!DOCTYPE html><html lang="en"><head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>' . htmlspecialchars($title) . ' | Seedbox</title>
    <link rel="stylesheet" href="/assets/style.css">
    </head><body>';
}

function render_footer() { echo '</body></html>'; }

// ─── Routing ───
$action = $_GET['action'] ?? 'dashboard';

// Login
if ($action === 'login' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    if (verify_admin_password($_POST['password'] ?? '')) {
        $_SESSION['admin_logged_in'] = true;
        $_SESSION['admin_user'] = $_POST['username'] ?? 'admin';
        header('Location: /'); exit;
    }
    $_SESSION['login_error'] = 'Invalid credentials';
    header('Location: /?action=login'); exit;
}

if ($action === 'logout') { session_destroy(); header('Location: /?action=login'); exit; }

// Show login form
if (!is_logged_in()) {
    render_header('Login');
    include PANEL_DIR . '/includes/login.php';
    render_footer(); exit;
}

// ─── API endpoints ───
if ($action === 'api') {
    header('Content-Type: application/json');
    $api = $_GET['api'] ?? '';
    switch ($api) {
        case 'stats':
            $cpu = sys_getloadavg()[0];
            $mem_total = 0; $mem_free = 0;
            foreach (file('/proc/meminfo') as $line) {
                if (preg_match('/^MemTotal:\s+(\d+)/', $line, $m)) $mem_total = $m[1];
                if (preg_match('/^MemAvailable:\s+(\d+)/', $line, $m)) $mem_free = $m[1];
            }
            $disk = disk_total_space('/home/seedbox-users');
            $disk_free = disk_free_space('/home/seedbox-users');
            $users = db()->query("SELECT COUNT(*) FROM users WHERE status='active'")->fetchColumn();
            echo json_encode([
                'cpu_load' => round($cpu, 2),
                'mem_used_mb' => round(($mem_total - $mem_free) / 1024),
                'mem_total_mb' => round($mem_total / 1024),
                'disk_used_gb' => round(($disk - $disk_free) / 1e9, 1),
                'disk_total_gb' => round($disk / 1e9, 1),
                'active_users' => $users,
            ]);
            break;
        case 'users':
            $rows = db()->query("SELECT id,username,status,disk_quota,disk_used,rt_port,qb_port,web_port,created_at FROM users WHERE status!='deleted' ORDER BY username")->fetchAll(PDO::FETCH_ASSOC);
            echo json_encode($rows);
            break;
        case 'adduser':
            $u = preg_replace('/[^a-z0-9_-]/', '', strtolower($_POST['username'] ?? ''));
            $p = $_POST['password'] ?? '';
            $q = intval($_POST['quota'] ?? 10240);
            if (!$u || !$p || strlen($u) < 3) { echo json_encode(['error'=>'Invalid input']); break; }
            $output = []; $rc = 0;
            exec("seedbox-admin adduser " . escapeshellarg($u) . " " . escapeshellarg($p) . " $q 2>&1", $output, $rc);
            echo json_encode(['success' => $rc === 0, 'output' => implode("\n", $output)]);
            break;
        case 'modquota':
            $u = preg_replace('/[^a-z0-9_-]/', '', $_POST['username'] ?? '');
            $q = intval($_POST['quota'] ?? 10240);
            exec("seedbox-admin modquota " . escapeshellarg($u) . " $q 2>&1", $output, $rc);
            echo json_encode(['success' => $rc === 0]);
            break;
        case 'deluser':
            $u = preg_replace('/[^a-z0-9_-]/', '', $_POST['username'] ?? '');
            exec("echo y | seedbox-admin deluser " . escapeshellarg($u) . " 2>&1", $output, $rc);
            echo json_encode(['success' => $rc === 0]);
            break;
        case 'audit':
            $rows = db()->query("SELECT * FROM audit_log ORDER BY timestamp DESC LIMIT 100")->fetchAll(PDO::FETCH_ASSOC);
            echo json_encode($rows);
            break;
        default:
            echo json_encode(['error' => 'Unknown API endpoint']);
    }
    exit;
}

// ─── Admin Panel Pages ───
render_header('Admin Dashboard');
include PANEL_DIR . '/includes/admin.php';
render_footer();
PHPEOF

    # ── Login include ──
    cat > "$PANEL_DIR/includes/login.php" << 'PHPEOF'
<div class="login-wrap">
  <div class="login-box">
    <div class="login-logo">⚙ SEEDBOX</div>
    <h2>Admin Login</h2>
    <?php if (!empty($_SESSION['login_error'])): ?>
      <div class="alert error"><?= htmlspecialchars($_SESSION['login_error']) ?></div>
      <?php unset($_SESSION['login_error']); ?>
    <?php endif; ?>
    <form method="POST" action="/?action=login">
      <label>Username</label>
      <input type="text" name="username" required autofocus>
      <label>Password</label>
      <input type="password" name="password" required>
      <button type="submit" class="btn-primary">Login</button>
    </form>
  </div>
</div>
PHPEOF

    # ── Admin Panel include ──
    cat > "$PANEL_DIR/includes/admin.php" << 'PHPEOF'
<div class="layout">
<nav class="sidebar">
  <div class="sidebar-brand">⚙ SEEDBOX</div>
  <ul>
    <li><a href="/" data-page="dashboard" class="active">📊 Dashboard</a></li>
    <li><a href="/" data-page="users">👥 Users</a></li>
    <li><a href="/" data-page="adduser">➕ Add User</a></li>
    <li><a href="/" data-page="audit">📋 Audit Log</a></li>
    <li><a href="/?action=logout">🚪 Logout</a></li>
  </ul>
  <div class="sidebar-footer">v<?= VERSION ?></div>
</nav>
<main class="content">

<!-- Dashboard -->
<section id="page-dashboard">
  <h1>Server Dashboard</h1>
  <div class="stats-grid" id="stats-grid">
    <div class="stat-card" id="stat-cpu"><div class="stat-label">CPU Load</div><div class="stat-value">...</div></div>
    <div class="stat-card" id="stat-mem"><div class="stat-label">Memory</div><div class="stat-value">...</div></div>
    <div class="stat-card" id="stat-disk"><div class="stat-label">Disk</div><div class="stat-value">...</div></div>
    <div class="stat-card" id="stat-users"><div class="stat-label">Active Users</div><div class="stat-value">...</div></div>
  </div>
</section>

<!-- Users -->
<section id="page-users" style="display:none">
  <h1>User Management</h1>
  <table class="data-table" id="users-table">
    <thead><tr><th>Username</th><th>Status</th><th>Quota (MB)</th><th>Ports</th><th>Created</th><th>Actions</th></tr></thead>
    <tbody id="users-tbody"><tr><td colspan="6">Loading...</td></tr></tbody>
  </table>
</section>

<!-- Add User -->
<section id="page-adduser" style="display:none">
  <h1>Add New User</h1>
  <form id="add-user-form" class="form-card">
    <label>Username <small>(3-32 chars, a-z 0-9 _ -)</small></label>
    <input type="text" name="username" pattern="[a-z0-9_-]{3,32}" required>
    <label>Password <small>(min 8 chars)</small></label>
    <input type="password" name="password" minlength="8" required>
    <label>Disk Quota (MB) <small>default 10240 = 10 GB</small></label>
    <input type="number" name="quota" value="10240" min="512" max="10485760">
    <button type="submit" class="btn-primary">Create User</button>
    <div id="add-user-result"></div>
  </form>
</section>

<!-- Audit Log -->
<section id="page-audit" style="display:none">
  <h1>Audit Log</h1>
  <table class="data-table">
    <thead><tr><th>Time</th><th>Actor</th><th>Action</th><th>Target</th><th>Details</th></tr></thead>
    <tbody id="audit-tbody"><tr><td colspan="5">Loading...</td></tr></tbody>
  </table>
</section>

</main>
</div>

<!-- Modal -->
<div id="modal-overlay" style="display:none">
  <div id="modal">
    <h3 id="modal-title"></h3>
    <div id="modal-body"></div>
    <div class="modal-btns">
      <button class="btn-danger" id="modal-confirm">Confirm</button>
      <button class="btn-secondary" onclick="closeModal()">Cancel</button>
    </div>
  </div>
</div>

<script>
const api = (endpoint, data) => {
  const url = '/?action=api&api=' + endpoint;
  if (!data) return fetch(url).then(r=>r.json());
  return fetch(url, {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body: new URLSearchParams(data).toString()}).then(r=>r.json());
};

// Navigation
document.querySelectorAll('[data-page]').forEach(a => {
  a.addEventListener('click', e => {
    e.preventDefault();
    const page = a.dataset.page;
    document.querySelectorAll('section').forEach(s => s.style.display='none');
    document.getElementById('page-'+page).style.display='';
    document.querySelectorAll('[data-page]').forEach(x=>x.classList.remove('active'));
    a.classList.add('active');
    if (page==='users') loadUsers();
    if (page==='audit') loadAudit();
  });
});

// Stats
function loadStats() {
  api('stats').then(d => {
    document.querySelector('#stat-cpu .stat-value').textContent = d.cpu_load + ' (1m load)';
    document.querySelector('#stat-mem .stat-value').textContent = d.mem_used_mb + ' / ' + d.mem_total_mb + ' MB';
    document.querySelector('#stat-disk .stat-value').textContent = d.disk_used_gb + ' / ' + d.disk_total_gb + ' GB';
    document.querySelector('#stat-users .stat-value').textContent = d.active_users;
  });
}
loadStats(); setInterval(loadStats, 15000);

// Users
function loadUsers() {
  api('users').then(users => {
    const tbody = document.getElementById('users-tbody');
    tbody.innerHTML = users.map(u => `<tr>
      <td>${u.username}</td>
      <td><span class="badge ${u.status}">${u.status}</span></td>
      <td>
        <input type="number" id="q-${u.id}" value="${u.disk_quota}" style="width:100px">
        <button class="btn-sm" onclick="modQuota('${u.username}',${u.id})">Update</button>
      </td>
      <td>RT:${u.rt_port||'N/A'} QB:${u.qb_port||'N/A'} Web:${u.web_port||'N/A'}</td>
      <td>${(u.created_at||'').substring(0,10)}</td>
      <td><button class="btn-danger btn-sm" onclick="confirmDelete('${u.username}')">Delete</button></td>
    </tr>`).join('') || '<tr><td colspan="6">No users yet.</td></tr>';
  });
}

function modQuota(username, id) {
  const q = document.getElementById('q-'+id).value;
  api('modquota', {username, quota: q}).then(r => {
    alert(r.success ? 'Quota updated!' : 'Failed to update quota.');
  });
}

let deleteTarget = null;
function confirmDelete(username) {
  deleteTarget = username;
  document.getElementById('modal-title').textContent = 'Delete User: ' + username;
  document.getElementById('modal-body').innerHTML = '<p>This will permanently delete the user and ALL their data. This cannot be undone.</p>';
  document.getElementById('modal-overlay').style.display='flex';
}
document.getElementById('modal-confirm').onclick = () => {
  if (!deleteTarget) return;
  api('deluser', {username: deleteTarget}).then(r => {
    closeModal(); loadUsers();
  });
};
function closeModal() { document.getElementById('modal-overlay').style.display='none'; deleteTarget=null; }

// Add user form
document.getElementById('add-user-form').addEventListener('submit', e => {
  e.preventDefault();
  const fd = new FormData(e.target);
  const data = Object.fromEntries(fd);
  const btn = e.target.querySelector('button');
  btn.disabled = true; btn.textContent = 'Creating...';
  api('adduser', data).then(r => {
    btn.disabled = false; btn.textContent = 'Create User';
    const res = document.getElementById('add-user-result');
    if (r.success) {
      res.innerHTML = '<div class="alert success">User created successfully!</div>';
      e.target.reset();
    } else {
      res.innerHTML = '<div class="alert error">Error: ' + (r.output||r.error||'Unknown error') + '</div>';
    }
  });
});

// Audit Log
function loadAudit() {
  api('audit').then(rows => {
    document.getElementById('audit-tbody').innerHTML = rows.map(r =>
      `<tr><td>${r.timestamp}</td><td>${r.actor}</td><td>${r.action}</td><td>${r.target||''}</td><td>${r.details||''}</td></tr>`
    ).join('') || '<tr><td colspan="5">No log entries.</td></tr>';
  });
}
</script>
PHPEOF

    # ── User Dashboard ──
    cat > "$PANEL_DIR/user-dashboard.php" << 'PHPEOF'
<?php
$username = getenv('SEEDBOX_USER') ?: ($_SERVER['SEEDBOX_USER'] ?? 'unknown');
$home = "/home/seedbox-users/$username";
$disk_info = ['used' => 0, 'total' => 0];
if (is_dir($home)) {
    $df = shell_exec("df -k " . escapeshellarg($home) . " 2>/dev/null | awk 'NR==2{print $3\" \"$2}'");
    [$used_kb, $total_kb] = array_map('intval', explode(' ', trim($df ?: '0 0')));
    $disk_info = ['used' => round($used_kb/1024/1024, 2), 'total' => round($total_kb/1024/1024, 2)];
}
?>
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><title>Seedbox - <?= htmlspecialchars($username) ?></title>
<link rel="stylesheet" href="/assets/style.css">
</head><body>
<div class="user-dash">
  <h1>Welcome, <?= htmlspecialchars($username) ?></h1>
  <div class="stats-grid">
    <div class="stat-card">
      <div class="stat-label">Disk Used</div>
      <div class="stat-value"><?= $disk_info['used'] ?> GB / <?= $disk_info['total'] ?> GB</div>
      <div class="progress-bar"><div class="progress-fill" style="width:<?= $disk_info['total'] > 0 ? round($disk_info['used']/$disk_info['total']*100) : 0 ?>%"></div></div>
    </div>
  </div>
  <div class="quick-links">
    <a href="/rutorrent/" class="card-link">🌀 ruTorrent</a>
    <a href="/qbittorrent/" class="card-link">⚡ qBittorrent</a>
  </div>
  <div class="info-box">
    <h3>SFTP Access</h3>
    <code>sftp://<?= htmlspecialchars($username) ?>@<?= htmlspecialchars($_SERVER['HTTP_HOST'] ?? 'server') ?></code>
    <p>Your files are in: <code>/downloads</code></p>
  </div>
</div>
</body></html>
PHPEOF

    # ── CSS ──
    cat > "$PANEL_DIR/assets/style.css" << 'CSSEOF'
:root {
  --bg: #0f1117; --surface: #1a1d27; --border: #2a2d3e;
  --accent: #6c63ff; --accent2: #00d4aa; --danger: #e74c3c;
  --text: #e2e8f0; --muted: #64748b;
  --success: #27ae60; --warning: #f39c12;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: 'Segoe UI', system-ui, sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; }

/* Layout */
.layout { display: flex; min-height: 100vh; }
.sidebar { width: 220px; background: var(--surface); border-right: 1px solid var(--border);
  display: flex; flex-direction: column; padding: 0; flex-shrink: 0; }
.sidebar-brand { padding: 24px 20px; font-size: 1.2rem; font-weight: 700; color: var(--accent);
  border-bottom: 1px solid var(--border); letter-spacing: 2px; }
.sidebar ul { list-style: none; padding: 12px 0; flex: 1; }
.sidebar ul li a { display: block; padding: 12px 20px; color: var(--muted); text-decoration: none;
  transition: all .2s; font-size: .9rem; }
.sidebar ul li a:hover, .sidebar ul li a.active { background: rgba(108,99,255,.15); color: var(--accent); }
.sidebar-footer { padding: 12px 20px; color: var(--muted); font-size: .75rem; border-top: 1px solid var(--border); }
.content { flex: 1; padding: 32px; overflow-y: auto; }
.content h1 { font-size: 1.5rem; margin-bottom: 24px; color: var(--text); }

/* Stats Grid */
.stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 28px; }
.stat-card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 20px; }
.stat-label { font-size: .8rem; color: var(--muted); text-transform: uppercase; letter-spacing: 1px; margin-bottom: 8px; }
.stat-value { font-size: 1.4rem; font-weight: 700; color: var(--accent2); }

/* Table */
.data-table { width: 100%; border-collapse: collapse; background: var(--surface); border-radius: 12px; overflow: hidden; }
.data-table th { background: rgba(108,99,255,.2); padding: 12px 16px; text-align: left; font-size: .8rem;
  text-transform: uppercase; letter-spacing: 1px; color: var(--muted); }
.data-table td { padding: 12px 16px; border-top: 1px solid var(--border); font-size: .9rem; vertical-align: middle; }
.data-table tr:hover td { background: rgba(255,255,255,.02); }

/* Buttons */
.btn-primary { background: var(--accent); color: #fff; border: none; border-radius: 8px;
  padding: 10px 20px; cursor: pointer; font-size: .9rem; font-weight: 600; transition: opacity .2s; }
.btn-primary:hover { opacity: .85; }
.btn-danger { background: var(--danger); color: #fff; border: none; border-radius: 8px;
  padding: 8px 16px; cursor: pointer; font-size: .8rem; }
.btn-secondary { background: var(--border); color: var(--text); border: none; border-radius: 8px;
  padding: 8px 16px; cursor: pointer; }
.btn-sm { padding: 4px 10px; border-radius: 6px; font-size: .8rem; }

/* Form */
.form-card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 24px; max-width: 480px; }
.form-card label { display: block; font-size: .8rem; color: var(--muted); margin-bottom: 4px; margin-top: 16px; }
.form-card input { width: 100%; background: var(--bg); border: 1px solid var(--border); border-radius: 8px;
  color: var(--text); padding: 10px 14px; font-size: .9rem; }
.form-card input:focus { outline: none; border-color: var(--accent); }
.form-card button { margin-top: 20px; }

/* Badge */
.badge { display: inline-block; padding: 2px 8px; border-radius: 99px; font-size: .75rem; font-weight: 600; }
.badge.active { background: rgba(39,174,96,.2); color: #27ae60; }
.badge.disabled { background: rgba(231,76,60,.2); color: var(--danger); }

/* Alert */
.alert { padding: 12px 16px; border-radius: 8px; margin: 12px 0; font-size: .9rem; }
.alert.error { background: rgba(231,76,60,.15); border: 1px solid var(--danger); color: #ff6b6b; }
.alert.success { background: rgba(39,174,96,.15); border: 1px solid #27ae60; color: #2ecc71; }

/* Modal */
#modal-overlay { position: fixed; inset: 0; background: rgba(0,0,0,.6); display: flex;
  align-items: center; justify-content: center; z-index: 9999; }
#modal { background: var(--surface); border: 1px solid var(--border); border-radius: 16px; padding: 28px; max-width: 440px; width: 90%; }
#modal h3 { margin-bottom: 16px; }
.modal-btns { margin-top: 20px; display: flex; gap: 10px; }

/* Login */
.login-wrap { min-height: 100vh; display: flex; align-items: center; justify-content: center; }
.login-box { background: var(--surface); border: 1px solid var(--border); border-radius: 16px; padding: 40px; width: 100%; max-width: 400px; }
.login-logo { font-size: 2rem; text-align: center; margin-bottom: 8px; color: var(--accent); letter-spacing: 3px; }
.login-box h2 { text-align: center; margin-bottom: 24px; }
.login-box label { display: block; font-size: .8rem; color: var(--muted); margin-bottom: 4px; margin-top: 16px; }
.login-box input { width: 100%; background: var(--bg); border: 1px solid var(--border); border-radius: 8px;
  color: var(--text); padding: 10px 14px; font-size: .9rem; }
.login-box button { width: 100%; margin-top: 24px; padding: 12px; }

/* User Dashboard */
.user-dash { max-width: 800px; margin: 40px auto; padding: 0 20px; }
.quick-links { display: flex; gap: 16px; margin: 20px 0; flex-wrap: wrap; }
.card-link { background: var(--surface); border: 1px solid var(--border); border-radius: 12px;
  padding: 20px 28px; text-decoration: none; color: var(--text); font-size: 1rem; font-weight: 600; transition: border-color .2s; }
.card-link:hover { border-color: var(--accent); }
.info-box { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 20px; margin-top: 16px; }
.info-box h3 { margin-bottom: 10px; }
.info-box code { background: var(--bg); padding: 4px 8px; border-radius: 6px; font-family: monospace; }
.progress-bar { background: var(--bg); border-radius: 99px; height: 6px; margin-top: 8px; overflow: hidden; }
.progress-fill { background: linear-gradient(90deg, var(--accent), var(--accent2)); height: 100%; border-radius: 99px; transition: width .3s; }
CSSEOF

    chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null || chown -R nginx:nginx "$PANEL_DIR" 2>/dev/null || true
    log "Admin panel created at $PANEL_DIR"
}

# ──────────────────────── NGINX ADMIN CONFIG ─────────────────────────────────
configure_nginx() {
    section "Configuring Nginx"

    # Disable default site
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

    # Admin panel vhost
    cat > /etc/nginx/sites-available/seedbox-admin.conf << NGINXEOF
server {
    listen ${ADMIN_PANEL_PORT} ssl http2;
    server_name _;

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         EECDH+AESGCM:EDH+AESGCM;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_prefer_server_ciphers on;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    root /var/www/seedbox-panel;
    index index.php;

    client_max_body_size 16M;
    client_body_timeout  120;

    # PHP
    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass unix:/run/php/seedbox-admin.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 120;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ /\. { deny all; }
    location ~* \.(conf|ini|log|sh|sql)$ { deny all; }

    access_log /var/log/nginx/seedbox-admin-access.log;
    error_log  /var/log/nginx/seedbox-admin-error.log;
}

# HTTP redirect
server {
    listen 80 default_server;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host:${ADMIN_PANEL_PORT}\$request_uri; }
}
NGINXEOF

    # Symlink
    ln -sf /etc/nginx/sites-available/seedbox-admin.conf \
           /etc/nginx/sites-enabled/seedbox-admin.conf 2>/dev/null || \
    cp     /etc/nginx/sites-available/seedbox-admin.conf \
           /etc/nginx/conf.d/seedbox-admin.conf 2>/dev/null || true

    mkdir -p /run/php

    # PHP-FPM pool for admin panel
    PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.1")
    PHP_FPM_POOL_DIR="/etc/php/${PHP_VER}/fpm/pool.d"
    [[ -d "$PHP_FPM_POOL_DIR" ]] || PHP_FPM_POOL_DIR="/etc/php-fpm.d"
    mkdir -p "$PHP_FPM_POOL_DIR"

    cat > "${PHP_FPM_POOL_DIR}/seedbox-admin.conf" << PHPEOF
[seedbox-admin]
user = www-data
group = www-data
listen = /run/php/seedbox-admin.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 5
pm.max_requests = 500
php_admin_value[open_basedir] = /var/www/seedbox-panel:/etc/seedbox:/tmp
php_admin_value[disable_functions] = passthru,shell_exec,popen,proc_open
php_admin_flag[allow_url_fopen] = off
PHPEOF

    # Add exec permission for seedbox-admin CLI from PHP
    # (php_admin_value[disable_functions] above doesn't include exec — needed for adduser)
    sed -i 's/php_admin_value\[disable_functions\].*/php_admin_value[disable_functions] = passthru,shell_exec,popen,proc_open/' \
        "${PHP_FPM_POOL_DIR}/seedbox-admin.conf" 2>/dev/null || true

    # Nginx tuning
    NGINX_WORKERS=$(nproc)
    cat > /etc/nginx/nginx.conf << NGINXMAINEOF
user www-data;
worker_processes ${NGINX_WORKERS};
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 75;
    keepalive_requests 1000;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Logging
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" "\$http_user_agent"';
    access_log /var/log/nginx/access.log main buffer=16k;
    error_log  /var/log/nginx/error.log warn;

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_proxied any;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript;

    # Security headers
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;

    # Rate limiting
    limit_req_zone \$binary_remote_addr zone=login:10m rate=5r/m;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*.conf;
}
NGINXMAINEOF

    mkdir -p /etc/nginx/{conf.d,sites-available,sites-enabled,htpasswd.d}
    nginx -t && systemctl enable nginx && systemctl restart nginx
    log "Nginx configured."
}

# ──────────────────────── SECURE SFTP ────────────────────────────────────────
configure_sftp() {
    section "Configuring Secure SFTP (Chroot)"

    # Backup sshd_config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak."$(date +%s)"

    # Remove any existing seedbox SFTP block
    sed -i '/# SEEDBOX SFTP BEGIN/,/# SEEDBOX SFTP END/d' /etc/ssh/sshd_config

    cat >> /etc/ssh/sshd_config << 'SSHEOF'

# SEEDBOX SFTP BEGIN
Match Group seedbox-sftp
    ChrootDirectory /home/seedbox-users/%u
    ForceCommand internal-sftp -u 0022 -l VERBOSE
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
    PasswordAuthentication yes
    PubkeyAuthentication yes
    AuthorizedKeysFile /home/seedbox-users/%u/.ssh/authorized_keys
# SEEDBOX SFTP END
SSHEOF

    # Create group
    groupadd -f seedbox-sftp

    # Harden sshd globally
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 4/' /etc/ssh/sshd_config
    sed -i 's/^#*LoginGraceTime.*/LoginGraceTime 30/' /etc/ssh/sshd_config
    sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 300/' /etc/ssh/sshd_config
    sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 2/' /etc/ssh/sshd_config

    # Use internal-sftp subsystem
    sed -i 's|^Subsystem.*sftp.*|Subsystem sftp internal-sftp|' /etc/ssh/sshd_config

    sshd -t && systemctl reload sshd || systemctl reload ssh
    log "Secure SFTP configured with chroot isolation."
}

# ──────────────────────── DISK QUOTAS ────────────────────────────────────────
configure_disk_quotas() {
    section "Configuring Disk Quotas"

    # Install quota tools
    if [[ "$PKG_MGR" == "apt" ]]; then
        apt-get install -y -qq quota quotatool 2>/dev/null || true
    else
        $PKG_INSTALL quota quotatool 2>/dev/null || true
    fi

    # Find mount point for users home
    USERS_MOUNT=$(df "$SEEDBOX_USERS_HOME" 2>/dev/null | awk 'NR==2{print $6}' || echo "/")
    FSTAB_DEV=$(grep " $USERS_MOUNT " /etc/fstab 2>/dev/null | awk '{print $1}' | head -1 || echo "")

    if [[ -n "$FSTAB_DEV" ]]; then
        # Add quota options to fstab if not present
        if ! grep -q "usrquota" /etc/fstab; then
            cp /etc/fstab /etc/fstab.bak."$(date +%s)"
            sed -i "s|\($USERS_MOUNT.*defaults\)|\1,usrquota,grpquota|g" /etc/fstab || true
            # Try to remount
            mount -o remount,usrquota,grpquota "$USERS_MOUNT" 2>/dev/null || \
            warn "Could not remount with quota; may require reboot."
        fi
        quotacheck -cum "$USERS_MOUNT" 2>/dev/null || true
        quotaon -u "$USERS_MOUNT" 2>/dev/null || \
        quotaon -a 2>/dev/null || true
        log "Disk quotas enabled on $USERS_MOUNT"
    else
        warn "Could not configure disk quotas — /etc/fstab entry not found for $USERS_MOUNT."
        warn "Quotas will be enforced via monitoring script instead."
    fi

    # Quota enforcement cron (fallback)
    cat > /usr/local/bin/seedbox-quota-check << 'QUOTAEOF'
#!/usr/bin/env bash
DB="/etc/seedbox/users.db"
USERS_HOME="/home/seedbox-users"
[[ ! -f "$DB" ]] && exit 0
sqlite3 "$DB" "SELECT username,disk_quota FROM users WHERE status='active';" | \
while IFS='|' read -r user quota_mb; do
    [[ -d "$USERS_HOME/$user" ]] || continue
    used_kb=$(du -sk "$USERS_HOME/$user" 2>/dev/null | awk '{print $1}')
    used_mb=$(( used_kb / 1024 ))
    sqlite3 "$DB" "UPDATE users SET disk_used=$used_mb WHERE username='$user';" 2>/dev/null
    quota_kb=$(( quota_mb * 1024 ))
    if (( used_kb > quota_kb )); then
        # Stop torrents for over-quota user
        systemctl stop "rtorrent@$user" 2>/dev/null || true
        systemctl stop "qbittorrent@$user" 2>/dev/null || true
        logger "SEEDBOX: User $user exceeded quota (${used_mb}MB / ${quota_mb}MB) — torrents paused."
    fi
done
QUOTAEOF
    chmod +x /usr/local/bin/seedbox-quota-check

    # Run every 5 minutes
    (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/seedbox-quota-check >> /var/log/seedbox/quota.log 2>&1") | \
    sort -u | crontab -
    log "Quota monitoring cron installed (every 5 min)."
}

# ──────────────────────── KERNEL & NETWORK OPTIMIZATION ──────────────────────
apply_kernel_optimizations() {
    section "Applying Kernel & Network Optimizations"

    # Backup sysctl
    cp /etc/sysctl.conf /etc/sysctl.conf.bak."$(date +%s)" 2>/dev/null || true

    SYSCTL_FILE="/etc/sysctl.d/99-seedbox.conf"
    cat > "$SYSCTL_FILE" << 'SYSCTLEOF'
# ─── Seedbox Kernel Optimizations ───────────────────────────────────────────

# ── Network Core Buffers ──
net.core.rmem_default = 262144
net.core.rmem_max = 536870912
net.core.wmem_default = 262144
net.core.wmem_max = 536870912
net.core.optmem_max = 40960
net.core.netdev_max_backlog = 250000
net.core.netdev_budget = 600
net.core.somaxconn = 65535

# ── TCP Buffers & Tuning ──
net.ipv4.tcp_rmem = 4096 87380 536870912
net.ipv4.tcp_wmem = 4096 65536 536870912
net.ipv4.tcp_mem = 786432 1048576 26777216
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_moderate_rcvbuf = 1

# ── TCP Congestion & Algorithm ──
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# ── TCP Connection Tuning ──
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 0
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# ── Connection Tracking ──
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 300
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15

# ── File Descriptors ──
fs.file-max = 2097152
fs.nr_open = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# ── VM ──
vm.swappiness = 10
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 1
vm.min_free_kbytes = 65536

# ── Security Hardening ──
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.sysrq = 0
SYSCTLEOF

    # Enable BBR if kernel supports it
    if modprobe tcp_bbr 2>/dev/null; then
        log "BBR congestion control loaded."
    else
        warn "BBR not supported on this kernel; falling back to cubic."
        sed -i 's/net.ipv4.tcp_congestion_control = bbr/net.ipv4.tcp_congestion_control = cubic/' "$SYSCTL_FILE"
    fi

    sysctl -p "$SYSCTL_FILE" 2>&1 | grep -v "^$" | grep -v "net.netfilter" | \
        sed 's/^/  /' | tee -a "$LOGFILE" || true

    # ── Limits ──
    cat > /etc/security/limits.d/99-seedbox.conf << 'LIMITSEOF'
# Seedbox performance limits
*    soft nofile 1048576
*    hard nofile 1048576
*    soft nproc  65535
*    hard nproc  65535
root soft nofile 1048576
root hard nofile 1048576
LIMITSEOF

    # PAM
    for pam_file in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive /etc/pam.d/system-auth; do
        [[ -f "$pam_file" ]] && grep -q 'pam_limits' "$pam_file" || \
        echo "session required pam_limits.so" >> "$pam_file" 2>/dev/null || true
    done

    # ── Disk I/O Scheduler ──
    for DISK in $(lsblk -dno NAME 2>/dev/null | grep -E '^(sd|nvme|vd)'); do
        DISK_PATH="/sys/block/$DISK/queue/scheduler"
        if [[ -f "$DISK_PATH" ]]; then
            if grep -q 'mq-deadline' "$DISK_PATH" 2>/dev/null; then
                echo mq-deadline > "$DISK_PATH" 2>/dev/null || true
            elif grep -q 'deadline' "$DISK_PATH" 2>/dev/null; then
                echo deadline > "$DISK_PATH" 2>/dev/null || true
            fi
        fi
    done

    # Persist I/O scheduler via udev
    cat > /etc/udev/rules.d/60-seedbox-io.rules << 'UDEVEOF'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="nvme*", ATTR{queue/scheduler}="none"
UDEVEOF

    # ── IRQ Balancing ──
    if [[ "$PKG_MGR" == "apt" ]]; then
        apt-get install -y -qq irqbalance 2>/dev/null || true
    else
        $PKG_INSTALL irqbalance 2>/dev/null || true
    fi
    systemctl enable irqbalance &>/dev/null && systemctl start irqbalance &>/dev/null || true

    log "Kernel and network optimizations applied."
}

# ──────────────────────── FIREWALL ───────────────────────────────────────────
configure_firewall() {
    section "Configuring Firewall"

    if command -v ufw &>/dev/null; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow 22/tcp    comment "SSH"
        ufw allow 80/tcp    comment "HTTP"
        ufw allow 443/tcp   comment "HTTPS"
        ufw allow "${ADMIN_PANEL_PORT}/tcp" comment "Seedbox Admin Panel"
        # Torrent ports
        ufw allow 45000:65535/tcp comment "Torrent TCP"
        ufw allow 45000:65535/udp comment "Torrent UDP"
        ufw --force enable
        log "UFW firewall configured."
    elif command -v firewall-cmd &>/dev/null; then
        systemctl enable firewalld && systemctl start firewalld
        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        firewall-cmd --permanent --add-port="${ADMIN_PANEL_PORT}/tcp"
        firewall-cmd --permanent --add-port="45000-65535/tcp"
        firewall-cmd --permanent --add-port="45000-65535/udp"
        firewall-cmd --reload
        log "Firewalld configured."
    else
        warn "No firewall found (ufw/firewalld). Skipping."
    fi
}

# ──────────────────────── FAIL2BAN ───────────────────────────────────────────
configure_fail2ban() {
    section "Configuring Fail2ban"

    cat > /etc/fail2ban/jail.d/seedbox.conf << 'F2BEOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
maxretry = 4
bantime  = 86400

[nginx-http-auth]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/seedbox-admin-error.log
maxretry = 6

[nginx-limit-req]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/error.log
maxretry = 10

[seedbox-admin-panel]
enabled  = true
port     = 8080
filter   = seedbox-admin
logpath  = /var/log/nginx/seedbox-admin-access.log
maxretry = 5
bantime  = 3600
F2BEOF

    cat > /etc/fail2ban/filter.d/seedbox-admin.conf << 'F2BEOF'
[Definition]
failregex = ^<HOST> .* "POST /\?action=login.*" 401
ignoreregex =
F2BEOF

    systemctl enable fail2ban && systemctl restart fail2ban
    log "Fail2ban configured."
}

# ──────────────────────── LOGROTATE ──────────────────────────────────────────
configure_logrotate() {
    cat > /etc/logrotate.d/seedbox << 'LREOF'
/var/log/seedbox/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        systemctl reload nginx > /dev/null 2>&1 || true
    endscript
}
LREOF
    log "Log rotation configured."
}

# ──────────────────────── MOTD ───────────────────────────────────────────────
configure_motd() {
    cat > /etc/motd << MOTDEOF

  ╔══════════════════════════════════════════════════════╗
  ║            S E E D B O X   S E R V E R              ║
  ╠══════════════════════════════════════════════════════╣
  ║  Admin Panel  : https://${SERVER_HOST}:${ADMIN_PANEL_PORT}          ║
  ║  Admin CLI    : seedbox-admin help                   ║
  ║  Docs         : /opt/seedbox/README.md               ║
  ╚══════════════════════════════════════════════════════╝

MOTDEOF
}

# ──────────────────────── SERVICE STARTUP ────────────────────────────────────
start_services() {
    section "Starting Services"
    for SVC in nginx; do
        systemctl enable "$SVC" &>/dev/null && systemctl restart "$SVC" &>/dev/null && log "$SVC started." || warn "$SVC failed to start."
    done

    # PHP-FPM
    PHP_FPM_SVC=$(systemctl list-units --type=service --state=loaded 2>/dev/null | grep -oP 'php[\d.]*-fpm' | head -1 || echo "php-fpm")
    systemctl enable "$PHP_FPM_SVC" &>/dev/null && systemctl restart "$PHP_FPM_SVC" &>/dev/null && log "$PHP_FPM_SVC started." || warn "$PHP_FPM_SVC failed."
}

# ──────────────────────── WRITE README ───────────────────────────────────────
write_readme() {
    mkdir -p "$SEEDBOX_BASE"
    cat > "$SEEDBOX_BASE/README.md" << READMEEOF
# Seedbox Server — Quick Reference

## Admin Panel
URL:      https://${SERVER_HOST}:${ADMIN_PANEL_PORT}
Username: ${ADMIN_USER}
Password: (set during install)

## CLI Management (run as root)
    seedbox-admin adduser  <user> <pass> [quota_mb]   # Create user
    seedbox-admin deluser  <user>                      # Delete user
    seedbox-admin modquota <user> <quota_mb>           # Change quota
    seedbox-admin listusers                            # List all users
    seedbox-admin status                               # Service status

## Per-User Access
    Web Dashboard:  https://${SERVER_HOST}:<web_port>/
    ruTorrent:      https://${SERVER_HOST}:<web_port>/rutorrent/
    qBittorrent:    https://${SERVER_HOST}:<web_port>/qbittorrent/
    SFTP:           sftp://<user>@${SERVER_HOST}   (chrooted to ~/downloads)

## Key Paths
    User homes:     /home/seedbox-users/<username>/
    Config:         /etc/seedbox/
    User DB:        /etc/seedbox/users.db
    Logs:           /var/log/seedbox/
    Admin panel:    /var/www/seedbox-panel/
    ruTorrent:      /var/www/rutorrent/

## Services
    rtorrent@<user>        systemctl {start|stop|restart|status} rtorrent@<user>
    qbittorrent@<user>     systemctl {start|stop|restart|status} qbittorrent@<user>
    nginx                  systemctl {start|stop|restart|status} nginx

## Disk Quotas
    View quotas:    repquota -a
    Manual set:     seedbox-admin modquota <user> <mb>

## SSL
    Cert:  ${SSL_CERT}
    Key:   ${SSL_KEY}

## Security
    - All users chrooted (SFTP and file isolation)
    - Fail2ban active (SSH + Admin Panel)
    - Firewall: only ports 22, 80, 443, ${ADMIN_PANEL_PORT}, 45000-65535 open
    - Kernel BBR + optimized TCP/VM tuning
    - Per-user PHP-FPM pools (process isolation)

## Installed: ${TIMESTAMP}
READMEEOF
    log "README written to $SEEDBOX_BASE/README.md"
}

# ──────────────────────── PRINT SUMMARY ──────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗"
    echo -e "║         SEEDBOX INSTALLATION COMPLETE!                  ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Admin Panel:${NC}    https://${SERVER_HOST}:${ADMIN_PANEL_PORT}"
    echo -e "  ${BOLD}Admin User:${NC}     ${ADMIN_USER}"
    echo -e "  ${BOLD}rTorrent:${NC}       $([[ $INSTALL_RTORRENT == true ]] && echo '✔ Installed' || echo '✘ Skipped')"
    echo -e "  ${BOLD}qBittorrent:${NC}    $([[ $INSTALL_QBIT == true ]] && echo '✔ Installed' || echo '✘ Skipped')"
    echo -e "  ${BOLD}SSL:${NC}            $([[ $USE_LETSENCRYPT == true ]] && echo "Let's Encrypt" || echo "Self-signed")"
    echo -e "  ${BOLD}Optimizations:${NC}  $([[ $APPLY_OPTIMIZATIONS == true ]] && echo 'Applied' || echo 'Skipped')"
    echo ""
    echo -e "  ${BOLD}Next Steps:${NC}"
    echo -e "  1. Open https://${SERVER_HOST}:${ADMIN_PANEL_PORT} in your browser"
    echo -e "  2. Login with admin credentials"
    echo -e "  3. Create users: ${CYAN}seedbox-admin adduser <name> <pass> [quota_mb]${NC}"
    echo -e "  4. Full docs:    ${CYAN}cat $SEEDBOX_BASE/README.md${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠ If using self-signed SSL, accept the browser certificate warning.${NC}"
    echo -e "  ${YELLOW}⚠ A reboot is recommended to apply all kernel changes.${NC}"
    echo ""
}

# ──────────────────────── MAIN ────────────────────────────────────────────────
main() {
    mkdir -p "$(dirname "$LOGFILE")"
    touch "$LOGFILE"

    echo "[$TIMESTAMP] Starting Seedbox installer" >> "$LOGFILE"

    detect_distro
    interactive_setup
    install_base_packages
    setup_ssl
    create_admin_user
    init_user_db
    create_chroot_template

    [[ "$INSTALL_RTORRENT" == "true" ]] && { install_rtorrent; install_rutorrent; }
    [[ "$INSTALL_QBIT" == "true" ]] && install_qbittorrent

    create_admin_panel
    create_seedbox_admin_cli
    configure_nginx
    configure_sftp
    configure_disk_quotas
    [[ "$APPLY_OPTIMIZATIONS" == "true" ]] && apply_kernel_optimizations
    configure_firewall
    configure_fail2ban
    configure_logrotate
    configure_motd
    start_services
    write_readme
    print_summary

    echo "[$TIMESTAMP] Installation complete." >> "$LOGFILE"
}

main "$@"
