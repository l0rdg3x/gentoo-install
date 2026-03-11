# CLAUDE.md — AI Assistant Guide for gentoo-install

## Project Overview

This is a single-file Bash script (`gentoo-install.sh`) that automates Gentoo Linux desktop installation. It handles everything from interactive configuration collection through disk partitioning, Btrfs subvolume setup, stage3 extraction, and in-chroot system configuration.

**Target audience**: Personal use / desktop Gentoo installs on AMD64 hardware.
**License**: GPLv3
**Architecture**: x86_64 (amd64) only; supports both systemd and OpenRC init systems.

---

## Repository Structure

```
gentoo-install/
├── gentoo-install.sh   # The entire installer (~1060 lines, single script)
├── README.md           # User-facing documentation
└── LICENSE             # GPLv3
```

There is no build system, no test suite, no CI/CD, and no separate config files. Everything is in `gentoo-install.sh`.

---

## Script Architecture

The script has **three logical sections**, controlled by a `--chroot` argument guard:

### Section 1: Dialog Config Wizard (lines 14–236)
Runs on the **live host** (no `--chroot` flag). Uses the `dialog` TUI to collect all installation parameters interactively, then exports them as environment variables.

Four helper functions drive all dialogs:
- `ask_input VAR "Title" "Prompt" "default"` — text input box
- `ask_pass VAR "Title" "Prompt"` — password box (hidden input)
- `ask_yesno VAR "Title" "Prompt" default_y_or_n` — yes/no dialog
- `ask_radio VAR "Title" "Prompt" tag item on|off ...` — single-choice radiolist

### Section 2: Chroot Section (lines 241–755)
Runs **inside the chroot** (triggered by `--chroot` flag). Configures the new Gentoo system: Portage, profile, make.conf, packages, bootloader, users, and post-install scripts.

### Section 3: Host (Pre-Chroot) Section (lines 757–887)
Runs on the **live host** after the wizard. Handles disk operations: wipe, GPT partitioning, optional LUKS formatting, Btrfs formatting and subvolume creation, swap file setup, stage3 download/extraction, and chroot entry.

---

## Dual-Mode Execution Flow

```
User runs: ./gentoo-install.sh
    │
    ├─ [Section 1] Dialog wizard collects config → exports vars
    │
    ├─ [Section 3] Host operations:
    │     Partition disk → LUKS (optional) → Btrfs subvols
    │     → Download stage3 → Mount virtual filesystems
    │     → Copy script to /mnt/gentoo/
    │
    └─ chroot /mnt/gentoo ... /bin/bash /gentoo-install.sh --chroot
          │
          └─ [Section 2] Chroot operations:
                emerge-webrsync → profile → make.conf → mirrors
                → packages → kernel → bootloader → users → cleanup
```

---

## Key Configuration Variables

All configuration is collected in Section 1 and exported for the chroot. Boolean-like flags use `"y"` / `"n"` strings throughout (not `true`/`false`).

| Variable | Type | Description |
|---|---|---|
| `HOSTNAME` | string | System hostname |
| `INIT_SYSTEM` | `systemd`/`openrc` | Init system to install |
| `TIMEZONE_SET` | string | e.g. `Europe/Rome` |
| `LOCALE_GEN_SET` | string | `/etc/locale.gen` entries (newline-separated via `\n`) |
| `ESELECT_LOCALE_SET` | string | e.g. `it_IT.UTF8` (no dash) |
| `CONSOLE_KEYMAP` | string | Console keymap (e.g. `it`, `us`, `de`) |
| `ESELECT_PROF` | string | Full Portage profile path (varies by init system) |
| `BINHOST` | `y`/`n` | Use Gentoo binary package host |
| `BINHOST_V3` | `y`/`n` | Use x86-64-v3 binaries (requires AVX2) |
| `MIRROR` | URL | Stage3 mirror base URL |
| `DEV_INSTALL` | `ssd`/`nvme` | Disk type (drives partition naming) |
| `DISK_INSTALL` | path | Target disk (e.g. `/dev/sda`, `/dev/nvme0n1`) |
| `EFI_PART` | path | Derived EFI partition path |
| `ROOT_PART` | path | Derived root partition path |
| `SWAP_G` | size | Swap file size (e.g. `16G`) |
| `LUKSED` | `y`/`n` | Enable LUKS encryption |
| `LUKS_PASS` | string | LUKS passphrase |
| `TPM_UNLOCK` | `y`/`n` | Enable TPM2 LUKS auto-unlock |
| `VIDEOCARDS` | string | `VIDEO_CARDS` value for make.conf |
| `INTEL_CPU_MICROCODE` | `y`/`n` | Install Intel microcode |
| `PLYMOUTH_THEME_SET` | string | `solar`/`bgrt`/`spinner`/`tribar` |
| `SECUREBOOT_MODSIGN` | `y`/`n` | Enable Secure Boot + module signing |
| `MOK_PASS` | string | MOK enrollment password |
| `GRUB_PASSWORD_ENABLE` | `y`/`n` | Protect GRUB menu with password |
| `GRUB_PASS` | string | GRUB boot menu password |
| `ROOT_PASS` | string | Root account password |
| `USER_NAME` | string | Non-root username |
| `USER_PASS` | string | Non-root user password |

### Partition Naming Logic

```bash
if [[ "$DEV_INSTALL" == "nvme" ]]; then
    EFI_PART="${DISK_INSTALL}p1"   # e.g. /dev/nvme0n1p1
    ROOT_PART="${DISK_INSTALL}p2"
else
    EFI_PART="${DISK_INSTALL}1"    # e.g. /dev/sda1
    ROOT_PART="${DISK_INSTALL}2"
fi
```

---

## Filesystem Layout

```
GPT disk:
  Partition 1  →  /boot   (FAT32, 1 GiB EFI System Partition)
  Partition 2  →  /       (Btrfs, or LUKS→Btrfs)

Btrfs subvolumes:
  @            →  /
  @home        →  /home
  @snapshots   →  /.snapshots
  @log         →  /var/log
  @cache       →  /var/cache
  @tmp         →  /tmp
  @swap        →  /swap         (nodatacow, no compression)

Btrfs mount options (all except @tmp/@swap):
  noatime,compress=zstd:3,ssd,discard=async

Swap: /swap/swap.img (Btrfs file, CoW disabled via chattr +C)
```

---

## Boot Chain

```
UEFI firmware
  → /boot/EFI/gentoo/shimx64.efi     (pre-signed by Microsoft/Fedora)
  → /boot/EFI/gentoo/grubx64.efi     (Gentoo pre-built signed standalone GRUB)
  → kernel + initramfs in /boot/
```

**Important**: `grub-install` is NOT used because it produces an unsigned binary that shim cannot verify. The pre-built signed standalone GRUB reads `grub.cfg` from its own EFI directory (`/boot/EFI/gentoo/grub.cfg`).

### update-grub

A wrapper script at `/usr/local/sbin/update-grub` always writes grub.cfg to the correct location:
```bash
GRUB_CFG="/boot/EFI/gentoo/grub.cfg" grub-mkconfig -o "$GRUB_CFG"
```

Use `update-grub` (not `grub-mkconfig` directly) when regenerating the bootloader config.

---

## Secure Boot

- Uses `sbctl` to generate MOK (Machine Owner Key) keys stored at `/var/lib/sbctl/keys/db/`
- Keys are enrolled into shim's MOKlist via `mokutil --import`, NOT into the UEFI db directly
- `91-sbctl.install` kernel install hook (fetched from upstream) auto-signs kernels on install
- make.conf variables set: `MODULES_SIGN_KEY`, `MODULES_SIGN_CERT`, `MODULES_SIGN_HASH`, `SECUREBOOT_SIGN_KEY`, `SECUREBOOT_SIGN_CERT`
- USE flags added: `modules-sign secureboot`
- **First reboot**: MokManager launches automatically → enroll MOK key with the password → reboot → enable Secure Boot in UEFI

---

## TPM2 LUKS Auto-Unlock

TPM2 enrollment **cannot** happen during install (PCR values are invalid in chroot). Instead, the script generates `/usr/local/sbin/gentoo-tpm-enroll.sh` which the user runs after first boot:

```bash
sudo /usr/local/sbin/gentoo-tpm-enroll.sh
```

This uses `systemd-cryptenroll` to bind the LUKS key to PCR 7 (Secure Boot state). The LUKS passphrase always works as a fallback.

---

## Portage / Package Management Conventions

- Profile: `default/linux/amd64/23.0/...` (systemd variants only)
- Portage repo: switched from rsync to git-based sync after install
- Package accepts keywords for `~amd64` tracked in `/etc/portage/package.accept_keywords/pkgs`
- USE flags per-package in `/etc/portage/package.use/`
- CPU flags auto-detected via `cpuid2cpuflags` → `/etc/portage/package.use/00cpu-flags`
- With binhost: `getbinpkg binpkg-request-signature` FEATURES added, `--usepkg=y --binpkg-changed-deps=y` in `EMERGE_DEFAULT_OPTS`
- Kernel options: `sys-kernel/gentoo-kernel-bin` (with binhost) or `sys-kernel/gentoo-kernel` (source-based)

### make.conf Defaults

```
COMMON_FLAGS="-march=native -O2 -pipe"
MAKEOPTS="-j$(nproc) -l$(nproc)"
EMERGE_DEFAULT_OPTS="--jobs $(nproc) --load-average $(nproc)"
FEATURES="${FEATURES} candy parallel-fetch parallel-install"
USE="dist-kernel systemd"
ACCEPT_LICENSE="*"
GRUB_PLATFORMS="efi-64"
LC_MESSAGES=C.utf8
```

---

## Shell Script Conventions

### Strict Mode
```bash
#!/usr/bin/env bash
set -euo pipefail
```

### Logging Prefixes
- `[*]` — informational message
- `[!]` — warning or important notice
- `[*] [HOST] ...` — host-side operation
- `[*] [CHROOT] ...` — chroot-side operation
- `[update-grub] ...` — tool-specific output

### Boolean Flags
Always `"y"` or `"n"` strings. Tested with `[[ "$VAR" == "y" ]]`.

### Variable Naming
- `UPPERCASE` — configuration variables and exports
- `lowercase` with leading `_` (`_var`, `_title`) — local function parameters
- `EXTRA_USE`, `EXTRA_FEATURES` — accumulator variables built up conditionally

### Heredocs
- `<<DELIMITER` — allows variable expansion (used when embedding config values)
- `<<'DELIMITER'` — literal/no expansion (used for scripts written to disk)

### Error Handling Pattern
```bash
command || { echo "[!] Error message"; exit 1; }
```

### Section Delimiters
```bash
# =============================================================================
# SECTION NAME
# =============================================================================
```

### Temporary Files
```bash
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
```

### Conditional Config Accumulation
Features and USE flags are accumulated into `EXTRA_USE` and `EXTRA_FEATURES` strings, then `sed -i` patches them into `/etc/portage/make.conf` after the base config is written.

---

## Files Generated on the Installed System

| Path | Purpose |
|---|---|
| `/etc/portage/make.conf` | Portage build configuration |
| `/etc/portage/binrepos.conf/gentoobinhost.conf` | Binary package repo |
| `/etc/portage/package.use/*` | Per-package USE flags |
| `/etc/portage/package.accept_keywords/pkgs` | `~amd64` keywords |
| `/etc/portage/repos.conf/gentoo.conf` | Git-based Portage repo config |
| `/etc/dracut.conf.d/gentoo.conf` | Initramfs config (hostonly, modules) |
| `/etc/dracut.conf.d/tpm2.conf` | TPM2 kernel drivers in initramfs |
| `/etc/default/grub` | GRUB configuration |
| `/etc/default/grub-btrfs/config` | grub-btrfs paths for snapshot booting |
| `/etc/crypttab` | LUKS device mapping (if LUKS enabled) |
| `/etc/systemd/zram-generator.conf.d/zram0-swap.conf` | ZRAM swap (ram/2, zstd) |
| `/etc/systemd/system/grub-btrfsd.service.d/override.conf` | grub-btrfsd systemd override |
| `/etc/kernel/postinst.d/99-update-grub` | Run update-grub after kernel installs |
| `/usr/local/sbin/update-grub` | Wrapper: grub-mkconfig → correct path |
| `/usr/local/sbin/gentoo-tpm-enroll.sh` | TPM2 LUKS enrollment (run post-boot) |

---

## Post-Installation Tasks (User Must Do)

1. **First reboot**: If Secure Boot enabled, MokManager will launch — enroll the MOK key with the password set during install, then reboot and enable Secure Boot in UEFI firmware settings.
2. **TPM2 enrollment**: If TPM unlock enabled, run `sudo /usr/local/sbin/gentoo-tpm-enroll.sh` after first successful boot.
3. **grub-btrfs**: Install and enable for Btrfs snapshot boot entries:
   ```bash
   emerge sys-boot/grub-btrfs
   systemctl enable --now grub-btrfsd
   ```
4. **System update**: `emerge --update --deep --newuse @world`
5. **Networking**: `iw`, `wpa_supplicant`, `dhcpcd`, and `NetworkManager` are pre-installed.

---

## Known Limitations and TODOs

- AMD64 / x86_64 only (no ARM64)
- TPM2 auto-unlock uses `systemd-cryptenroll` (systemd) or `clevis` (OpenRC)
- Desktop use only (no server-optimized stage3 option)
- No pre-installation sanity checks / validation
- Defaults lean toward Italian locale (`Europe/Rome`, `it_IT`, `it` keymap) — change interactively at wizard prompts

---

## Development Notes

- The script is intentionally monolithic — resist splitting it unless there is a strong reason. The single-file design is a deliberate choice for portability during live-CD installation.
- The chroot hand-off passes every variable explicitly via `/usr/bin/env VAR=value ...` on the `chroot` command line. If you add a new configuration variable, add it to both the `export` block (line ~230) and the `chroot` invocation (lines ~857–886).
- `grub-install` must NOT be used — it produces an unsigned binary incompatible with the shim-based Secure Boot chain.
- TPM2 enrollment scripts that use `systemd-cryptenroll` cannot run during chroot because PCR values are not valid until a real boot occurs.
- When writing config files with heredocs that contain bash variables from the install context, use `<<DELIMITER` (unquoted). When writing scripts that should be literal bash on the installed system, use `<<'DELIMITER'` (quoted).
