#!/usr/bin/env bash

# DXSpider deployment and configuration (bundle-first, optimized)
# Uses a static git bundle (history + tags) shipped with this repo:
#   assets/spider.bundle.gz + assets/spider.bundle.gz.sha256
#
# Fallback (optional): if bundle is missing, it can clone from REPO_URL.
#
# Version: 2.2
# Date: 2025-12-18

set -Eeuo pipefail

# ----------------------------
# Script location (for relative files)
# ----------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------
# Defaults (override via env)
# ----------------------------
: "${REPO_URL:=https://github.com/EA3CV/dx-spider.git}"   # fallback only
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

get_os_keys() {
  local pretty="" id="" version="" like=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    pretty="${PRETTY_NAME:-}"
    id="${ID:-}"
    version="${VERSION_ID:-}"
    like="${ID_LIKE:-}"
  elif [[ -r /etc/redhat-release ]]; then
    pretty="$(cat /etc/redhat-release)"
  else
    pretty="$(uname -s) $(uname -r)"
  fi

  [[ -n "$pretty" ]] && echo "$pretty"
  [[ -n "$id" && -n "$version" ]] && echo "${id}:${version}"
  [[ -n "$id" && -n "$version" ]] && echo "${id} ${version}"
  [[ -n "$id" ]] && echo "${id}"
  [[ -n "$like" ]] && echo "${like}"
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

  IFS=';' read -ra steps <<< "${actions}"
  for raw in "${steps[@]}"; do
    local step
    step="$(echo "$raw" | xargs)"
    [[ -n "$step" ]] || continue

    if [[ "$step" =~ [[:space:]] ]]; then
      die "Invalid step '${step}' in ${CONF_FILE} (spaces not allowed)."
    fi
    declare -F "$step" >/dev/null 2>&1 || die "Step '${step}' is not a known function."
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
    perl-DBD-MySQL perl-DBD-MariaDB || true
}

install_package_debian() {
  log "Installing dependencies (Debian/Ubuntu/Raspbian)..."
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -y
  apt-get upgrade -y

  apt-get install -y \
    ca-certificates \
    git curl gzip coreutils procps \
    build-essential \
    cpanminus \
    libtimedate-perl \
    libnet-telnet-perl \
    libcurses-perl \
    libdigest-sha-perl \
    libdata-dumper-simple-perl \
    libjson-perl \
    libjson-xs-perl \
    libmojolicious-perl \
    libdata-structure-util-perl \
    libmath-round-perl \
    libev-perl \
    libnet-cidr-lite-perl \
    libio-compress-perl \
    libdbd-mysql-perl \
    libdbd-mariadb-perl
}

ensure_cpanm_and_modules() {
  if ! have_cmd cpanm; then
    log "cpanm not found. Bootstrapping via curl..."
    curl -fsSL https://cpanmin.us | perl - App::cpanminus
  fi
  have_cmd cpanm || die "cpanm installation failed."

  log "Ensuring Perl modules (cpanm --notest)..."
  cpanm --notest EV Mojolicious JSON JSON::XS Data::Structure::Util Math::Round || true
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
  bundle_gz="${tmpdir}/spider.bundle.gz"
  sha_file="${tmpdir}/spider.bundle.gz.sha256"

  if bundle_available_local; then
    log "Using LOCAL bundle shipped with this installer:"
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

  # Clone into SPIDER_DIR (must be empty / non-existent)
  if [[ -d "${SPIDER_DIR}" && -n "$(ls -A "${SPIDER_DIR}" 2>/dev/null || true)" ]]; then
    if [[ "${FORCE}" == "1" ]]; then
      log "FORCE=1: removing existing '${SPIDER_DIR}' before bundle clone..."
      rm -rf "${SPIDER_DIR}"
    else
      die "Destination '${SPIDER_DIR}' is not empty. Use FORCE=1 to replace it."
    fi
  fi
  mkdir -p "${SPIDER_DIR}"
  chown "${SYSOP_USER}:${SPIDER_GROUP}" "${SPIDER_DIR}"

  log "Cloning DXSpider from bundle into ${SPIDER_DIR}..."
  # Clone from bundle into directory; if SPIDER_DIR exists empty, git clone will create subdir unless we pass path.
  # So we clone into a temp dir then move, or clone directly with SPIDER_DIR as target and ensure parent exists.
  rm -rf "${SPIDER_DIR}"
  su - "${SYSOP_USER}" -c "git clone '${bundle_file}' '${SPIDER_DIR}'"

  # Checkout branch if exists
  su - "${SYSOP_USER}" -c "cd '${SPIDER_DIR}
