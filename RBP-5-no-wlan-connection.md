# Ubuntu Server on Raspberry Pi 5 via cloud-init: WLAN + SSH Fix

## TL;DR

Flashing Ubuntu Server 64-bit onto a Raspberry Pi 5 via Raspberry Pi Imager results in the device not appearing on the network. The root causes are: (1) `enable_ssh` is not a valid cloud-init directive and silently fails, and (2) `openssh-server` is not explicitly declared as a package, so SSH may not be guaranteed to start. The fix is to remove `enable_ssh`, add `openssh-server` to the `packages` list, and ensure `ssh_pwauth: true` is present. The WLAN configuration via `network-config` on the boot partition is correct as-is when properly filled out via Imager.

---

## Background

When using Raspberry Pi Imager to flash Ubuntu Server 64-bit to a Pi 5, the tool writes two cloud-init configuration files to the boot partition:

- `user-data` — defines users, packages, locale, SSH behavior
- `network-config` — defines network interfaces via Netplan (version 2)

On first boot, `cloud-init` reads these files and configures the system accordingly. If either file contains errors or unsupported directives, cloud-init silently skips the affected section without producing obvious failure output on the console.

---

## Symptoms

- The device is assigned a DHCP lease by the router (visible in the router UI) but does not respond to ping
- `arp -n <ip>` returns `(incomplete)` — no ARP reply is received, indicating the device is not actually reachable at that address
- `nmap -sn <subnet>` does not list the Pi's IP
- The router's DHCP table shows a stale entry from a previous session rather than an active one
- SSH connection attempts time out or are immediately refused

---

## Diagnosis

### Step 1: Verify ARP

```bash
arp -n 192.168.2.109
```

An `(incomplete)` result confirms the IP shown in the router is a stale cache entry. The device is not on the network.

### Step 2: Scan the subnet

```bash
nmap -sn 192.168.2.0/24
```

If the Pi does not appear at all, it has not successfully connected to WLAN.

### Step 3: Inspect the boot partition

Remove the SD card or SSD, insert it into another machine, and inspect the two cloud-init files on the boot partition (mounted automatically on macOS):

```bash
cat /Volumes/bootfs/network-config
cat /Volumes/bootfs/user-data
```

---

## Root Cause

### Invalid directive: `enable_ssh`

The following directive is **not recognized by cloud-init**:

```yaml
enable_ssh: true
```

This key does not exist in the cloud-init schema. It is silently ignored. As a result, `openssh-server` may not be installed or started, even if the Imager UI shows SSH as "enabled."

### Missing explicit package declaration

Without `openssh-server` in the `packages` list, SSH availability on first boot depends entirely on whether the base image includes it. On Ubuntu Server for Pi, this is not always guaranteed in the context of a fresh cloud-init run.

---

## Fix

### Corrected `user-data`

```yaml
#cloud-config
hostname: HL-RBP-5
manage_etc_hosts: true
packages:
  - avahi-daemon
  - openssh-server
apt:
  conf: |
    Acquire {
      Check-Date "false";
    };
timezone: Europe/Berlin
keyboard:
  model: pc105
  layout: "de"
users:
  - name: <Username>
    groups: users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo
    shell: /bin/bash
    lock_passwd: false
    passwd: <yescrypt-hash>
ssh_pwauth: true
```

Key changes:
- Removed `enable_ssh: true` (invalid directive)
- Added `openssh-server` explicitly to `packages`
- `ssh_pwauth: true` remains — this is the correct directive to allow password-based SSH authentication

### Working `network-config`

```yaml
network:
  version: 2
  wifis:
    wlan0:
      dhcp4: true
      regulatory-domain: "DE"
      access-points:
        "YOUR-SSID":
          password: "your-password"
      optional: true
```

The `optional: true` flag means the system will not block boot waiting for WLAN to come up. This is correct behavior for a headless setup.

---

## Applying the Fix

1. Insert the SD card or SSD into another machine
2. Open the boot partition (auto-mounts on macOS as `bootfs`)
3. Edit `user-data` as shown above
4. Safely eject the storage medium
5. Insert back into the Pi and power on
6. Wait approximately 2 minutes for cloud-init to complete on first boot
7. Scan for the device:

```bash
nmap -sn 192.168.2.0/24
```

8. Connect via SSH:

```bash
ssh <Username>@<ip>
```

---

## Notes

- The `passwd` field must contain a pre-hashed password in yescrypt, SHA-512, or another format supported by the system's `chpasswd`. Plain text passwords must not be used here.
- `avahi-daemon` enables mDNS resolution, allowing the device to be reached via `hostname.local` once on the network.
- cloud-init logs are available at `/var/log/cloud-init.log` and `/var/log/cloud-init-output.log` on the Pi itself for post-boot debugging.
- The Raspberry Pi Imager UI "Enable SSH" toggle does not reliably translate to a working SSH configuration via cloud-init on Ubuntu Server. Always verify `user-data` manually.

---

## Environment

| Component | Version / Detail |
|-----------|-----------------|
| Hardware | Raspberry Pi 5 |
| OS | Ubuntu Server 24.04 LTS 64-bit |
| Flash tool | Raspberry Pi Imager |
| Init system | cloud-init |
| Network config | Netplan v2 |
| SSH | openssh-server (via cloud-init packages) |
