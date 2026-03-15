# Gentoo Auto-Install

An interactive installation script for Gentoo Linux desktop systems. It walks you through every option via a dialog-based wizard, then handles partitioning, encryption, filesystem setup, stage3 extraction, and full in-chroot system configuration — all in a single script.

> **Warning:** This script **wipes the target disk entirely**. Always back up important data first. Test in a virtual machine if you are unsure.

## Features

- **Interactive dialog wizard** — no need to edit the script; every option is configured at runtime
- **systemd and OpenRC** — choose your init system; all features work with both
- **LUKS full-disk encryption** with optional **TPM2 auto-unlock** (PCR 7)
- **Btrfs** with subvolumes (`@`, `@home`, `@log`, `@cache`, `@tmp`, `@swap`) and zstd compression
- **Secure Boot** via shim + pre-signed standalone GRUB + sbctl MOK keys + kernel module signing
- **GRUB password protection** — optional password to prevent editing boot parameters
- **Plymouth** boot splash with theme selection (solar, bgrt, spinner, tribar)
- **Binary packages** — optional Gentoo binhost with x86-64 or x86-64-v3 selection for faster installs
- **ZRAM swap** — zstd-compressed RAM swap configured automatically alongside the Btrfs swap file
- **Suspend-to-idle** — `mem_sleep_default=s2idle` set by default in kernel cmdline for modern hardware
- **grub-btrfs ready** — config pre-created so snapshot boot entries work out of the box after `emerge sys-boot/grub-btrfs`
- **Pre-installation validation** — checks root privileges, UEFI mode, disk availability, required tools, and network before any destructive operation
- **NVMe and SATA/SSD** support with automatic partition naming
- **Portage profiles** — KDE Plasma, GNOME, Desktop, or Minimal (systemd and OpenRC variants)

## Prerequisites

- Gentoo LiveCD, minimal installation ISO, or any Linux live environment with `bash` and `dialog`
- AMD64 (x86_64) hardware
- Internet connection
- UEFI firmware (legacy BIOS is not supported)

## Installation

### 1. Boot and download the script

Boot from a live environment and run as root:

```bash
# Download
wget https://raw.githubusercontent.com/l0rdg3x/gentoo-install/master/gentoo-install.sh
chmod +x gentoo-install.sh
```

### 2. Run the installer

```bash
./gentoo-install.sh
```

The dialog wizard will ask for:

| Category | Options |
|---|---|
| **System** | Hostname |
| **Init system** | systemd or OpenRC |
| **Localization** | Timezone, locale, keymap |
| **Profile** | KDE Plasma / GNOME / Desktop / Minimal (systemd or OpenRC variants) |
| **Portage** | Binary packages (y/n), x86-64-v3 binaries (y/n), mirror URL |
| **Disk** | Target device type (NVMe/SSD), device path, swap size |
| **Encryption** | LUKS (y/n), passphrase, TPM2 unlock (y/n) |
| **Hardware** | VIDEO_CARDS, Intel microcode (y/n) |
| **Boot** | Plymouth theme, Secure Boot (y/n), MOK password, GRUB password (y/n) |
| **Users** | Root password, non-root username and password |

A summary screen shows all choices before anything touches the disk — cancel here to abort safely.

### 3. Wait

After confirmation, the script runs unattended through two phases:

**Host phase** (automatic):
1. Wipes and partitions the disk (GPT: 1 GiB EFI + remaining root)
2. Optionally LUKS-encrypts the root partition
3. Creates Btrfs with subvolumes and mounts everything
4. Creates a swap file on the `@swap` subvolume
5. Downloads and extracts the latest stage3 tarball (systemd or OpenRC variant)
6. Mounts virtual filesystems and enters chroot

**Chroot phase** (automatic):
1. Syncs Portage and sets the selected profile
2. Selects best mirrors via `mirrorselect`
3. Generates `make.conf` with native CPU flags and parallel build settings
4. Configures binary package repository (if selected)
5. Sets locale, timezone, and keymap
6. Installs kernel (binary or source-based), firmware, and microcode
7. Installs shim + pre-signed GRUB to the ESP (no `grub-install`)
8. Generates and enrolls MOK keys for Secure Boot (if selected)
9. Configures GRUB password protection (if selected)
10. Sets up dracut initramfs with Plymouth, Btrfs, LUKS, and TPM2 modules
11. Configures ZRAM swap, fstab, hostname, and system identity
12. Installs networking tools (NetworkManager, dhcpcd, wpa_supplicant, iw)
13. Enables services (systemd: `systemctl enable` / OpenRC: `rc-update add`)
14. Creates user accounts with sudo access
15. Switches Portage to git-based repo sync
16. Pre-configures grub-btrfs paths and `update-grub` wrapper
17. Creates TPM2 enrollment script (if selected)

### 4. Finalize

When the script finishes:

```bash
exit
swapoff /mnt/gentoo/swap/swap.img
umount -R /mnt/gentoo
reboot
```

## Post-Installation

### First boot (Secure Boot)

If Secure Boot was enabled:

1. **MokManager** launches automatically on first boot
2. Choose **Enroll MOK** and enter the MOK password you set during install
3. Reboot
4. In UEFI firmware settings, **enable Secure Boot**

Verify module signatures after boot: `modinfo <module> | grep sig`

### TPM2 enrollment

If TPM2 unlock was enabled, run **after** your first successful boot:

```bash
sudo /usr/local/sbin/gentoo-tpm-enroll.sh
```

This binds the LUKS key to TPM2 PCR 7 (Secure Boot state). Your LUKS passphrase continues to work as a fallback.

To remove TPM2 unlock later:

- **systemd**: `sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/<your-luks-partition>`
- **OpenRC**: `sudo clevis luks unbind -d /dev/<your-luks-partition> -s <slot>` (use `cryptsetup luksDump` to find the clevis slot)

### grub-btrfs (snapshot boot entries)

Config is pre-created during install. Just install the package:

```bash
emerge sys-boot/grub-btrfs

# systemd:
systemctl enable --now grub-btrfsd

# OpenRC:
rc-update add grub-btrfsd default
rc-service grub-btrfsd start
```

### System update

```bash
emerge --update --deep --newuse @world
```

### Networking

NetworkManager is enabled by default. Additionally, `iw`, `wpa_supplicant`, and `dhcpcd` are pre-installed for manual configuration. See the [Gentoo Networking Handbook](https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Networking).

### Regenerating GRUB config

Always use the wrapper script instead of calling `grub-mkconfig` directly:

```bash
update-grub
```

This writes to the correct path (`/boot/EFI/gentoo/grub.cfg`) used by the standalone signed GRUB.

## Init System Comparison

| Feature | systemd | OpenRC |
|---|---|---|
| **Stage3** | `desktop-systemd` | `desktop-openrc` |
| **USE flags** | `dist-kernel systemd` | `dist-kernel elogind` |
| **Session management** | systemd-logind (built-in) | elogind (standalone) |
| **ZRAM swap** | `zram-generator` (systemd config) | `zram-init` (`/etc/conf.d/zram-init`) |
| **LUKS config** | `/etc/crypttab` | `/etc/crypttab` |
| **TPM2 auto-unlock** | `systemd-cryptenroll` | `clevis` + `clevis-pin-tpm2` |
| **Hostname** | `/etc/hostname` + `systemd-firstboot` | `/etc/hostname` + `/etc/conf.d/hostname` |
| **Keymap** | `systemd-firstboot --keymap=` | `/etc/conf.d/keymaps` |
| **Service management** | `systemctl enable` | `rc-update add` |
| **Cron** | systemd timers (built-in) | `cronie` (installed automatically) |
| **Hibernation block** | `systemctl mask hibernate.target` | Kernel cmdline (`mem_sleep_default=s2idle`) |

## Disk Layout

### Partition Table (GPT)

| # | Size | Type | Filesystem | Mount |
|---|---|---|---|---|
| 1 | 1 GiB | EFI System Partition | FAT32 | `/boot` |
| 2 | Remaining | Linux root | Btrfs (or LUKS → Btrfs) | `/` |

### Btrfs Subvolumes

| Subvolume | Mount Point | Options |
|---|---|---|
| `@` | `/` | `noatime,compress=zstd:3,ssd,discard=async` |
| `@home` | `/home` | same |
| `@log` | `/var/log` | same |
| `@cache` | `/var/cache` | same |
| `@tmp` | `/tmp` | `noatime` (mode 1777) |
| `@swap` | `/swap` | `noatime,nodatacow` (no compression) |

Swap file: `/swap/swap.img` (size configured during install, CoW disabled via `chattr +C`).

ZRAM swap is also configured (`ram/2`, zstd compression, priority 100).

## Boot Chain

```
UEFI firmware
  → shimx64.efi       (pre-signed by Microsoft/Fedora)
  → grubx64.efi       (Gentoo pre-built signed standalone GRUB)
  → kernel + initramfs (in /boot/)
```

All EFI binaries live in `/boot/EFI/gentoo/`. `grub-install` is **not** used — it produces an unsigned binary that shim cannot verify. The pre-signed standalone GRUB reads its config from `/boot/EFI/gentoo/grub.cfg`.

## Security Features

| Feature | Details |
|---|---|
| **LUKS** | AES-256 full-disk encryption (512-bit key) via `cryptsetup` |
| **Secure Boot** | shim → signed GRUB → signed kernel; MOK keys generated by `sbctl`, enrolled via `mokutil` into shim MOKlist |
| **Kernel module signing** | `MODULES_SIGN_HASH=sha512` with sbctl keys; unsigned modules rejected |
| **TPM2 auto-unlock** | systemd: `systemd-cryptenroll` / OpenRC: `clevis` — binds LUKS to PCR 7 (Secure Boot state) |
| **GRUB password** | PBKDF2-hashed password prevents editing boot entries (boot menu remains accessible) |
| **Suspend-to-idle** | `mem_sleep_default=s2idle` in kernel cmdline forces S0ix sleep (modern hardware default) |
| **Hibernation disabled** | systemd: `hibernate.target` masked; both: s2idle default prevents accidental hibernate |
| **Sudo** | Non-root user added to `wheel` group with full sudo access |

## Customization

### make.conf

The generated `/etc/portage/make.conf` includes:

```
COMMON_FLAGS="-march=native -O2 -pipe"
MAKEOPTS="-j$(nproc) -l$(nproc)"
EMERGE_DEFAULT_OPTS="--jobs $(nproc) --load-average $(nproc)"
FEATURES="${FEATURES} candy parallel-fetch parallel-install"
USE="dist-kernel systemd|elogind [modules-sign secureboot]"
ACCEPT_LICENSE="*"
GRUB_PLATFORMS="efi-64"
VIDEO_CARDS="<your selection>"
```

Best mirrors are auto-selected via `mirrorselect`. CPU flags are auto-detected via `cpuid2cpuflags`.

### Installed packages

Core (systemd): `systemd`, `grub`, `shim`, `efibootmgr`, `mokutil`, `sbctl`, `btrfs-progs`, `dosfstools`, `dracut`, `plymouth`, `git`

Core (OpenRC): `elogind`, `grub`, `shim`, `efibootmgr`, `mokutil`, `sbctl`, `btrfs-progs`, `dosfstools`, `dracut`, `plymouth`, `git`, `cronie`

Kernel: `gentoo-kernel-bin` (with binhost) or `gentoo-kernel` (source-based), `linux-firmware`, `sof-firmware`, optionally `intel-microcode`

Networking: `NetworkManager`, `chrony`, `dhcpcd`, `wpa_supplicant`, `iw`

Utilities: `mlocate`, `sudo`, `genfstab`
- systemd: `zram-generator`
- OpenRC: `zram-init`

Encryption (if LUKS): `tpm2-tools`, `tpm2-tss`
- OpenRC TPM2: additionally `clevis`

## Troubleshooting

| Problem | Solution |
|---|---|
| Script fails early | Pre-installation checks report what is wrong — verify root privileges, UEFI mode, disk path, missing tools, or network |
| `dialog` not found | Script auto-installs it via `emerge` or `apt-get` |
| Network errors during stage3 download | Check internet connection; try a different mirror |
| LUKS open fails | Double-check passphrase; ensure partition exists |
| Secure Boot not working after reboot | Make sure you enrolled the MOK key in MokManager and enabled Secure Boot in UEFI settings |
| TPM2 enrollment fails | Must be run after a real boot (not from chroot); ensure `tpm2-tools` is installed and TPM2 device exists |
| GRUB config not updating | Use `update-grub` instead of `grub-mkconfig` directly |
| Kernel modules fail signature check | Rebuild kernel with `emerge @module-rebuild` after MOK enrollment |
| OpenRC services not starting | Check `rc-update show` for enabled services; use `rc-service <name> start` to start manually |

## TODO

- [ ] Server use option (different stage3)
- [ ] Multi-architecture support (ARM64)

## Contributing

Contributions and forks are welcome! Please submit pull requests or open issues for bug fixes, feature enhancements, documentation improvements, or hardware compatibility updates.

## License

GPLv3 — see [LICENSE](LICENSE).
