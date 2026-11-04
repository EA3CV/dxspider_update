# IMPORTANT NOTE

There are two scripts to update DXSpider:

- `update_dxspider.sh` will only work when the **official DXSpider repository** is back online.
- `update_dxspider_alternative.sh` was created to update your DXSpider while the official site is down.

In addition, this project includes a **fresh installation script (from scratch)** that installs DXSpider from the **EA3CV GitHub repository** and configures it as a **systemd** service.

---

# Fresh installation (from scratch)

This installation method deploys DXSpider from:

- Repository: `https://github.com/EA3CV/dx-spider.git`
- Default branch: `mojo`
- Install path: `/home/sysop/spider`
- Symlink: `/spider -> /home/sysop/spider`
- systemd service: `dxspider`

## Download installer (ZIP)

Download this repository as a ZIP and run the installer:

```bash
wget https://github.com/EA3CV/dxspider_update/archive/refs/heads/main.zip -O dxspider_tools.zip
unzip dxspider_tools.zip
cd dxspider_update-main

chmod +x install_dxspider.sh
sudo ./install_dxspider.sh
```

## Download installer (git clone)

```bash
git clone https://github.com/EA3CV/dxspider_update.git
cd dxspider_update

chmod +x install_dxspider.sh
sudo ./install_dxspider.sh
```

## Files used by the installer

The installer requires these two files to be in the same directory:

- `install_dxspider.sh`
- `distro_actions.conf`

## Interactive configuration

During installation you will be prompted for:

- Cluster callsign (`mycall`)
- Your callsign (`myalias`)
- Name (`myname`)
- Email (`myemail`)
- Locator (`mylocator`)
- QTH (`myqth`)

The main configuration file is:

- `/spider/local/DXVars.pm`

## Verify the service

```bash
systemctl status dxspider
```

Logs (if output is not suppressed in the unit file):

```bash
journalctl -u dxspider -f
```

## Non-interactive install (optional)

```bash
sudo NONINTERACTIVE=1 DXCLUSTER_CALL=EA3CV SELFCALL=EA3CV MYNAME="Your Name" EMAIL="you@example.com" MYLOCATOR=JN11AA MYQTH="City,Country" ./install_dxspider.sh
```

---

# To use `update_dxspider.sh`

This script will allow you to update your DXSpider node to the latest build of the MOJO version.

This job is based on the great development of the DXSpider installation script by Yiannis Panagou, SV5FRI.

Before starting the update, a backup of the installation running on your machine will be created. It is important that you tell the script the path where DXSpider is installed.

## Download script

```bash
wget https://github.com/EA3CV/dxspider_update/archive/refs/heads/main.zip -O update_dxspider.zip
```

Must be run as root user.

## Uncompress & change permissions

```bash
unzip update_dxspider.zip
cd dxspider_update-main
chmod a+x update_dxspider.sh
```

## Run script

```bash
./update_dxspider.sh
```

## Script has been tested on the following Operating Systems (Linux Distributions)

- CentOS Linux 8
- Rocky Linux 8
- Rocky Linux 9
- AlmaLinux 9
- Raspbian GNU/Linux 9
- Raspbian GNU/Linux 10
- Raspbian GNU/Linux 11
- Raspbian GNU/Linux 12
- Raspbian GNU/Linux 13
- Debian GNU/Linux 9
- Debian GNU/Linux 10
- Debian GNU/Linux 11
- Debian GNU/Linux 12
- Debian GNU/Linux 13
- Ubuntu 22
- Ubuntu 24
- Ubuntu 25
- Ubuntu 26
- Fedora Linux 39
- Fedora Linux 40
- Fedora Linux 41
- Linux Mint 21
- Zorin

---


