#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# GENTOO AUTO-INSTALL SCRIPT
# Boot chain: UEFI → shim (pre-signed by Microsoft/Fedora)
#                  → grubx64.efi (Gentoo pre-built signed standalone GRUB)
#                  → kernel in /boot/
# Secureboot: sbctl generates MOK keys; key enrolled via mokutil into shim MOKlist.
#             NO sbctl enroll-keys (no direct UEFI db enrollment needed with shim).
# Snapshots:  grub-btrfs + snapper
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

    # ---- Localization ----
    ask_input TIMEZONE_SET "Localization" \
        "Timezone  (search: ls -l /usr/share/zoneinfo)" \
        "Europe/Rome"

    ask_input LOCALE_GEN_SET "Localization" \
        "Entries for /etc/locale.gen (separate multiple with \\n)\nExample: it_IT ISO-8859-1\\nit_IT.UTF-8 UTF-8" \
        "it_IT ISO-8859-1\nit_IT.UTF-8 UTF-8"

    ask_input ESELECT_LOCALE_SET "Localization" \
        "eselect locale target — UTF8 without the dash\nExample: it_IT.UTF-8  ->  it_IT.UTF8" \
        "it_IT.UTF8"

    ask_input SYSTEMD_LOCALE "Localization" \
        "systemd-firstboot keymap  (e.g. it, us, de):" \
        "it"

    # ---- Profile ----
    ask_radio ESELECT_PROF "Portage Profile" \
        "Select a Portage profile  (only systemd profiles are supported):" \
        "default/linux/amd64/23.0/desktop/plasma/systemd" "KDE Plasma / systemd"      "on"  \
        "default/linux/amd64/23.0/desktop/gnome/systemd"  "GNOME / systemd"           "off" \
        "default/linux/amd64/23.0/desktop/systemd"        "Desktop (no DE) / systemd" "off" \
        "default/linux/amd64/23.0/systemd"                "Minimal / systemd"         "off"

    # ---- Portage / binhost ----
    ask_yesno BINHOST "Portage" \
        "Use Gentoo binary package host?\n(Much faster installation -- recommended)" "y"
    if [[ "$BINHOST" == "y" ]]; then
        ask_yesno BINHOST_V3 "Portage" \
            "Use x86-64-v3 binaries?\n(Requires AVX2 -- choose No if unsure)" "y"
    else
        BINHOST_V3="n"
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
        "Swap file size  (e.g. 8G, 16G, 32G):" "16G"

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
    ask_input VIDEOCARDS "Hardware" \
        "VIDEO_CARDS value for make.conf\nExamples:  intel   /   amdgpu radeonsi   /   nvidia" \
        "intel"

    ask_yesno INTEL_CPU_MICROCODE "Hardware" \
        "Install Intel CPU microcode  (sys-firmware/intel-microcode)?" "y"

    # ---- Plymouth ----
    ask_radio PLYMOUTH_THEME_SET "Boot Splash" \
        "Plymouth theme:" \
        "solar"   "Solar   (animated sun rings)"     "on"  \
        "bgrt"    "BGRT    (OEM logo, if available)"  "off" \
        "spinner" "Spinner (simple spinner)"          "off" \
        "tribar"  "Tribar  (three-bar progress)"      "off"

    # ---- Secure Boot ----
    ask_yesno SECUREBOOT_MODSIGN "Secure Boot" \
        "Enable Secure Boot + kernel module signing?\n(Uses sbctl MOK keys, enrolled via shim/MokManager)" "y"
    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        ask_pass MOK_PASS "Secure Boot" \
            "MOK enrollment password\n(MokManager will prompt for this on first reboot):"
    else
        MOK_PASS=""
    fi

    # ---- Users ----
    ask_pass ROOT_PASS "Users" "Root password:"
    ask_input USER_NAME "Users" "Non-root username:" "user"
    ask_pass USER_PASS  "Users" "Password for $USER_NAME:"

    # ---- Summary ----
    SUMMARY="Installation summary -- please confirm:

  Hostname        : $HOSTNAME
  Timezone        : $TIMEZONE_SET
  Locale          : $ESELECT_LOCALE_SET
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

  Root user       : root
  Non-root user   : $USER_NAME

  !! $DISK_INSTALL will be completely wiped !!"

    if ! dialog --clear --title "Confirm Installation" --yesno "$SUMMARY" 34 72; then
        clear
        echo "Installation cancelled."
        exit 0
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

    export HOSTNAME TIMEZONE_SET LOCALE_GEN_SET ESELECT_LOCALE_SET SYSTEMD_LOCALE
    export ESELECT_PROF DISK_INSTALL DEV_INSTALL EFI_PART ROOT_PART
    export SWAP_G LUKSED LUKS_PASS BINHOST BINHOST_V3 MIRROR
    export VIDEOCARDS INTEL_CPU_MICROCODE PLYMOUTH_THEME_SET
    export SECUREBOOT_MODSIGN MOK_PASS ROOT_PASS USER_NAME USER_PASS TPM_UNLOCK
fi

# =============================================================================
# CHROOT SECTION
# =============================================================================
if [[ "${1:-}" == "--chroot" ]]; then
    : "${SWAP_UUID_HOST:?SWAP_UUID_HOST not set}"
    : "${SWAP_OFFSET_HOST:?SWAP_OFFSET_HOST not set}"

    echo "[*] [CHROOT] Environment ready"
    rm -f /etc/profile.d/debug* || true
    mkdir -p /var/db/repos/gentoo/
    source /etc/profile

    echo "[*] [CHROOT] emerge-webrsync"
    emerge-webrsync

    echo "[*] [CHROOT] Setting profile: $ESELECT_PROF"
    eselect profile set "$ESELECT_PROF"

    emerge --oneshot app-portage/mirrorselect

    echo "[*] [CHROOT] Writing make.conf"
    cat > /etc/portage/make.conf <<MAKECONF
# ====================
# = GENTOO MAKE.CONF =
# ====================

COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
RUSTFLAGS="${RUSTFLAGS} -C target-cpu=native"

MAKEOPTS="-j$(nproc) -l$(nproc)"

EMERGE_DEFAULT_OPTS="--jobs $(nproc) --load-average $(nproc)"

FEATURES="${FEATURES} candy parallel-fetch parallel-install"

USE="dist-kernel systemd"

ACCEPT_LICENSE="*"

GRUB_PLATFORMS="efi-64"

VIDEO_CARDS="$VIDEOCARDS"

# Build output in English (required for bug reports)
LC_MESSAGES=C.utf8

MAKECONF

    echo "[*] [CHROOT] Selecting best mirrors"
    BEST_MIRROR=$(mirrorselect -s3 -b10 -D -o)
    echo "$BEST_MIRROR" >> /etc/portage/make.conf

    EXTRA_USE=""
    EXTRA_FEATURES=""

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
        sed -i "s/^USE=\"dist-kernel systemd\"/USE=\"dist-kernel systemd${EXTRA_USE}\"/" \
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
    printf "en_US.UTF-8 UTF-8\n%b\n" "$LOCALE_GEN_SET" > /etc/locale.gen
    locale-gen
    eselect locale set "$ESELECT_LOCALE_SET"
    env-update && source /etc/profile

    echo "[*] [CHROOT] Writing package.use"
    echo "sys-kernel/installkernel dracut grub systemd" \
        > /etc/portage/package.use/installkernel
    echo "sys-boot/grub truetype mount" \
        > /etc/portage/package.use/grub
    echo "sys-apps/systemd cryptsetup tpm" \
        > /etc/portage/package.use/systemd
    echo "sys-apps/kmod pkcs7" \
        > /etc/portage/package.use/kmod

    mkdir -p /etc/portage/package.accept_keywords/
    cat > /etc/portage/package.accept_keywords/pkgs <<KEYWORDS
app-crypt/sbctl ~amd64
sys-boot/mokutil ~amd64
sys-kernel/gentoo-kernel-bin ~amd64
sys-kernel/gentoo-kernel ~amd64
virtual/dist-kernel ~amd64
KEYWORDS

    echo "[*] [CHROOT] Installing sbctl and generating MOK keys"
    emerge app-crypt/efitools app-crypt/sbctl
    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        sbctl create-keys
    fi

    echo "[*] [CHROOT] Installing core packages"
    emerge \
        sys-boot/grub sys-boot/shim sys-boot/efibootmgr sys-boot/mokutil \
        app-crypt/efitools \
        sys-fs/btrfs-progs sys-fs/xfsprogs sys-fs/dosfstools \
        sys-apps/systemd sys-apps/kmod dev-vcs/git

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

    if [[ "$LUKSED" == "y" ]]; then
        LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
        ROOT_DEV="/dev/mapper/root"
    else
        ROOT_DEV="$ROOT_PART"
    fi
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
    SWAP_UUID="$SWAP_UUID_HOST"
    SWAP_OFFSET="$SWAP_OFFSET_HOST"

    echo "[*] [CHROOT] Writing dracut config"
    mkdir -p /etc/dracut.conf.d
    DRACUT_MODULES="btrfs resume"
    [[ "$LUKSED" == "y" ]] && DRACUT_MODULES+=" crypt"
    [[ "${TPM_UNLOCK:-n}" == "y" ]] && DRACUT_MODULES+=" tpm2-tss"
    cat > /etc/dracut.conf.d/gentoo.conf <<DRACUT
hostonly="yes"
add_dracutmodules+=" $DRACUT_MODULES "
DRACUT
    # TPM2 kernel drivers needed in initramfs for early unlock
    if [[ "${TPM_UNLOCK:-n}" == "y" ]]; then
        cat > /etc/dracut.conf.d/tpm2.conf <<TPM2CONF
# TPM2 drivers: tpm_crb (PCIe/ACPI), tpm_tis (LPC), tpm_tis_core (common base)
add_drivers+=" tpm tpm_tis_core tpm_tis tpm_crb "
TPM2CONF
    fi

    echo "[*] [CHROOT] Configuring /etc/default/grub"
    CMDLINE_LINUX="root=UUID=$ROOT_UUID resume=UUID=$SWAP_UUID resume_offset=$SWAP_OFFSET quiet rw splash"
    [[ "$LUKSED" == "y" ]] && CMDLINE_LINUX+=" rd.luks.uuid=$LUKS_UUID"
    sed -i "s|^#*GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$CMDLINE_LINUX\"|" \
        /etc/default/grub
    sed -i 's/#GRUB_GFXPAYLOAD_LINUX=/GRUB_GFXPAYLOAD_LINUX=keep/' /etc/default/grub
    if [[ "$LUKSED" == "y" ]]; then
        grep -q 'GRUB_ENABLE_CRYPTODISK' /etc/default/grub \
            || echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
    fi

    echo "[*] [CHROOT] Installing kernel"
    KERNEL_PKG=$([[ "$BINHOST" == "y" ]] && echo "sys-kernel/gentoo-kernel-bin" \
                                          || echo "sys-kernel/gentoo-kernel")
    emerge "$KERNEL_PKG"
    emerge sys-kernel/linux-firmware sys-firmware/sof-firmware
    [[ "$INTEL_CPU_MICROCODE" == "y" ]] && emerge sys-firmware/intel-microcode

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

    echo "[*] [CHROOT] Setting up zram"
    emerge sys-apps/zram-generator sys-fs/genfstab
    mkdir -p /etc/systemd/zram-generator.conf.d
    cat > /etc/systemd/zram-generator.conf.d/zram0-swap.conf <<ZRAM
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

    genfstab -U / >> /etc/fstab

    echo "$HOSTNAME" > /etc/hostname
    systemd-machine-id-setup
    systemd-firstboot --keymap="$SYSTEMD_LOCALE"

    echo "[*] [CHROOT] Installing additional packages"
    emerge \
        sys-apps/mlocate \
        sys-boot/plymouth \
        net-misc/chrony \
        net-wireless/iw \
        net-wireless/wpa_supplicant \
        net-misc/dhcpcd \
        app-admin/sudo \
        net-misc/networkmanager

    # TPM2 tools (needed for systemd-cryptenroll at first boot)
    if [[ "${TPM_UNLOCK:-n}" == "y" ]]; then
        emerge app-crypt/tpm2-tools
    fi

    systemctl enable chronyd.service NetworkManager
    plymouth-set-default-theme "$PLYMOUTH_THEME_SET"

    # ---- TPM2 enrollment script (runs after first reboot) ----
    # systemd-cryptenroll cannot be run during install chroot because the TPM
    # PCR values are not valid until the system boots normally for the first time.
    if [[ "${TPM_UNLOCK:-n}" == "y" ]]; then
        echo "[*] [CHROOT] Creating TPM2 enrollment script"
        LUKS_UUID_FOR_ENROLL=$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null || true)
        cat > /usr/local/sbin/gentoo-tpm-enroll.sh <<TPMENROLL
#!/usr/bin/env bash
# =============================================================================
# TPM2 LUKS enrollment script — run ONCE after first successful boot
# Binds the LUKS decryption key to TPM2 PCR 7+14.
#
# PCR 7  = Secure Boot state (firmware certs + SB on/off)
# PCR 14 = shim MOK database (changes if shim certs change, stable across
#           kernel upgrades — unlike PCR 4 which changes on every kernel update)
#
# Fallback: the LUKS passphrase always works even if TPM unlock fails.
# =============================================================================
set -euo pipefail

LUKS_DEV="\${1:-/dev/disk/by-uuid/$LUKS_UUID_FOR_ENROLL}"

if [[ ! -b "\$LUKS_DEV" ]]; then
    echo "[!] LUKS device not found: \$LUKS_DEV"
    echo "    Usage: \$0 [/dev/sdXN]"
    exit 1
fi

echo "[*] Checking TPM2 device..."
if ! systemd-cryptenroll --tpm2-device=list 2>&1 | grep -q 'PATH'; then
    echo "[!] No TPM2 device found. Aborting."
    exit 1
fi

echo "[*] Current LUKS keyslots:"
systemd-cryptenroll "\$LUKS_DEV"

echo ""
echo "[*] Enrolling TPM2 key bound to PCR 7+14"
echo "    PCR 7  = Secure Boot state"
echo "    PCR 14 = shim MOK database"
echo "    Enter your LUKS passphrase when prompted."
echo ""

systemd-cryptenroll \
    --tpm2-device=auto \
    --tpm2-pcrs=7+14 \
    "\$LUKS_DEV"

echo ""
echo "[*] Enrollment complete. Updated keyslots:"
systemd-cryptenroll "\$LUKS_DEV"

echo ""
echo "[*] Updating /etc/crypttab for TPM2 auto-unlock..."
LUKS_UUID_VAL=\$(blkid -s UUID -o value "\$LUKS_DEV")
if grep -q "luks-\$LUKS_UUID_VAL\|UUID=\$LUKS_UUID_VAL" /etc/crypttab 2>/dev/null; then
    # Add tpm2-device=auto to existing crypttab entry
    sed -i "s|\(UUID=\$LUKS_UUID_VAL[[:space:]].*none[[:space:]]\)\(.*\)|\1\2,tpm2-device=auto|" /etc/crypttab
    echo "[*] /etc/crypttab updated."
else
    echo "[!] Could not find UUID=\$LUKS_UUID_VAL in /etc/crypttab"
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
echo "      systemd-cryptenroll --wipe-slot=tpm2 \$LUKS_DEV"
TPMENROLL
        chmod +x /usr/local/sbin/gentoo-tpm-enroll.sh
        echo "[*] [CHROOT] TPM2 enrollment script created at /usr/local/sbin/gentoo-tpm-enroll.sh"
    fi

    echo "[*] [CHROOT] Setting up users"
    echo "root:$ROOT_PASS" | chpasswd
    useradd -m -G users,wheel,audio,cdrom,usb,video -s /bin/bash "$USER_NAME"
    echo "${USER_NAME}:${USER_PASS}" | chpasswd
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

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

    echo "[*] [CHROOT] Cleanup"
    rm -f /stage3-*.tar.*
    swapoff /swap/swap.img || true

    echo "============================================"
    echo "[*] EFI partition layout:"
    find /boot/EFI -name "*.efi" | sort
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
    echo "[*] Done. Type 'exit', unmount everything, then reboot."
    rm -f /gentoo-install.sh
    exit 0
fi

# =============================================================================
# HOST (PRE-CHROOT) SECTION
# =============================================================================

echo "[*] [HOST] Clock synchronization"
chronyd -q

echo "[*] [HOST] Wiping partition table on $DISK_INSTALL"
sgdisk --zap-all "$DISK_INSTALL"

echo "[*] [HOST] Creating GPT partition table"
parted -s "$DISK_INSTALL" mklabel gpt

echo "[*] [HOST] Creating EFI partition (1 MiB -> 513 MiB)"
parted -s "$DISK_INSTALL" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK_INSTALL" set 1 esp on
mkfs.fat -F32 "$EFI_PART"

echo "[*] [HOST] Creating root partition (513 MiB -> 100%)"
parted -s "$DISK_INSTALL" mkpart primary 513MiB 100%
parted -s "$DISK_INSTALL" type 2 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709

mkdir -p /mnt/gentoo

if [[ "$LUKSED" == "y" ]]; then
    echo "[*] [HOST] [LUKS] Encrypting root partition"
    echo -n "$LUKS_PASS" | cryptsetup luksFormat --key-size 512 "$ROOT_PART" \
        -d - --batch-mode \
        || { echo "[!] luksFormat failed"; exit 1; }
    echo "[*] [HOST] [LUKS] Opening LUKS container"
    echo -n "$LUKS_PASS" | cryptsetup luksOpen "$ROOT_PART" root \
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
for subvol in @ @home @log @cache @swap; do
    btrfs subvolume create "$subvol"
done
cd ~
umount /mnt/gentoo

MOUNT_OPTS="noatime,compress=zstd:3,ssd,discard=async"

echo "[*] [HOST] Mounting subvolumes"
mount -o "$MOUNT_OPTS",subvol=@      "$ROOT_DEV_MNT" /mnt/gentoo
mkdir -p /mnt/gentoo/{boot,home,var/cache,var/log,swap}
mount -o "$MOUNT_OPTS",subvol=@home  "$ROOT_DEV_MNT" /mnt/gentoo/home
mount -o "$MOUNT_OPTS",subvol=@log   "$ROOT_DEV_MNT" /mnt/gentoo/var/log
mount -o "$MOUNT_OPTS",subvol=@cache "$ROOT_DEV_MNT" /mnt/gentoo/var/cache
mount -o noatime,subvol=@swap        "$ROOT_DEV_MNT" /mnt/gentoo/swap
mount "$EFI_PART" /mnt/gentoo/boot

echo "[*] [HOST] Creating swap file ($SWAP_G)"
truncate -s 0 /mnt/gentoo/swap/swap.img
chattr +C /mnt/gentoo/swap/swap.img
btrfs property set /mnt/gentoo/swap/ compression none
fallocate -l "$SWAP_G" /mnt/gentoo/swap/swap.img
chmod 0600 /mnt/gentoo/swap/swap.img
mkswap /mnt/gentoo/swap/swap.img
swapon /mnt/gentoo/swap/swap.img

echo "[*] [HOST] Computing hibernation resume parameters"
SWAP_UUID_HOST=$(blkid -s UUID -o value "$ROOT_DEV_MNT")
SWAP_OFFSET_HOST=$(btrfs inspect-internal map-swapfile -r /mnt/gentoo/swap/swap.img)
echo "    SWAP_UUID_HOST   = $SWAP_UUID_HOST"
echo "    SWAP_OFFSET_HOST = $SWAP_OFFSET_HOST"
export SWAP_UUID_HOST SWAP_OFFSET_HOST

echo "[*] [HOST] Downloading stage3"
cd /mnt/gentoo
LATEST=$(curl -s "$MIRROR/latest-stage3-amd64-desktop-systemd.txt")
STAGE3=$(echo "$LATEST" \
    | grep 'stage3-amd64-desktop-systemd-.*\.tar\.xz$' \
    | cut -d' ' -f1)
wget "$MIRROR/$STAGE3"

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
cp "$(readlink -f "$0")" /mnt/gentoo/gentoo-install.sh
chmod +x /mnt/gentoo/gentoo-install.sh

chroot /mnt/gentoo /usr/bin/env \
    HOSTNAME="$HOSTNAME" \
    TIMEZONE_SET="$TIMEZONE_SET" \
    LOCALE_GEN_SET="$LOCALE_GEN_SET" \
    ESELECT_LOCALE_SET="$ESELECT_LOCALE_SET" \
    SYSTEMD_LOCALE="$SYSTEMD_LOCALE" \
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
    SWAP_UUID_HOST="$SWAP_UUID_HOST" \
    SWAP_OFFSET_HOST="$SWAP_OFFSET_HOST" \
    /bin/bash /gentoo-install.sh --chroot