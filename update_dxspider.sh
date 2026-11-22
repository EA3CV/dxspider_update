#!/usr/bin/bash

#
# Script for UPDATE and DXSpider Cluster configuration
# Upgrade from Master or Mojo to the latest Mojo version
#
# Create By Kin, EA3CV and based on the code of Yiannis Panagou, SV5FRI
#
# E-mail: ea3cv@cronux.net
# Version 0.6.22
# Date 20261122
#

set -Eeuo pipefail

# --- Defaults (can be overridden via env) ---
: "${REPO_URL:=git://scm.dxcluster.org/spider}"
: "${BACKUP_REPO_URL:=https://github.com/EA3CV/dxspider.git}"
: "${BRANCH:=mojo}"
: "${BACKUP_DIR:=/home/spider.backup}"
# Optional override; by default stage beside the selected DXSpider tree.
: "${TMP_BASE:=}"

# --- Globals used by original script ---
DXSPATH=""
OWNER=""
GROUP=""
BACKUP="false"
OLD_TYPE=""
OLD_SERVICE_PATH="/etc/systemd/system/dxspider.service"
OLD_DXS_PATH=""
PID=""
STATUS=""

die() { echo -e "ERROR: $*" >&2; exit 1; }
log() { echo -e "$*"; }
sed_escape() { printf '%s' "$1" | sed -e 's/[\\\/&]/\\&/g'; }

# Only updater-created staging paths are eligible for cleanup.
UPDATE_TMP_ACTIVE=""
cleanup_update_temp()
{
        # Remove only the exact staging directory registered by this run.
        # Reject symlinks, nested paths and names outside mktemp's pattern.
        if [ -n "${UPDATE_TMP_ACTIVE}" ] &&
           [ -d "${UPDATE_TMP_ACTIVE}" ] &&
           [ ! -L "${UPDATE_TMP_ACTIVE}" ] &&
           [ "$(dirname -- "${UPDATE_TMP_ACTIVE}")" = "${TMP_BASE}" ] &&
           [[ "$(basename -- "${UPDATE_TMP_ACTIVE}")" =~ ^dxspider\.update\.[[:alnum:]]{6}$ ]]; then
                if ! rm -rf -- "${UPDATE_TMP_ACTIVE}"; then
                        echo "ERROR: unable to remove updater staging directory ${UPDATE_TMP_ACTIVE}" >&2
                        return 1
                fi
        elif [ -n "${UPDATE_TMP_ACTIVE}" ] && [ -e "${UPDATE_TMP_ACTIVE}" ]; then
                echo "ERROR: unsafe updater staging path; preserved ${UPDATE_TMP_ACTIVE}" >&2
                return 1
        fi
        return 0
}
# Transaction state: never discard the only surviving previous tree.
SWAP_HELD_ACTIVE=""
UPDATE_FINISHED=0
BACKUP_STAGE_ACTIVE=""
BACKUP_PREVIOUS_ACTIVE=""
DXSPIDER_WAS_ACTIVE=0
BACKUP_REQUESTED=1
UPDATE_TRANSACTION_STARTED=0
WEB_STOPPED=()
ORIGINAL_SERVICE_SNAPSHOT=""
ORIGINAL_SERVICE_EXISTED=0
cleanup_update_exit()
{
        local rc=$? failed_tree="" rollback_ok=1
        trap - ERR EXIT
        set +e
        if [ -n "${SWAP_HELD_ACTIVE}" ] && [ "${UPDATE_FINISHED}" -ne 1 ]; then
                # Keep both trees and diagnostics for inspection after any rollback.
                local rollback_staging="${UPDATE_TMP_ACTIVE}"
                echo "ERROR: update failed after replacing DXSpider; restoring the original tree" >&2
                if [ "${OLD_TYPE}" = "service" ]; then
                        systemctl stop dxspider.service >&2 || true
                fi
                # Move the incomplete new tree aside; never remove it before restoring.
                failed_tree="${UPDATE_TMP_ACTIVE}/failed-new-spider"
                if [ -e "${failed_tree}" ]; then rollback_ok=0; fi
                if [ "${rollback_ok}" -eq 1 ] && [ -e "${DXSPATH}" ] && ! mv -- "${DXSPATH}" "${failed_tree}"; then
                        rollback_ok=0
                fi
                if [ "${rollback_ok}" -eq 1 ] && mv -- "${SWAP_HELD_ACTIVE}" "${DXSPATH}"; then
                        SWAP_HELD_ACTIVE=""
                        if [ "${OLD_TYPE}" = "service" ]; then
                                if [ "${ORIGINAL_SERVICE_EXISTED}" -eq 1 ]; then
                                        cp -a -- "${ORIGINAL_SERVICE_SNAPSHOT}" "${OLD_SERVICE_PATH}" || rollback_ok=0
                                else
                                        rm -f -- "${OLD_SERVICE_PATH}" || rollback_ok=0
                                fi
                                systemctl daemon-reload || rollback_ok=0
                                if [ "${DXSPIDER_WAS_ACTIVE}" -eq 1 ]; then
                                        systemctl restart dxspider.service || rollback_ok=0
                                fi
                        fi
                        if [ "${rollback_ok}" -eq 1 ]; then
                                echo "Original DXSpider tree restored at ${DXSPATH}" >&2
                        else
                                echo "WARNING: original tree restored, but service recovery needs inspection" >&2
                        fi
                else
                        rollback_ok=0
                fi
                if [ "${rollback_ok}" -ne 1 ]; then
                        echo "CRITICAL: automatic recovery incomplete; inspect ${DXSPATH}" >&2
                fi
                echo "Rollback diagnostics preserved at ${rollback_staging}" >&2
                UPDATE_TMP_ACTIVE=""
        fi
        if [ -n "${BACKUP_STAGE_ACTIVE}" ] && [ -d "${BACKUP_STAGE_ACTIVE}" ]; then
                rm -rf -- "${BACKUP_STAGE_ACTIVE}" || true
        fi
        if [ -n "${BACKUP_PREVIOUS_ACTIVE}" ] && [ -d "${BACKUP_PREVIOUS_ACTIVE}" ]; then
                if [ ! -e "${BACKUP_DIR}" ]; then
                        mv -- "${BACKUP_PREVIOUS_ACTIVE}" "${BACKUP_DIR}" || true
                else
                        echo "WARNING: older backup preserved at ${BACKUP_PREVIOUS_ACTIVE}" >&2
                fi
        fi
        # Restore the service state on failures even before the tree swap.
        if [ "${UPDATE_FINISHED}" -ne 1 ] && [ "${UPDATE_TRANSACTION_STARTED}" -eq 1 ]; then
                if [ -n "${SWAP_HELD_ACTIVE}" ]; then
                        echo "CRITICAL: original tree is not restored; services will remain stopped" >&2
                        rollback_ok=0
                elif [ "${OLD_TYPE}" = "service" ]; then
                        if [ "${ORIGINAL_SERVICE_EXISTED}" -eq 1 ] && [ -f "${ORIGINAL_SERVICE_SNAPSHOT}" ]; then
                                cp -a -- "${ORIGINAL_SERVICE_SNAPSHOT}" "${OLD_SERVICE_PATH}" || rollback_ok=0
                        elif [ "${ORIGINAL_SERVICE_EXISTED}" -eq 0 ]; then
                                rm -f -- "${OLD_SERVICE_PATH}" || rollback_ok=0
                        fi
                        systemctl daemon-reload || rollback_ok=0
                        if [ "${DXSPIDER_WAS_ACTIVE}" -eq 1 ]; then
                                systemctl restart dxspider.service || rollback_ok=0
                        else
                                systemctl stop dxspider.service || rollback_ok=0
                        fi
                fi
                local web_service
                if [ "${rollback_ok}" -eq 1 ]; then
                        for web_service in "${WEB_STOPPED[@]}"; do
                                systemctl start "$web_service" || rollback_ok=0
                        done
                fi
                if [ "${rollback_ok}" -ne 1 ]; then
                        echo "CRITICAL: recovery requires manual inspection" >&2
                        rc=1
                fi
        fi
        if [ -n "${ORIGINAL_SERVICE_SNAPSHOT}" ] && [ -f "${ORIGINAL_SERVICE_SNAPSHOT}" ]; then
                rm -f -- "${ORIGINAL_SERVICE_SNAPSHOT}" || true
        fi
        if ! cleanup_update_temp; then
                echo "WARNING: staging cleanup incomplete; manual inspection required" >&2
                [ "${rc}" -ne 0 ] || rc=1
        fi
        return "${rc}"
}
trap 'cleanup_update_exit' EXIT
trap 'die "Aborted at line $LINENO (command: $BASH_COMMAND)"' ERR

check_update_staging_space()
{
        local install_kb runtime_kb=0 required_kb available_kb deficit_kb backup_kb=0 part
        if [ -z "${TMP_BASE}" ]; then
                TMP_BASE="$(dirname -- "${DXSPATH}")"
        fi
        [ -d "${TMP_BASE}" ] || die "Temporary base directory does not exist: ${TMP_BASE}"
        [ -w "${TMP_BASE}" ] || die "Temporary base directory is not writable: ${TMP_BASE}"
        TMP_BASE="$(realpath -e -- "${TMP_BASE}")" || die "Cannot resolve temporary base directory"
        [ "$(stat -c %d -- "${DXSPATH}")" = "$(stat -c %d -- "${TMP_BASE}")" ] ||
                die "Staging and DXSpider must be on the same filesystem"
        install_kb="$(du -sk -- "${DXSPATH}" | awk '{print $1}')"
        for part in local local_data connect scripts local_cmd; do
                if [ -d "${DXSPATH}/${part}" ]; then
                        runtime_kb=$((runtime_kb + $(du -sk -- "${DXSPATH}/${part}" | awk '{print $1}')))
                fi
        done
        # Staged Git tree, runtime copy, filesystem headroom. Original tree
        # stays in place (renamed, not copied) for rollback.
        required_kb=$((install_kb + runtime_kb + 524288))
        available_kb="$(df -Pk -- "${TMP_BASE}" | awk 'END {print $4}')"
        [[ "${available_kb}" =~ ^[0-9]+$ ]] || die "Cannot determine free space on ${TMP_BASE}"
        echo "Update staging: required $(( (required_kb+1023)/1024 )) MiB; available $((available_kb/1024)) MiB"
        if (( available_kb < required_kb )); then
                deficit_kb=$((required_kb-available_kb))
                die "Insufficient disk space: missing $(( (deficit_kb+1023)/1024 )) MiB. Existing DXSpider untouched."
        fi
        if [ "${BACKUP_REQUESTED}" -eq 1 ]; then
                local parent backup_available
                parent="$(realpath -e -- "$(dirname -- "${BACKUP_DIR}")")" || die "Backup parent unavailable"
                backup_available="$(df -Pk -- "${parent}" | awk 'END {print $4}')"
                backup_kb=$((install_kb + 262144))
                # If both destinations share a filesystem, reserve both at once.
                if [ "$(stat -c %d -- "${parent}")" = "$(stat -c %d -- "${TMP_BASE}")" ]; then
                        backup_kb=$((backup_kb + required_kb))
                fi
                echo "Backup filesystem: required $(( (backup_kb+1023)/1024 )) MiB; available $((backup_available/1024)) MiB"
                if (( backup_available < backup_kb )); then
                        deficit_kb=$((backup_kb-backup_available))
                        die "Insufficient disk space for backup and update: missing $(( (deficit_kb+1023)/1024 )) MiB. Existing DXSpider untouched."
                fi
        fi
}


backup()
{
        local parent stage previous metadata
        is_spider
        is_service
        if [ "${OLD_TYPE}" = "pid" ]; then
                require_manual_spider_stopped
        fi
        is_backup
        preflight_repo

        # Never overwrite the only rollback copy in place.
        [ -n "${BACKUP_DIR}" ] && [ "${BACKUP_DIR}" != "/" ] || die "Unsafe BACKUP_DIR"
        [ "${BACKUP_DIR}" != "${DXSPATH}" ] || die "Backup equals installation"
        case "${BACKUP_DIR}/" in "${DXSPATH}/"*) die "Backup is inside installation" ;; esac
        case "${DXSPATH}/" in "${BACKUP_DIR}/"*) die "Installation is inside backup" ;; esac
        [ ! -L "${BACKUP_DIR}" ] || die "Backup directory must not be a symlink"
        parent="$(realpath -e -- "$(dirname -- "${BACKUP_DIR}")")" || die "Backup parent missing"
        BACKUP_DIR="${parent%/}/$(basename -- "${BACKUP_DIR}")"
        if [ "${BACKUP}" = "true" ]; then
                echo "A backup exists at ${BACKUP_DIR}. Replace it with a fresh rollback copy? [Y/N]"
                read -r YESNO
                case "${YESNO^^}" in
                        N)
                                [ -f "${BACKUP_DIR}/spider/perl/cluster.pl" ] || die "Existing backup incomplete"
                                [ -f "${BACKUP_DIR}/config.backup" ] || die "Existing backup metadata missing"
                                echo "Using the current Backup."
                                return 0
                                ;;
                        Y) ;;
                        *) die "Invalid backup response" ;;
                esac
        fi

        # Space for the replacement backup must be available before stopping.
        local required_kb available_kb
        required_kb="$(du -sk -- "${DXSPATH}" | awk '{print $1}')"
        available_kb="$(df -Pk -- "${parent}" | awk 'END {print $4}')"
        (( available_kb >= required_kb + 262144 )) || die "Not enough space for safe backup replacement"

        if [ "${OLD_TYPE}" = "service" ] && [ "$(systemctl is-active dxspider.service 2>/dev/null || true)" = "active" ]; then
                DXSPIDER_WAS_ACTIVE=1
        fi
        stop_spider
        stage="$(mktemp -d "${parent%/}/dxspider.backup-build.XXXXXX")"
        BACKUP_STAGE_ACTIVE="${stage}"
        # Failures before installation remove only the newly built staging copy.
        # The snapshot is made as the actual DXSpider Unix account, not root.
        # The parent and staging directory remain managed by root; only this
        # private staging directory is delegated to the owner.
        chown -- "$OWNER:$GROUP" "$stage"
        chmod 0700 "$stage"
        if ! runuser -u "$OWNER" -- cp -a -- "${DXSPATH}" "${stage}/spider"; then
                rm -rf -- "${stage}"
                die "Backup copy failed; previous backup preserved"
        fi
        if [ ! -f "${stage}/spider/perl/cluster.pl" ]; then
                rm -rf -- "${stage}"
                die "Backup validation failed; previous backup preserved"
        fi
        if [ -f "${OLD_SERVICE_PATH}" ]; then
                if ! cp -a -- "${OLD_SERVICE_PATH}" "${stage}/dxspider.service"; then
                        rm -rf -- "${stage}"
                        die "Service backup failed; previous backup preserved"
                fi
        fi
        if ! cat > "${stage}/config.backup" <<EOL
owner=$OWNER
group=$GROUP
old_type=$OLD_TYPE
old_dxs_path=$DXSPATH
old_service_path=$OLD_SERVICE_PATH
EOL
        then
                rm -rf -- "${stage}"
                die "Backup metadata failed; previous backup preserved"
        fi
        previous=""
        if [ -e "${BACKUP_DIR}" ]; then
                previous="$(mktemp -d "${parent%/}/dxspider.backup-old.XXXXXX")"
                rmdir -- "${previous}"
                if ! mv -- "${BACKUP_DIR}" "${previous}"; then
                        rm -rf -- "${stage}"
                        die "Cannot preserve previous backup"
                fi
                BACKUP_PREVIOUS_ACTIVE="${previous}"
        fi
        if ! mv -- "${stage}" "${BACKUP_DIR}"; then
                if [ -n "${previous}" ] && mv -- "${previous}" "${BACKUP_DIR}"; then
                        BACKUP_PREVIOUS_ACTIVE=""
                fi
                die "Cannot activate new backup; previous copy at ${previous:-$BACKUP_DIR}"
        fi
        BACKUP_STAGE_ACTIVE=""
        if [ -n "${previous}" ]; then
                rm -rf -- "${previous}" || die "New backup ready; old backup cleanup failed"
                BACKUP_PREVIOUS_ACTIVE=""
        fi
        echo "Fresh rollback backup ready: ${BACKUP_DIR}/spider"
}

# Distribution lookup: one configuration entry per OS family.
# RPM 8/9 remain separate because their package actions differ.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

normalize_distro()
{
        local distro_id="$1" version="$2" major
        major="${version%%.*}"
        case "$distro_id" in
                ubuntu|linuxmint|debian|raspbian|fedora)
                        [[ "$major" =~ ^[0-9]+$ ]] || return 1
                        case "$distro_id" in
                                ubuntu) printf 'Ubuntu %s\n' "$major" ;;
                                linuxmint) printf 'Linux Mint %s\n' "$major" ;;
                                debian) printf 'Debian GNU/Linux %s\n' "$major" ;;
                                raspbian) printf 'Raspbian GNU/Linux %s\n' "$major" ;;
                                fedora) printf 'Fedora Linux %s\n' "$major" ;;
                        esac ;;
                zorin) printf 'zorin\n' ;;
                centos|rocky|almalinux)
                        [[ "$major" =~ ^[0-9]+$ ]] || return 1
                        case "$major" in
                                8|9) ;;
                                *) return 1 ;;
                        esac
                        case "$distro_id" in
                                centos) printf 'CentOS Linux %s\n' "$major" ;;
                                rocky) printf 'Rocky Linux %s\n' "$major" ;;
                                almalinux) printf 'AlmaLinux %s\n' "$major" ;;
                        esac ;;
                *) return 1 ;;
        esac
}

check_distro()
{
        local distro_id="" version_id="" distroname="" distro_key="" actions="" action=""
        local distro_file="${SCRIPT_DIR}/distro_actions.conf"
        local -a action_list=()

        if [ -f /etc/os-release ]; then
                # shellcheck disable=SC1091
                . /etc/os-release
                distro_id="${ID:-}"
                version_id="${VERSION_ID:-}"
                distroname="${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-}}"
        elif [ -f /etc/redhat-release ]; then
                distroname="$(cat /etc/redhat-release)"
                die "Missing /etc/os-release; cannot safely determine distribution ID/version: ${distroname}"
        else
                die "Missing /etc/os-release"
        fi

        distro_key="$(normalize_distro "$distro_id" "$version_id")" || die "Unsupported distribution: ${distroname}"
        [ -f "$distro_file" ] || die "Missing distribution actions: $distro_file"
        # Exact family lookup. The config deliberately contains no minor
        # versions or release codenames; never use a prefix match here.
        actions="$(awk -F, -v key="$distro_key" '
                function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
                /^[[:space:]]*(#|$)/ { next }
                NF >= 2 && trim($1) == key { print trim($2); exit }
        ' "$distro_file")"
        [ -n "$actions" ] || die "Unsupported distribution: ${distroname} (normalized: ${distro_key})"

        IFS=';' read -r -a action_list <<< "$actions"
        # Validate every action before installing any packages.
        for action in "${action_list[@]}"; do
                action="${action#"${action%%[![:space:]]*}"}"
                action="${action%"${action##*[![:space:]]}"}"
                case "$action" in
                        install_epel_8|install_epel_9|install_package_CentOS_8|install_package_Rocky_9|install_package_debian)
                                declare -F "$action" >/dev/null || die "Package action not implemented: $action" ;;
                        *) die "Invalid package action: $action" ;;
                esac
        done

        # Preflight validates the OS and its actions without changing packages.
        if [ "${1:-}" = "validate" ]; then
                echo "Validated OS: ${distroname} (matched: ${distro_key})"
                return 0
        fi

        echo "Detected OS: ${distroname}"
        echo "Matched OS: ${distro_key}"
        echo "Package actions: ${actions}"
        read -n 1 -s -r -p $'Press any key to continue...'
        echo
        for action in "${action_list[@]}"; do
                action="${action#"${action%%[![:space:]]*}"}"
                action="${action%"${action##*[![:space:]]}"}"
                "$action"
        done
}

# Check the script is being run by root user
check_run_user()
{
        if [ "$(id -u)" != "0" ]; then
                echo "This script must be run as root" 1>&2
                exit 1
        fi
}

# --- NEW: Preflight repo reachable ---
preflight_repo()
{
        echo "Checking Dirk repository: ${REPO_URL}"
        if su - "$OWNER" -c "git ls-remote '${REPO_URL}' 'refs/heads/${BRANCH}'" 2>/dev/null | grep -q .; then
                return 0
        fi
        echo "Dirk repository unavailable; checking GitHub backup: ${BACKUP_REPO_URL}"
        su - "$OWNER" -c "git ls-remote '${BACKUP_REPO_URL}' 'refs/heads/${BRANCH}'" 2>/dev/null | grep -q . || die "Neither repository provides branch ${BRANCH}; aborting before stopping DXSpider"
}

# --- NEW: clone to temp + checkout branch ---
clone_to_temp()
{
        local tmpdir="$1"

        # The temporary directory is created by root, but git clone is run as
        # the DXSpider owner user. Give ownership to that user so it can create
        # the spider directory inside the temporary directory.
        chown "$OWNER:$GROUP" "$tmpdir"
        chmod 0755 "$tmpdir"

        # Run in the main shell: failures must preserve the EXIT cleanup trap.
        echo -e "Cloning new DXSpider tree into: ${tmpdir}/spider" >&2
        if ! su - "$OWNER" -c "git clone --branch '${BRANCH}' '${REPO_URL}' '${tmpdir}/spider'" >&2; then
                echo "Dirk clone failed; trying GitHub backup: ${BACKUP_REPO_URL}" >&2
                rm -rf "${tmpdir}/spider"
                if ! su - "$OWNER" -c "git clone --branch '${BRANCH}' '${BACKUP_REPO_URL}' '${tmpdir}/spider'" >&2; then
                        die "Both repositories failed; existing installation untouched"
                fi
        fi

        # Robust branch checkout:
        if ! su - "$OWNER" -c "cd '${tmpdir}/spider' && (git checkout '${BRANCH}' || git checkout -B '${BRANCH}' 'origin/${BRANCH}')" >&2; then
                die "Git checkout failed; existing installation untouched"
        fi

}

# Preserve site-owned runtime directories, without following symlinks.
preserve_runtime_data()
{
        local old="$1" new="$2" part
        if [ -n "$(manual_spider_pids)" ]; then
                die "DXSpider process detected during runtime copy; SQLite snapshot would be unsafe"
        fi
        for part in local local_data connect scripts local_cmd; do
                if [ -L "${old}/${part}" ]; then
                        die "Refusing to migrate symlinked runtime directory: ${old}/${part}"
                fi
                if [ -e "${old}/${part}" ] && [ ! -d "${old}/${part}" ]; then
                        die "Runtime path is not a directory: ${old}/${part}"
                fi
                if [ -d "${old}/${part}" ]; then
                        echo "Preserving ${old}/${part} -> ${new}/${part}"
                        # The installed runtime tree is authoritative. Remove
                        # upstream copies first to avoid retaining stale files.
                        if [ -e "${new}/${part}" ] || [ -L "${new}/${part}" ]; then
                                rm -rf -- "${new}/${part}"
                        fi
                        mkdir -- "${new}/${part}"
                        rsync -a -- "${old}/${part}/" "${new}/${part}/" ||
                                die "Unable to preserve ${part}"
                fi
        done
}

# --- NEW: atomic-ish swap ---
swap_tree()
{
        local tmpdir="$1"
        local newtree="${tmpdir}/spider"
        local oldtree="${DXSPATH}"
        local held="${tmpdir}/previous-spider"
        [ -d "${newtree}" ] || die "Staged tree missing"
        [ ! -e "${held}" ] || die "Unexpected previous tree"
        [ "$(stat -c %d -- "${oldtree}")" = "$(stat -c %d -- "${tmpdir}")" ] || die "Staging must be on the same filesystem"
        stop_spider
        mv -- "${oldtree}" "${held}"
        SWAP_HELD_ACTIVE="${held}"
        if ! mv -- "${newtree}" "${oldtree}"; then
                mv -- "${held}" "${oldtree}" || die "CRITICAL: old installation preserved at ${held}"
                SWAP_HELD_ACTIVE=""
                die "New tree activation failed; original restored"
        fi
        # Preserve original runtime permissions; do not alter the home directory.
}

config_app()
{
        # This is an UPDATE, not a fresh installation. Never prompt for
        # identity fields or invoke create_sysop.pl: it can delete and recreate
        # DXUser records, losing passwords and persistent attributes.
        [ -f "${DXSPATH}/local/DXVars.pm" ] ||
                die "Existing DXVars.pm missing after migration; refusing to reinitialize SYSOP"
        [ -d "${DXSPATH}/local_data" ] ||
                die "Existing local_data missing after migration; refusing to reinitialize SYSOP"
        echo "Existing DXSpider configuration and SYSOP database preserved."
}

create_service()
{
        echo -e " "
        echo -e "Now make configuration for systemd dxspider service"
        echo -e " "

        # Always write the service with the real DXSpider path selected by the user.
        # The old service is already saved in the backup directory before this point.
        cat > /etc/systemd/system/dxspider.service <<EOL
[Unit]
Description=Dxspider DXCluster service
After=network.target

[Service]
Type=simple
User=$OWNER
Group=$GROUP
ExecStart=/usr/bin/perl -w ${DXSPATH}/perl/cluster.pl
# Comment out line below for logging everything to /var/log/messages
StandardOutput=null
Restart=always

[Install]
WantedBy=multi-user.target
EOL

        systemctl daemon-reload || true
        echo -e " "
}

enable_service()
{
        echo -e "Enable Dxspider Service to start up"
        echo -e " "
        systemctl enable dxspider
        systemctl restart dxspider
        systemctl --no-pager --full status dxspider || true
}

## CentOS 7.x
#
# Dependency inventory from Guia_DXS_ES / Guide_DXS_EN (DXSpider ea3cv).
# Validate the full inventory before replacing the running tree. Avoid CPAN
# installs for modules already supplied by the distribution.
DXS_REQUIRED_MODULES=(
        EV Mojolicious JSON JSON::XS Data::Structure::Util Math::Round
        Net::CIDR::Lite DBI DBD::SQLite Date::Parse HTML::Parser
        IO::Socket::INET6 Archive::Zip Curses Mail::Internet Digest::SHA
        LWP::UserAgent LWP::Parallel::UserAgent DB_File IO::Pty
        Authen::SASL Net::SMTP::SSL Email::Sender
)

ensure_extra_perl_modules()
{
        local module
        local -a missing=()
        perl -e 'die "Perl >= 5.16.1 required\n" if $] < 5.016001' || die "Perl version is too old"
        for module in "${DXS_REQUIRED_MODULES[@]}"; do
                if ! perl -M"$module" -e 1 >/dev/null 2>&1; then
                        missing+=("$module")
                fi
        done
        if [ "${#missing[@]}" -gt 0 ]; then
                log "Missing Perl modules: ${missing[*]}"
                command -v cpanm >/dev/null 2>&1 || die "cpanm unavailable; install cpanminus and retry"
                # CPAN fallback only for missing modules; do not suppress failures.
                for module in "${missing[@]}"; do
                        log "Installing missing Perl module: $module"
                        cpanm "$module" || die "CPAN installation failed: $module"
                done
        fi
        for module in "${DXS_REQUIRED_MODULES[@]}"; do
                perl -M"$module" -e 1 >/dev/null 2>&1 || die "Missing required Perl module after installation: $module"
        done
        perl -MMojolicious -e 'Mojolicious->VERSION(7.26)' >/dev/null 2>&1 || die "Mojolicious >= 7.26 required"
        log "DXSpider Perl dependency verification: OK"
}

install_epel_7()
{
        yum -y install epel-release || true
}

# Install extra packages for CentOS 7.x
install_package_CentOS_7()
{
        echo -e "Starting Installation Dxspider Cluster"
        echo -e " "
        yum -y install perl git gcc make rsync perl-TimeDate perl-Time-HiRes perl-Curses perl-Net-Telnet perl-Data-Dumper perl-DB_File perl-ExtUtils-MakeMaker perl-Digest-MD5 perl-Digest-SHA perl-IO-Compress curl libnet-cidr-lite-perl perl-DBI perl-DBD-SQLite
        command -v cpanm >/dev/null 2>&1 && cpanm Curses || true
}

## CentOS 8.x
#
install_epel_8()
{
        echo -e "Starting Installation Dxspider Cluster"
        echo -e " "
        dnf makecache --refresh
        dnf -y install epel-release || true
}

# Install extra packages for CentOS 8.x
install_package_CentOS_8()
{
        dnf -y install perl git gcc make rsync perl-TimeDate perl-Time-HiRes perl-Curses perl-Net-Telnet perl-Data-Dumper perl-DB_File perl-ExtUtils-MakeMaker perl-Digest-MD5 perl-IO-Compress perl-Digest-SHA perl-Net-CIDR-Lite curl libnet-cidr-lite-perl perl-DBI perl-DBD-SQLite perl-App-cpanminus openssl-devel zlib-devel
        dnf -y install perl-DBI perl-DBD-SQLite perl-Email-Sender perl-IO-Tty || true
}

## Debian & raspbian
#
# Rocky Linux 9 / AlmaLinux 9 (Fedora uses package action only).
install_epel_9()
{
        dnf -y install epel-release
}

install_package_Rocky_9()
{
        dnf -y install perl git gcc make rsync perl-TimeDate perl-Time-HiRes perl-Curses perl-Net-Telnet perl-Data-Dumper perl-DB_File perl-ExtUtils-MakeMaker perl-Digest-MD5 perl-IO-Compress perl-Digest-SHA perl-Net-CIDR-Lite curl perl-DBI perl-DBD-SQLite perl-App-cpanminus openssl-devel zlib-devel
        dnf -y install perl-DBI perl-DBD-SQLite perl-Email-Sender perl-IO-Tty || true
}

install_package_debian()
{
        echo -e "Starting Installation Dxspider Cluster"
        echo -e " "
        apt-get update
        apt-get -y install perl git rsync curl iproute2 gzip procps build-essential cpanminus libssl-dev zlib1g-dev \
                libtimedate-perl libnet-telnet-perl libcurses-perl libdigest-sha-perl \
                libdata-dumper-simple-perl libjson-perl libmojolicious-perl \
                libdata-structure-util-perl libmath-round-perl libev-perl \
                libjson-xs-perl libnet-cidr-lite-perl libdbi-perl \
                libdbd-sqlite3-perl libhtml-parser-perl \
                libio-socket-inet6-perl libarchive-zip-perl libmailtools-perl \
                libwww-perl libio-pty-perl \
                libauthen-sasl-perl libnet-smtp-ssl-perl libemail-sender-perl
}

ensure_userdsn()
{
        local file="${DXSPATH}/local/DXVars.pm"
        perl -0pi -e 'if (!/^\s*our \$userdsn\s*=/m) { s/\n1;\s*\z/\nour \$userdsn = "dbi:SQLite:dbname=\$root\/local_data\/dxusers.db";\n\n1;\n/ or die "DXVars.pm: final 1; not found\n" }' "$file"
        chown "${OWNER}:${GROUP}" "$file"
}

# Add the registration section from the NEW upstream DXVars.pm.issue only when absent.
# Never replace existing SYSOP registration settings or merge a partial block.
ensure_registration_config()
{
        local file="${DXSPATH}/local/DXVars.pm"
        local template="${DXSPATH}/perl/DXVars.pm.issue"
        [ -f "$file" ] || die "Missing $file"
        [ -f "$template" ] || die "Missing $template"

        perl - "$file" "$template" <<'PERL'
use strict;
use warnings;
use File::Copy qw(copy);
my ($target, $template) = @ARGV;
sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read $path: $!\n";
    local $/;
    return <$fh>;
}
my $current = slurp($target);
my $issue = slurp($template);
my @names = qw(reg_enable reg_password_length reg_template_dir
               reg_email_enable reg_email_smtp reg_email_port reg_email_user
               reg_email_pass reg_email_from reg_email_admin
               reg_telegram_enable reg_telegram_token reg_telegram_chatid);
my @present = grep { $current =~ /^\s*(?:our\s+)?\$\Q$_\E\s*=/m } @names;
if (@present == @names) {
    print "Registration configuration already present; unchanged\n";
    exit 0;
}
if (@present) {
    die "DXVars.pm contains partial registration configuration (" . join(', ', @present) . "); refusing to overwrite or duplicate; inspect manually\n";
}
my $start = index($issue, '# DXSpider registration configuration');
die "Registration section missing from $template\n" if $start < 0;
my $end = index($issue, "\n1;", $start);
die "Registration section terminator missing from $template\n" if $end < 0;
my $block = substr($issue, $start, $end - $start);
for my $name (@names) {
    die "Missing $name in template\n" unless $block =~ /^\s*(?:our\s+)?\$\Q$name\E\s*=/m;
}
my $dsn = qr/^\s*our\s+\$userdsn\s*=.*?;[^\n]*(?:\n|\z)/m;
my @dsn_matches = ($current =~ /($dsn)/g);
die "Expected a single userdsn assignment in $target\n" unless @dsn_matches == 1;
$current =~ s/($dsn)/$1\n$block\n/ or die "Could not insert registration section\n";
die "DXVars.pm lacks final 1;\n" unless $current =~ /\n1;\s*\z/;
my $backup = "$target.pre-registration.bak";
die "Backup already exists: $backup; refusing to overwrite\n" if -e $backup;
copy($target, $backup) or die "Cannot create $backup: $!\n";
my $temp = "$target.registration.tmp.$$";
open my $fh, '>', $temp or die "Cannot write $temp: $!\n";
print {$fh} $current or die "Cannot write $temp: $!\n";
close $fh or die "Cannot close $temp: $!\n";
my @st = stat($target);
chmod($st[2] & 07777, $temp) or die "chmod $temp: $!\n";
chown($st[4], $st[5], $temp) or die "chown $temp: $!\n";
rename($temp, $target) or die "Cannot replace $target: $!\n";
print "Registration section inserted from DXVars.pm.issue; backup: $backup\n";
PERL
}

# Enter CallSign for cluster
insert_cluster_call()
{
        echo -n "Please enter your DXCluster NODE callsign: "
        chr="\""
        read -r DXCALL
        echo "${DXCALL}"
        DXCALL_ESC=$(sed_escape "${DXCALL}")
        su - "$OWNER" -c "sed -i 's/mycall =.*/mycall = ${chr}${DXCALL_ESC}${chr};/' '${DXSPATH}/local/DXVars.pm'"
}

# Enter your CallSign
insert_call()
{
        echo -n "Please enter your SYSOP callsign: "
        chr="\""
        read -r SELFCALL
        echo "${SELFCALL}"
        SELFCALL_ESC=$(sed_escape "${SELFCALL}")
        su - "$OWNER" -c "sed -i 's/myalias =.*/myalias = ${chr}${SELFCALL_ESC}${chr};/' '${DXSPATH}/local/DXVars.pm'"
}

# Enter your Name
insert_name()
{
        echo -n "Please enter your Name: "
        chr="\""
        read -r MYNAME
        echo "${MYNAME}"
        MYNAME_ESC=$(sed_escape "${MYNAME}")
        su - "$OWNER" -c "sed -i 's/myname =.*/myname = ${chr}${MYNAME_ESC}${chr};/' '${DXSPATH}/local/DXVars.pm'"
}

# Enter your E-mail
insert_email()
{
        echo -n "Please enter your E-mail Address (e.g. your@email.com, no backslash): "
        read -r EMAIL
        echo "${EMAIL}"
        EMAIL_VALUE="${EMAIL}" perl -i -pe '
          BEGIN { $v = $ENV{EMAIL_VALUE}; $v =~ s/\\@/@/g; $v =~ s/\\/\\\\/g; $v =~ s/\x27/\\\x27/g; }
          s/^(\s*(?:our\s+)?\$?myemail\s*=\s*).*(;\s*)$/${1}\x27$v\x27${2}/;
        ' "${DXSPATH}/local/DXVars.pm"
        chown "$OWNER:$GROUP" "${DXSPATH}/local/DXVars.pm"
}
# Enter your mylocator
insert_locator()
{
        echo -n "Please enter your Locator(Use Capital Letter): "
        chr="\""
        read -r MYLOCATOR
        echo "${MYLOCATOR}"
        MYLOCATOR_ESC=$(sed_escape "${MYLOCATOR}")
        su - "$OWNER" -c "sed -i 's/mylocator =.*/mylocator = ${chr}${MYLOCATOR_ESC}${chr};/' '${DXSPATH}/local/DXVars.pm'"
}

# Enter your myqth
insert_qth()
{
        echo -n "Please enter your QTH(use comma without space): "
        chr="\""
        read -r MYQTH
        echo "${MYQTH}"
        MYQTH_ESC=$(sed_escape "${MYQTH}")
        su - "$OWNER" -c "sed -i 's/myqth =.*/myqth = ${chr}${MYQTH_ESC}${chr};/' '${DXSPATH}/local/DXVars.pm'"

        echo -e " "
        echo -e "================================================================="
        echo -e "                         ATTENTION"
        echo -e " "
        echo -e "It is recommended that if you want to keep the user database,"
        echo -e "answer \"N\" when asked:"
        echo -e " "
        echo -e "Do you wish to destroy your user database (THINK!!!) [y/N]: N"
        echo -e " "
        echo -e "As the Node data will be requested again, the following question"
        echo -e "must be answered with a \"Y\":"
        echo -e " "
        echo -e "Do you wish to reset your cluster and sysop information? [y/N]: Y"
        echo -e " "
        echo -e "================================================================="
        echo -e " "
}

is_backup()
{
        if [ -d "${BACKUP_DIR}" ] && [ -n "$(ls -A "${BACKUP_DIR}" 2>/dev/null || true)" ]; then
                BACKUP="true"
                echo "Backup exists and is not empty."
        else
                BACKUP="false"
                echo "Backup does not exist."
        fi
}

# Find a running cluster.pl belonging to the exact installation selected by the SYSOP.
# A matching process blocks an unattended update; it is never killed here.
manual_spider_pids()
{
        local target pid proc arg cwd candidate cmd exe
        local -a argv=()
        target=$(readlink -f -- "${DXSPATH}/perl/cluster.pl") || return 1
        for proc in /proc/[0-9]*; do
                [ -r "${proc}/cmdline" ] || continue
                pid=${proc##*/}
                argv=()
                mapfile -d '' -t argv < "${proc}/cmdline" 2>/dev/null || continue
                cwd=$(readlink -- "${proc}/cwd" 2>/dev/null || true)
                # /proc/PID/cwd may refer to a renamed/deleted directory after
                # an earlier updater swap. Do not rely solely on realpath.
                for arg in "${argv[@]}"; do
                        case "$arg" in
                                cluster.pl|./cluster.pl|*/cluster.pl)
                                        candidate=""
                                        if [[ "$arg" = /* ]]; then
                                                candidate=$(readlink -f -- "$arg" 2>/dev/null || true)
                                        elif [ -n "$cwd" ]; then
                                                candidate=$(readlink -f -- "${cwd}/${arg}" 2>/dev/null || true)
                                        fi
                                        if [ "$candidate" = "$target" ] ||
                                           [[ "$cwd" = "${DXSPATH}/perl" || "$cwd" = "${DXSPATH}/perl (deleted)" || "$cwd" = "${DXSPATH}/perl/"* ]] ||
                                           [[ "$cwd" = *"/previous-spider/perl"* || "$cwd" = *"/failed-new-spider/perl"* ]]; then
                                                printf '%s\n' "$pid"
                                        else
                                                # Ambiguous cluster.pl: refuse to copy an
                                                # active SQLite database rather than guess.
                                                printf '%s\n' "$pid"
                                        fi
                                        break ;;
                        esac
                done
        done
}

require_manual_spider_stopped()
{
        local pids
        pids=$(manual_spider_pids) || die "Cannot inspect DXSpider processes; update cancelled"
        if [ -n "$pids" ]; then
                echo "===============================================================" >&2
                echo "DXSpider is running manually at: ${DXSPATH}" >&2
                echo "Process PID(s): ${pids//$'\n'/, }" >&2
                echo "Stop this DXSpider instance manually before updating." >&2
                echo "No processes have been stopped by the updater." >&2
                echo "===============================================================" >&2
                die "Manual DXSpider process is still running; update cancelled"
        fi
}

is_service()
{
        local load_state="" active_state="" manual_pids=""
        # A leftover unit file does not mean that the selected DXSpider tree
        # is managed by systemd. Never turn a manual instance into a service.
        manual_pids=$(manual_spider_pids) || die "Cannot inspect DXSpider processes"
        if command -v systemctl >/dev/null 2>&1; then
                load_state=$(systemctl show dxspider.service -p LoadState --value 2>/dev/null || true)
                active_state=$(systemctl is-active dxspider.service 2>/dev/null || true)
        fi
        STATUS="$active_state"
        if [ -n "$manual_pids" ] && [ "$active_state" != "active" ]; then
                OLD_TYPE="pid"
                echo "DXSpider is running manually; existing service unit will be ignored."
        elif [ "$load_state" = "loaded" ] && [ "$active_state" = "active" ]; then
                OLD_TYPE="service"
                echo "DXSpider is running under systemctl."
        else
                OLD_TYPE="pid"
                echo "DXSpider is in manual mode (systemd service inactive or absent)."
        fi
}

verify_dxspider_service()
{
        local i state mainpid
        # A transient systemd 'active' immediately after restart is insufficient.
        for i in 1 2 3 4 5; do
                sleep 1
                state=$(systemctl is-active dxspider.service 2>/dev/null || true)
                mainpid=$(systemctl show dxspider.service -p MainPID --value 2>/dev/null || true)
                if [ "$state" != "active" ] || ! [[ "$mainpid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$mainpid" 2>/dev/null; then
                        die "DXSpider service failed post-update verification (state=$state, PID=$mainpid)"
                fi
        done
        echo "DXSpider service verified active for 5 seconds."
}

is_spider()
{
        if [ -f "${DXSPATH}/perl/cluster.pl" ]; then
                echo "Getting owner and group ..."
                OWNER=$(stat -c '%U' "${DXSPATH}/perl/cluster.pl")
                GROUP=$(stat -c '%G' "${DXSPATH}/perl/cluster.pl")
        else
                echo "DXSpider is not installed where indicated."
                echo "Try again."
                echo "Bye!"
                exit 0
        fi
}

make_backup()
{
        # (kept for compatibility; not used in main flow)
        if [ "${BACKUP}" = "true" ]; then
                echo "A backup directory already exists."
                echo "Do you want to delete it? [Y/N] "
                read -r YESNO
                if [ "${YESNO}" = "Y" ]; then
                        echo " "
                        echo "Backup begins ..."
                        rm -rf "${BACKUP_DIR}"
                        cp -a "${DXSPATH}" "${BACKUP_DIR}/spider"
                else
                        echo "Using the current Backup."
                fi
        else
                echo "DXSpider manual process detection is handled by require_manual_spider_stopped"
        fi
}

make_config()
{
        mkdir -p "${BACKUP_DIR}"
        if [ -f "${BACKUP_DIR}/config.backup" ]; then
                mv "${BACKUP_DIR}/config.backup" "${BACKUP_DIR}/config.backup.old" || true
        fi

        cat > "${BACKUP_DIR}/config.backup" <<EOL
owner=$OWNER
group=$GROUP
old_type=$OLD_TYPE
old_dxs_path=$DXSPATH
old_service_path=$OLD_SERVICE_PATH
EOL
}

read_config()
{
        while IFS== read -r type value
        do
                if [ "$type" = "owner" ]; then
                        OWNER=$value
                        echo "$OWNER"
                elif [ "$type" = "group" ]; then
                        GROUP=$value
                        echo "$GROUP"
                elif [ "$type" = "old_type" ]; then
                        OLD_TYPE=$value
                        echo "$OLD_TYPE"
                elif [ "$type" = "old_dxs_path" ]; then
                        OLD_DXS_PATH=$value
                        echo "Restoring backup to $OLD_DXS_PATH"
                elif [ "$type" = "old_service_path" ]; then
                        OLD_SERVICE_PATH=$value
                        echo "$OLD_SERVICE_PATH"
                fi
        done < "${BACKUP_DIR}/config.backup"
}

run_restore()
{
        if [ "${BACKUP}" = "true" ]; then
                stop_spider
                systemctl disable dxspider || true

                rm -rf "${OLD_DXS_PATH}"
                mkdir -p "$(dirname "${OLD_DXS_PATH}")"
                cp -a "${BACKUP_DIR}/spider" "${OLD_DXS_PATH}"

                cd "${OLD_DXS_PATH}"
                # cp -a restores the backed-up ownership and permissions.

                if [ -f "${BACKUP_DIR}/dxspider.service" ]; then
                        cp -f "${BACKUP_DIR}/dxspider.service" "$OLD_SERVICE_PATH" || true
                fi
                systemctl daemon-reload || true
                if [ "${OLD_TYPE}" = "service" ]; then
                        systemctl restart dxspider || true
                fi
                echo "Backup restored."
                echo "Verify DXSpider startup using the original method."
                echo "Bye!"
        else
                echo "Error in ${BACKUP_DIR}/config.backup"
                echo "Bye."
        fi
}

stop_spider()
{
        if [ "${OLD_TYPE}" = "pid" ]; then
                require_manual_spider_stopped
        else
                if [ "${DXSPIDER_WAS_ACTIVE}" -eq 1 ]; then
                        systemctl stop dxspider.service || die "Unable to stop dxspider.service"
                fi
        fi
}

update_spider()
{
        # SAFE UPDATE:
        # - verify repo reachable
        # - clone to temp
        # - preserve local/local_data
        # - swap into DXSPATH
        # This avoids leaving system non-startable when repo unreachable.

        echo -e "Now starting to download application DxSpider (safe update)"
        echo -e " "

        local tmpdir
        check_update_staging_space
        tmpdir="$(mktemp -d "${TMP_BASE}/dxspider.update.XXXXXX")"
        UPDATE_TMP_ACTIVE="${tmpdir}"
        clone_to_temp "${tmpdir}"
        # A consistent SQLite copy requires a quiescent source. In manual
        # mode the operator must stop DXSpider; systemd mode stops it here.
        stop_spider
        # Recheck after stopping to catch a concurrent manual restart.
        if [ -n "$(manual_spider_pids)" ]; then
                die "A cluster.pl process is still running; refusing live database copy"
        fi
        preserve_runtime_data "${DXSPATH}" "${tmpdir}/spider"
        if [ -d "${DXSPATH}/data" ]; then
                mkdir -p "${tmpdir}/spider/local_data"
                cp -a -- "${DXSPATH}/data/." "${tmpdir}/spider/local_data/." ||
                        die "Unable to migrate legacy data into staging"
        fi
        swap_tree "${tmpdir}"
        # Keep staging and old installation until configuration and service succeed.

        # Dependencies were installed and verified before replacing DXSpider.

        echo -e " "
}

welcome()
{
        clear
        echo -e " "
        echo -e "==============================================================="
        echo -e " "
        echo -e "This script can make a Backup of the current DXSpider"
        echo -e "software in the ${BACKUP_DIR} directory"
        echo -e "Users, DB and configuration files will be maintained."
        echo -e " "
        echo -e "Only OS versions that have been verified will be supported."
        echo -e " "
        echo -e "==============================================================="
        echo -e " "
        read -n 1 -s -r -p $'Press any key to continue ...'
        echo -e " "
        echo -e "Indicates path where DXSpider is installed."
        echo -n "For example: /home/spider or /home/sysop/spider or ... : "
        read -r DXSPATH
        echo -e " "
        echo -e "==============================================================="
        echo -e "To upgrade your DXSpider, press [U]"
        echo -e "To restore the backup, press [R]"
        echo -e "==============================================================="
        echo -e " "
        echo -n "Please enter [U]pdate, [R]estore o [Q]uit: "
        read -r OPTION
        OPTION="${OPTION^^}"

        if [ "${OPTION}" == "U" ]; then
                echo -e " "
                echo -e "==============================================================="
                echo -e "                     Updating DXSpider..."
                echo -e "==============================================================="
                echo -e " "

                # Reject unsupported OS versions before stopping DXSpider.
                check_distro validate
                # Never stop a manually started DXSpider process automatically.
                is_spider
                is_service
                if [ "${OLD_TYPE}" = "pid" ]; then
                        require_manual_spider_stopped
                fi
                is_backup
                echo "Do you want to make a backup? (Recommended) [Y/n]: "
                read -r YESNO
                case "${YESNO^^}" in
                        ""|Y) BACKUP_REQUESTED=1 ;;
                        N) BACKUP_REQUESTED=0; echo "No permanent backup will be created or replaced." ;;
                        *) die "Invalid backup response" ;;
                esac
                # All capacity checks run before services are stopped or data changed.
                check_update_staging_space
                preflight_repo
                check_distro
                ensure_extra_perl_modules
                # The original tree is the temporary rollback source, even when
                # the user declines a persistent backup.
                if [ "${OLD_TYPE}" = "service" ] && [ "$(systemctl is-active dxspider.service 2>/dev/null || true)" = "active" ]; then
                        DXSPIDER_WAS_ACTIVE=1
                fi
                if [ -f "${OLD_SERVICE_PATH}" ]; then
                        ORIGINAL_SERVICE_EXISTED=1
                        ORIGINAL_SERVICE_SNAPSHOT="$(mktemp "${TMP_BASE}/dxspider.service.XXXXXX")"
                        cp -a -- "${OLD_SERVICE_PATH}" "${ORIGINAL_SERVICE_SNAPSHOT}"
                fi
                UPDATE_TRANSACTION_STARTED=1
                # Stop optional web services only when active; remember their state.
                if command -v systemctl >/dev/null 2>&1; then
                        for web_service in dxweb.service dxweb-admin.service; do
                                if [ "$(systemctl is-active "$web_service" 2>/dev/null || true)" = "active" ]; then
                                        WEB_STOPPED+=("$web_service")
                                        systemctl stop "$web_service" || die "Unable to stop $web_service"
                                fi
                        done
                fi
                if [ "${BACKUP_REQUESTED}" -eq 1 ]; then
                        backup
                fi
                # Avoid modifying the original runtime tree before commit.
                # The legacy data/ migration is performed in the staged tree.
                update_spider
                config_app
                ensure_userdsn
                ensure_registration_config
                # Preserve the original startup method and existing unit file.
                # Never create, enable or rewrite a service during an update.
                if [ "${OLD_TYPE}" = "service" ] && [ "${DXSPIDER_WAS_ACTIVE}" -eq 1 ]; then
                        systemctl restart dxspider.service || die "Unable to restart existing DXSpider service"
                        verify_dxspider_service
                else
                        echo "Manual startup mode preserved; DXSpider was not started by the updater."
                fi

                # The update has succeeded; the fresh rollback copy is already
                # available, so the old live tree is no longer needed.
                # Restore optional web services that were running before update.
                for web_service in "${WEB_STOPPED[@]}"; do
                        systemctl start "$web_service" || die "Unable to restart $web_service"
                done
                UPDATE_FINISHED=1
                # The installed tree and service are now committed. A cleanup
                # failure must be reported, not silently presented as success.
                cleanup_update_temp || die "Update installed but staging cleanup failed; inspect ${UPDATE_TMP_ACTIVE}"
                UPDATE_TMP_ACTIVE=""
                SWAP_HELD_ACTIVE=""

                echo -e " "
                echo -e "==============================================================="
                echo -e "                      DXSpider Updated"
                echo -e "==============================================================="
                echo ""
                echo "NOTICE: DXWeb and dxweb-admin services, if previously active,"
                echo "        have been restarted after successful update."
                echo "        Inactive web services were left inactive."
                echo -e " "

        elif [ "${OPTION}" == "R" ]; then
                echo -e " "
                echo -e "==============================================================="
                echo -e "                     Restore DXSpider..."
                echo -e "==============================================================="
                echo -e " "

                is_backup
                read_config
                # The saved mode can be stale; inspect the currently selected tree.
                DXSPATH="$OLD_DXS_PATH"
                is_spider
                is_service
                if [ "${OLD_TYPE}" = "pid" ]; then
                        require_manual_spider_stopped
                fi
                run_restore

        elif [ "${OPTION}" == "Q" ]; then
                echo -e " "
                echo -e "==============================================================="
                echo -e "                     Bye. See you next time"
                echo -e "==============================================================="
                echo -e " "
        fi
}

main()
{
        check_run_user
        welcome
}

main

exit 0
