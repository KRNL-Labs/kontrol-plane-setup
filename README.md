# install

## 🧩 README — Kontrolplane Setup Script

### 📘 Overview

`kontrolplane-ubuntu-amd64-install.sh` is an automated setup script for deploying the **Kontrolplane service** on Linux systems.

It installs dependencies, sets up **gVisor (runsc)** as a Docker runtime, downloads binaries and configuration files from **S3**, creates a dedicated service user, and registers a **systemd service** that runs `kontrolplane-amd64`.

> ✅ Designed to run as root — the script assumes it has full system access (no sudo inside).
> 

---

### ⚙️ Features

- ✅ Installs **Docker** and **gVisor (runsc)** runtime.
- ✅ Optionally sets **gVisor as the default Docker runtime**.
- ✅ Downloads **binary and configuration** files from **public S3 URLs**.
- ✅ Creates a **systemd service** running under a non-root user (`kontrol_plane`).
- ✅ Logs output to `/home/kontrolplane/log/kontrolplane.log`.
- ✅ Supports command-line options for custom setups.

---

### 📦 Requirements

- Linux system (Ubuntu, Debian, or Amazon Linux–compatible)
- Root privileges (run script as `root` or with `sudo -i`)
- Internet access (to fetch packages and S3 files)
- Publicly accessible S3 objects for the binary and optional config

---

### 🚀 Usage

### 1️⃣ Make script executable

```bash
chmod +x kontrolplane-ubuntu-amd64-install.sh
```

### 2️⃣ Run as root

```bash
sudo -i
bash kontrolplane-ubuntu-amd64-install.sh
```

Or provide custom options:

```bash
bash kontrolplane-ubuntu-amd64-install.sh \
  --bin-s3 s3://your-bucket/releases/latest/rpc-amd64 \
  --cfg-s3 s3://your-bucket/releases/latest/config.toml \
  --s3-region ap-southeast-1 \
  --set-default-runtime \
  --service-user kontrol_plane \
  --service-name kontrolplane
```

---

### 🧠 Command-line Options

| Option | Description | Default |
| --- | --- | --- |
| `--bin-s3 <s3-uri>` | Public S3 URI to the Kontrolplane binary | **Required** |
| `--cfg-s3 <s3-uri>` | Optional S3 URI to config file | *(empty)* |
| `--s3-region <region>` | S3 region (if not using global endpoint) | *(empty)* |
| `--set-default-runtime` | Set gVisor (runsc) as the default Docker runtime | `false` |
| `--create-service` | Create and enable systemd service automatically | `true` |
| `--service-user <name>` | Service user to run under | `kontrol_plane` |
| `--service-name <name>` | Systemd unit name | `kontrolplane` |
| `-h, --help` | Show help message | — |

---

### 🧰 What the Script Does (Step-by-Step)

1. **Detects architecture** (`x86_64` only supported currently).
2. **Installs dependencies:** `docker`, `curl`, `wget`, `coreutils`, and `ca-certificates`.
3. **Installs Cosign** (for image signing).
4. **Downloads and installs gVisor** (`runsc` + `containerd-shim-runsc-v1`).
5. **Configures Docker** to include the `runsc` runtime.
    - If `-set-default-runtime` is used, it sets `runsc` as default.
6. **Creates user and directories:**
    - `/home/kontrol_plane`
    - `/etc/kontrolplane/` for binary and config
    - `/home/kontrolplane/log/kontrolplane.log` for logs
7. **Downloads binary from S3** → `/etc/kontrolplane/kontrolplane-amd64`
8. **Downloads config (optional)** → `/etc/kontrolplane/config.toml`
9. **Creates systemd unit** at `/etc/systemd/system/kontrolplane.service`
10. **Starts and enables service** automatically.

---

### 🧾 Example Systemd Unit (Generated)

```
[Unit]
Description=kontrolplane service
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=kontrol_plane
WorkingDirectory=/etc/kontrolplane
SupplementaryGroups=docker
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/bin/bash -c '/etc/kontrolplane/kontrolplane-amd64 -log=debug >> /var/log/kontrolplane.log 2>&1'
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target

```

---

### 🪵 Log Locations

| Path | Purpose |
| --- | --- |
| `/var/log/kontrolplane.log` | Service log output |
| `/etc/kontrolplane/config.toml` | Optional configuration file |
| `/etc/kontrolplane/kontrolplane-amd64` | Service binary |

---

### 🔍 Monitoring and Debugging

### Check service status

```bash
systemctl status kontrolplane
```

### View logs

```bash
tail -f /home/kontrolplane/log/kontrolplane.log
```

### Restart the service

```bash
systemctl restart kontrolplane
```

### Reload systemd after script update

```bash
systemctl daemon-reload
```