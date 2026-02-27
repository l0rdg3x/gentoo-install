#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# GENTOO AUTO-INSTALL SCRIPT
# Boot chain: UEFI → shim (pre-signed by Microsoft/Fedora)
#                  → grubx64.efi (Gentoo pre-built signed standalone GRUB)
#                  → kernel in /boot/
# Secureboot: sbctl generates MOK keys; key enrolled via mokutil into shim MOKlist.
#             NO sbctl enroll-keys (no direct UEFI db enrollment needed with shim).
# Snapshots:  grub-btrfs + snapper for boot-from-snapshot support.
# =============================================================================

########### CONFIG ############
HOSTNAME="gentoo-qemu"                                           # CHANGE
TIMEZONE_SET="Europe/Rome"                                       # CHANGE: ls -l /usr/share/zoneinfo
LOCALE_GEN_SET="it_IT ISO-8859-1\nit_IT.UTF-8 UTF-8"            # CHANGE: cat /usr/share/i18n/SUPPORTED
ESELECT_LOCALE_SET="it_IT.UTF8"                                  # CHANGE: UTF8 without dash (it_IT.UTF-8 → it_IT.UTF8)
SYSTEMD_LOCALE="it"                                              # CHANGE
INTEL_CPU_MICROCODE="y"                                          # CHANGE: "y" or "n"
SECUREBOOT_MODSIGN="y"                                           # CHANGE: "y" or "n"
VIDEOCARDS="intel"                                               # CHANGE: https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Base
PLYMOUTH_THEME_SET="solar"                                       # CHANGE: https://wiki.gentoo.org/wiki/Plymouth
LUKSED="n"                                                       # CHANGE: "y" or "n"
LUKS_PASS="Passw0rdd!"                                           # CHANGE
DEV_INSTALL="ssd"                                                # CHANGE: "nvme" or "ssd"
SWAP_G="16G"                                                     # CHANGE
BINHOST="y"                                                      # CHANGE: "y" = binary packages, "n" = full source
BINHOST_V3="y"                                                   # CHANGE: "y" = x86-64-v3, "n" = x86-64
ROOT_PASS="Passw0rdd!"                                           # CHANGE
USER_NAME="l0rdg3x"                                              # CHANGE
USER_PASS="Passw0rdd!"                                           # CHANGE
MOK_PASS="Passw0rdd!"                                           # CHANGE
ESELECT_PROF="default/linux/amd64/23.0/desktop/plasma/systemd"  # CHANGE
MIRROR="https://distfiles.gentoo.org/releases/amd64/autobuilds" # CHANGE
###############################

if [[ "$DEV_INSTALL" == "nvme" ]]; then
    DISK_INSTALL="/dev/nvme0n1"   # CHANGE
    EFI_PART="${DISK_INSTALL}p1"
    ROOT_PART="${DISK_INSTALL}p2"
elif [[ "$DEV_INSTALL" == "ssd" ]]; then
    DISK_INSTALL="/dev/sda"       # CHANGE
    EFI_PART="${DISK_INSTALL}1"
    ROOT_PART="${DISK_INSTALL}2"
else
    echo "[!] DEV_INSTALL must be 'nvme' or 'ssd'"; exit 1
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

    # ---- Portage bootstrap ----
    echo "[*] [CHROOT] emerge-webrsync"
    emerge-webrsync

    echo "[*] [CHROOT] Setting profile: $ESELECT_PROF"
    eselect profile set "$ESELECT_PROF"

    emerge --oneshot app-portage/mirrorselect

    # ---- make.conf ----
    echo "[*] [CHROOT] Writing make.conf"
    cat > /etc/portage/make.conf <<EOF
# ====================
# = GENTOO MAKE.CONF =
# ====================

COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="\${RUSTFLAGS} -C target-cpu=native"

MAKEOPTS="-j$(nproc) -l$(nproc)"

EMERGE_DEFAULT_OPTS="--jobs $(nproc) --load-average $(nproc)"

FEATURES="\${FEATURES} candy parallel-fetch parallel-install"

USE="dist-kernel systemd"

ACCEPT_LICENSE="*"

GRUB_PLATFORMS="efi-64"

VIDEO_CARDS="$VIDEOCARDS"

# Build output in English (required for bug reports)
LC_MESSAGES=C.utf8

EOF

    BEST_MIRROR=$(mirrorselect -s3 -b10 -D -o)
    echo "$BEST_MIRROR" >> /etc/portage/make.conf

    EXTRA_USE=""
    EXTRA_FEATURES=""

    # ---- Secureboot USE flags ----
    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        # modules-sign: kernel modules are signed with our MOK key
        # secureboot:   installkernel signs the kernel image; grub installs pre-signed binary
        EXTRA_USE+=" modules-sign secureboot"

        if ! mountpoint -q /sys/firmware/efi/efivars; then
            mount -t efivarfs efivarfs /sys/firmware/efi/efivars \
                || { echo "[!] Error mounting efivars"; exit 1; }
        fi

        cat >> /etc/portage/make.conf <<EOF

# MOK signing keys (generated by sbctl, used for kernel modules and kernel image)
# With shim, these keys are enrolled into shim's MOKlist — NOT into the UEFI db.
MODULES_SIGN_KEY="/var/lib/sbctl/keys/db/db.key"
MODULES_SIGN_CERT="/var/lib/sbctl/keys/db/db.pem"
MODULES_SIGN_HASH="sha512"

SECUREBOOT_SIGN_KEY="/var/lib/sbctl/keys/db/db.key"
SECUREBOOT_SIGN_CERT="/var/lib/sbctl/keys/db/db.pem"

EOF
    fi

    # ---- Binary packages ----
    if [[ "$BINHOST" == "y" ]]; then
        EXTRA_FEATURES+=" getbinpkg binpkg-request-signature"
        mkdir -p /etc/portage/binrepos.conf/
        SUFFIX=$([[ "$BINHOST_V3" == "y" ]] && echo "x86-64-v3" || echo "x86-64")
        cat > /etc/portage/binrepos.conf/gentoobinhost.conf <<EOF
[binhost]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/$SUFFIX
EOF
        emerge --sync
    fi

    # ---- Patch make.conf with accumulated USE / FEATURES ----
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

    # ---- CPU flags ----
    echo "[*] [CHROOT] Detecting CPU flags"
    emerge --oneshot app-portage/cpuid2cpuflags
    echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

    # ---- Localization ----
    echo "[*] [CHROOT] Setting localization"
    ln -sf ../usr/share/zoneinfo/"$TIMEZONE_SET" /etc/localtime
    printf "en_US.UTF-8 UTF-8\n%b\n" "$LOCALE_GEN_SET" > /etc/locale.gen
    locale-gen
    eselect locale set "$ESELECT_LOCALE_SET"
    env-update && source /etc/profile

    # ---- package.use ----
    echo "[*] [CHROOT] Writing package.use"

    # installkernel: no UKI — plain dracut initramfs + signed kernel image
    # secureboot USE makes installkernel sign the kernel EFI image automatically
    echo "sys-kernel/installkernel dracut grub systemd" \
        > /etc/portage/package.use/installkernel

    # grub:
    #   secureboot — installs the pre-built Fedora/Gentoo-signed standalone EFI
    #                at /usr/lib/grub/grub-x86_64.efi.signed
    #   shim       — adds sys-boot/shim as dependency (installs to /usr/share/shim/)
    #   device-mapper, truetype, mount — useful grub features
    echo "sys-boot/grub secureboot shim device-mapper truetype mount" \
        > /etc/portage/package.use/grub

    echo "sys-boot/plymouth systemd-integration" \
        > /etc/portage/package.use/plymouth

    echo "sys-apps/systemd cryptsetup zstd" \
        > /etc/portage/package.use/systemd

    # kmod: modinfo shows module signature info — useful to verify signing works
    echo "sys-apps/kmod pkcs7" \
        > /etc/portage/package.use/kmod

    # ---- package.accept_keywords ----
    mkdir -p /etc/portage/package.accept_keywords/
    cat > /etc/portage/package.accept_keywords/pkgs <<EOF
app-crypt/sbctl ~amd64
sys-boot/mokutil ~amd64
sys-kernel/gentoo-kernel-bin ~amd64
sys-kernel/gentoo-kernel ~amd64
virtual/dist-kernel ~amd64
EOF

    # ---- sbctl keys — must exist BEFORE kernel emerge ----
    # installkernel will call sbsign using SECUREBOOT_SIGN_KEY/CERT from make.conf.
    # If the keys don't exist yet, the kernel postinst will fail.
    echo "[*] [CHROOT] Installing sbctl and generating MOK keys"
    emerge app-crypt/efitools app-crypt/sbctl
    wget https://raw.githubusercontent.com/Deftera186/sbctl/8c7a57ed052f94b8f8eb32321c34736adfdf6ce7/contrib/kernel-install/91-sbctl.install -O /usr/lib/kernel/install.d/91-sbctl.install
    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        sbctl create-keys
        # Keys are now at /var/lib/sbctl/keys/db/db.{key,pem}
        # We will enroll them into shim's MOKlist later with mokutil (NOT into UEFI db)
    fi

    # ---- Core packages ----
    echo "[*] [CHROOT] Installing core packages"
    # shellcheck disable=SC2086
    emerge \
        sys-boot/grub sys-boot/shim sys-boot/efibootmgr sys-boot/mokutil \
        app-crypt/efitools sys-fs/btrfs-progs \
        sys-fs/xfsprogs sys-fs/dosfstools \
        sys-apps/systemd sys-apps/kmod dev-vcs/git

    # ---- Verify shim and signed GRUB are present ----
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

    # ---- UUIDs ----
    if [[ "$LUKSED" == "y" ]]; then
        LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
        ROOT_DEV="/dev/mapper/root"
    else
        ROOT_DEV="$ROOT_PART"
    fi
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
    SWAP_UUID="$SWAP_UUID_HOST"
    SWAP_OFFSET="$SWAP_OFFSET_HOST"

    # ---- dracut config (plain initramfs, no UKI) ----
    echo "[*] [CHROOT] Writing dracut config"
    mkdir -p /etc/dracut.conf.d

    DRACUT_MODULES="btrfs resume"
    [[ "$LUKSED" == "y" ]] && DRACUT_MODULES+=" crypt"

    cat > /etc/dracut.conf.d/gentoo.conf <<EOF
hostonly="yes"
add_dracutmodules+=" $DRACUT_MODULES "
EOF

    # ---- Kernel cmdline for GRUB ----
    # Used by grub-mkconfig via /etc/default/grub
    CMDLINE_LINUX="root=UUID=$ROOT_UUID resume=UUID=$SWAP_UUID resume_offset=$SWAP_OFFSET quiet rw splash"
    [[ "$LUKSED" == "y" ]] && CMDLINE_LINUX+=" rd.luks.uuid=$LUKS_UUID"

    # ---- /etc/default/grub ----
    echo "[*] [CHROOT] Configuring /etc/default/grub"
    sed -i "s|^#*GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$CMDLINE_LINUX\"|" \
        /etc/default/grub
    sed -i 's/#GRUB_GFXPAYLOAD_LINUX=/GRUB_GFXPAYLOAD_LINUX=keep/' /etc/default/grub
    [[ "$LUKSED" == "y" ]] && \
        grep -q 'GRUB_ENABLE_CRYPTODISK' /etc/default/grub || \
        echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub

    # ---- Kernel ----
    echo "[*] [CHROOT] Installing kernel"
    KERNEL_PKG=$([[ "$BINHOST" == "y" ]] && echo "sys-kernel/gentoo-kernel-bin" \
                                          || echo "sys-kernel/gentoo-kernel")
    emerge "$KERNEL_PKG"
    emerge sys-kernel/linux-firmware sys-firmware/sof-firmware
    [[ "$INTEL_CPU_MICROCODE" == "y" ]] && emerge sys-firmware/intel-microcode

    # ---- Bootloader installation ----
    # The chain is:  shim (BOOTX64.EFI, signed by Microsoft/Fedora)
    #                  └→ grubx64.efi  (pre-signed standalone GRUB, verified by shim via MOKlist)
    #                       └→ kernel + initramfs in /boot/
    #
    # grub-install is NOT used:
    #   It produces an unsigned binary that shim cannot verify.
    #   Instead we copy the pre-built signed standalone from /usr/lib/grub/.
    #
    # The signed standalone GRUB reads grub.cfg from its own EFI directory
    # (/boot/EFI/gentoo/grub.cfg), NOT from /boot/grub/grub.cfg.
    # We tell grub-mkconfig where to write via GRUB_CFG env var.

    echo "[*] [CHROOT] Installing shim + pre-signed GRUB to ESP"
    mkdir -p /boot/EFI/gentoo

    cp "$SHIM_EFI"    /boot/EFI/gentoo/shimx64.efi
    cp "$SHIM_MM"     /boot/EFI/gentoo/mmx64.efi
    cp "$SIGNED_GRUB" /boot/EFI/gentoo/grubx64.efi

    echo "[*] [CHROOT] Generating grub.cfg in ESP (standalone GRUB reads it from there)"
    GRUB_CFG=/boot/EFI/gentoo/grub.cfg \
        grub-mkconfig -o /boot/EFI/gentoo/grub.cfg

    echo "[*] [CHROOT] Registering shim in UEFI boot order"
    efibootmgr --create \
        --disk "$DISK_INSTALL" \
        --part 1 \
        --loader '\EFI\gentoo\shimx64.efi' \
        --label "Gentoo Linux" \
        --unicode

    # ---- MOK enrollment ----
    # With shim we only need to enroll the key into shim's MOKlist.
    # We do NOT call "sbctl enroll-keys" (that would write into the UEFI db,
    # which is unnecessary with shim and can cause issues on some boards).
    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        echo "[*] [CHROOT] Converting signing cert to DER format for MOK enrollment"
        openssl x509 \
            -in  /var/lib/sbctl/keys/db/db.pem \
            -inform PEM \
            -out /var/lib/sbctl/keys/db/db.der \
            -outform DER

        echo "[*] [CHROOT] Enrolling MOK key via mokutil"
        echo "[!] You will be asked to set a one-time enrollment password."
        echo "    Write it down — MokManager will ask for it on first reboot."
        printf "%s\n%s\n" "$MOK_PASS" "$MOK_PASS" | mokutil --import /var/lib/sbctl/keys/db/db.der
    fi

    # ---- Post-install kernel config (dracut rebuild) ----
    if [[ "$BINHOST" == "y" ]]; then
        emerge --config sys-kernel/gentoo-kernel-bin
    else
        emerge --config sys-kernel/gentoo-kernel
    fi

    # Rebuild grub.cfg after dracut rebuild (initramfs path may have changed)
    GRUB_CFG=/boot/EFI/gentoo/grub.cfg \
        grub-mkconfig -o /boot/EFI/gentoo/grub.cfg

    # ---- zram ----
    echo "[*] [CHROOT] Setting up zram"
    emerge sys-apps/zram-generator sys-fs/genfstab

    mkdir -p /etc/systemd/zram-generator.conf.d
    cat > /etc/systemd/zram-generator.conf.d/zram0-swap.conf <<EOF
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

    # ---- fstab ----
    genfstab -U / >> /etc/fstab

    # ---- System identity ----
    echo "$HOSTNAME" > /etc/hostname
    systemd-machine-id-setup
    systemd-firstboot --keymap="$SYSTEMD_LOCALE"

    # ---- Additional packages ----
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

    systemctl enable chronyd.service NetworkManager
    plymouth-set-default-theme "$PLYMOUTH_THEME_SET"

    # ---- Users ----
    echo "[*] [CHROOT] Setting up users"
    echo "root:$ROOT_PASS" | chpasswd
    useradd -m -G users,wheel,audio,cdrom,usb,video -s /bin/bash "$USER_NAME"
    echo "${USER_NAME}:${USER_PASS}" | chpasswd
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

    # ---- Switch portage repo to git ----
    echo "[*] [CHROOT] Switching Portage repo to git"
    mkdir -p /etc/portage/repos.conf/
    cat > /etc/portage/repos.conf/gentoo.conf <<EOF
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
EOF

    rm -rf /var/db/repos/gentoo/*
    emaint sync

    # ---- Cleanup ----
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
        echo "    2. Choose 'Enroll MOK' and enter the password set by mokutil"
        echo "    3. Reboot"
        echo "    4. In UEFI firmware settings: ENABLE Secure Boot"
        echo ""
        echo "[!] To verify module signatures after boot:"
        echo "    modinfo <module> | grep sig"
    fi
    echo "============================================"
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

echo "[*] [HOST] Creating EFI partition (1 MiB → 513 MiB)"
parted -s "$DISK_INSTALL" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK_INSTALL" set 1 esp on
mkfs.fat -F32 "$EFI_PART"

echo "[*] [HOST] Creating root partition (513 MiB → 100%)"
parted -s "$DISK_INSTALL" mkpart primary 513MiB 100%
parted -s "$DISK_INSTALL" type 2 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709

mkdir -p /mnt/gentoo

# ---- LUKS (optional) ----
if [[ "$LUKSED" == "y" ]]; then
    echo "[*] [HOST] [LUKS] Encrypting root partition"
    echo -n "$LUKS_PASS" | cryptsetup luksFormat --key-size 512 "$ROOT_PART" -d - --batch-mode \
        || { echo "[!] luksFormat failed"; exit 1; }
    echo "[*] [HOST] [LUKS] Opening LUKS container"
    echo -n "$LUKS_PASS" | cryptsetup luksOpen "$ROOT_PART" root -d - \
        || { echo "[!] luksOpen failed"; exit 1; }
    ROOT_DEV_MNT="/dev/mapper/root"
else
    ROOT_DEV_MNT="$ROOT_PART"
fi

# ---- Btrfs ----
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

# ---- Swapfile ----
echo "[*] [HOST] Creating swap file ($SWAP_G)"
truncate -s 0 /mnt/gentoo/swap/swap.img
chattr +C /mnt/gentoo/swap/swap.img     # disable CoW (required for btrfs swapfile)
btrfs property set /mnt/gentoo/swap/ compression none
fallocate -l "$SWAP_G" /mnt/gentoo/swap/swap.img
chmod 0600 /mnt/gentoo/swap/swap.img
mkswap /mnt/gentoo/swap/swap.img
swapon /mnt/gentoo/swap/swap.img

# ---- Swap UUID + offset (computed on host where mounts are reliable) ----
echo "[*] [HOST] Computing hibernation resume parameters"
# With btrfs: resume UUID = filesystem UUID of the block device (not subvolume)
SWAP_UUID_HOST=$(blkid -s UUID -o value "$ROOT_DEV_MNT")
SWAP_OFFSET_HOST=$(btrfs inspect-internal map-swapfile -r /mnt/gentoo/swap/swap.img)
echo "    SWAP_UUID_HOST   = $SWAP_UUID_HOST"
echo "    SWAP_OFFSET_HOST = $SWAP_OFFSET_HOST"
export SWAP_UUID_HOST SWAP_OFFSET_HOST

# ---- Stage3 ----
echo "[*] [HOST] Downloading stage3"
cd /mnt/gentoo
LATEST=$(curl -s "$MIRROR/latest-stage3-amd64-desktop-systemd.txt")
STAGE3=$(echo "$LATEST" \
    | grep 'stage3-amd64-desktop-systemd-.*\.tar\.xz' \
    | grep -v '\.CONTENTS\|\.DIGESTS\|\.asc' \
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
cp /root/gentoo-install.sh /mnt/gentoo/gentoo-install.sh
chmod +x /mnt/gentoo/gentoo-install.sh

chroot /mnt/gentoo /usr/bin/env \
    SWAP_UUID_HOST="$SWAP_UUID_HOST" \
    SWAP_OFFSET_HOST="$SWAP_OFFSET_HOST" \
    /bin/bash /gentoo-install.sh --chroot
