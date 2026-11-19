#!/usr/bin/bash

#
# Script for UPDATE and DXSpider Cluster configuration
# Upgrade from Master or Mojo to the latest Mojo version
#
# Create By Kin, EA3CV and based on the code of Yiannis Panagou, SV5FRI
#
# E-mail: ea3cv@cronux.net
# Version 0.6.17
# Date 20261118
#

set -Eeuo pipefail

# --- Defaults (can be overridden via env) ---
: "${REPO_URL:=git://scm.dxcluster.org/spider}"
: "${BACKUP_REPO_URL:=https://github.com/EA3CV/dxspider.git}"
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
# Distribution lookup: one configuration entry per OS family.
# RPM 8/9 remain separate because their package actions differ.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

normalize_distro()
{
        local distro_id="$1" version="$2" major
        major="${version%%.*}"
        case "$distro_id" in
                ubuntu) printf 'Ubuntu\n' ;;
                linuxmint) printf 'Linux Mint\n' ;;
                debian) printf 'Debian GNU/Linux\n' ;;
                raspbian) printf 'Raspbian GNU/Linux\n' ;;
                zorin) printf 'zorin\n' ;;
                fedora) printf 'Fedora Linux\n' ;;
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
        if ! su - "$OWNER" -c "git clone --branch '${BRANCH}' '${REPO_URL}' '${tmpdir}/spider'" >&2; then
                echo "Dirk clone failed; trying GitHub backup: ${BACKUP_REPO_URL}" >&2
                rm -rf "${tmpdir}/spider"
                su - "$OWNER" -c "git clone --branch '${BRANCH}' '${BACKUP_REPO_URL}' '${tmpdir}/spider'" >&2 || die "Both repositories failed; existing installation untouched"
        fi

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

        # Dependencies were installed and verified before replacing DXSpider.

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
                ensure_extra_perl_modules

                # Keep your original local_data copy (but safe with mkdir -p)
                mkdir -p "${DXSPATH}/local_data"
                if [ -d "${DXSPATH}/data" ]; then
                        cp -a "${DXSPATH}/data/." "${DXSPATH}/local_data/." || true
                fi

                update_spider
                config_app
                ensure_userdsn
                ensure_registration_config
                create_service
                enable_service

                echo -e " "
                echo -e "==============================================================="
                echo -e "                      DXSpider Updated"
                echo -e "==============================================================="
                echo ""
                echo "NOTICE: If DXWeb and dxweb-admin services are installed,"
                echo "        they have NOT been restarted by this updater."
                echo "        Only the DXSpider service was restarted."
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
