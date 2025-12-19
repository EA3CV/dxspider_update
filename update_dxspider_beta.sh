#!/usr/bin/env bash

#
# DXSpider alternative updater (deterministic, bundle-based)
#
# Purpose:
#   Update an existing DXSpider installation while the official upstream repo is unavailable,
#   using the bundled full Git history (tags/commits) shipped with this repository.
#
# Repository / assets expected (relative to this script):
#   assets/spider.bundle.gz
#   assets/spider.bundle.gz.sha256   (must reference "spider.bundle.gz" without paths)
#
# By Kin, EA3CV <ea3cv@cronux.net>
#
# Version: 0.6.0
# Date   : 2025-12-18
#

set -Eeuo pipefail

# ----------------------------
# Defaults (override via env)
# ----------------------------
: "${BRANCH:=mojo}"
: "${KEEP_LOCAL:=1}"          # 1 = preserve local/, local_cmd/, cmd_import/, local_data/
: "${KEEP_DATA_COPY:=1}"      # 1 = copy data/* -> local_data/ before update (as original)
: "${FORCE_BRANCH:=0}"        # 1 = force checkout to BRANCH even if already on it
: "${NONINTERACTIVE:=0}"      # 1 = do not prompt; requires DXSPATH and OPTION=U/R/Q

# Internal paths
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="${SCRIPT_DIR}/assets"
BUNDLE_GZ="${ASSETS_DIR}/spider.bundle.gz"
BUNDLE_SHA="${ASSETS_DIR}/spider.bundle.gz.sha256"

log() { echo -e "[dxspider-update] $*"; }
die() { echo -e "[dxspider-update] ERROR: $*" >&2; exit 1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "This script must be run as root."
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# ----------------------------
# Original-style service detection
# ----------------------------
OWNER=""
GROUP=""
DXSPATH=""
PID=""

is_spider() {
  [[ -n "${DXSPATH}" ]] || die "DXSPATH is empty."
  if [[ -f "${DXSPATH}/perl/cluster.pl" ]]; then
    log "Detecting owner/group from ${DXSPATH}/perl/cluster.pl ..."
    OWNER="$(stat -c '%U' "${DXSPATH}/perl/cluster.pl")"
    GROUP="$(stat -c '%G' "${DXSPATH}/perl/cluster.pl")"
  else
    die "DXSpider not found at '${DXSPATH}' (missing perl/cluster.pl)."
  fi
}

is_service() {
  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "dxspider.service"; then
    if systemctl is-active --quiet dxspider 2>/dev/null || systemctl is-enabled --quiet dxspider 2>/dev/null; then
      log "DXSpider managed by systemd (dxspider.service)."
      return 0
    fi
  fi
  return 1
}

stop_spider() {
  log "Stopping DXSpider..."
  if is_service; then
    systemctl stop dxspider || true
  else
    PID="$(pgrep -f 'perl.*cluster\.pl' | head -n 1 || true)"
    if [[ -n "${PID}" ]]; then
      kill -9 "${PID}" || true
    fi
  fi
}

start_spider() {
  log "Starting DXSpider..."
  if is_service; then
    systemctl daemon-reload || true
    systemctl start dxspider || true
  else
    log "No systemd service detected. Start manually with: ${DXSPATH}/perl/cluster.pl"
  fi
}

# ----------------------------
# Distro deps (minimal; keep your existing behavior)
# ----------------------------
check_distro_and_install_deps() {
  # Keep it simple: only ensure tools required by this updater exist.
  need_cmd git
  need_cmd sha256sum
  need_cmd gunzip
  need_cmd tar
  need_cmd rsync
}

# ----------------------------
# Bundle clone (deterministic history/tags)
# ----------------------------
verify_bundle_assets() {
  [[ -f "${BUNDLE_GZ}" ]] || die "Missing bundle: ${BUNDLE_GZ}"
  [[ -f "${BUNDLE_SHA}" ]] || die "Missing bundle checksum: ${BUNDLE_SHA}"

  log "Verifying bundle checksum..."
  ( cd "${ASSETS_DIR}" && sha256sum -c "$(basename "${BUNDLE_SHA}")" )
}

bundle_clone_to_tmp() {
  local tmpdir bundle_file
  tmpdir="$(mktemp -d)"
  chmod 0755 "${tmpdir}"

  log "Preparing temporary clone directory: ${tmpdir}"
  cp -f "${BUNDLE_GZ}" "${tmpdir}/spider.bundle.gz"
  cp -f "${BUNDLE_SHA}" "${tmpdir}/spider.bundle.gz.sha256"

  ( cd "${tmpdir}" && sha256sum -c "spider.bundle.gz.sha256" )
  gunzip -f "${tmpdir}/spider.bundle.gz"
  bundle_file="${tmpdir}/spider.bundle"

  log "Cloning from bundle (full history/tags) ..."
  rm -rf "${tmpdir}/src"
  git clone "${bundle_file}" "${tmpdir}/src"

  if [[ "${FORCE_BRANCH}" == "1" ]]; then
    ( cd "${tmpdir}/src" && git checkout -f "${BRANCH}" || git checkout -b "${BRANCH}" "origin/${BRANCH}" )
  else
    ( cd "${tmpdir}/src" && git checkout "${BRANCH}" >/dev/null 2>&1 || git checkout -b "${BRANCH}" "origin/${BRANCH}" )
  fi

  echo "${tmpdir}"
}

print_build_info() {
  local repo="$1"
  if [[ -d "${repo}/.git" ]]; then
    local version build commit
    version="$(cd "${repo}" && git describe --tags --long --always 2>/dev/null || true)"
    build="$(cd "${repo}" && git rev-list --count HEAD 2>/dev/null || true)"
    commit="$(cd "${repo}" && git rev-parse --short HEAD 2>/dev/null || true)"
    log "Build info: version=${version} build=${build} commit=${commit}"
  fi
}

# ----------------------------
# Preserve local state + update code
# ----------------------------
preserve_state() {
  local backup_dir="$1"
  mkdir -p "${backup_dir}"

  if [[ "${KEEP_LOCAL}" == "1" ]]; then
    log "Preserving local state (local/, local_cmd/, cmd_import/, local_data/) ..."
    tar -C "${DXSPATH}" -czf "${backup_dir}/local_state.tgz"       --ignore-failed-read       local local_cmd cmd_import local_data 2>/dev/null || true
  fi

  if [[ "${KEEP_DATA_COPY}" == "1" ]]; then
    log "Copying data/* -> local_data/ (original updater behavior) ..."
    mkdir -p "${DXSPATH}/local_data"
    cp -a "${DXSPATH}/data/." "${DXSPATH}/local_data/." 2>/dev/null || true
  fi

  if [[ -f "${DXSPATH}/local/DXVars.pm" ]]; then
    cp -a "${DXSPATH}/local/DXVars.pm" "${backup_dir}/DXVars.pm" || true
  fi
}

restore_state() {
  local backup_dir="$1"

  if [[ "${KEEP_LOCAL}" == "1" && -f "${backup_dir}/local_state.tgz" ]]; then
    log "Restoring local state ..."
    tar -C "${DXSPATH}" -xzf "${backup_dir}/local_state.tgz" || true
  fi

  if [[ -f "${backup_dir}/DXVars.pm" ]]; then
    mkdir -p "${DXSPATH}/local"
    cp -a "${backup_dir}/DXVars.pm" "${DXSPATH}/local/DXVars.pm" || true
  fi
}

update_tree_from_tmp() {
  local tmpdir="$1"
  local src="${tmpdir}/src"
  local backup_dir="${tmpdir}/preserve"

  [[ -d "${src}" ]] || die "Temporary source directory missing: ${src}"

  stop_spider
  preserve_state "${backup_dir}"

  log "Updating code in-place at ${DXSPATH} ..."
  rsync -a --delete     --exclude '/local/'     --exclude '/local_cmd/'     --exclude '/cmd_import/'     --exclude '/local_data/'     "${src}/" "${DXSPATH}/"

  restore_state "${backup_dir}"

  log "Fixing ownership/permissions..."
  chown -R "${OWNER}:${GROUP}" "${DXSPATH}" || true
  find "${DXSPATH}" -type d -exec chmod 2775 {} \; || true
  find "${DXSPATH}" -type f -exec chmod 0664 {} \; || true
  if [[ -d "${DXSPATH}/perl" ]]; then
    find "${DXSPATH}/perl" -type f -name "*.pl" -exec chmod 0775 {} \; 2>/dev/null || true
    find "${DXSPATH}/perl" -type f -name "*dbg" -exec chmod 0775 {} \; 2>/dev/null || true
  fi

  ln -sfn "${DXSPATH}" /spider

  print_build_info "${DXSPATH}"

  start_spider
  log "Update completed."
}

# ----------------------------
# UI / flow (kept similar)
# ----------------------------
welcome() {
  clear || true
  echo -e " "
  echo -e "==============================================================="
  echo -e " "
  echo -e "DXSpider alternative updater (bundle-based)"
  echo -e " "
  echo -e "This updater preserves local configuration and user DB files"
  echo -e "and updates the code deterministically from the bundled Git history."
  echo -e " "
  echo -e "Bundle: ${BUNDLE_GZ}"
  echo -e "Branch: ${BRANCH}"
  echo -e " "
  echo -e "==============================================================="
  echo -e " "

  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    : "${DXSPATH:?NONINTERACTIVE=1 requires DXSPATH}"
    : "${OPTION:?NONINTERACTIVE=1 requires OPTION=U|R|Q}"
    return 0
  fi

  read -n 1 -s -r -p $'Press any key to continue ...'
  echo -e " "
  echo -e "Indicates path where DXSpider is installed."
  echo -n "For example: /home/spider or /home/sysop/spider or ... : "
  read -r DXSPATH
  echo -e " "
  echo -e "==============================================================="
  echo -e "To upgrade your DXSpider, press [U]"
  echo -e "To restore the backup, press [R] (legacy behavior)"
  echo -e "==============================================================="
  echo -e " "
  echo -n "Please enter [U]pdate, [R]estore o [Q]uit: "
  read -r OPTION
}

# Legacy restore path (kept, but optional)
BACKUP="false"
OLD_DXS_PATH=""
OLD_SERVICE_PATH=""

is_backup() {
  if [[ -d /home/spider.backup && -n "$(ls -A /home/spider.backup 2>/dev/null || true)" ]]; then
    BACKUP="true"
  else
    BACKUP="false"
  fi
}

make_config() {
  mkdir -p /home/spider.backup
  cat > /home/spider.backup/config.backup <<EOL
owner=${OWNER}
group=${GROUP}
old_type=service
old_dxs_path=${DXSPATH}
old_service_path=/etc/systemd/system/dxspider.service
EOL
}

read_config() {
  while IFS== read -r type value; do
    case "$type" in
      owner) OWNER="$value" ;;
      group) GROUP="$value" ;;
      old_dxs_path) OLD_DXS_PATH="$value" ;;
      old_service_path) OLD_SERVICE_PATH="$value" ;;
    esac
  done < /home/spider.backup/config.backup
}

run_restore() {
  [[ "${BACKUP}" == "true" ]] || die "No backup found in /home/spider.backup"
  stop_spider
  systemctl disable dxspider 2>/dev/null || true
  rm -rf "${DXSPATH}"
  mkdir -p "${OLD_DXS_PATH}"
  cp -r /home/spider.backup/spider "${OLD_DXS_PATH}/../"
  chown -R "${OWNER}:${GROUP}" "${OLD_DXS_PATH}" || true
  systemctl enable dxspider 2>/dev/null || true
  systemctl start dxspider 2>/dev/null || true
  log "Backup restored."
}

backup_legacy() {
  is_spider
  is_backup
  make_config
  stop_spider

  if [[ "${BACKUP}" == "true" ]]; then
    echo "A backup directory already exists."
    echo "Do you want to delete it? [Y/N] "
    read -r YESNO
    if [[ "${YESNO}" == "N" ]]; then
      echo "Using the current Backup."
      return 0
    elif [[ "${YESNO}" == "Y" ]]; then
      echo "Backup begins ..."
      rm -rf /home/spider.backup
      mkdir -p /home/spider.backup
      cp -r "${DXSPATH}" /home/spider.backup/spider
      return 0
    else
      die "Bye!"
    fi
  else
    mkdir -p /home/spider.backup
    cp -r "${DXSPATH}" /home/spider.backup/spider
  fi
}

main() {
  require_root
  check_distro_and_install_deps
  welcome

  case "${OPTION}" in
    U|u)
      is_spider
      log "Current installed tree build info (before):"
      print_build_info "${DXSPATH}"

      backup_legacy

      verify_bundle_assets
      tmpdir="$(bundle_clone_to_tmp)"
      log "Bundle clone build info (source):"
      print_build_info "${tmpdir}/src"

      update_tree_from_tmp "${tmpdir}"
      ;;
    R|r)
      is_backup
      read_config
      run_restore
      ;;
    Q|q)
      log "Bye."
      ;;
    *)
      die "Invalid option: ${OPTION}"
      ;;
  esac
}

main "$@"
