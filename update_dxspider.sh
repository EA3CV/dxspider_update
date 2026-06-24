#!/usr/bin/bash

#
# Script for UPDATE and DXSpider Cluster configuration
# Upgrade from Master or Mojo to the latest Mojo version
#
# Create By Kin, EA3CV and based on the code of Yiannis Panagou, SV5FRI
#
# E-mail: ea3cv@cronux.net
# Version 0.6.3
# Date 20260624
#

set -Eeuo pipefail

# --- Defaults (can be overridden via env) ---
: "${REPO_URL:=git://scm.dxspider.org/spider}"
: "${BRANCH:=mojo}"
: "${BACKUP_DIR:=/home/spider.backup}"
: "${TMP_BASE:=/tmp}"

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

trap 'die "Aborted at line $LINENO (command: $BASH_COMMAND)"' ERR

backup()
{
        is_spider
        is_service
        is_backup
        make_config

        # Check the repository before stopping or changing anything.
        preflight_repo

        stop_spider

        if [ "${BACKUP}" = "true" ]; then
                echo "A backup directory already exists."
                echo "Do you want to delete it? [Y/N] "
                read -r YESNO
                YESNO="${YESNO^^}"
                if [ "${YESNO}" = "N" ]; then
                        [ -f "${BACKUP_DIR}/config.backup.old" ] && mv "${BACKUP_DIR}/config.backup.old" "${BACKUP_DIR}/config.backup" || true
                        echo "Using the current Backup."
                elif [ "${YESNO}" = "Y" ]; then
                        echo " "
                        echo "Backup begins ..."
                        rm -rf "${BACKUP_DIR}"
                        mkdir -p "${BACKUP_DIR}"
                        [ -f "${OLD_SERVICE_PATH}" ] && cp -a "${OLD_SERVICE_PATH}" "${BACKUP_DIR}/dxspider.service" || true
                        cp -a "${DXSPATH}" "${BACKUP_DIR}/spider"
                else
                        echo "Bye!"
                        exit 1
                fi
        else
                echo " "
                echo "Backup begins ..."
                mkdir -p "${BACKUP_DIR}"
                [ -f "${OLD_SERVICE_PATH}" ] && cp -a "${OLD_SERVICE_PATH}" "${BACKUP_DIR}/dxspider.service" || true
                cp -a "${DXSPATH}" "${BACKUP_DIR}/spider"
        fi
}
# Function Check Distribution and Version
check_distro() {

        arch=$(uname -m)
        kernel=$(uname -r)
        if [ -f "/etc/os-release" ]; then
                # shellcheck disable=SC1091
                . /etc/os-release
                distroname="${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-}}"
                distro_id="${ID:-unknown}"
                version_id="${VERSION_ID:-}"
        elif [ -f "/etc/redhat-release" ]; then
                distroname=$(cat /etc/redhat-release)
                distro_id="rhel"
                version_id=""
        else
                distroname="$(uname -s) $(uname -r)"
                distro_id="unknown"
                version_id=""
        fi

        echo -e " "
        echo -e "==============================================================="
        echo -e "      Your OS distribution is ${distroname}"
        echo -e "=============================================================== "
        echo -e " "
        echo -e " "
        read -n 1 -s -r -p $'Press any key to continue...'
        echo -e " "

        case "${distro_id}:${version_id}" in
                debian:*|raspbian:*|ubuntu:*|linuxmint:*)
                        install_package_debian
                        ;;
                centos:7*|rhel:7*)
                        install_epel_7
                        install_package_CentOS_7
                        ;;
                centos:8*|rhel:8*|rocky:8*|fedora:*)
                        install_epel_8
                        install_package_CentOS_8
                        ;;
                *)
                        echo -e " "
                        echo -e "==============================================================="
                        echo -e "      Your OS distribution ${distroname} is not supported"
                        echo -e "=============================================================== "
                        echo -e " "
                        echo -e " "
                        exit 1
                        ;;
        esac
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
        echo -e " "
        echo -e "Checking repository reachability: ${REPO_URL}"
        if ! su - "$OWNER" -c "git ls-remote '${REPO_URL}' >/dev/null 2>&1"; then
                die "Repository is unreachable: ${REPO_URL}. Aborting to avoid breaking DXSpider."
        fi
}

# --- NEW: clone to temp + checkout branch ---
clone_to_temp()
{
        local tmpdir
        tmpdir="$(mktemp -d "${TMP_BASE}/dxspider.update.XXXXXX")"

        # The temporary directory is created by root, but git clone is run as
        # the DXSpider owner user. Give ownership to that user so it can create
        # the spider directory inside the temporary directory.
        chown "$OWNER:$GROUP" "$tmpdir"
        chmod 0755 "$tmpdir"

        # IMPORTANT:
        # This function is called as: tmpdir="$(clone_to_temp)".
        # Therefore, stdout must contain ONLY the final temporary path.
        # All progress messages and git output must go to stderr, otherwise
        # tmpdir gets polluted with text and rsync may interpret it as a remote host.
        echo -e "Cloning new DXSpider tree into: ${tmpdir}/spider" >&2
        su - "$OWNER" -c "git clone '${REPO_URL}' '${tmpdir}/spider'" >&2 || die "Unable to clone repository into ${tmpdir}/spider"

        su - "$OWNER" -c "cd '${tmpdir}/spider' && git fetch --all --tags --prune" >&2

        # Robust branch checkout:
        su - "$OWNER" -c "cd '${tmpdir}/spider' && (git checkout '${BRANCH}' || git checkout -B '${BRANCH}' 'origin/${BRANCH}')" >&2

        echo "$tmpdir"
}

# --- NEW: preserve local + local_data into new tree ---
preserve_runtime_data()
{
        local old="$1"
        local new="$2"

        # Preserve local/ if exists (DXVars.pm, Listeners.pm, etc.)
        if [ -d "${old}/local" ]; then
                echo "Preserving ${old}/local -> ${new}/local"
                mkdir -p "${new}/local"
                rsync -a "${old}/local/" "${new}/local/"
        fi

        # Preserve local_data/ if exists (user DB etc.)
        if [ -d "${old}/local_data" ]; then
                echo "Preserving ${old}/local_data -> ${new}/local_data"
                mkdir -p "${new}/local_data"
                rsync -a "${old}/local_data/" "${new}/local_data/"
        fi
}

# --- NEW: atomic-ish swap ---
swap_tree()
{
        local tmpdir="$1"
        local newtree="${tmpdir}/spider"
        local oldtree="${DXSPATH}"
        local ts
        ts="$(date +%Y%m%d%H%M%S)"
        local snapshot="${BACKUP_DIR}/spider.preupdate.${ts}"

        echo -e " "
        echo "Stopping service..."
        stop_spider

        echo "Saving pre-update snapshot to: ${snapshot}"
        mkdir -p "${BACKUP_DIR}"
        cp -a "${oldtree}" "${snapshot}"

        echo "Replacing ${oldtree} with new version..."
        rm -rf "${oldtree}"
        mkdir -p "$(dirname "${oldtree}")"
        mv "${newtree}" "${oldtree}"

        # Fix ownership/permissions similar to your original
        chown -R "$OWNER:$GROUP" "${oldtree}"
        cd "${oldtree}"
        find ./ -type d -exec chmod 2775 {} \;
        find ./ -type f -exec chmod 775 {} \;
}

config_app()
{
        echo "Fix up permissions"
        echo -e " "
        echo -e "Please use capital letters"
        echo -e " "

        cd "${DXSPATH}"

        # The tree has already been freshly cloned and checked out.
        # Do not run another pull here; it can introduce unrelated failures.
        su - "$OWNER" -c "cd '${DXSPATH}' && git status --short >/dev/null"

        chown -R "$OWNER:$GROUP" "${DXSPATH}"
        cd "${DXSPATH}"
        find ./ -type d -exec chmod 2775 {} \;
        find ./ -type f -exec chmod 775 {} \;

        su - "$OWNER" -c "mkdir -p '${DXSPATH}/local' '${DXSPATH}/cmd_import' '${DXSPATH}/local_cmd' '${DXSPATH}/local_data'"

        # Only copy DXVars.pm.issue if DXVars doesn't exist
        if [ ! -f "${DXSPATH}/local/DXVars.pm" ]; then
                su - "$OWNER" -c "cp '${DXSPATH}/perl/DXVars.pm.issue' '${DXSPATH}/local/DXVars.pm'"
        fi

        insert_cluster_call
        insert_call
        insert_name
        insert_email
        insert_locator
        insert_qth

        echo -e "Now create basic user file"
        su - "$OWNER" -c "'${DXSPATH}/perl/create_sysop.pl'"
        echo -e " "
        echo -e "Installation has been finished."
        echo -e "Now login as ${OWNER} user."
        echo -e "Start application and check if everything is ok with: ${DXSPATH}/perl/cluster.pl"
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
install_epel_7()
{
        yum -y install epel-release || true
}

# Install extra packages for CentOS 7.x
install_package_CentOS_7()
{
        echo -e "Starting Installation Dxspider Cluster"
        echo -e " "
        yum -y install perl git gcc make rsync perl-TimeDate perl-Time-HiRes perl-Digest-SHA1 perl-Curses perl-Net-Telnet perl-Data-Dumper perl-DB_File perl-ExtUtils-MakeMaker perl-Digest-MD5 perl-Digest-SHA perl-IO-Compress curl libnet-cidr-lite-perl
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
        dnf -y install perl git gcc make rsync perl-TimeDate perl-Time-HiRes perl-Curses perl-Net-Telnet perl-Data-Dumper perl-DB_File perl-ExtUtils-MakeMaker perl-Digest-MD5 perl-IO-Compress perl-Digest-SHA perl-Net-CIDR-Lite curl libnet-cidr-lite-perl
}

## Debian & raspbian
#
install_package_debian()
{
        echo -e "Starting Installation Dxspider Cluster"
        echo -e " "
        apt-get update
        apt-get -y install perl rsync libtimedate-perl libnet-telnet-perl libcurses-perl libdigest-sha-perl libdata-dumper-simple-perl git libjson-perl libmojolicious-perl  libdata-structure-util-perl libmath-round-perl libev-perl libjson-xs-perl build-essential procps libnet-cidr-lite-perl curl
}

# Enter CallSign for cluster
insert_cluster_call()
{
        echo -n "Please enter CallSign for DxCluster: "
        chr="\""
        read -r DXCALL
        echo "${DXCALL}"
        DXCALL_ESC=$(sed_escape "${DXCALL}")
        su - "$OWNER" -c "sed -i 's/mycall =.*/mycall = ${chr}${DXCALL_ESC}${chr};/' '${DXSPATH}/local/DXVars.pm'"
}

# Enter your CallSign
insert_call()
{
        echo -n "Please enter your CallSign: "
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
        echo -n "Please enter your E-mail Address(syntax like your\\@email.com): "
        chr="\""
        read -r EMAIL
        echo "${EMAIL}"
        EMAIL_ESC=$(sed_escape "${EMAIL}")
        su - "$OWNER" -c "sed -i 's/myemail =.*/myemail = ${chr}${EMAIL_ESC}${chr};/' '${DXSPATH}/local/DXVars.pm'"
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

is_service()
{
        STATUS=$(systemctl is-active dxspider 2>/dev/null || true)

        if [ "${STATUS}" = "active" ] || [ "${STATUS}" = "inactive" ] || [ "${STATUS}" = "failed" ]; then
                OLD_TYPE="service"
                OLD_SERVICE_PATH="/etc/systemd/system/dxspider.service"
                echo "DXSpider is using systemctl."
        else
                PID=$(pgrep -f cluster.pl | head -n 1 || true)
                OLD_TYPE="pid"
                echo "DXSpider has PID ${PID}"
        fi
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
                PID=$(pgrep -f cluster.pl | head -n 1 || true)
                echo "DXSpider has PID $PID"
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
                chown -R "$OWNER:$GROUP" "${OLD_DXS_PATH}"
                find ./ -type d -exec chmod 2775 {} \;
                find ./ -type f -exec chmod 775 {} \;

                if [ -f "${BACKUP_DIR}/dxspider.service" ]; then
                        cp -f "${BACKUP_DIR}/dxspider.service" "$OLD_SERVICE_PATH" || true
                fi
                systemctl daemon-reload || true
                systemctl enable dxspider || true
                systemctl restart dxspider || true
                echo "Backup restored."
                echo "DXSpider running."
                echo "Bye!"
        else
                echo "Error in ${BACKUP_DIR}/config.backup"
                echo "Bye."
        fi
}

stop_spider()
{
        if [ "${OLD_TYPE}" = "pid" ]; then
                [ -z "${PID}" ] && PID=$(pgrep -f cluster.pl | head -n 1 || true)
                [ -n "${PID}" ] && kill -9 "${PID}" || true
        else
                systemctl stop dxspider || true
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
        tmpdir="$(clone_to_temp)"
        preserve_runtime_data "${DXSPATH}" "${tmpdir}/spider"
        swap_tree "${tmpdir}"
        rm -rf "${tmpdir}" || true

        # Perl deps (best effort)
        curl -fsSL https://cpanmin.us | perl - App::cpanminus || true
        cpanm EV Mojolicious JSON JSON::XS Data::Structure::Util Math::Round || true

        echo -e " "
}

welcome()
{
        clear
        echo -e " "
        echo -e "==============================================================="
        echo -e " "
        echo -e "This script update will make a Backup of the current DXSpider"
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

                backup
                check_distro

                # Keep your original local_data copy (but safe with mkdir -p)
                mkdir -p "${DXSPATH}/local_data"
                if [ -d "${DXSPATH}/data" ]; then
                        cp -a "${DXSPATH}/data/." "${DXSPATH}/local_data/." || true
                fi

                update_spider
                config_app
                create_service
                enable_service

                echo -e " "
                echo -e "==============================================================="
                echo -e "                      DXSpider Updated"
                echo -e "==============================================================="
                echo -e " "

        elif [ "${OPTION}" == "R" ]; then
                echo -e " "
                echo -e "==============================================================="
                echo -e "                     Restore DXSpider..."
                echo -e "==============================================================="
                echo -e " "

                is_backup
                read_config
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
