#!/bin/bash

#
# Script for UPDATE and DXSpider Cluster configuration (deterministic bundle-based)
# Upgrade from Master or Mojo to the latest MOJO version shipped in this repository bundle.
#
# By Kin, EA3CV
#
# E-mail: ea3cv@cronux.net
# Version 0.6.6
# Date 20251222
#
# Notes:
# - Keeps original backup/restore functionality in /home/spider.backup
#   so version/build/commit (git describe / rev-list) are correct.
# - Does not leave any cloned "dx-spider" directory behind (uses a temp dir).
#

set -e

# -----------------------------
# Bundle assets (relative paths)
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS_DIR="${SCRIPT_DIR}/assets"
BUNDLE_GZ="${ASSETS_DIR}/spider.bundle.gz"
BUNDLE_SHA="${ASSETS_DIR}/spider.bundle.gz.sha256"

# -----------------------------
# Globals
# -----------------------------
OWNER=""
GROUP=""
DXSPATH=""
PID=""
STATUS=""
OLD_TYPE=""
OLD_SERVICE_PATH="/etc/systemd/system/dxspider.service"
OLD_DXS_PATH=""
BACKUP="false"

# -----------------------------
# Helpers
# -----------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

cleanup_tmp() {
    [ -n "${TMPDIR_UPDATE:-}" ] && [ -d "${TMPDIR_UPDATE:-}" ] && rm -rf "${TMPDIR_UPDATE:-}" 2>/dev/null || true
}
trap cleanup_tmp EXIT

# -----------------------------
# Check the script is being run by root user
# -----------------------------
check_run_user()
{
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" 1>&2
        exit 1
    fi
}

# -----------------------------
# Detect distro (kept as original)
# -----------------------------
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

# -----------------------------
# Install packages (kept as original)
# -----------------------------
install_epel_7()
{
        yum check-update ; yum -y update
        yum -y install epel-release
}

install_package_CentOS_7()
{
        echo -e "Starting Installation Dxspider Cluster"
        echo -e " "
        yum check-update ; yum -y update
        yum -y install perl git gcc make perl-TimeDate perl-Time-HiRes perl-Digest-SHA1 perl-Curses perl-Net-Telnet perl-Data-Dumper perl-DB_File perl-ExtUtils-MakeMaker perl-Digest-MD5 perl-Digest-SHA perl-IO-Compress curl libnet-cidr-lite-perl
        cpanm install Curses || true
}

install_epel_8()
{
        echo -e "Starting Installation Dxspider Cluster"
        echo -e " "
        dnf makecache --refresh || true
        dnf check-update ; dnf -y update
        dnf -y install epel-release || true
}

install_package_CentOS_8()
{
        dnf check-update ; dnf -y update
        dnf -y install perl git gcc make perl-TimeDate perl-Time-HiRes perl-Curses perl-Net-Telnet perl-Data-Dumper perl-DB_File perl-ExtUtils-MakeMaker perl-Digest-MD5 perl-IO-Compress perl-Digest-SHA perl-Net-CIDR-Lite curl libnet-cidr-lite-perl || true
}

install_package_debian()
{
        echo -e "Starting Installation Dxspider Cluster"
        echo -e " "
        apt-get update ; apt-get -y upgrade
        apt-get -y install perl libtimedate-perl libnet-telnet-perl libcurses-perl libdigest-sha-perl libdata-dumper-simple-perl git libjson-perl libmojolicious-perl libdata-structure-util-perl libmath-round-perl libev-perl libjson-xs-perl build-essential procps libnet-cidr-lite-perl curl rsync || true
}

# -----------------------------
# Backup / restore (kept, but fixed to ALWAYS create backup)
# -----------------------------
is_backup()
{
        if [ -d /home/spider.backup ] && [ ! -z "$(ls -A /home/spider.backup 2>/dev/null)" ]; then
                BACKUP="true"
                echo "Backup exists and is not empty."
        else
                BACKUP="false"
                echo "Backup does not exist or is empty."
        fi
}

make_config()
{
        mkdir -p /home/spider.backup
        if [ -f "/home/spider.backup/config.backup" ]; then
                mv /home/spider.backup/config.backup /home/spider.backup/config.backup.old || true
        fi
        cat > /home/spider.backup/config.backup <<EOL
owner=$OWNER
group=$GROUP
old_type=$OLD_TYPE
old_dxs_path=$DXSPATH
old_service_path=$OLD_SERVICE_PATH
EOL
}

backup()
{
        is_spider
        is_service
        is_backup
        make_config
        stop_spider

        if [ "${BACKUP}" = "true" ]; then
                echo "A backup directory already exists."
                echo "Do you want to delete it and create a new backup? [Y/N] "
                read YESNO
                if [ "${YESNO}" = "N" ]; then
                        echo "Using the current Backup."
                        return 0
                elif [ "${YESNO}" = "Y" ]; then
                        echo " "
                        echo "Backup begins ..."
                        rm -rf /home/spider.backup
                        mkdir -p /home/spider.backup
                else
                        echo "Bye!"
                        exit 1
                fi
        else
                mkdir -p /home/spider.backup
        fi

        if [ -f "${OLD_SERVICE_PATH}" ]; then
                cp -f "${OLD_SERVICE_PATH}" /home/spider.backup/dxspider.service || true
        fi

        rm -rf /home/spider.backup/spider 2>/dev/null || true
        cp -a "${DXSPATH}" /home/spider.backup/spider
}

read_config()
{
        while IFS== read -r type value
        do
                if [ "$type" = "owner" ]; then
                        OWNER=$value
                elif [ "$type" = "group" ]; then
                        GROUP=$value
                elif [ "$type" = "old_type" ]; then
                        OLD_TYPE=$value
                elif [ "$type" = "old_dxs_path" ]; then
                        OLD_DXS_PATH=$value
                        echo "Restoring backup to $OLD_DXS_PATH"
                elif [ "$type" = "old_service_path" ]; then
                        OLD_SERVICE_PATH=$value
                fi
        done < /home/spider.backup/config.backup
}

run_restore()
{
        if [ "${BACKUP}" = "true" ]; then
                stop_spider
                systemctl disable dxspider 2>/dev/null || true
                rm -rf "${DXSPATH}"
                mkdir -p "${OLD_DXS_PATH}"
                cp -a /home/spider.backup/spider "${OLD_DXS_PATH}/../"
                cd "${OLD_DXS_PATH}" || exit 1
                chown -R "$OWNER.$GROUP" "${OLD_DXS_PATH}" || true
                find ./ -type d -exec chmod 2775 {} \; || true
                find ./ -type f -exec chmod 0775 {} \; || true

                if [ -f "/home/spider.backup/dxspider.service" ]; then
                        cp -f /home/spider.backup/dxspider.service "$OLD_SERVICE_PATH" || true
                fi
                systemctl daemon-reload 2>/dev/null || true
                systemctl enable dxspider 2>/dev/null || true
                systemctl start dxspider 2>/dev/null || true
                echo "Backup restored."
                echo "DXSpider running."
                echo "Bye!"

        else
                echo "Error in /home/spider.backup/config.backup"
                echo "Bye."
        fi
}

# -----------------------------
# Detect service / spider
# -----------------------------
is_service()
{
        STATUS=$(systemctl is-active dxspider 2>/dev/null || true)

        if [ "$STATUS" = "active" ] || [ "$STATUS" = "inactive" ]; then
                OLD_TYPE="service"
                OLD_SERVICE_PATH="/etc/systemd/system/dxspider.service"
                echo "DXSpider is using systemctl."
                echo "DXSpider status: $STATUS"
        else
                PID=$(pgrep -f 'perl.*cluster\.pl' | head -n 1 || true)
                OLD_TYPE="pid"
                if [ -n "${PID:-}" ]; then
                        echo "DXSpider has the PID $PID"
                else
                        echo "DXSpider PID not found (may be stopped)."
                fi
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

stop_spider()
{
        if [ -n "${PID:-}" ]; then
                kill -9 "${PID}" 2>/dev/null || true
        else
                systemctl stop dxspider 2>/dev/null || true
        fi
}

# -----------------------------
# Deterministic update from bundle
# -----------------------------
verify_bundle_assets()
{
        [ -f "$BUNDLE_GZ" ] || die "Missing bundle: $BUNDLE_GZ"
        [ -f "$BUNDLE_SHA" ] || die "Missing bundle checksum: $BUNDLE_SHA"

        echo "Verifying bundle checksum..."
        ( cd "$ASSETS_DIR" && sha256sum -c "$(basename "$BUNDLE_SHA")" ) || die "Bundle checksum failed."
}

print_build_info()
{
        local repo="$1"
        if [ -d "${repo}/.git" ]; then
                local v b c
                v=$(su - "$OWNER" -c "cd '$repo' && git describe --tags --long --always 2>/dev/null" || true)
                b=$(su - "$OWNER" -c "cd '$repo' && git rev-list --count HEAD 2>/dev/null" || true)
                c=$(su - "$OWNER" -c "cd '$repo' && git rev-parse --short HEAD 2>/dev/null" || true)
                echo "version=${v} build=${b} commit=${c}"
        fi
}

update_spider()
{
        echo -e "Now starting deterministic update from bundle"
        echo -e " "

        verify_bundle_assets

        TMPDIR_UPDATE="$(mktemp -d /tmp/dxspider-update.XXXXXX)"
        mkdir -p "$TMPDIR_UPDATE"
        cp -f "$BUNDLE_GZ" "$TMPDIR_UPDATE/spider.bundle.gz"
        cp -f "$BUNDLE_SHA" "$TMPDIR_UPDATE/spider.bundle.gz.sha256"

        ( cd "$TMPDIR_UPDATE" && sha256sum -c "spider.bundle.gz.sha256" ) || die "Bundle checksum failed in tmp."
        gunzip -f "$TMPDIR_UPDATE/spider.bundle.gz"
        [ -f "$TMPDIR_UPDATE/spider.bundle" ] || die "Bundle decompression failed."

        rm -rf "$TMPDIR_UPDATE/src"
        git clone "$TMPDIR_UPDATE/spider.bundle" "$TMPDIR_UPDATE/src" || die "git clone from bundle failed."

        su - "$OWNER" -c "cd '$TMPDIR_UPDATE/src' && git checkout mojo >/dev/null 2>&1 || git checkout -b mojo origin/mojo" || true

        echo "Source bundle build info:"
        print_build_info "$TMPDIR_UPDATE/src"

        mkdir -p "$TMPDIR_UPDATE/preserve"
        tar -C "$DXSPATH" -czf "$TMPDIR_UPDATE/preserve/local_state.tgz" \
                --ignore-failed-read local local_cmd cmd_import local_data 2>/dev/null || true
        if [ -f "$DXSPATH/local/DXVars.pm" ]; then
                cp -a "$DXSPATH/local/DXVars.pm" "$TMPDIR_UPDATE/preserve/DXVars.pm" || true
        fi

        rsync -a --delete \
                --exclude '/local/' \
                --exclude '/local_cmd/' \
                --exclude '/cmd_import/' \
                --exclude '/local_data/' \
                "$TMPDIR_UPDATE/src/" "$DXSPATH/"

        if [ -d "$DXSPATH/.git" ]; then
                mv "$DXSPATH/.git" "$DXSPATH/.git.BAD.$(date +%F-%H%M%S)" || true
        fi
        cp -a "$TMPDIR_UPDATE/src/.git" "$DXSPATH/.git" || die "Failed to copy deterministic .git"

        tar -C "$DXSPATH" -xzf "$TMPDIR_UPDATE/preserve/local_state.tgz" 2>/dev/null || true
        if [ -f "$TMPDIR_UPDATE/preserve/DXVars.pm" ]; then
                mkdir -p "$DXSPATH/local"
                cp -a "$TMPDIR_UPDATE/preserve/DXVars.pm" "$DXSPATH/local/DXVars.pm" || true
        fi

        ln -sfn "$DXSPATH" /spider

        echo -e " "
}

# -----------------------------
# Config + service (kept as original)
# -----------------------------
config_app()
{
        echo "Fix up permissions"
        echo -e " "
        echo -e "Please use capital letters"
        echo -e " "

        cd "${DXSPATH}" || exit 1

        chown -R "$OWNER.$GROUP" "${DXSPATH}" || true
        find ./ -type d -exec chmod 2775 {} \; || true
        find ./ -type f -exec chmod 0775 {} \; || true
        su - "$OWNER" -c "mkdir -p '${DXSPATH}/local'" || true
        su - "$OWNER" -c "mkdir -p '${DXSPATH}/cmd_import'" || true
        su - "$OWNER" -c "mkdir -p '${DXSPATH}/local_cmd'" || true

        if [ ! -f "${DXSPATH}/local/DXVars.pm" ]; then
                su - "$OWNER" -c "cp '${DXSPATH}/perl/DXVars.pm.issue' '${DXSPATH}/local/DXVars.pm'" || true
        fi

        insert_cluster_call
        insert_call
        insert_name
        insert_email
        insert_locator
        insert_qth

        echo -e "Now create basic user file"
        su - "$OWNER" -c "/spider/perl/create_sysop.pl" || true
        echo -e " "
        echo -e "Update has been finished."
        echo -e "Current build info (installed):"
        print_build_info "$DXSPATH"
        echo -e " "
}

create_service()
{
        echo -e " "
        echo -e "Now make configuration for systemd dxspider service"
        echo -e " "

        if [ -f "/etc/systemd/system/dxspider.service" ]; then
                echo "Files dxspider.service exist"
        else
                touch /etc/systemd/system/dxspider.service
                cat >> /etc/systemd/system/dxspider.service <<EOL
[Unit]
Description= Dxspider DXCluster service
After=network.target

[Service]
Type=simple
User=$OWNER
Group=$GROUP
ExecStart= /usr/bin/perl -w /spider/perl/cluster.pl
StandardOutput=null
Restart=always

[Install]
WantedBy=multi-user.target
EOL
        fi

        systemctl daemon-reload 2>/dev/null || true
        echo -e " "
}

enable_service()
{
        echo -e "Enable Dxspider Service to start up"
        echo -e " "
        systemctl enable dxspider 2>/dev/null || true
        systemctl start dxspider 2>/dev/null || true
}

# -----------------------------
# Prompts for DXVars (kept as original)
# -----------------------------
insert_cluster_call()
{
        echo -n "Please enter CallSign for DxCluster: "
        chr="\""
        read DXCALL
        echo "${DXCALL}"
        su - "$OWNER" -c "sed -i 's/mycall =.*/mycall = ${chr}${DXCALL}${chr};/' /spider/local/DXVars.pm" || true
}

insert_call()
{
        echo -n "Please enter your CallSign: "
        chr="\""
        read SELFCALL
        echo "${SELFCALL}"
        su - "$OWNER" -c "sed -i 's/myalias =.*/myalias = ${chr}${SELFCALL}${chr};/' /spider/local/DXVars.pm" || true
}

insert_name()
{
        echo -n "Please enter your Name: "
        chr="\""
        read MYNAME
        echo "${MYNAME}"
        su - "$OWNER" -c "sed -i 's/myname =.*/myname = ${chr}${MYNAME}${chr};/' /spider/local/DXVars.pm" || true
}

insert_email()
{
        echo -n "Please enter your E-mail Address(syntax like your\@email.com): "
        chr="\""
        read EMAIL
        echo "${EMAIL}"
        su - "$OWNER" -c "sed -i 's/myemail =.*/myemail = ${chr}${EMAIL}${chr};/' /spider/local/DXVars.pm" || true
}

insert_locator()
{
        echo -n "Please enter your Locator(Use Capital Letter): "
        chr="\""
        read MYLOCATOR
        echo "${MYLOCATOR}"
        su - "$OWNER" -c "sed -i 's/mylocator =.*/mylocator = ${chr}${MYLOCATOR}${chr};/' /spider/local/DXVars.pm" || true
}

insert_qth()
{
        echo -n "Please enter your QTH(use comma without space): "
        chr="\""
        read MYQTH
        echo "${MYQTH}"
        su - "$OWNER" -c "sed -i 's/myqth =.*/myqth = ${chr}${MYQTH}${chr};/' /spider/local/DXVars.pm" || true

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

# -----------------------------
# UI
# -----------------------------
welcome()
{
        clear
        echo -e " "
        echo -e "==============================================================="
        echo -e " "
        echo -e "This script will make a Backup of the current DXSpider"
        echo -e "software in the /home/spider.backup directory"
        echo -e "Users, DB and configuration files will be maintained."
        echo -e " "
        echo -e "Update source: bundled git history (assets/spider.bundle.gz)"
        echo -e " "
        echo -e "==============================================================="
        echo -e " "
        read -n 1 -s -r -p $'Press any key to continue ...'
        echo -e " "
        echo -e "Indicates path where DXSpider is installed."
        echo -n "For example: /home/spider or /home/sysop/spider or ... : "
        read DXSPATH

        echo -e " "
        echo -e "==============================================================="
        echo -e "To upgrade your DXSpider, press [U]"
        echo -e "To restore the backup, press [R]"
        echo -e "==============================================================="
        echo -e " "
        echo -n "Please enter [U]pdate, [R]estore o [Q]uit: "
        read OPTION

        if [ "${OPTION}" == "U" ]; then
                echo -e " "
                echo -e "==============================================================="
                echo -e "                     Updating DXSpider..."
                echo -e "==============================================================="
                echo -e " "

                backup
                check_distro
                mkdir -p "${DXSPATH}/local_data" || true
                cp -a "${DXSPATH}/data/." "${DXSPATH}/local_data/." 2>/dev/null || true

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
