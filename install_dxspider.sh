#!/usr/bin/env bash

# DXSpider deployment and configuration (bundle-first, optimized)
# Uses a static git bundle (history + tags) shipped with this repo:
#   assets/spider.bundle.gz + assets/spider.bundle.gz.sha256
#
# Fallback (optional): if bundle is missing, it can clone from REPO_URL.
#
# Version: 2.13
# Date: 20261118

set -Eeuo pipefail

# ----------------------------
# Script location (for relative files)
# ----------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------
# Defaults (override via env)
# ----------------------------
: "${REPO_URL:=git://scm.dxcluster.org/spider}"   # fallback only
: "${BACKUP_REPO_URL:=https://github.com/EA3CV/dxspider.git}"
: "${BRANCH:=mojo}"

: "${SYSOP_USER:=sysop}"
: "${SPIDER_GROUP:=spider}"

: "${HOME_BASE:=/home}"
: "${SPIDER_HOME:=${HOME_BASE}/${SYSOP_USER}}"
: "${SPIDER_DIR:=${SPIDER_HOME}/spider}"
: "${SPIDER_LINK:=/spider}"

: "${CONF_FILE:=${SCRIPT_DIR}/distro_actions.conf}"

# Bundle shipped with this installer repo (preferred)
: "${LOCAL_BUNDLE_GZ:=${SCRIPT_DIR}/assets/spider.bundle.gz}"
: "${LOCAL_BUNDLE_SHA:=${SCRIPT_DIR}/assets/spider.bundle.gz.sha256}"

# Optional remote bundle fallback (leave empty to disable)
: "${BUNDLE_URL:=}"
: "${BUNDLE_SHA_URL:=}"

: "${FORCE:=0}"            # 1 -> delete existing SPIDER_DIR before clone
: "${NONINTERACTIVE:=0}"   # 1 -> requires DX* vars below

# If NONINTERACTIVE=1, provide:
# DXCLUSTER_CALL, SELFCALL, MYNAME, EMAIL, MYLOCATOR, MYQTH

log() { echo -e "[dxspider-install] $*"; }
die() { echo -e "[dxspider-install] ERROR: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "This script must be run as root."
}

# ----------------------------
# distro_actions.conf loader (safe)
# ----------------------------
declare -gA distro_actions

load_distro_actions() {
  [[ -f "${CONF_FILE}" ]] || die "Configuration file '${CONF_FILE}' not found at: ${CONF_FILE}"

  while IFS=, read -r name actions; do
    name="$(echo "${name:-}" | xargs)"
    actions="$(echo "${actions:-}" | xargs)"
    [[ -n "$name" ]] || continue
    [[ "$name" =~ ^# ]] && continue
    distro_actions["$name"]="$actions"
  done < "${CONF_FILE}"
}

normalize_distro() {
  local id="$1" version="$2" major="${2%%.*}"
  case "$id" in
    ubuntu) printf 'Ubuntu %s\n' "$major" ;;
    linuxmint) printf 'Linux Mint %s\n' "$major" ;;
    debian) printf 'Debian GNU/Linux %s\n' "$major" ;;
    raspbian) printf 'Raspbian GNU/Linux %s\n' "$major" ;;
    zorin) printf 'zorin\n' ;;
    fedora) printf 'Fedora Linux %s\n' "$major" ;;
    centos|rocky|almalinux)
      [[ "$major" =~ ^[0-9]+$ ]] || return 1
      case "$major" in 8|9) ;; *) return 1 ;; esac
      case "$id" in
        centos) printf 'CentOS Linux %s\n' "$major" ;;
        rocky) printf 'Rocky Linux %s\n' "$major" ;;
        almalinux) printf 'AlmaLinux %s\n' "$major" ;;
      esac ;;
    *) return 1 ;;
  esac
}

get_os_keys() {
  local id="" version=""
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    id="${ID:-}"
    version="${VERSION_ID:-}"
  else
    die "Missing /etc/os-release"
  fi
  normalize_distro "$id" "$version" || die "Unsupported distribution: $id $version"
}

run_actions_for_distro() {
  load_distro_actions

  local matched_key="" actions=""
  while IFS= read -r key; do
    if [[ -n "${distro_actions[$key]:-}" ]]; then
      matched_key="$key"
      actions="${distro_actions[$key]}"
      break
    fi
  done < <(get_os_keys)

  [[ -n "$matched_key" ]] || die "Your OS distribution is not supported by ${CONF_FILE}."

  log "Detected distribution: ${matched_key}"
  log "Executing actions: ${actions}"
  echo

  local -a steps=() validated=()
  local raw step
  IFS=';' read -ra steps <<< "${actions}"
  # Validate every action before any package installation starts.
  for raw in "${steps[@]}"; do
    step="$(echo "$raw" | xargs)"
    [[ -n "$step" && "$step" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]] || die "Invalid step '$step' in ${CONF_FILE}."
    case "$step" in
      install_epel_8|install_epel_9|install_package_CentOS_8|install_package_Rocky_9|install_package_debian) ;;
      *) die "Unknown action '$step' in ${CONF_FILE}." ;;
    esac
    declare -F "$step" >/dev/null 2>&1 || die "Step '$step' is not implemented."
    validated+=("$step")
  done
  for step in "${validated[@]}"; do
    "$step"
  done
}

# ----------------------------
# Package installation (superset + bundle tooling)
# ----------------------------
install_epel_8() {
  log "Enabling EPEL (8.x)..."
  dnf -y makecache --refresh || true
  dnf -y update
  dnf -y install epel-release || true
}

install_epel_9() {
  log "Enabling EPEL (9.x)..."
  dnf -y makecache --refresh || true
  dnf -y update
  dnf -y install epel-release || true
}

install_package_CentOS_8() {
  log "Installing dependencies (RHEL-like 8.x)..."
  dnf -y makecache --refresh || true
  dnf -y update

  dnf -y install \
    git curl gzip coreutils procps-ng \
    perl gcc make \
    perl-TimeDate perl-Time-HiRes \
    perl-Curses perl-Net-Telnet perl-Data-Dumper perl-DB_File \
    perl-ExtUtils-MakeMaker \
    perl-Digest-MD5 perl-Digest-SHA \
    perl-IO-Compress \
    perl-Net-CIDR-Lite \
    perl-App-cpanminus \
    perl-JSON perl-JSON-XS \
    perl-Mojolicious \
    perl-Data-Structure-Util \
    perl-Math-Round \
    perl-EV \
    perl-DBI perl-DBD-SQLite \
    perl-DBD-MySQL perl-DBD-MariaDB || true
}

install_package_Rocky_9() {
  log "Installing dependencies (RHEL-like 9.x / Fedora mapping)..."
  dnf -y makecache --refresh || true
  dnf -y update

  dnf -y install \
    git curl gzip coreutils procps-ng \
    perl gcc make \
    perl-TimeDate perl-Time-HiRes \
    perl-Curses perl-Net-Telnet perl-Data-Dumper perl-DB_File \
    perl-ExtUtils-MakeMaker \
    perl-Digest-MD5 perl-Digest-SHA \
    perl-IO-Compress \
    perl-Net-CIDR-Lite \
    perl-App-cpanminus \
    perl-JSON perl-JSON-XS \
    perl-Mojolicious \
    perl-Data-Structure-Util \
    perl-Math-Round \
    perl-EV \
    perl-DBI perl-DBD-SQLite \
    perl-DBD-MySQL perl-DBD-MariaDB || true
}

install_package_debian() {
  log "Installing dependencies (Debian/Ubuntu/Raspbian)..."
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -y
  apt-get upgrade -y

  apt-get install -y \
    perl git rsync curl iproute2 gzip procps build-essential cpanminus libssl-dev zlib1g-dev \
    libtimedate-perl libnet-telnet-perl libcurses-perl libdigest-sha-perl \
    libdata-dumper-simple-perl libjson-perl libmojolicious-perl \
    libdata-structure-util-perl libmath-round-perl libev-perl \
    libjson-xs-perl libnet-cidr-lite-perl libdbi-perl \
    libdbd-sqlite3-perl libhtml-parser-perl \
    libio-socket-inet6-perl libarchive-zip-perl libmailtools-perl \
    libwww-perl libio-pty-perl \
    libauthen-sasl-perl libnet-smtp-ssl-perl libemail-sender-perl
}

# Required Perl modules from Guia_DXS_ES / Guide_DXS_EN.
DXS_REQUIRED_MODULES=(
        EV Mojolicious JSON JSON::XS Data::Structure::Util Math::Round
        Net::CIDR::Lite DBI DBD::SQLite Date::Parse HTML::Parser
        IO::Socket::INET6 Archive::Zip Curses Mail::Internet Digest::SHA
        LWP::UserAgent LWP::Parallel::UserAgent DB_File IO::Pty
        Authen::SASL Net::SMTP::SSL Email::Sender
)

install_optional_perl_packages() {
  local package
  local -a packages=()
  if have_cmd apt-get; then
    packages=(libdbi-perl libdbd-sqlite3-perl libemail-sender-perl libio-pty-perl)
    for package in "${packages[@]}"; do apt-get install -y "$package" || log "Native package unavailable: $package"; done
  elif have_cmd dnf; then
    packages=(perl-DBI perl-DBD-SQLite perl-Email-Sender perl-IO-Tty)
    for package in "${packages[@]}"; do dnf -y install "$package" || log "Native package unavailable: $package"; done
  fi
}

ensure_cpanm_and_modules() {
  local module
  local -a missing=()
  perl -e 'die "Perl >= 5.16.1 required\n" if $] < 5.016001' || die "Perl version is too old"
  for module in "${DXS_REQUIRED_MODULES[@]}"; do
    perl -M"$module" -e 1 >/dev/null 2>&1 || missing+=("$module")
  done
  if (( ${#missing[@]} > 0 )); then
    log "Missing Perl modules: ${missing[*]}"
    have_cmd cpanm || die "cpanm unavailable; install cpanminus and retry"
    for module in "${missing[@]}"; do
      log "Installing missing Perl module: $module"
      cpanm "$module" || die "Failed to install Perl module $module"
    done
  fi
  for module in "${DXS_REQUIRED_MODULES[@]}"; do
    perl -M"$module" -e 1 >/dev/null 2>&1 || die "Perl module still unavailable: $module"
  done
  perl -MMojolicious -e 'Mojolicious->VERSION(7.26)' >/dev/null 2>&1 || die "Mojolicious >= 7.26 required"
  log "DXSpider Perl dependency verification: OK"
}

# ----------------------------
# User/group + filesystem
# ----------------------------
ensure_group() {
  if getent group "${SPIDER_GROUP}" >/dev/null 2>&1; then
    log "Group '${SPIDER_GROUP}' exists."
  else
    log "Creating group '${SPIDER_GROUP}'..."
    groupadd "${SPIDER_GROUP}"
  fi
}

ensure_user() {
  if id "${SYSOP_USER}" >/dev/null 2>&1; then
    log "User '${SYSOP_USER}' exists."
  else
    log "Creating user '${SYSOP_USER}'..."
    useradd -m -s /bin/bash -g "${SPIDER_GROUP}" "${SYSOP_USER}"
    if [[ "${NONINTERACTIVE}" != "1" ]]; then
      log "Set password for user '${SYSOP_USER}':"
      passwd "${SYSOP_USER}"
    else
      log "NONINTERACTIVE=1: password not set here. Set it manually if needed."
    fi
  fi

  usermod -aG "${SPIDER_GROUP}" "${SYSOP_USER}" || true
  usermod -aG "${SPIDER_GROUP}" root || true
}

prepare_paths() {
  mkdir -p "${SPIDER_HOME}"
  chown "${SYSOP_USER}:${SPIDER_GROUP}" "${SPIDER_HOME}"

  if [[ -d "${SPIDER_DIR}" && -n "$(ls -A "${SPIDER_DIR}" 2>/dev/null || true)" ]]; then
    if [[ "${FORCE}" == "1" ]]; then
      log "FORCE=1: removing existing '${SPIDER_DIR}'..."
      rm -rf "${SPIDER_DIR}"
    else
      log "Directory '${SPIDER_DIR}' exists and is not empty (not deleting)."
    fi
  fi

  mkdir -p "${SPIDER_DIR}"
  chown "${SYSOP_USER}:${SPIDER_GROUP}" "${SPIDER_DIR}"

  # Create/refresh symlink /spider -> /home/sysop/spider
  if [[ -e "${SPIDER_LINK}" && ! -L "${SPIDER_LINK}" ]]; then
    if [[ -d "${SPIDER_LINK}" && -n "$(ls -A "${SPIDER_LINK}" 2>/dev/null || true)" ]]; then
      die "'${SPIDER_LINK}' exists as a non-empty directory. Resolve it manually or change SPIDER_LINK."
    fi
    rm -rf "${SPIDER_LINK}"
  fi
  ln -sfn "${SPIDER_DIR}" "${SPIDER_LINK}"
}

# ----------------------------
# Bundle install (history+tags) + fallback git clone
# ----------------------------
bundle_available_local() {
  [[ -f "${LOCAL_BUNDLE_GZ}" && -f "${LOCAL_BUNDLE_SHA}" ]]
}

clone_from_bundle() {
  have_cmd git || die "git is required but not installed."
  have_cmd sha256sum || die "sha256sum is required but not installed."
  have_cmd gunzip || die "gunzip is required but not installed."
  have_cmd curl || true

  local tmpdir bundle_gz sha_file bundle_file
  tmpdir="$(mktemp -d)"

  # Allow sysop to read the bundle from this temp dir
  chmod 0755 "${tmpdir}"
  chown "${SYSOP_USER}:${SPIDER_GROUP}" "${tmpdir}"

  bundle_gz="${tmpdir}/spider.bundle.gz"
  sha_file="${tmpdir}/spider.bundle.gz.sha256"

  if bundle_available_local; then
    log "Using LOCAL bundle:"
    log "  ${LOCAL_BUNDLE_GZ}"
    cp -f "${LOCAL_BUNDLE_GZ}" "${bundle_gz}"
    cp -f "${LOCAL_BUNDLE_SHA}" "${sha_file}"
  else
    [[ -n "${BUNDLE_URL}" && -n "${BUNDLE_SHA_URL}" ]] || die "No local bundle found and BUNDLE_URL/BUNDLE_SHA_URL not set."
    have_cmd curl || die "curl is required to download remote bundle."
    log "Downloading bundle from remote..."
    curl -fsSLo "${bundle_gz}" "${BUNDLE_URL}"
    curl -fsSLo "${sha_file}" "${BUNDLE_SHA_URL}"
  fi

  log "Verifying bundle checksum..."
  (cd "${tmpdir}" && sha256sum -c "$(basename "${sha_file}")")

  log "Extracting bundle..."
  gunzip -f "${bundle_gz}"
  bundle_file="${tmpdir}/spider.bundle"

  # Ensure sysop can read the extracted bundle file
  chown "${SYSOP_USER}:${SPIDER_GROUP}" "${bundle_file}"
  chmod 0644 "${bundle_file}"

  # Destination must be empty or FORCE=1
  if [[ -d "${SPIDER_DIR}" && -n "$(ls -A "${SPIDER_DIR}" 2>/dev/null || true)" ]]; then
    if [[ "${FORCE}" == "1" ]]; then
      log "FORCE=1: removing existing '${SPIDER_DIR}' before bundle clone..."
      rm -rf "${SPIDER_DIR}"
    else
      die "Destination '${SPIDER_DIR}' is not empty. Use FORCE=1 to replace it."
    fi
  fi

  mkdir -p "$(dirname "${SPIDER_DIR}")"
  chown "${SYSOP_USER}:${SPIDER_GROUP}" "$(dirname "${SPIDER_DIR}")" || true
  rm -rf "${SPIDER_DIR}"

  log "Cloning DXSpider from bundle into ${SPIDER_DIR}..."
  su - "${SYSOP_USER}" -c "git clone '${bundle_file}' '${SPIDER_DIR}'"

  su - "${SYSOP_USER}" -c "cd '${SPIDER_DIR}' && (git checkout '${BRANCH}' || git checkout -b '${BRANCH}' 'origin/${BRANCH}' || true)"

  log "Bundle clone check (must show tags/history):"
  su - "${SYSOP_USER}" -c "cd '${SPIDER_DIR}' && git describe --tags --long --always"
  su - "${SYSOP_USER}" -c "cd '${SPIDER_DIR}' && git rev-list --count HEAD"
  su - "${SYSOP_USER}" -c "cd '${SPIDER_DIR}' && git rev-parse --short HEAD"
}

clone_from_repo_fallback() {
  log "Bundle not available. Trying Dirk repository first: ${REPO_URL}"
  if [[ -d "${SPIDER_DIR}/.git" ]]; then
    if ! su - "${SYSOP_USER}" -c "cd '${SPIDER_DIR}' && git fetch '${REPO_URL}' '${BRANCH}'"; then
      log "Dirk repository failed; trying GitHub backup: ${BACKUP_REPO_URL}"
      su - "${SYSOP_USER}" -c "cd '${SPIDER_DIR}' && git fetch '${BACKUP_REPO_URL}' '${BRANCH}'" || die "Both repositories failed"
    fi
    su - "${SYSOP_USER}" -c "cd '${SPIDER_DIR}' && git checkout -B '${BRANCH}' FETCH_HEAD"
  else
    mkdir -p "${SPIDER_DIR}"
    chown "${SYSOP_USER}:${SPIDER_GROUP}" "${SPIDER_DIR}"
    if ! su - "${SYSOP_USER}" -c "git clone --branch '${BRANCH}' '${REPO_URL}' '${SPIDER_DIR}'"; then
      log "Dirk repository failed; trying GitHub backup: ${BACKUP_REPO_URL}"
      # Remove only the failed new clone; never remove an existing installation.
      [[ ! -d "${SPIDER_DIR}/.git" ]] || die "Partial Git clone exists; refusing to overwrite it"
      rm -rf "${SPIDER_DIR}"
      su - "${SYSOP_USER}" -c "git clone --branch '${BRANCH}' '${BACKUP_REPO_URL}' '${SPIDER_DIR}'" || die "Both repositories failed"
    fi
  fi
  log "Fallback clone check:"
  su - "${SYSOP_USER}" -c "cd '${SPIDER_DIR}' && git describe --tags --long --always && git rev-parse --short HEAD"
}

git_install_spider() {
  log "Installing DXSpider (bundle-first)..."
  if bundle_available_local || { [[ -n "${BUNDLE_URL}" && -n "${BUNDLE_SHA_URL}" ]]; }; then
    clone_from_bundle
  else
    clone_from_repo_fallback
  fi
}

# ----------------------------
# App configuration
# ----------------------------
ensure_runtime_dirs() {
  su - "${SYSOP_USER}" -c "mkdir -p '${SPIDER_LINK}/local' '${SPIDER_LINK}/local_cmd' '${SPIDER_LINK}/cmd_import' '${SPIDER_LINK}/local_data'"
}

install_local_files() {
  [[ -f "${SPIDER_LINK}/perl/DXVars.pm.issue" ]] || die "Missing /spider/perl/DXVars.pm.issue"

  if [[ ! -f "${SPIDER_LINK}/local/DXVars.pm" ]]; then
    su - "${SYSOP_USER}" -c "cp '${SPIDER_LINK}/perl/DXVars.pm.issue' '${SPIDER_LINK}/local/DXVars.pm'"
  else
    log "DXVars.pm already exists. Leaving it untouched."
  fi

  if [[ -f "${SPIDER_LINK}/perl/Listeners.pm" ]]; then
    if [[ ! -f "${SPIDER_LINK}/local/Listeners.pm" ]]; then
      su - "${SYSOP_USER}" -c "cp '${SPIDER_LINK}/perl/Listeners.pm' '${SPIDER_LINK}/local/Listeners.pm'"
    fi
    su - "${SYSOP_USER}" -c "sed -i -E 's/^[[:space:]]*#[[:space:]]*(\\[\\s*\"0\\.0\\.0\\.0\"\\s*,\\s*7300\\s*\\],)/\\1/' '${SPIDER_LINK}/local/Listeners.pm' || true"
  fi
}

set_dxvars_field() {
  local key="$1" value="$2" file="${SPIDER_LINK}/local/DXVars.pm"
  [[ -f "$file" ]] || die "DXVars.pm not found at: $file"

  KEY="$key" VALUE="$value" perl -i -0777 -pe '
    my $k = $ENV{KEY};
    my $v = $ENV{VALUE};
    if ($k eq "myemail") {
      $v =~ s/\\@/@/g;
      $v =~ s/\\/\\\\/g;
      $v =~ s/\x27/\\\x27/g;
      s/^(\s*(?:our\s+)?\$\Q$k\E\s*=\s*).*(;\s*)$/${1}\x27$v\x27${2}/mg;
    } else {
      $v =~ s/\\/\\\\/g;
      $v =~ s/"/\\"/g;
      s/^(\s*\Q$k\E\s*=\s*).*(;\s*)$/${1}"$v"${2}/mg;
      s/^(\s*(?:our\s+)?\$\Q$k\E\s*=\s*).*(;\s*)$/${1}"$v"${2}/mg;
    }
  ' "$file"
}
prompt_var() {
  local var="$1" prompt="$2" def="${3:-}" val=""
  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    val="${!var:-}"
    [[ -n "$val" ]] || die "NONINTERACTIVE=1 but env var '${var}' is missing."
    return 0
  fi
  if [[ -n "${!var:-}" ]]; then
    return 0
  fi
  if [[ -n "$def" ]]; then
    read -r -p "${prompt} [${def}]: " val
    val="${val:-$def}"
  else
    read -r -p "${prompt}: " val
    [[ -n "$val" ]] || die "Value required for ${var}."
  fi
  printf -v "$var" '%s' "$val"
}

configure_dxvars() {
  log "Configuring /spider/local/DXVars.pm ..."
  prompt_var DXCLUSTER_CALL "Please enter CallSign for DxCluster (mycall)" ""
  prompt_var SELFCALL       "Please enter your CallSign (myalias)" ""
  prompt_var MYNAME         "Please enter your Name (myname)" ""
  prompt_var EMAIL          "Please enter your E-mail Address (myemail)" ""
  prompt_var MYLOCATOR      "Please enter your Locator (mylocator, uppercase recommended)" ""
  prompt_var MYQTH          "Please enter your QTH (myqth, comma without spaces recommended)" ""

  MYLOCATOR="$(echo "${MYLOCATOR}" | tr '[:lower:]' '[:upper:]')"

  set_dxvars_field "mycall"    "${DXCLUSTER_CALL}"
  set_dxvars_field "myalias"   "${SELFCALL}"
  set_dxvars_field "myname"    "${MYNAME}"
  set_dxvars_field "myemail"   "${EMAIL}"
  set_dxvars_field "mylocator" "${MYLOCATOR}"
  set_dxvars_field "myqth"     "${MYQTH}"
}

ensure_userdsn() {
  local file="${SPIDER_LINK}/local/DXVars.pm"
  perl -0pi -e 'if (!/^\s*our \$userdsn\s*=/m) { s/\n1;\s*\z/\nour \$userdsn = "dbi:SQLite:dbname=\$root\/local_data\/dxusers.db";\n\n1;\n/ or die "DXVars.pm: final 1; not found\n" }' "$file"
  chown "${SYSOP_USER}:${SPIDER_GROUP}" "$file"
}

fix_permissions() {
  log "Fixing ownership/permissions..."

  chown -R "${SYSOP_USER}:${SPIDER_GROUP}" "${SPIDER_DIR}"

  find "${SPIDER_DIR}" -type d -exec chmod 2775 {} \;
  find "${SPIDER_DIR}" -type f -exec chmod 0664 {} \;

  if [[ -d "${SPIDER_DIR}/perl" ]]; then
    find "${SPIDER_DIR}/perl" -type f -name "*.pl" -exec chmod 0775 {} \; 2>/dev/null || true
    find "${SPIDER_DIR}/perl" -type f -name "*dbg" -exec chmod 0775 {} \; 2>/dev/null || true
  fi

  if [[ -f "${SPIDER_LINK}/perl/console.pl" ]]; then
    ln -sfn "${SPIDER_LINK}/perl/console.pl" /usr/local/bin/dx
    chmod 0775 /usr/local/bin/dx || true
  fi

  if compgen -G "${SPIDER_LINK}/perl/*dbg" >/dev/null; then
    for f in ${SPIDER_LINK}/perl/*dbg; do
      ln -sfn "$f" "/usr/local/bin/$(basename "$f")"
      chmod 0775 "/usr/local/bin/$(basename "$f")" || true
    done
  fi
}

create_sysop_db() {
  log "Now create basic user file (create_sysop.pl)..."
  [[ -f "${SPIDER_LINK}/perl/create_sysop.pl" ]] || die "Missing /spider/perl/create_sysop.pl"
  chmod 0775 "${SPIDER_LINK}/perl/create_sysop.pl" || true
  su - "${SYSOP_USER}" -c "${SPIDER_LINK}/perl/create_sysop.pl"
}

# ----------------------------
# systemd service
# ----------------------------
create_service() {
  local unit="/etc/systemd/system/dxspider.service"
  log "Creating systemd service: ${unit}"

  cat > "${unit}" <<EOF
[Unit]
Description=Dxspider DXCluster service
After=network.target

[Service]
Type=simple
User=${SYSOP_USER}
Group=${SPIDER_GROUP}
ExecStart=/usr/bin/perl -w /spider/perl/cluster.pl
# Comment out line below for logging everything to journal/syslog
StandardOutput=null
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

enable_and_start_service() {
  log "Enabling and starting dxspider..."
  systemctl enable dxspider
  systemctl restart dxspider
  systemctl --no-pager --full status dxspider || true
}

print_summary() {
  cat <<EOF

===============================================================
DXSpider installation finished
===============================================================
Bundle    : $(bundle_available_local && echo "LOCAL (${LOCAL_BUNDLE_GZ})" || echo "REMOTE/FALLBACK")
Repo      : ${REPO_URL}
Branch    : ${BRANCH}
Path      : ${SPIDER_DIR}
Symlink   : ${SPIDER_LINK} -> ${SPIDER_DIR}
User      : ${SYSOP_USER}
Group     : ${SPIDER_GROUP}
Service   : systemctl status dxspider

NOTICE: DXWeb and dxweb-admin services have NOT been configured.
        This installer only configures the DXSpider service.

EOF
}

main() {
  require_root
  run_actions_for_distro

  ensure_group
  ensure_user
  prepare_paths

  install_optional_perl_packages
  ensure_cpanm_and_modules
  git_install_spider

  ensure_runtime_dirs
  install_local_files
  configure_dxvars
  ensure_userdsn
  fix_permissions

  create_sysop_db

  create_service
  enable_and_start_service

  print_summary
}

main "$@"
