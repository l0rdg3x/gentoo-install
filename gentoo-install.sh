#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# GENTOO AUTO-INSTALL SCRIPT
# Supports both systemd and OpenRC init systems.
# Boot chain: UEFI → shim (pre-signed by Microsoft/Fedora)
#                  → grubx64.efi (Gentoo pre-built signed standalone GRUB)
#                  → kernel in /boot/
# Secureboot: sbctl generates MOK keys; key enrolled via mokutil into shim MOKlist.
#             NO sbctl enroll-keys (no direct UEFI db enrollment needed with shim).
# =============================================================================

# =============================================================================
# DIALOG CONFIG WIZARD  (skipped inside chroot)
# =============================================================================
if [[ "${1:-}" != "--chroot" ]]; then

    if ! command -v dialog &>/dev/null; then
        echo "[!] 'dialog' not found. Installing..."
        if command -v emerge &>/dev/null; then
            emerge --oneshot dev-util/dialog
        elif command -v apt-get &>/dev/null; then
            apt-get install -y dialog
        else
            echo "[!] Cannot install dialog automatically. Please install it manually."
            exit 1
        fi
    fi

    TMP=$(mktemp)
    trap 'rm -f "$TMP"' EXIT

    # ask_input VAR "Title" "Prompt" "default"
    ask_input() {
        local _var="$1" _title="$2" _prompt="$3" _default="$4"
        dialog --clear --title "$_title" \
               --inputbox "$_prompt" 10 65 "$_default" 2>"$TMP"
        printf -v "$_var" '%s' "$(cat "$TMP")"
    }

    # ask_pass VAR "Title" "Prompt"
    ask_pass() {
        local _var="$1" _title="$2" _prompt="$3"
        dialog --clear --title "$_title" \
               --passwordbox "$_prompt" 10 65 2>"$TMP"
        printf -v "$_var" '%s' "$(cat "$TMP")"
    }

    # ask_yesno VAR "Title" "Prompt" default_y_or_n
    ask_yesno() {
        local _var="$1" _title="$2" _prompt="$3" _default="$4"
        local extra=""
        [[ "$_default" == "n" ]] && extra="--defaultno"
        if dialog --clear --title "$_title" $extra --yesno "$_prompt" 9 65 2>/dev/null; then
            printf -v "$_var" 'y'
        else
            printf -v "$_var" 'n'
        fi
    }

    # ask_radio VAR "Title" "Prompt" tag1 item1 on|off  tag2 item2 on|off ...
    ask_radio() {
        local _var="$1" _title="$2" _prompt="$3"
        shift 3
        dialog --clear --title "$_title" \
               --radiolist "$_prompt" 20 72 10 "$@" 2>"$TMP"
        printf -v "$_var" '%s' "$(cat "$TMP")"
    }

    clear
    dialog --clear --title "Gentoo Auto-Install" \
        --msgbox "Welcome to the Gentoo automated installer.\n\nYou will now configure the installation options.\nPress ENTER to start." \
        10 62

    # ---- System ----
    ask_input HOSTNAME "System" "Hostname:" "gentoo"

    # ---- Init System ----
    ask_radio INIT_SYSTEM "Init System" \
        "Select the init system:" \
        "systemd" "systemd  (recommended)" "on"  \
        "openrc"  "OpenRC   (traditional init)" "off"

    # ---- Installation Type ----
    ask_radio INSTALL_TYPE "Installation Type" \
        "Select the installation type:" \
        "desktop" "Desktop  (Plymouth boot splash, Wi-Fi tools)" "on"  \
        "server"  "Server   (minimal — no splash, no Wi-Fi tools, stable kernel)" "off"

    # ---- Localization ----
    ask_input TIMEZONE_SET "Localization" \
        "Timezone  (search: ls -l /usr/share/zoneinfo)" \
        "Europe/Rome"

    ask_input CONSOLE_KEYMAP "Localization" \
        "Console keymap  (e.g. it, us, de):" \
        "it"

    # Locale-gen questions are asked after variant selection (musl has no locale-gen)
    LOCALE_GEN_SET=""
    ESELECT_LOCALE_SET=""

    # ---- Installation Variant ----
    ask_radio INSTALL_VARIANT "Installation Variant" \
        "Select the installation variant:" \
        "standard"           "Standard (glibc + GCC) — recommended"        "on"  \
        "llvm"               "LLVM (glibc + Clang/LLVM)"                   "off" \
        "hardened"           "Hardened (glibc + GCC + hardened)"            "off" \
        "musl"               "Musl (musl + GCC)"                           "off" \
        "musl-llvm"          "Musl + LLVM (musl + Clang/LLVM)"             "off" \
        "musl-hardened"      "Musl + Hardened (musl + GCC + hardened)"     "off" \
        "musl-llvm-hardened" "Musl + LLVM + Hardened (experimental combo)" "off"

    # ---- musl + systemd guard ----
    # musl variants only support OpenRC (systemd requires glibc)
    case "$INSTALL_VARIANT" in
        musl|musl-llvm|musl-hardened|musl-llvm-hardened)
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                dialog --clear --title "Init System Override" \
                    --msgbox "The '$INSTALL_VARIANT' variant does not support systemd (requires glibc).\n\nSwitching to OpenRC automatically." \
                    9 62
                INIT_SYSTEM="openrc"
            fi
            ;;
    esac

    # ---- Locale (glibc only — musl has no locale-gen) ----
    case "$INSTALL_VARIANT" in
        musl|musl-llvm|musl-hardened|musl-llvm-hardened)
            # musl uses UTF-8 natively; locale-gen does not exist
            ;;
        *)
            ask_input LOCALE_GEN_SET "Localization" \
                'Entries for /etc/locale.gen (separate multiple with \n)\nExample: it_IT ISO-8859-1\nit_IT.UTF-8 UTF-8' \
                'it_IT ISO-8859-1\nit_IT.UTF-8 UTF-8'

            ask_input ESELECT_LOCALE_SET "Localization" \
                "eselect locale target — UTF8 without the dash\nExample: it_IT.UTF-8  ->  it_IT.UTF8" \
                "it_IT.UTF8"
            ;;
    esac

    # ---- Profile ----
    if [[ "$INSTALL_VARIANT" == "standard" ]]; then
        if [[ "$INSTALL_TYPE" == "server" ]]; then
            # Server: base profiles only (no desktop/plasma/gnome)
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                ask_radio ESELECT_PROF "Portage Profile" \
                    "Select a Portage profile:" \
                    "default/linux/amd64/23.0/systemd" "Base / systemd  (recommended for server)" "on"  \
                    "default/linux/amd64/23.0"          "Minimal (no systemd USE flags)"           "off"
            else
                ESELECT_PROF="default/linux/amd64/23.0"
            fi
        elif [[ "$INIT_SYSTEM" == "systemd" ]]; then
            ask_radio ESELECT_PROF "Portage Profile" \
                "Select a Portage profile:" \
                "default/linux/amd64/23.0/desktop/plasma/systemd" "KDE Plasma / systemd"      "on"  \
                "default/linux/amd64/23.0/desktop/gnome/systemd"  "GNOME / systemd"           "off" \
                "default/linux/amd64/23.0/desktop/systemd"        "Desktop (no DE) / systemd" "off" \
                "default/linux/amd64/23.0/systemd"                "Minimal / systemd"         "off"
        else
            ask_radio ESELECT_PROF "Portage Profile" \
                "Select a Portage profile:" \
                "default/linux/amd64/23.0/desktop/plasma" "KDE Plasma / OpenRC"      "on"  \
                "default/linux/amd64/23.0/desktop/gnome"  "GNOME / OpenRC"           "off" \
                "default/linux/amd64/23.0/desktop"        "Desktop (no DE) / OpenRC" "off" \
                "default/linux/amd64/23.0"                "Minimal / OpenRC"         "off"
        fi
    else
        # Non-standard variants: profile assigned automatically (no desktop variants exist)
        _BASE="default/linux/amd64/23.0"
        case "$INSTALL_VARIANT" in
            llvm)               _PROF_SUFFIX="llvm" ;;
            hardened)           _PROF_SUFFIX="hardened" ;;
            musl)               _PROF_SUFFIX="musl" ;;
            musl-llvm)          _PROF_SUFFIX="musl/llvm" ;;
            musl-hardened)      _PROF_SUFFIX="musl/hardened" ;;
            musl-llvm-hardened) _PROF_SUFFIX="musl/llvm" ;;  # base profile; hardened added via make.conf
        esac
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            ESELECT_PROF="${_BASE}/${_PROF_SUFFIX}/systemd"
        else
            ESELECT_PROF="${_BASE}/${_PROF_SUFFIX}"
        fi
    fi

    # ---- Portage / binhost ----
    if [[ "$INSTALL_VARIANT" != "standard" ]]; then
        # Binhost not available for non-standard variants (musl/llvm/hardened)
        BINHOST="n"
        BINHOST_V3="n"
    else
        ask_yesno BINHOST "Portage" \
            "Use Gentoo binary package host?\n(Much faster installation -- recommended)" "y"
        if [[ "$BINHOST" == "y" ]]; then
            ask_yesno BINHOST_V3 "Portage" \
                "Use x86-64-v3 binaries?\n(Requires AVX2 -- choose No if unsure)" "y"
        else
            BINHOST_V3="n"
        fi
    fi

    ask_input MIRROR "Portage" \
        "Stage3 mirror base URL:" \
        "https://distfiles.gentoo.org/releases/amd64/autobuilds"

    # ---- Disk ----
    ask_radio DEV_INSTALL "Disk" \
        "Target disk type:" \
        "ssd"  "SATA / SSD  (/dev/sda)"     "on"  \
        "nvme" "NVMe        (/dev/nvme0n1)"  "off"

    if [[ "$DEV_INSTALL" == "nvme" ]]; then
        ask_input DISK_INSTALL "Disk" "NVMe device path:" "/dev/nvme0n1"
    else
        ask_input DISK_INSTALL "Disk" "SATA/SSD device path:" "/dev/sda"
    fi

    ask_input SWAP_G "Disk" \
        "Swap file size  (e.g. 4G, 8G, 16G):" "16G"

    # ---- LUKS ----
    ask_yesno LUKSED "Encryption" \
        "Enable LUKS encryption on the root partition?" "n"
    if [[ "$LUKSED" == "y" ]]; then
        ask_pass LUKS_PASS "Encryption" "LUKS passphrase:"
        ask_yesno TPM_UNLOCK "Encryption" \
            "Enable automatic TPM2 unlock for LUKS?\n\nThe LUKS passphrase will still work as fallback.\nTPM enrollment runs after first reboot via /usr/local/sbin/gentoo-tpm-enroll.sh" "n"
    else
        LUKS_PASS=""
        TPM_UNLOCK="n"
    fi

    # ---- Hardware ----
    _vc_hint="Examples:  intel   /   amdgpu radeonsi   /   nvidia"
    [[ "$INSTALL_TYPE" == "server" ]] && \
        _vc_hint="$_vc_hint\n(Server without dedicated GPU: use 'fbdev')"
    ask_input VIDEOCARDS "Hardware" \
        "VIDEO_CARDS value for make.conf\n$_vc_hint" \
        "intel"

    ask_yesno INTEL_CPU_MICROCODE "Hardware" \
        "Install Intel CPU microcode  (sys-firmware/intel-microcode)?" "y"

    # ---- Plymouth ----
    if [[ "$INSTALL_TYPE" == "desktop" ]]; then
        ask_radio PLYMOUTH_THEME_SET "Boot Splash" \
            "Plymouth theme:" \
            "solar"   "Solar   (animated sun rings)"     "on"  \
            "bgrt"    "BGRT    (OEM logo, if available)"  "off" \
            "spinner" "Spinner (simple spinner)"          "off" \
            "tribar"  "Tribar  (three-bar progress)"      "off"
    else
        PLYMOUTH_THEME_SET=""
    fi

    # ---- Secure Boot ----
    ask_yesno SECUREBOOT_MODSIGN "Secure Boot" \
        "Enable Secure Boot + kernel module signing?\n(Uses sbctl MOK keys, enrolled via shim/MokManager)" "y"
    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        ask_pass MOK_PASS "Secure Boot" \
            "MOK enrollment password\n(MokManager will prompt for this on first reboot):"
    else
        MOK_PASS=""
    fi

    ask_yesno GRUB_PASSWORD_ENABLE "GRUB" \
    "Enable GRUB password?\n(Prevents editing boot parameters with 'e')" "y"
    if [[ "$GRUB_PASSWORD_ENABLE" == "y" ]]; then
        ask_pass GRUB_PASS "GRUB" "GRUB boot menu password:"
    else
        GRUB_PASS=""
    fi

    # ---- SELinux ----
    if [[ "$INSTALL_VARIANT" == "hardened" ]]; then
        ask_yesno SELINUX "SELinux" \
            "Enable SELinux (Security-Enhanced Linux)?\n\nProvides mandatory access control (MAC).\nThe system will boot in PERMISSIVE mode initially.\nYou must relabel and switch to enforcing after first boot." "n"
        if [[ "$SELINUX" == "y" ]]; then
            ask_radio SELINUX_TYPE "SELinux Policy Type" \
                "Select the SELinux policy type:" \
                "targeted" "Targeted (recommended — only daemons confined)" "on" \
                "strict"   "Strict (all processes confined)"                "off" \
                "mls"      "MLS (Multi-Level Security — advanced)"         "off"
        else
            SELINUX_TYPE=""
        fi
    else
        SELINUX="n"
        SELINUX_TYPE=""
    fi

    # Apply SELinux sub-profile for non-standard hardened variants
    if [[ "$SELINUX" == "y" && "$INSTALL_VARIANT" != "standard" ]]; then
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            ESELECT_PROF="${ESELECT_PROF%/systemd}/selinux/systemd"
        else
            ESELECT_PROF="${ESELECT_PROF}/selinux"
        fi
    fi

    # ---- Users ----
    ask_pass ROOT_PASS "Users" "Root password:"
    ask_input USER_NAME "Users" "Non-root username:" "user"
    ask_pass USER_PASS  "Users" "Password for $USER_NAME:"

    # ---- Summary ----
    SUMMARY="Installation summary -- please confirm:

  Hostname        : $HOSTNAME
  Init system     : $INIT_SYSTEM
  Install type    : $INSTALL_TYPE
  Variant         : $INSTALL_VARIANT
  Timezone        : $TIMEZONE_SET
  Locale          : ${ESELECT_LOCALE_SET:-"(musl — not applicable)"}
  Profile         : $ESELECT_PROF

  Disk            : $DISK_INSTALL  ($DEV_INSTALL)
  Swap            : $SWAP_G
  LUKS            : $LUKSED
  TPM2 unlock     : $TPM_UNLOCK

  Binary packages : $BINHOST  (v3: $BINHOST_V3)
  Video cards     : $VIDEOCARDS
  Intel microcode : $INTEL_CPU_MICROCODE
  Plymouth theme  : $PLYMOUTH_THEME_SET
  Secure Boot     : $SECUREBOOT_MODSIGN
  SELinux         : $SELINUX $( [[ "$SELINUX" == "y" ]] && echo "($SELINUX_TYPE)" || true )
  Grub Password   : $GRUB_PASSWORD_ENABLE

  Non-root user   : $USER_NAME

  !! $DISK_INSTALL will be completely wiped !!"

    if ! dialog --clear --title "Confirm Installation" --yesno "$SUMMARY" 34 72; then
        clear
        echo "Installation cancelled."
        exit 0
    fi

    # Warn about experimental variants
    if [[ "$INSTALL_VARIANT" != "standard" ]]; then
        dialog --clear --title "Warning: Experimental Variant" --msgbox \
            "The '$INSTALL_VARIANT' variant uses experimental Gentoo profiles.\n\nThese profiles are NOT officially supported for desktop use.\nBinary packages are NOT available — everything will be compiled from source.\n\nProceed only if you know what you are doing." \
            12 72
    fi

    clear

    # ---- Derive partition names ----
    if [[ "$DEV_INSTALL" == "nvme" ]]; then
        EFI_PART="${DISK_INSTALL}p1"
        ROOT_PART="${DISK_INSTALL}p2"
    else
        EFI_PART="${DISK_INSTALL}1"
        ROOT_PART="${DISK_INSTALL}2"
    fi

    export HOSTNAME TIMEZONE_SET LOCALE_GEN_SET ESELECT_LOCALE_SET CONSOLE_KEYMAP
    export INIT_SYSTEM INSTALL_TYPE INSTALL_VARIANT ESELECT_PROF DISK_INSTALL DEV_INSTALL EFI_PART ROOT_PART
    export SWAP_G LUKSED LUKS_PASS BINHOST BINHOST_V3 MIRROR
    export VIDEOCARDS INTEL_CPU_MICROCODE PLYMOUTH_THEME_SET
    export SECUREBOOT_MODSIGN MOK_PASS ROOT_PASS USER_NAME USER_PASS TPM_UNLOCK
    export GRUB_PASSWORD_ENABLE GRUB_PASS SELINUX SELINUX_TYPE
fi

# =============================================================================
# CHROOT SECTION
# =============================================================================
if [[ "${1:-}" == "--chroot" ]]; then

    echo "[*] [CHROOT] Environment ready  (init=$INIT_SYSTEM  variant=$INSTALL_VARIANT)"
    rm -f /etc/profile.d/debug* || true
    echo 'GRUB_CFG=/boot/EFI/gentoo/grub.cfg' >> /etc/environment
    mkdir -p /var/db/repos/gentoo/
    source /etc/profile

    echo "[*] [CHROOT] emerge-webrsync"
    emerge-webrsync

    echo "[*] [CHROOT] Setting profile: $ESELECT_PROF"
    eselect profile set "$ESELECT_PROF"

    # LLVM variants: create gcc/g++ wrappers that delegate to clang.
    # Some packages hardcode "gcc" in their Makefiles. On Gentoo, clang lives in
    # /usr/lib/llvm/XX/bin/ and the versioned path changes on updates, so we use
    # wrapper scripts that resolve clang via PATH at runtime.
    case "$INSTALL_VARIANT" in
        llvm|musl-llvm|musl-llvm-hardened)
            if ! command -v gcc &>/dev/null && command -v clang &>/dev/null; then
                echo "[*] [CHROOT] Creating gcc/g++ wrappers for clang (LLVM variant)"
                printf '#!/bin/sh\nexec clang "$@"\n' > /usr/local/bin/gcc
                printf '#!/bin/sh\nexec clang++ "$@"\n' > /usr/local/bin/g++
                chmod +x /usr/local/bin/gcc /usr/local/bin/g++
            fi
            ;;
    esac

    emerge --oneshot app-portage/mirrorselect

    # ---- Determine init-specific USE flag ----
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        INIT_USE="systemd"
        INIT_DONTUSE="-elogind"
    else
        INIT_USE="elogind"
        INIT_DONTUSE="-systemd"
    fi

    # ---- Determine variant-specific make.conf values ----
    HARDENED_CFLAGS=""
    case "$INSTALL_VARIANT" in
        hardened)
            HARDENED_CFLAGS=" -fstack-protector-strong -D_FORTIFY_SOURCE=2"
            ;;
        musl-hardened|musl-llvm-hardened)
            # musl does not implement glibc's __*_chk wrappers, so
            # _FORTIFY_SOURCE has no effect — only use -fstack-protector-strong
            HARDENED_CFLAGS=" -fstack-protector-strong"
            ;;
    esac

    # C.utf8 locale is provided by glibc; musl only supports C/POSIX
    case "$INSTALL_VARIANT" in
        musl|musl-llvm|musl-hardened|musl-llvm-hardened)
            LC_MESSAGES_VAL="C" ;;
        *)
            LC_MESSAGES_VAL="C.utf8" ;;
    esac

    # Dynamic parallel emerge/make jobs based on RAM, swap and CPU threads.
    #
    # LLVM variants: ~2 GiB per compile thread (typical; peak is higher for
    # heavyweight packages like LLVM itself, but those are built first via the
    # LLVM-upgrade step before this formula matters for the rest of the world).
    # 1 GiB reserved for OS/Portage overhead.
    # total_slots = (RAM - 1 GiB) / 2 GiB; EMERGE_JOBS = total_slots / nproc
    # (clamped to [1,4]); make_j = total_slots / EMERGE_JOBS (clamped to nproc).
    # make -l keeps instantaneous load ≤ make_j regardless of EMERGE_JOBS.
    #
    # GCC variants: ~256 MiB per concurrent thread (average across packages).
    # Swap counted at 50% (slower than RAM). Full nproc for MAKEOPTS.
    _nproc=$(nproc)
    case "$INSTALL_VARIANT" in
        llvm|musl-llvm|musl-llvm-hardened)
            _ram_mib=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
            _total_slots=$(( (_ram_mib - 1024) / 2048 ))
            [[ $_total_slots -lt 1 ]] && _total_slots=1
            EMERGE_JOBS=$(( _total_slots / _nproc ))
            [[ $EMERGE_JOBS -lt 1 ]] && EMERGE_JOBS=1
            [[ $EMERGE_JOBS -gt 4 ]] && EMERGE_JOBS=4
            _make_j=$(( _total_slots / EMERGE_JOBS ))
            [[ $_make_j -gt $_nproc ]] && _make_j=$_nproc
            [[ $_make_j -lt 1 ]] && _make_j=1
            _pipe_flag=" -pipe"
            _lto_flag=" -flto=thin"
            echo "[*] [CHROOT] LLVM variant: ${_ram_mib} MiB RAM, ${_nproc} cores → MAKEOPTS=-j${_make_j}, --jobs ${EMERGE_JOBS}, ThinLTO"
            ;;
        *)
            _eff_mib=$(awk '/MemTotal/{r=$2} /SwapTotal/{s=$2} END{printf "%d", (r + s/2) / 1024}' /proc/meminfo)
            EMERGE_JOBS=$(( _eff_mib / 256 / _nproc ))
            [[ $EMERGE_JOBS -lt 1 ]] && EMERGE_JOBS=1
            [[ $EMERGE_JOBS -gt $_nproc ]] && EMERGE_JOBS=$_nproc
            _make_j=$_nproc
            _pipe_flag=" -pipe"
            _lto_flag=" -flto"
            echo "[*] [CHROOT] Resources: ${_eff_mib} MiB effective, ${_nproc} threads → MAKEOPTS=-j${_make_j}, --jobs ${EMERGE_JOBS}, LTO"
            ;;
    esac

    echo "[*] [CHROOT] Writing make.conf"
    cat > /etc/portage/make.conf <<MAKECONF
# ====================
# = GENTOO MAKE.CONF =
# ====================

COMMON_FLAGS="-march=native -O2${_pipe_flag}${HARDENED_CFLAGS}${_lto_flag}"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="\${RUSTFLAGS} -C target-cpu=native"

MAKEOPTS="-j${_make_j} -l${_make_j}"

EMERGE_DEFAULT_OPTS="--jobs ${EMERGE_JOBS} --load-average ${_make_j}"

LDFLAGS="\${LDFLAGS}${_lto_flag}"

FEATURES="\${FEATURES} candy parallel-fetch parallel-install"

USE="dist-kernel $INIT_USE $INIT_DONTUSE"

ACCEPT_LICENSE="*"

GRUB_PLATFORMS="efi-64"

VIDEO_CARDS="$VIDEOCARDS"

# Build output in English (required for bug reports)
LC_MESSAGES=$LC_MESSAGES_VAL

MAKECONF

    # Toolchain-specific configuration appended to make.conf
    case "$INSTALL_VARIANT" in
        llvm|musl-llvm|musl-llvm-hardened)
            echo "[*] [CHROOT] Configuring LLVM toolchain in make.conf"
            cat >> /etc/portage/make.conf <<'LLVMCONF'

# LLVM/Clang toolchain — only CC/CXX and safe binutils replacements.
# LD, AS, CPP, STRIP, etc. are set by the LLVM profile via eselect.
CC="clang"
CXX="clang++"
AR="llvm-ar"
NM="llvm-nm"
RANLIB="llvm-ranlib"

LLVMCONF
            ;;
        *)
            # GCC LTO requires wrapper tools that expose the LTO plugin to binutils.
            # Without these, ld cannot read the LLVM/GCC IR objects at link time.
            echo "[*] [CHROOT] Configuring GCC LTO tools in make.conf"
            cat >> /etc/portage/make.conf <<'GCCLTOCONF'

# GCC LTO tools — exposes the GCC LTO plugin to binutils at link time.
AR="gcc-ar"
NM="gcc-nm"
RANLIB="gcc-ranlib"

GCCLTOCONF
            ;;
    esac

    echo "[*] [CHROOT] Selecting best mirrors"
    BEST_MIRROR=$(mirrorselect -s3 -b10 -S -D -o)
    echo "$BEST_MIRROR" >> /etc/portage/make.conf

    EXTRA_USE=""
    EXTRA_FEATURES=""

    # Hardened USE flags
    case "$INSTALL_VARIANT" in
        hardened|musl-hardened|musl-llvm-hardened)
            EXTRA_USE+=" hardened pie ssp"
            ;;
    esac

    # SELinux USE flags
    if [[ "${SELINUX:-n}" == "y" ]]; then
        EXTRA_USE+=" selinux"
        [[ "$SELINUX_TYPE" == "targeted" ]] && EXTRA_USE+=" unconfined"
    fi

    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        EXTRA_USE+=" modules-sign secureboot"
        if ! mountpoint -q /sys/firmware/efi/efivars; then
            mount -t efivarfs efivarfs /sys/firmware/efi/efivars \
                || { echo "[!] Error mounting efivars"; exit 1; }
        fi
        cat >> /etc/portage/make.conf <<SBCONF

# MOK signing keys (generated by sbctl)
# Enrolled into shim MOKlist via mokutil -- NOT into UEFI db.
MODULES_SIGN_KEY="/var/lib/sbctl/keys/db/db.key"
MODULES_SIGN_CERT="/var/lib/sbctl/keys/db/db.pem"
MODULES_SIGN_HASH="sha512"

SECUREBOOT_SIGN_KEY="/var/lib/sbctl/keys/db/db.key"
SECUREBOOT_SIGN_CERT="/var/lib/sbctl/keys/db/db.pem"

SBCONF
    fi

    if [[ "$BINHOST" == "y" ]]; then
        EXTRA_FEATURES+=" getbinpkg binpkg-request-signature"
        mkdir -p /etc/portage/binrepos.conf/
        SUFFIX=$([[ "$BINHOST_V3" == "y" ]] && echo "x86-64-v3" || echo "x86-64")
        cat > /etc/portage/binrepos.conf/gentoobinhost.conf <<BINCONF
[binhost]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/$SUFFIX
BINCONF
        emerge --sync
    fi

    if [[ -n "$EXTRA_USE" ]]; then
        sed -i "s/^USE=\"dist-kernel $INIT_USE $INIT_DONTUSE\"/USE=\"dist-kernel $INIT_USE $INIT_DONTUSE${EXTRA_USE}\"/" \
            /etc/portage/make.conf
    fi
    if [[ -n "$EXTRA_FEATURES" ]]; then
        sed -i "s/parallel-install\"/parallel-install${EXTRA_FEATURES}\"/" \
            /etc/portage/make.conf
        sed -i 's/EMERGE_DEFAULT_OPTS="--jobs/EMERGE_DEFAULT_OPTS="--usepkg=y --binpkg-changed-deps=y --jobs/' \
            /etc/portage/make.conf
    fi

    echo "[*] [CHROOT] Detecting CPU flags"
    emerge --oneshot app-portage/cpuid2cpuflags
    echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

    echo "[*] [CHROOT] Setting localization"
    ln -sf ../usr/share/zoneinfo/"$TIMEZONE_SET" /etc/localtime
    # musl does not use glibc locales — locale-gen and eselect locale are unavailable
    if command -v locale-gen &>/dev/null; then
        printf "en_US.UTF-8 UTF-8\n%b\n" "$LOCALE_GEN_SET" > /etc/locale.gen
        locale-gen
        eselect locale set "$ESELECT_LOCALE_SET"
    else
        echo "[!] [CHROOT] Skipping locale-gen (musl libc — locales not supported)"
    fi
    env-update && source /etc/profile

    echo "[*] [CHROOT] Writing package.use"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        echo "sys-kernel/installkernel dracut grub systemd" \
            > /etc/portage/package.use/installkernel
        echo "sys-apps/systemd cryptsetup tpm" \
            > /etc/portage/package.use/systemd
    else
        echo "sys-kernel/installkernel dracut grub" \
            > /etc/portage/package.use/installkernel
        echo "sys-auth/elogind -cgroup-hybrid" \
            > /etc/portage/package.use/elogind
    fi
    echo "sys-boot/grub truetype mount" \
        > /etc/portage/package.use/grub
    echo "sys-apps/kmod pkcs7" \
        > /etc/portage/package.use/kmod

    mkdir -p /etc/portage/package.accept_keywords/
    if [[ "${INSTALL_TYPE:-desktop}" == "server" ]]; then
        # Server: use stable kernel — no ~amd64 keyword for kernel packages
        cat > /etc/portage/package.accept_keywords/pkgs <<KEYWORDS
app-crypt/sbctl ~amd64
sys-boot/mokutil ~amd64
KEYWORDS
    else
        cat > /etc/portage/package.accept_keywords/pkgs <<KEYWORDS
app-crypt/sbctl ~amd64
sys-boot/mokutil ~amd64
sys-kernel/gentoo-kernel-bin ~amd64
sys-kernel/gentoo-kernel ~amd64
virtual/dist-kernel ~amd64
KEYWORDS
    fi

    echo "[*] [CHROOT] Installing sbctl and generating MOK keys"
    emerge -N app-crypt/efitools app-crypt/sbctl
    wget https://raw.githubusercontent.com/Deftera186/sbctl/8c7a57ed052f94b8f8eb32321c34736adfdf6ce7/contrib/kernel-install/91-sbctl.install -O /usr/lib/kernel/install.d/91-sbctl.install
    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        sbctl create-keys
    fi

    # Hardened kernel USE flag
    case "$INSTALL_VARIANT" in
        hardened|musl-hardened|musl-llvm-hardened)
            echo "sys-kernel/gentoo-kernel hardened" \
                > /etc/portage/package.use/kernel-hardened
            ;;
    esac

    # SELinux kernel USE flag
    if [[ "${SELINUX:-n}" == "y" ]]; then
        echo "sys-kernel/gentoo-kernel selinux" \
            >> /etc/portage/package.use/kernel-hardened
    fi

    echo "[*] [CHROOT] Installing core packages"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        _PLYMOUTH_PKG=""
        [[ "${INSTALL_TYPE:-desktop}" == "desktop" ]] && _PLYMOUTH_PKG="sys-boot/plymouth"
        emerge -N \
            sys-boot/grub sys-boot/shim sys-boot/efibootmgr sys-boot/mokutil \
            app-crypt/efitools app-eselect/eselect-repository \
            sys-fs/btrfs-progs sys-fs/xfsprogs sys-fs/dosfstools \
            sys-apps/systemd sys-apps/kmod dev-vcs/git \
            sys-kernel/dracut \
            ${_PLYMOUTH_PKG:+"$_PLYMOUTH_PKG"}
    else
        _PLYMOUTH_PKGS=""
        if [[ "${INSTALL_TYPE:-desktop}" == "desktop" ]]; then
            cat >> /etc/portage/package.accept_keywords/pkgs <<KEYWORDPLY
sys-boot/plymouth-openrc-plugin ~amd64
KEYWORDPLY
            _PLYMOUTH_PKGS="sys-boot/plymouth sys-boot/plymouth-openrc-plugin"
        fi
        emerge -N \
            sys-boot/grub sys-boot/shim sys-boot/efibootmgr sys-boot/mokutil \
            app-crypt/efitools app-eselect/eselect-repository \
            sys-fs/btrfs-progs sys-fs/xfsprogs sys-fs/dosfstools \
            sys-auth/elogind sys-apps/kmod dev-vcs/git \
            sys-kernel/dracut \
            ${_PLYMOUTH_PKGS:+$_PLYMOUTH_PKGS}
    fi

    SHIM_EFI="/usr/share/shim/BOOTX64.EFI"
    SHIM_MM="/usr/share/shim/mmx64.efi"
    SIGNED_GRUB="/usr/lib/grub/grub-x86_64.efi.signed"

    for f in "$SHIM_EFI" "$SHIM_MM" "$SIGNED_GRUB"; do
        if [[ ! -f "$f" ]]; then
            echo "[!] Required file not found: $f"
            echo "    Check that sys-boot/grub has USE='secureboot' and sys-boot/shim is installed."
            exit 1
        fi
    done
    echo "[*] [CHROOT] shim and signed GRUB verified OK"

    # =========================================================================
    # SELINUX PACKAGES
    # =========================================================================
    if [[ "${SELINUX:-n}" == "y" ]]; then
        echo "[*] [CHROOT] Installing SELinux packages"
        # Package USE flags for targeted policy
        [[ "$SELINUX_TYPE" == "targeted" ]] && \
            echo "sec-policy/selinux-base-policy unconfined" \
                > /etc/portage/package.use/selinux-policy
        # Core SELinux packages
        emerge -N \
            sys-libs/libselinux \
            sys-apps/policycoreutils \
            sys-apps/checkpolicy \
            sec-policy/selinux-base \
            sec-policy/selinux-base-policy \
            sys-process/audit \
            sec-policy/selinux-dbus \
            sec-policy/selinux-networkmanager

        # Write /etc/selinux/config (permissive for first boot, user switches later)
        echo "[*] [CHROOT] Writing /etc/selinux/config"
        mkdir -p /etc/selinux
        cat > /etc/selinux/config <<SELINUXCONF
# SELinux configuration
SELINUX=permissive
SELINUXTYPE=$SELINUX_TYPE
SELINUXCONF
    fi

    # =========================================================================
    # LUKS / CRYPTTAB
    # =========================================================================
    if [[ "$LUKSED" == "y" ]]; then
        LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
        ROOT_DEV="/dev/mapper/root"
        echo "root  UUID=$LUKS_UUID  none  luks,discard" > /etc/crypttab
    else
        ROOT_DEV="$ROOT_PART"
    fi
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")

    echo "[*] [CHROOT] Writing dracut config"
    mkdir -p /etc/dracut.conf.d
    if [[ "${INSTALL_TYPE:-desktop}" == "desktop" ]]; then
        DRACUT_MODULES="btrfs plymouth"
    else
        DRACUT_MODULES="btrfs"
    fi
    [[ "$LUKSED" == "y" ]] && DRACUT_MODULES+=" crypt"
    [[ "${SELINUX:-n}" == "y" ]] && DRACUT_MODULES+=" selinux"
    cat > /etc/dracut.conf.d/gentoo.conf <<DRACUT
hostonly="yes"
add_dracutmodules+=" $DRACUT_MODULES "
DRACUT

    # On OpenRC, omit systemd-specific dracut modules that can cause
    # conflicts (e.g. systemd-udevd taking over the console from Plymouth).
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        cat >> /etc/dracut.conf.d/gentoo.conf <<DRACUT_ORC
omit_dracutmodules+=" systemd systemd-initrd systemd-networkd dracut-systemd "
DRACUT_ORC
    fi

    # TPM2 kernel drivers needed in initramfs for early unlock
    if [[ "${TPM_UNLOCK:-n}" == "y" ]]; then
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            emerge -N app-crypt/tpm2-tools app-crypt/tpm2-tss
            cat > /etc/dracut.conf.d/tpm2.conf <<TPM2CONF
# TPM2 drivers: tpm_crb (PCIe/ACPI), tpm_tis (LPC), tpm_tis_core (common base)
add_drivers+=" tpm tpm_tis_core tpm_tis tpm_crb "
add_dracutmodules+=" tpm2-tss "
TPM2CONF
        else
            echo "[*] [CHROOT] Enabling GURU overlay for app-crypt/clevis"
            eselect repository enable guru
            emaint sync -r guru
            cat >> /etc/portage/package.accept_keywords/pkgs <<CLEVISKEYWORDS
app-crypt/clevis ~amd64
dev-libs/jose ~amd64
dev-libs/luksmeta ~amd64
CLEVISKEYWORDS
            emerge -N app-crypt/clevis app-crypt/tpm2-tools
            cat > /etc/dracut.conf.d/tpm2.conf <<TPM2CONF
# TPM2 drivers: tpm_crb (PCIe/ACPI), tpm_tis (LPC), tpm_tis_core (common base)
add_drivers+=" tpm tpm_tis_core tpm_tis tpm_crb "
add_dracutmodules+=" clevis clevis-pin-tpm2 "
TPM2CONF
        fi
    fi

    # =========================================================================
    # GRUB CONFIGURATION
    # =========================================================================
    echo "[*] [CHROOT] Configuring /etc/default/grub"
    if [[ "${INSTALL_TYPE:-desktop}" == "desktop" ]]; then
        CMDLINE_LINUX="root=UUID=$ROOT_UUID quiet rw splash mem_sleep_default=s2idle"
        [[ "$INIT_SYSTEM" == "openrc" ]] && CMDLINE_LINUX+=" rd.udev.log_priority=3 vt.global_cursor_default=0"
    else
        CMDLINE_LINUX="root=UUID=$ROOT_UUID quiet rw"
    fi
    [[ "$LUKSED" == "y" ]] && CMDLINE_LINUX+=" rd.luks.uuid=$LUKS_UUID rd.luks.name=$LUKS_UUID=root"
    [[ "${SELINUX:-n}" == "y" ]] && CMDLINE_LINUX+=" security=selinux selinux=1"

    # Write cmdline for dracut: it reads /etc/cmdline.d/ when running inside a chroot
    # (where /proc/cmdline is the host's cmdline and unusable).
    mkdir -p /etc/cmdline.d
    echo "$CMDLINE_LINUX" > /etc/cmdline.d/gentoo.conf

    sed -i "s|^#*GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$CMDLINE_LINUX\"|" \
        /etc/default/grub
    sed -i 's/#GRUB_GFXPAYLOAD_LINUX=/GRUB_GFXPAYLOAD_LINUX=keep/' /etc/default/grub
    if [[ "$LUKSED" == "y" ]]; then
        grep -q 'GRUB_ENABLE_CRYPTODISK' /etc/default/grub \
            || echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
    fi
    if [[ "$GRUB_PASSWORD_ENABLE" == "y" ]]; then
        sed -i 's/CLASS="--class gnu-linux --class gnu --class os"/CLASS="--class gnu-linux --class gnu --class os --unrestricted"/' \
            /etc/grub.d/10_linux
    fi

    # =========================================================================
    # KERNEL
    # =========================================================================
    echo "[*] [CHROOT] Installing kernel"
    KERNEL_PKG=$([[ "$BINHOST" == "y" ]] && echo "sys-kernel/gentoo-kernel-bin" \
                                          || echo "sys-kernel/gentoo-kernel")
    emerge -N "$KERNEL_PKG"
    emerge -N sys-kernel/linux-firmware sys-firmware/sof-firmware
    [[ "$INTEL_CPU_MICROCODE" == "y" ]] && emerge -N sys-firmware/intel-microcode

    # Boot chain: shim (pre-signed by Fedora/Microsoft)
    #               -> grubx64.efi (Gentoo pre-built signed standalone)
    #                    -> kernel + initramfs in /boot/
    # grub-install NOT used (produces unsigned binary shim cannot verify).
    # Standalone GRUB reads grub.cfg from its own EFI directory.
    echo "[*] [CHROOT] Installing shim + pre-signed GRUB to ESP"
    mkdir -p /boot/EFI/gentoo
    cp "$SHIM_EFI"    /boot/EFI/gentoo/shimx64.efi
    cp "$SHIM_MM"     /boot/EFI/gentoo/mmx64.efi
    cp "$SIGNED_GRUB" /boot/EFI/gentoo/grubx64.efi

    if [[ "${GRUB_PASSWORD_ENABLE:-n}" == "y" ]]; then
        GRUB_HASH=$(echo -e "$GRUB_PASS\n$GRUB_PASS" | grub-mkpasswd-pbkdf2 | grep -oP 'grub\.pbkdf2\.[^\s]+')
        cat >> /etc/grub.d/40_custom <<GRUBPWD
set superusers="root"
password_pbkdf2 root $GRUB_HASH
export superusers
GRUBPWD
    fi

    echo "[*] [CHROOT] Generating grub.cfg in ESP"
    GRUB_CFG=/boot/EFI/gentoo/grub.cfg \
        grub-mkconfig -o /boot/EFI/gentoo/grub.cfg

    echo "[*] [CHROOT] Registering shim in UEFI boot order"
    efibootmgr --create \
        --disk "$DISK_INSTALL" \
        --part 1 \
        --loader '\EFI\gentoo\shimx64.efi' \
        --label "Gentoo Linux" \
        --unicode

    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        echo "[*] [CHROOT] Converting cert to DER for MOK enrollment"
        openssl x509 \
            -in  /var/lib/sbctl/keys/db/db.pem \
            -inform PEM \
            -out /var/lib/sbctl/keys/db/db.der \
            -outform DER
        echo "[*] [CHROOT] Enrolling MOK key via mokutil"
        printf "%s\n%s\n" "$MOK_PASS" "$MOK_PASS" | mokutil --import /var/lib/sbctl/keys/db/db.der
    fi

    if [[ "$BINHOST" == "y" ]]; then
        emerge --config sys-kernel/gentoo-kernel-bin
    else
        emerge --config sys-kernel/gentoo-kernel
    fi
    GRUB_CFG=/boot/EFI/gentoo/grub.cfg \
        grub-mkconfig -o /boot/EFI/gentoo/grub.cfg

    # =========================================================================
    # ZRAM SWAP
    # =========================================================================
    echo "[*] [CHROOT] Setting up zram"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        emerge -N sys-apps/zram-generator sys-fs/genfstab
        mkdir -p /etc/systemd/zram-generator.conf.d
        cat > /etc/systemd/zram-generator.conf.d/zram0-swap.conf <<ZRAM
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM
    else
        emerge -N sys-block/zram-init sys-fs/genfstab
        cat > /etc/conf.d/zram-init <<ZRAM
type0="swap"
flag0=""
comp_algorithm0="zstd"
max_comp_streams0="$(nproc)"
size0="$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 2 ))K"
ZRAM
        rc-update add zram-init boot
    fi

    genfstab -U / >> /etc/fstab

    # For OpenRC, the 'swap' service runs before 'localmount', so the @swap
    # Btrfs subvolume is not yet mounted when swapon is attempted.
    # Fix: mark the swap file as 'noauto' in fstab (so OpenRC's swap service
    # skips it), then activate it via /etc/local.d/ which runs after localmount.
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        sed -i 's|\(/swap/swap\.img\s\+none\s\+swap\s\+\)\(defaults\)|\1noauto|' /etc/fstab
        mkdir -p /etc/local.d
        cat > /etc/local.d/swap-file.start <<'SWAPSTART'
#!/bin/sh
swapon /swap/swap.img
SWAPSTART
        chmod +x /etc/local.d/swap-file.start
        cat > /etc/local.d/swap-file.stop <<'SWAPSTOP'
#!/bin/sh
swapoff /swap/swap.img
SWAPSTOP
        chmod +x /etc/local.d/swap-file.stop
        rc-update add local default
    fi

    # =========================================================================
    # HOSTNAME / KEYMAP / MACHINE-ID
    # =========================================================================
    echo "$HOSTNAME" > /etc/hostname

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemd-machine-id-setup
        systemd-firstboot --keymap="$CONSOLE_KEYMAP"
    else
        cat > /etc/conf.d/hostname <<HNCONF
hostname="$HOSTNAME"
HNCONF
        sed -i "s/^keymap=.*/keymap=\"$CONSOLE_KEYMAP\"/" /etc/conf.d/keymaps
    fi

    # =========================================================================
    # ADDITIONAL PACKAGES
    # =========================================================================
    echo "[*] [CHROOT] Installing additional packages"
    _WIFI_PKGS=""
    [[ "${INSTALL_TYPE:-desktop}" == "desktop" ]] && _WIFI_PKGS="net-wireless/iw net-wireless/wpa_supplicant"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        emerge -N \
            sys-apps/plocate \
            net-misc/chrony \
            net-misc/dhcpcd \
            app-admin/sudo \
            net-misc/networkmanager \
            ${_WIFI_PKGS:+$_WIFI_PKGS}
    else
        emerge -N \
            sys-apps/plocate \
            net-misc/chrony \
            net-misc/dhcpcd \
            app-admin/sudo \
            net-misc/networkmanager \
            sys-process/cronie \
            ${_WIFI_PKGS:+$_WIFI_PKGS}
    fi

    # =========================================================================
    # SERVICE ENABLEMENT
    # =========================================================================
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl enable chronyd.service NetworkManager
        if [[ "${INSTALL_TYPE:-desktop}" == "desktop" ]]; then
            plymouth-set-default-theme "$PLYMOUTH_THEME_SET"
        fi
        # Disable hibernation: not supported with Secure Boot lockdown.
        # Suspend-to-idle (s2idle) is set via kernel cmdline (desktop only).
        systemctl mask hibernate.target suspend-then-hibernate.target
    else
        rc-update add chronyd default
        rc-update add NetworkManager default
        rc-update add elogind boot
        rc-update add cronie default
        [[ "${SELINUX:-n}" == "y" ]] && rc-update add selinux_gentoo boot
        if [[ "${INSTALL_TYPE:-desktop}" == "desktop" ]]; then
            plymouth-set-default-theme "$PLYMOUTH_THEME_SET"
            # plymouth-openrc-plugin handles Plymouth lifecycle automatically.
            # Disable interactive mode so OpenRC doesn't conflict with Plymouth.
            sed -i 's/^#*rc_interactive=.*/rc_interactive="NO"/' /etc/rc.conf
        fi
    fi

    # =========================================================================
    # GRUB-BTRFS PREPARATION
    # Configure grub-btrfs to use the correct grub.cfg path for the
    # standalone signed GRUB in /boot/EFI/gentoo/.
    # grub-btrfs is not emerged here (user installs it post-install),
    # but we pre-create the config so it works out of the box.
    # =========================================================================
    echo "[*] [CHROOT] Pre-configuring grub-btrfs paths"

    # grub-btrfs config: tell it where our grub dir lives
    mkdir -p /etc/default/grub-btrfs
    cat > /etc/default/grub-btrfs/config <<GRUBBTCFG
# grub-btrfs configuration
# Adjusted for standalone signed GRUB in /boot/EFI/gentoo/
GRUB_BTRFS_GRUB_DIRNAME="/boot/EFI/gentoo"
GRUB_BTRFS_MKCONFIG="/usr/local/sbin/update-grub"
GRUB_BTRFS_GBTRFS_SEARCH_DIRNAME="/EFI/gentoo"
GRUBBTCFG

    # update-grub wrapper: always output to the correct grub.cfg location
    cat > /usr/local/sbin/update-grub <<'UPDATEGRUB'
#!/usr/bin/env bash
# Wrapper: regenerate grub.cfg in the standalone GRUB's EFI directory.
# This ensures grub-btrfs, kernel installs, and manual updates all
# write to the correct location.
set -euo pipefail
GRUB_CFG="/boot/EFI/gentoo/grub.cfg"
echo "[update-grub] Generating $GRUB_CFG ..."
GRUB_CFG="$GRUB_CFG" grub-mkconfig -o "$GRUB_CFG"
echo "[update-grub] Done."
UPDATEGRUB
    chmod +x /usr/local/sbin/update-grub

    # Init-specific grub-btrfsd service configuration
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        mkdir -p /etc/systemd/system/grub-btrfsd.service.d
        cat > /etc/systemd/system/grub-btrfsd.service.d/override.conf <<'GRUBBTOVERRIDE'
[Service]
# Clear the default ExecStart, then set ours
ExecStart=
ExecStart=/usr/bin/grub-btrfsd --syslog /.snapshots
Environment="GRUB_CFG=/boot/EFI/gentoo/grub.cfg"
GRUBBTOVERRIDE
    else
        mkdir -p /etc/conf.d
        cat > /etc/conf.d/grub-btrfsd <<'GRUBBTRC'
# grub-btrfsd OpenRC configuration
GRUB_BTRFSD_OPTS="--syslog /.snapshots"
GRUBBTRC
    fi

    # Also make installkernel use our update-grub for grub.cfg regeneration
    mkdir -p /etc/kernel
    cat > /etc/kernel/postinst.d/99-update-grub <<'POSTINST'
#!/usr/bin/env bash
# Regenerate grub.cfg after kernel install
exec /usr/local/sbin/update-grub
POSTINST
    chmod +x /etc/kernel/postinst.d/99-update-grub

    # =========================================================================
    # TPM2 ENROLLMENT SCRIPT (runs after first reboot)
    # =========================================================================
    if [[ "${TPM_UNLOCK:-n}" == "y" ]]; then
        echo "[*] [CHROOT] Creating TPM2 enrollment script"
        LUKS_UUID_FOR_ENROLL=$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null || true)

        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            # ---- systemd: use systemd-cryptenroll ----
            cat > /usr/local/sbin/gentoo-tpm-enroll.sh <<'TPMENROLL_HEAD'
#!/usr/bin/env bash
# =============================================================================
# TPM2 LUKS enrollment script — run ONCE after first successful boot
# Binds the LUKS decryption key to TPM2 PCR 7.
#
# PCR 7  = Secure Boot state (firmware certs + SB on/off)
#
# Fallback: the LUKS passphrase always works even if TPM unlock fails.
# =============================================================================
set -euo pipefail
TPMENROLL_HEAD

            # Inject the LUKS device path (needs variable expansion)
            echo "LUKS_DEV=\"\${1:-/dev/disk/by-uuid/$LUKS_UUID_FOR_ENROLL}\"" \
                >> /usr/local/sbin/gentoo-tpm-enroll.sh

            cat >> /usr/local/sbin/gentoo-tpm-enroll.sh <<'TPMENROLL_BODY'

if [[ ! -b "$LUKS_DEV" ]]; then
    echo "[!] LUKS device not found: $LUKS_DEV"
    echo "    Usage: $0 [/dev/sdXN]"
    exit 1
fi

echo "[*] Checking TPM2 device..."
if ! systemd-cryptenroll --tpm2-device=list 2>&1 | grep -q 'PATH'; then
    echo "[!] No TPM2 device found. Aborting."
    exit 1
fi

echo "[*] Current LUKS keyslots:"
systemd-cryptenroll "$LUKS_DEV"

echo ""
echo "[*] Enrolling TPM2 key bound to PCR 7"
echo "    PCR 7  = Secure Boot state"
echo "    Enter your LUKS passphrase when prompted."
echo ""
TPMENROLL_BODY

            cat >> /usr/local/sbin/gentoo-tpm-enroll.sh <<'TPMENROLL_NOPIN'
systemd-cryptenroll \
    --tpm2-device=auto \
    --tpm2-pcrs=7 \
    "$LUKS_DEV"
TPMENROLL_NOPIN

            cat >> /usr/local/sbin/gentoo-tpm-enroll.sh <<'TPMENROLL_TAIL'

echo ""
echo "[*] Enrollment complete. Updated keyslots:"
systemd-cryptenroll "$LUKS_DEV"

echo ""
echo "[*] Updating /etc/crypttab for TPM2 auto-unlock..."
LUKS_UUID_VAL=$(blkid -s UUID -o value "$LUKS_DEV")
if grep -q "luks-$LUKS_UUID_VAL\|UUID=$LUKS_UUID_VAL" /etc/crypttab 2>/dev/null; then
    sed -i "s|\(UUID=$LUKS_UUID_VAL[[:space:]].*none[[:space:]]\)\(.*\)|\1\2,tpm2-device=auto|" /etc/crypttab
    echo "[*] /etc/crypttab updated."
else
    echo "[!] Could not find UUID=$LUKS_UUID_VAL in /etc/crypttab"
    echo "    Add 'tpm2-device=auto' to the options field manually."
fi

echo ""
echo "[*] Rebuilding initramfs to include TPM2 modules..."
dracut --force

echo ""
echo "[!] Done. TPM2 unlock is now active."
echo "    On next reboot, LUKS will unlock automatically via TPM2."
echo "    Your passphrase still works as fallback."
echo ""
echo "    To remove TPM2 unlock later:"
echo "      systemd-cryptenroll --wipe-slot=tpm2 $LUKS_DEV"
TPMENROLL_TAIL

        else
            # ---- OpenRC: use clevis for TPM2 binding ----
            cat > /usr/local/sbin/gentoo-tpm-enroll.sh <<'CLEVIS_HEAD'
#!/usr/bin/env bash
# =============================================================================
# TPM2 LUKS enrollment script (clevis) — run ONCE after first successful boot
# Binds the LUKS decryption key to TPM2 PCR 7.
#
# PCR 7  = Secure Boot state (firmware certs + SB on/off)
#
# Fallback: the LUKS passphrase always works even if TPM unlock fails.
# =============================================================================
set -euo pipefail
CLEVIS_HEAD

            # Inject the LUKS device path (needs variable expansion)
            echo "LUKS_DEV=\"\${1:-/dev/disk/by-uuid/$LUKS_UUID_FOR_ENROLL}\"" \
                >> /usr/local/sbin/gentoo-tpm-enroll.sh

            cat >> /usr/local/sbin/gentoo-tpm-enroll.sh <<'CLEVIS_BODY'

if [[ ! -b "$LUKS_DEV" ]]; then
    echo "[!] LUKS device not found: $LUKS_DEV"
    echo "    Usage: $0 [/dev/sdXN]"
    exit 1
fi

echo "[*] Checking TPM2 device..."
if ! tpm2_getcap properties-fixed 2>/dev/null | grep -q 'TPM2_PT_MANUFACTURER'; then
    echo "[!] No TPM2 device found. Aborting."
    exit 1
fi

echo "[*] Current LUKS keyslots:"
cryptsetup luksDump "$LUKS_DEV"

echo ""
echo "[*] Enrolling TPM2 key bound to PCR 7 using clevis"
echo "    PCR 7  = Secure Boot state"
echo "    Enter your LUKS passphrase when prompted."
echo ""

clevis luks bind -d "$LUKS_DEV" tpm2 '{"pcr_ids":"7"}'

echo ""
echo "[*] Enrollment complete. Updated keyslots:"
cryptsetup luksDump "$LUKS_DEV"

echo ""
echo "[*] Rebuilding initramfs to include clevis TPM2 modules..."
dracut --force

echo ""
echo "[!] Done. TPM2 unlock is now active."
echo "    On next reboot, LUKS will unlock automatically via TPM2."
echo "    Your passphrase still works as fallback."
echo ""
echo "    To remove TPM2 unlock later:"
echo "      clevis luks unbind -d $LUKS_DEV -s <slot>"
echo "      (use 'cryptsetup luksDump $LUKS_DEV' to find the clevis slot)"
CLEVIS_BODY
        fi
        chmod +x /usr/local/sbin/gentoo-tpm-enroll.sh
        echo "[*] [CHROOT] TPM2 enrollment script created at /usr/local/sbin/gentoo-tpm-enroll.sh"
    fi

    # =========================================================================
    # SELINUX RELABELING SCRIPT (runs after first reboot)
    # =========================================================================
    if [[ "${SELINUX:-n}" == "y" ]]; then
        echo "[*] [CHROOT] Creating SELinux relabeling script"
        cat > /usr/local/sbin/gentoo-selinux-relabel.sh <<'SELINUXRELABEL'
#!/usr/bin/env bash
# =============================================================================
# SELinux filesystem relabeling — run ONCE after first successful boot
#
# This script relabels the entire filesystem with correct SELinux contexts,
# then provides instructions for switching to enforcing mode.
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[!] Must run as root."
    exit 1
fi

echo "[*] Checking SELinux status..."
if ! command -v sestatus &>/dev/null; then
    echo "[!] sestatus not found. SELinux tools not installed?"
    exit 1
fi

sestatus

CURRENT_MODE=$(getenforce)
if [[ "$CURRENT_MODE" == "Disabled" ]]; then
    echo "[!] SELinux is disabled. Boot with selinux=1 and security=selinux."
    exit 1
fi

if [[ "$CURRENT_MODE" != "Permissive" ]]; then
    echo "[!] SELinux is in $CURRENT_MODE mode. Switching to Permissive for relabeling."
    setenforce 0
fi

echo ""
echo "[*] Loading SELinux policy modules..."
semodule -B || echo "[!] Warning: semodule -B returned non-zero. Continuing anyway."

echo ""
echo "[*] Relabeling entire filesystem. This may take several minutes..."
rlpkg -a -r 2>/dev/null || restorecon -Rv / 2>/dev/null || {
    echo "[!] Relabeling failed. Try manually: restorecon -Rv /"
    exit 1
}

echo ""
echo "[*] Relabeling complete."
echo ""
echo "[*] Next steps:"
echo "    1. Reboot the system"
echo "    2. After reboot, verify with: sestatus"
echo "    3. If everything works, switch to enforcing mode:"
echo "       sudo sed -i 's/^SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config"
echo "    4. Reboot again to boot in enforcing mode"
echo ""
echo "    To temporarily test enforcing without editing config:"
echo "       sudo setenforce 1"
echo ""
echo "    If enforcing mode causes problems, boot with enforcing=0"
echo "    on the kernel command line to force permissive mode."
SELINUXRELABEL
        chmod +x /usr/local/sbin/gentoo-selinux-relabel.sh
        echo "[*] [CHROOT] SELinux relabeling script created at /usr/local/sbin/gentoo-selinux-relabel.sh"
    fi

    # =========================================================================
    # USERS
    # =========================================================================
    echo "[*] [CHROOT] Setting up users"
    echo "root:$ROOT_PASS" | chpasswd
    useradd -m -G users,wheel,audio,cdrom,usb,video -s /bin/bash "$USER_NAME"
    echo "${USER_NAME}:${USER_PASS}" | chpasswd
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

    # =========================================================================
    # PORTAGE REPO: SWITCH TO GIT
    # =========================================================================
    echo "[*] [CHROOT] Switching Portage repo to git"
    mkdir -p /etc/portage/repos.conf/
    cat > /etc/portage/repos.conf/gentoo.conf <<GITCONF
[DEFAULT]
main-repo = gentoo

[gentoo]
sync-depth = 1
sync-type = git
auto-sync = yes
location = /var/db/repos/gentoo
sync-git-verify-commit-signature = yes
sync-openpgp-key-path = /usr/share/openpgp-keys/gentoo-release.asc
sync-uri = https://github.com/gentoo-mirror/gentoo.git
GITCONF

    rm -rf /var/db/repos/gentoo/*
    emaint sync

    # =========================================================================
    # CLEANUP & SUMMARY
    # =========================================================================
    echo "[*] [CHROOT] Cleanup"
    rm -f /stage3-*.tar.*
    swapoff /swap/swap.img || true

    echo "============================================"
    echo "[*] EFI partition layout:"
    find /boot/EFI -name "*.efi" | sort
    echo ""
    echo "[*] GRUB config location:"
    echo "    /boot/EFI/gentoo/grub.cfg"
    echo ""
    echo "[*] To regenerate grub.cfg at any time:"
    echo "    update-grub"
    echo ""
    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        echo "[!] On FIRST REBOOT:"
        echo "    1. MokManager launches automatically"
        echo "    2. Choose 'Enroll MOK' and enter the MOK password you set"
        echo "    3. Reboot"
        echo "    4. In UEFI firmware settings: ENABLE Secure Boot"
        echo ""
        echo "[!] Verify module signatures after boot:"
        echo "    modinfo <module> | grep sig"
    fi
    echo "============================================"
    if [[ "${TPM_UNLOCK:-n}" == "y" ]]; then
        echo "[!] TPM2 unlock:"
        echo "    After first successful boot, run:"
        echo "      sudo /usr/local/sbin/gentoo-tpm-enroll.sh"
        echo ""
    fi
    if [[ "${SELINUX:-n}" == "y" ]]; then
        echo "[!] SELinux:"
        echo "    System will boot in PERMISSIVE mode."
        echo "    After first boot, relabel the filesystem:"
        echo "      sudo /usr/local/sbin/gentoo-selinux-relabel.sh"
        echo "    Then follow the instructions to switch to enforcing."
        echo ""
    fi
    echo "[*] grub-btrfs: install it post-reboot with:"
    echo "      emerge sys-boot/grub-btrfs"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        echo "      systemctl enable --now grub-btrfsd"
    else
        echo "      rc-update add grub-btrfsd default"
        echo "      rc-service grub-btrfsd start"
    fi
    echo "    Config is already pre-created in /etc/default/grub-btrfs/config"
    echo ""
    echo "[*] Done. Type 'exit', unmount everything, then reboot."
    rm -f /gentoo-install.sh
    exit 0
fi

# =============================================================================
# PRE-INSTALLATION CHECKS
# =============================================================================

echo "[*] [HOST] Running pre-installation checks..."

# Root privileges
[[ $EUID -eq 0 ]] || { echo "[!] Must run as root."; exit 1; }

# UEFI boot mode
[[ -d /sys/firmware/efi ]] || { echo "[!] UEFI boot mode not detected. This script requires UEFI."; exit 1; }

# Target disk exists and is a block device
[[ -b "$DISK_INSTALL" ]] || { echo "[!] Target disk $DISK_INSTALL does not exist or is not a block device."; exit 1; }

# Target disk is not currently mounted
if grep -q "^${DISK_INSTALL}" /proc/mounts; then
    echo "[!] Target disk $DISK_INSTALL (or a partition) is currently mounted. Unmount first."
    exit 1
fi

# Required host tools
_REQUIRED_TOOLS="sgdisk parted mkfs.fat mkfs.btrfs btrfs mount curl wget tar blkid chattr fallocate mkswap chronyd truncate"
[[ "$LUKSED" == "y" ]] && _REQUIRED_TOOLS="$_REQUIRED_TOOLS cryptsetup"
_MISSING=""
for _tool in $_REQUIRED_TOOLS; do
    command -v "$_tool" &>/dev/null || _MISSING="$_MISSING $_tool"
done
[[ -z "$_MISSING" ]] || { echo "[!] Missing required tools:$_MISSING"; exit 1; }

# Network connectivity (mirror reachable)
if ! curl -s --max-time 5 --head "$MIRROR" &>/dev/null; then
    echo "[!] Cannot reach mirror $MIRROR. Check network connectivity."
    exit 1
fi

# Swap size sanity (warning only)
_SWAP_NUM="${SWAP_G//[^0-9]/}"
if [[ -n "$_SWAP_NUM" ]]; then
    (( _SWAP_NUM < 1 )) && echo "[!] Warning: Swap size $SWAP_G is unusually small (< 1G)."
    (( _SWAP_NUM > 64 )) && echo "[!] Warning: Swap size $SWAP_G is unusually large (> 64G)."
fi

# Hostname format (warning only)
[[ "$HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]] || echo "[!] Warning: Hostname '$HOSTNAME' contains invalid characters. Only [a-zA-Z0-9-] recommended."

echo "[*] [HOST] All pre-installation checks passed."

# =============================================================================
# HOST (PRE-CHROOT) SECTION
# =============================================================================

echo "[*] [HOST] Clock synchronization"
chronyd -q

echo "[*] [HOST] Wiping partition table on $DISK_INSTALL"
sgdisk --zap-all "$DISK_INSTALL"

echo "[*] [HOST] Creating GPT partition table"
parted -s "$DISK_INSTALL" mklabel gpt

echo "[*] [HOST] Creating EFI partition (1 MiB -> 1025 MiB = 1 GiB)"
parted -s "$DISK_INSTALL" mkpart ESP fat32 1MiB 1025MiB
parted -s "$DISK_INSTALL" set 1 esp on
mkfs.fat -F32 "$EFI_PART"

echo "[*] [HOST] Creating root partition (1025 MiB -> 100%)"
parted -s "$DISK_INSTALL" mkpart primary 1025MiB 100%
parted -s "$DISK_INSTALL" type 2 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709

mkdir -p /mnt/gentoo

if [[ "$LUKSED" == "y" ]]; then
    echo "[*] [HOST] [LUKS] Encrypting root partition"
    echo -n "$LUKS_PASS" | cryptsetup luksFormat --key-size 512 "$ROOT_PART" \
        -d - --batch-mode \
        || { echo "[!] luksFormat failed"; exit 1; }
    echo "[*] [HOST] [LUKS] Opening LUKS container"
    echo -n "$LUKS_PASS" | cryptsetup luksOpen --allow-discards "$ROOT_PART" root \
        -d - \
        || { echo "[!] luksOpen failed"; exit 1; }
    ROOT_DEV_MNT="/dev/mapper/root"
else
    ROOT_DEV_MNT="$ROOT_PART"
fi

echo "[*] [HOST] Formatting root as Btrfs"
mkfs.btrfs -f "$ROOT_DEV_MNT"

echo "[*] [HOST] Creating Btrfs subvolumes"
mount "$ROOT_DEV_MNT" /mnt/gentoo
cd /mnt/gentoo
for subvol in @ @home @log @cache @tmp @swap; do
    btrfs subvolume create "$subvol"
done
cd ~
umount /mnt/gentoo

MOUNT_OPTS="noatime,compress=zstd:3,ssd,discard=async"

echo "[*] [HOST] Mounting subvolumes"
mount -o "$MOUNT_OPTS",subvol=@      "$ROOT_DEV_MNT" /mnt/gentoo
mkdir -p /mnt/gentoo/{boot,home,.snapshots,var/cache,var/log,tmp,swap}
mount -o "$MOUNT_OPTS",subvol=@home       "$ROOT_DEV_MNT" /mnt/gentoo/home
mount -o "$MOUNT_OPTS",subvol=@log        "$ROOT_DEV_MNT" /mnt/gentoo/var/log
mount -o "$MOUNT_OPTS",subvol=@cache      "$ROOT_DEV_MNT" /mnt/gentoo/var/cache
mount -o noatime,subvol=@tmp              "$ROOT_DEV_MNT" /mnt/gentoo/tmp
mount -o noatime,nodatacow,subvol=@swap   "$ROOT_DEV_MNT" /mnt/gentoo/swap
mount "$EFI_PART" /mnt/gentoo/boot

# /tmp permissions: world-writable + sticky bit
chmod 1777 /mnt/gentoo/tmp

echo "[*] [HOST] Creating swap file ($SWAP_G)"
truncate -s 0 /mnt/gentoo/swap/swap.img
chattr +C /mnt/gentoo/swap/swap.img
btrfs property set /mnt/gentoo/swap/ compression none
fallocate -l "$SWAP_G" /mnt/gentoo/swap/swap.img
chmod 0600 /mnt/gentoo/swap/swap.img
mkswap /mnt/gentoo/swap/swap.img
swapon /mnt/gentoo/swap/swap.img

echo "[*] [HOST] Downloading stage3 ($INSTALL_VARIANT / $INIT_SYSTEM)"
cd /mnt/gentoo
case "$INSTALL_VARIANT" in
    standard)
        if [[ "${INSTALL_TYPE:-desktop}" == "server" ]]; then
            STAGE3_VARIANT="${INIT_SYSTEM}"           # stage3-amd64-systemd / stage3-amd64-openrc
        else
            STAGE3_VARIANT="desktop-${INIT_SYSTEM}"
        fi
        ;;
    llvm)               STAGE3_VARIANT="llvm-${INIT_SYSTEM}" ;;
    hardened)           STAGE3_VARIANT="hardened-${INIT_SYSTEM}" ;;
    musl)               STAGE3_VARIANT="musl" ;;
    musl-llvm)          STAGE3_VARIANT="musl-llvm" ;;
    musl-hardened)      STAGE3_VARIANT="musl-hardened" ;;
    musl-llvm-hardened) STAGE3_VARIANT="musl-llvm" ;;  # use musl-llvm stage3; hardened applied via profile + make.conf
esac
LATEST=$(curl -sS "$MIRROR/latest-stage3-amd64-${STAGE3_VARIANT}.txt") || {
    echo "[!] Failed to fetch stage3 metadata from $MIRROR/latest-stage3-amd64-${STAGE3_VARIANT}.txt"
    exit 1
}
STAGE3=$(echo "$LATEST" \
    | grep "stage3-amd64-${STAGE3_VARIANT}-.*\.tar\.xz" \
    | grep -v '\.CONTENTS\|\.DIGESTS\|\.asc' \
    | cut -d' ' -f1 || true)
if [[ -z "$STAGE3" ]]; then
    echo "[!] Could not find stage3 tarball in metadata for variant '$STAGE3_VARIANT'"
    echo "[!] URL: $MIRROR/latest-stage3-amd64-${STAGE3_VARIANT}.txt"
    exit 1
fi
wget "$MIRROR/$STAGE3" || { echo "[!] Failed to download $MIRROR/$STAGE3"; exit 1; }

echo "[*] [HOST] Extracting stage3"
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

echo "[*] [HOST] Copying DNS config"
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

echo "[*] [HOST] Mounting virtual filesystems"
mount --types proc    /proc    /mnt/gentoo/proc
mount --rbind         /sys     /mnt/gentoo/sys  && mount --make-rslave /mnt/gentoo/sys
mount --rbind         /dev     /mnt/gentoo/dev  && mount --make-rslave /mnt/gentoo/dev
mount --bind          /run     /mnt/gentoo/run  && mount --make-slave  /mnt/gentoo/run

echo "[*] [HOST] Entering chroot"
cp /root/gentoo-install.sh /mnt/gentoo/gentoo-install.sh
chmod +x /mnt/gentoo/gentoo-install.sh

chroot /mnt/gentoo /usr/bin/env \
    HOSTNAME="$HOSTNAME" \
    INIT_SYSTEM="$INIT_SYSTEM" \
    INSTALL_TYPE="$INSTALL_TYPE" \
    INSTALL_VARIANT="$INSTALL_VARIANT" \
    TIMEZONE_SET="$TIMEZONE_SET" \
    LOCALE_GEN_SET="$LOCALE_GEN_SET" \
    ESELECT_LOCALE_SET="$ESELECT_LOCALE_SET" \
    CONSOLE_KEYMAP="$CONSOLE_KEYMAP" \
    ESELECT_PROF="$ESELECT_PROF" \
    DISK_INSTALL="$DISK_INSTALL" \
    DEV_INSTALL="$DEV_INSTALL" \
    EFI_PART="$EFI_PART" \
    ROOT_PART="$ROOT_PART" \
    SWAP_G="$SWAP_G" \
    LUKSED="$LUKSED" \
    LUKS_PASS="${LUKS_PASS:-}" \
    BINHOST="$BINHOST" \
    BINHOST_V3="$BINHOST_V3" \
    MIRROR="$MIRROR" \
    VIDEOCARDS="$VIDEOCARDS" \
    INTEL_CPU_MICROCODE="$INTEL_CPU_MICROCODE" \
    PLYMOUTH_THEME_SET="$PLYMOUTH_THEME_SET" \
    SECUREBOOT_MODSIGN="$SECUREBOOT_MODSIGN" \
    MOK_PASS="${MOK_PASS:-}" \
    TPM_UNLOCK="${TPM_UNLOCK:-n}" \
    ROOT_PASS="$ROOT_PASS" \
    USER_NAME="$USER_NAME" \
    USER_PASS="$USER_PASS" \
    GRUB_PASSWORD_ENABLE="${GRUB_PASSWORD_ENABLE:-n}" \
    GRUB_PASS="${GRUB_PASS:-}" \
    SELINUX="${SELINUX:-n}" \
    SELINUX_TYPE="${SELINUX_TYPE:-}" \
    /bin/bash /gentoo-install.sh --chroot
