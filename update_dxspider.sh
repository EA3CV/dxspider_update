#!/usr/bin/bash

#
# Script for UPDATE and DXSpider Cluster configuration
# Upgrade from Master or Mojo to the latest Mojo version
#
# Create By Kin, EA3CV and based on the code of Yiannis Panagou, SV5FRI
#
# E-mail: ea3cv@cronux.net
# Version 0.6.1
# Date 20260601
#

set -Eeuo pipefail

# --- Defaults (can be overridden via env) ---
: "${REPO_URL:=https://scm.dxcluster.org/scm/spider}"   # safer than git:// (often blocked)
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

trap 'die "Aborted at line $LINENO (command: $BASH_COMMAND)"' ERR

backup()
{
        is_spider
        is_service
        is_backup
        make_config
        stop_spider

        if [ "${BACKUP}" = "true" ]; then
                echo "A backup directory already exists."
                echo "Do you want to delete it? [Y/N] "
                read -r YESNO
                if [ "${YESNO}" = "N" ]; then
                        stop_spider
                        [ -f "${BACKUP_DIR}/config.backup.old" ] && mv "${BACKUP_DIR}/config.backup.old" "${BACKUP_DIR}/config.backup" || true
                        echo "Using the current Backup."
                elif [ "${YESNO}" = "Y" ]; then
                        echo " "
                        echo "Backup begins ..."
                        stop_spider
                        rm -rf "${BACKUP_DIR}"
                        mkdir -p "${BACKUP_DIR}"
                        [ -f "${OLD_SERVICE_PATH}" ] && mv "${OLD_SERVICE_PATH}" "${BACKUP_DIR}/dxspider.service" || true
                        cp -a "${DXSPATH}" "${BACKUP_DIR}/spider"
                else
                        echo "Bye!"
                        exit 1
                fi
        else
                # If no backup existed, create it now
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
                distroname=$(grep PRETTY_NAME /etc/os-release | sed 's/PRETTY_NAME=//g' | tr -d '="')
        elif [ -f "/etc/redhat-release" ]; then
                distroname=$(cat /etc/redhat-release)
        else
                distroname="$(uname -s) $(uname -r)"
        fi

        echo -e " "
        echo -e "==============================================================="
        echo -e "      Your OS distribution is ${distroname}"
        echo -e "=============================================================== "
        echo -e " "
        echo -e " "
        read -n 1 -s -r -p $'Press any key to continue...'
        echo -e " "

        if [ "${distroname}" == "CentOS Linux 7 (Core)" ]; then
                                install_epel_7
                                install_package_CentOS_7
                        elif [ "${distroname}" == "CentOS Linux 8 (Core)" ]; then
                                install_epel_8
                                install_package_CentOS_8
                        elif [ "${distroname}" == "Rocky Linux 8.5 (Green Obsidian)" ]; then
                                install_epel_8
                                install_package_CentOS_8
                        elif [ "${distroname}" == "Raspbian GNU/Linux 8 (jessie)" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Raspbian GNU/Linux 9 (stretch)" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Debian GNU/Linux 9 (stretch)" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Raspbian GNU/Linux 10 (buster)" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Debian GNU/Linux 10 (buster)" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Raspbian GNU/Linux 11 (bullseye)" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Raspbian GNU/Linux 13 (trixie)" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Raspbian GNU/Linux 12 (bookworm)" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Debian GNU/Linux 11 (bullseye)" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Debian GNU/Linux 12 (bookworm)" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Debian GNU/Linux 13 (trixie)" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Ubuntu 20.04.6 LTS" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Ubuntu 22.04 LTS" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Ubuntu 22.04.1 LTS" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Ubuntu 22.04.2 LTS" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Ubuntu 22.04.3 LTS" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Ubuntu 22.04.4 LTS" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Ubuntu 22.04.5 LTS" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Ubuntu 24.04.2 LTS" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Ubuntu 26.04 LTS" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Fedora Linux 39 (Server Edition)" ]; then
                                install_epel_8
                                install_package_CentOS_8
                        elif [ "${distroname}" == "Fedora Linux 39 (Workstation Edition)" ]; then
                                install_epel_8
                                install_package_CentOS_8
                        elif [ "${distroname}" == "Debian GNU/Linux bookworm/sid" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Linux Mint 21.1" ]; then
                                install_package_debian
                        elif [ "${distroname}" == "Linux Mint 21.3" ]; then
                                install_package_debian
                else
                        echo -e " "
                        echo -e "==============================================================="
                        echo -e "      Your OS distribution ${distroname} is not supported"
                        echo -e "=============================================================== "
                        echo -e " "
                        echo -e " "
            exit 1
        fi
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
        chmod 0755 "$tmpdir"

        echo -e "Cloning new DXSpider tree into: ${tmpdir}/spider"
        su - "$OWNER" -c "git clone '${REPO_URL}' '${tmpdir}/spider'"

        su - "$OWNER" -c "cd '${tmpdir}/spider' && git fetch --all --tags --prune"

        # Robust branch checkout:
        su - "$OWNER" -c "cd '${tmpdir}/spider' && (git checkout '${BRANCH}' || git checkout -B '${BRANCH}' 'origin/${BRANCH}')"

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
        # Fix up permissions ( AS THE SYSOP USER )
        echo "Fix up permissions"
        echo -e " "
        echo -e "Please use capital letters"
        echo -e " "

        cd "${DXSPATH}"

        # These operations can fail if already on mojo; make them robust
        su - "$OWNER" -c "cd '${DXSPATH}' && git reset --hard"
        su - "$OWNER" -c "cd '${DXSPATH}' && git pull --ff-only || git pull"

        # robust checkout for branch
        su - "$OWNER" -c "cd '${DXSPATH}' && (git checkout '${BRANCH}' || git checkout -B '${BRANCH}' 'origin/${BRANCH}' || true)"

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
        su - "$OWNER" -c "/spider/perl/create_sysop.pl"
        echo -e " "
        echo -e "Installation has been finished."
        echo -e "Now login as sysop user.\nStart application and check if everything is ok with follow command /spider/perl/cluster.pl"
}

create_service()
{
        echo -e " "
        echo -e "Now make configuration for systemd dxspider service"
        echo -e " "

        if [ -f "/etc/systemd/system/dxspider.service" ]; then
                echo "Files dxspider.service exist"
                # Normalize possible old bug: ExecStart= /path  -> ExecStart=/path
                sed -i -E 's/^ExecStart=[[:space:]]+/ExecStart=/' /etc/systemd/system/dxspider.service || true
        else
                cat > /etc/systemd/system/dxspider.service <<EOL
[Unit]
Description=Dxspider DXCluster service
After=network.target

[Service]
Type=simple
User=$OWNER
Group=$GROUP
ExecStart=/usr/bin/perl -w /spider/perl/cluster.pl
# Comment out line below for logging everything to /var/log/messages
StandardOutput=null
Restart=always

[Install]
WantedBy=multi-user.target
EOL
        fi

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
        yum check-update ; yum -y update
        yum -y install epel-release
}

# Install extra packages for CentOS 7.x
install_package_CentOS_7()
{
        echo -e "Starting Installation Dxspider Cluster"
        echo -e " "
        yum check-update ; yum -y update
        yum -y install perl git gcc make perl-TimeDate perl-Time-HiRes perl-Digest-SHA1 perl-Curses perl-Net-Telnet perl-Data-Dumper perl-DB_File perl-ExtUtils-MakeMaker perl-Digest-MD5 perl-Digest-SHA perl-IO-Compress curl libnet-cidr-lite-perl
        cpanm install Curses
}

## CentOS 8.x
#
install_epel_8()
{
        echo -e "Starting Installation Dxspider Cluster"
        echo -e " "
        dnf makecache --refresh
        dnf check-update ; dnf -y update
        dnf -y install epel-release
}

# Install extra packages for CentOS 8.x
install_package_CentOS_8()
{
        dnf check-update ; dnf -y update
        dnf -y install perl git gcc make perl-TimeDate perl-Time-HiRes perl-Curses perl-Net-Telnet perl-Data-Dumper perl-DB_File perl-ExtUtils-MakeMaker perl-Digest-MD5 perl-IO-Compress perl-Digest-SHA perl-Net-CIDR-Lite curl libnet-cidr-lite-perl
}

## Debian & raspbian
#
install_package_debian()
{
        echo -e "Starting Installation Dxspider Cluster"
        echo -e " "
        apt-get update ; apt-get -y upgrade
        apt-get -y install perl libtimedate-perl libnet-telnet-perl libcurses-perl libdigest-sha-perl libdata-dumper-simple-perl git libjson-perl libmojolicious-perl  libdata-structure-util-perl libmath-round-perl libev-perl libjson-xs-perl build-essential procps libnet-cidr-lite-perl curl
}

# Enter CallSign for cluster
insert_cluster_call()
{
        echo -n "Please enter CallSign for DxCluster: "
        chr="\""
        read -r DXCALL
        echo "${DXCALL}"
        su - "$OWNER" -c "sed -i 's/mycall =.*/mycall = ${chr}${DXCALL}${chr};/' /spider/local/DXVars.pm"
}

# Enter your CallSign
insert_call()
{
        echo -n "Please enter your CallSign: "
        chr="\""
        read -r SELFCALL
        echo "${SELFCALL}"
        su - "$OWNER" -c "sed -i 's/myalias =.*/myalias = ${chr}${SELFCALL}${chr};/' /spider/local/DXVars.pm"
}

# Enter your Name
insert_name()
{
        echo -n "Please enter your Name: "
        chr="\""
        read -r MYNAME
        echo "${MYNAME}"
        su - "$OWNER" -c "sed -i 's/myname =.*/myname = ${chr}${MYNAME}${chr};/' /spider/local/DXVars.pm"
}

# Enter your E-mail
insert_email()
{
        echo -n "Please enter your E-mail Address(syntax like your\\@email.com): "
        chr="\""
        read -r EMAIL
        echo "${EMAIL}"
        su - "$OWNER" -c "sed -i 's/myemail =.*/myemail = ${chr}${EMAIL}${chr};/' /spider/local/DXVars.pm"
}

# Enter your mylocator
insert_locator()
{
        echo -n "Please enter your Locator(Use Capital Letter): "
        chr="\""
        read -r MYLOCATOR
        echo "${MYLOCATOR}"
        su - "$OWNER" -c "sed -i 's/mylocator =.*/mylocator = ${chr}${MYLOCATOR}${chr};/' /spider/local/DXVars.pm"
}

# Enter your myqth
insert_qth()
{
        echo -n "Please enter your QTH(use comma without space): "
        chr="\""
        read -r MYQTH
        echo "${MYQTH}"
        su - "$OWNER" -c "sed -i 's/myqth =.*/myqth = ${chr}${MYQTH}${chr};/' /spider/local/DXVars.pm"

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
        if [ -f "$DXSPATH/perl/cluster.pl" ]; then
                echo "Getting owner and group ..."
                OWNER=$(stat -c '%U' "$DXSPATH/perl/cluster.pl")
                GROUP=$(stat -c '%G' "$DXSPATH/perl/cluster.pl")
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
                rm -rf "${DXSPATH}"
                mkdir -p "${OLD_DXS_PATH}"
                cp -a "${BACKUP_DIR}/spider" "$(dirname "${OLD_DXS_PATH}")/"
                cd "${OLD_DXS_PATH}"
                chown -R "$OWNER:$GROUP" "${OLD_DXS_PATH}"
                find ./ -type d -exec chmod 2775 {} \;
                find ./ -type f -exec chmod 775 {} \;

                cp -f "${BACKUP_DIR}/dxspider.service" "$OLD_SERVICE_PATH" || true
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
        if [ "${OLD_TYPE}" = "pid" ] && [ -n "${PID}" ]; then
                kill -9 "${PID}" || true
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

        preflight_repo

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
