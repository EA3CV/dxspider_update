# IMPORTANT NOTE

There are two scripts to update DXSpider:

- `update_dxspider.sh` was created to install your DXSpider while the official site is down.
- `update_dxspider_alternative.sh` was created to update your DXSpider while the official site is down.

In addition, this project includes an **installation script (from scratch)** that installs DXSpider from the **EA3CV GitHub repository** and configures it as a **systemd** service.

---

# Fresh installation (from scratch)

This installation method deploys DXSpider from:

- Repository: `https://github.com/EA3CV/dx-spider.git`
- Default branch: `mojo`
- Install path: `/home/sysop/spider`
- Symlink: `/spider -> /home/sysop/spider`
- systemd service: `dxspider`

## Files needed

Place these two files in the same directory:

- `install_dxspider.sh`
- `distro_actions.conf`

## Install steps

1. Make the installer executable:

```bash
chmod +x install_dxspider.sh
```

2. Run as root:

```bash
sudo ./install_dxspider.sh
```

3. Follow the prompts (the installer will ask for):
- Cluster callsign (`mycall`)
- Your callsign (`myalias`)
- Name (`myname`)
- Email (`myemail`)
- Locator (`mylocator`)
- QTH (`myqth`)

4. Verify the service:

```bash
systemctl status dxspider
```

## Non-interactive install (optional)

```bash
sudo NONINTERACTIVE=1 \
DXCLUSTER_CALL=EA3CV \
SELFCALL=EA3CV \
MYNAME="Your Name" \
EMAIL="you@example.com" \
MYLOCATOR=JN11AA \
MYQTH="City,Country" \
./install_dxspider.sh
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

## Run

```bash
./update_dxspider.sh
```

## Tested Operating Systems (Linux Distributions)

- CentOS Linux 7 (Core)
- CentOS Linux 8 (Core)
- Debian GNU/Linux 9 (stretch)
- Debian GNU/Linux 10 (buster)
- Debian GNU/Linux 11 (bullseye)
- Debian GNU/Linux 12 (bookworm)
- Debian GNU/Linux 13 (trixie)
- Debian GNU/Linux bookworm/sid
- Fedora Linux 39 (Server Edition)
- Fedora Linux 39 (Workstation Edition)
- Linux Mint 21.1
- Linux Mint 21.3
- Raspbian GNU/Linux 9 (stretch)
- Raspbian GNU/Linux 10 (buster)
- Raspbian GNU/Linux 11 (bullseye)
- Raspbian GNU/Linux 12 (bookworm)
- Raspbian GNU/Linux 13 (trixie)
- Ubuntu 20.04.6 LTS
- Ubuntu 22.04 LTS
- Ubuntu 22.04.1 LTS
- Ubuntu 22.04.2 LTS
- Ubuntu 22.04.3 LTS
- Ubuntu 22.04.4 LTS
- Ubuntu 22.04.5 LTS
- Ubuntu 24.04.2 LTS
- Rocky Linux 8.5 (Green Obsidian)

---

# To use `update_dxspider_alternative.sh`

## Download script

```bash
wget https://github.com/EA3CV/dxspider_update/archive/refs/heads/main.zip -O update_dxspider_alternative.zip
```

Must be run as root user.

## Uncompress & change permissions

```bash
unzip update_dxspider_alternative.zip
cd dxspider_update-main
chmod a+x update_dxspider_alternative.sh
```

## Run

```bash
./update_dxspider_alternative.sh
```

---

# Notes / References

Remember that the alternative script is only for updating. For a new installation, see the development of Yiannis Panagou, SV5FRI at:

- https://github.com/glaukos78/dxspider_installation_v2

Sysops who want to be informed or participate in the evolution, new versions/builds and questions about DXSpider can request to subscribe to the official list:

- https://mailman.tobit.co.uk/mailman/listinfo/dxspider-support
