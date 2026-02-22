#!/usr/bin/env bash
set -euo pipefail

########### CONFIG ############   NOTE: MAYBE 'dialog' ?????
HOSTNAME="gentoo-qemu" #CHANGE
TIMEZONE_SET="Europe/Rome" #CHANGE: Your timezone: search with "ls -l /usr/share/zoneinfo"
LOCALE_GEN_SET="it_IT ISO-8859-1\nit_IT.UTF-8 UTF-8" #CHANGE Search with "cat /usr/share/i18n/SUPPORTED" add separated with \n like in example
ESELECT_LOCALE_SET="it_IT.UTF8" #CHANGE: Select the eselect locale from ESELECT_LOCALE_SET, The UTF8 one: Example "it_IT.UTF-8" become "it_IT.UTF8" w/o dash like in example
SYSTEMD_LOCALE="it" #CHANGE: Systemd locale
INTEL_CPU_MICROCODE="y" #CHANGE: Install or not Intel CPU microcode
SECUREBOOT_MODSIGN="y" #CHANGE: Enable Secureboot + Modules Sign
VIDEOCARDS="intel" #CHANGE: Your video cards: https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Base 
PLYMOUTH_THEME_SET="solar" #CHANGE: your favourite plymouth theme: https://wiki.gentoo.org/wiki/Plymouth
LUKSED="n" #CHANGE: Enable LUKS? "y" or "n"
DEV_INSTALL="ssd" #CHANGE: "nvme" or "ssd"
SWAP_G="16G" #CHANGE: SWAP GB
BINHOST="y" #CHANGE: 'n' if you want Gentoo full source compiled, 'y' if you want use binary packages
ROOT_PASS="Passw0rdd!" #CHANGE: Password for root user
USER_NAME="l0rdg3x" #CHANGE: non-root username
USER_PASS="Passw0rdd!" #CHANGE: Password for non root user 
ESELECT_PROF="default/linux/amd64/23.0/desktop/plasma/systemd" #CHANGE: Select your preferred profile: "eselect profile list | less" (only systemd profiles work with this script for now) [TODO]
MIRROR="https://mirror.leaseweb.com/gentoo/releases/amd64/autobuilds" #CHANGE: Your preferred mirror for stage3 download

if [[ "$DEV_INSTALL" == "nvme" ]]; then
    DISK_INSTALL="/dev/nvme0n1" #CHANGE: With your nvme dev
    EFI_PART="${DISK_INSTALL}p1" #DO NOT CHANGE
    ROOT_PART="${DISK_INSTALL}p2" #DO NOT CHANGE
fi
if [[ "$DEV_INSTALL" == "ssd" ]]; then
    DISK_INSTALL="/dev/sda" #CHANGE: With your ssd dev
    EFI_PART="${DISK_INSTALL}1" #DO NOT CHANGE
    ROOT_PART="${DISK_INSTALL}2" #DO NOT CHANGE
fi
###############################

if [[ "${1:-}" == "--chroot" ]]; then
    echo "[*] [CHROOT] Chroot environment ready"

    echo "[*] [CHROOT] Portage synchronization"
    source /etc/profile
    emerge-webrsync
    emerge --sync

    echo "[*] [CHROOT] Set Profile selection"
    eselect profile set "$ESELECT_PROF"

    emerge --oneshot app-portage/mirrorselect

    echo "[*] [CHROOT] Generic make.conf configuration"
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

MAKEOPTS="-j8 -l8"

EMERGE_DEFAULT_OPTS="--jobs 8 --load-average 8"

FEATURES="\${FEATURES} candy parallel-fetch parallel-install"

USE="dist-kernel"

ACCEPT_LICENSE="*"

GRUB_PLATFORMS="efi-64"

VIDEO_CARDS="$VIDEOCARDS"

# This sets the language of build output to English.
# Please keep this setting intact when reporting bugs.
LC_MESSAGES=C.utf8


EOF
        
    echo "[*] [CHROOT] Select Mirror list (wait 3 secs)"
    sleep 3
    mirrorselect -i -o >> /etc/portage/make.conf
    
    EXTRA_USE=""

    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        EXTRA_USE+=" modules-sign secureboot"
        if [ ! -d /sys/firmware/efi/efivars ]; then
            mount -t efivarfs efivarfs /sys/firmware/efi/efivars || { echo "Error efivars mount"; exit 1; }
        fi

        cat >> /etc/portage/make.conf <<EOF

# Optionally, to use custom signing keys.
MODULES_SIGN_KEY="/var/lib/sbctl/keys/db/db.key"
MODULES_SIGN_CERT="/var/lib/sbctl/keys/db/db.pem"
MODULES_SIGN_HASH="sha512"

# Optionally, to boot with secureboot enabled.
SECUREBOOT_SIGN_KEY="/var/lib/sbctl/keys/db/db.key"
SECUREBOOT_SIGN_CERT="/var/lib/sbctl/keys/db/db.pem"

EOF
    fi

    if [[ "$BINHOST" == "y" ]]; then
        EXTRA_USE+=" getbinpkg binpkg-request-signature"
    
        mkdir -p /etc/portage/binrepos.conf/
        cat > /etc/portage/binrepos.conf/gentoobinhost.conf <<EOF
[binhost]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64-v3
EOF
        getuto
    fi

    if [[ -n "$EXTRA_USE" ]]; then
        sed -i "s/dist-kernel/dist-kernel${EXTRA_USE}/" /etc/portage/make.conf
    fi

    echo "[*] [CHROOT] Setup CPU flags"
    mkdir -p /var/cache/ccache
    emerge --oneshot app-portage/cpuid2cpuflags
    echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

    echo "[*] [CHROOT] Set Localization"
    ln -sf ../usr/share/zoneinfo/"$TIMEZONE_SET" /etc/localtime
    cat > /etc/locale.gen <<EOF
en_US ISO-8859-1
en_US.UTF-8 UTF-8
EOF
    echo -e "$LOCALE_GEN_SET" >> /etc/locale.gen
    locale-gen
    eselect locale set "$ESELECT_LOCALE_SET"
    env-update && source /etc/profile

    echo "[*] [CHROOT] Base installation"
    echo "sys-kernel/installkernel grub dracut" > /etc/portage/package.use/installkernel
    echo "sys-boot/plymouth systemd" > /etc/portage/package.use/plymouth
    cat > /etc/portage/package.accept_keywords/pkgs <<EOF
sys-kernel/gentoo-kernel-bin ~amd64
sys-kernel/gentoo-kernel ~amd64
virtual/dist-kernel ~amd64
EOF

    if [[ "$LUKSED" == "y" ]]; then
        echo "sys-apps/systemd cryptsetup" > /etc/portage/package.use/systemd
        LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
        ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/root)
        SWAP_UUID=$(findmnt -no UUID -T /swap/swap.img)
        SWAP_OFFSET=$(filefrag -v /swap/swap.img|awk 'NR==4{gsub(/\./,"");print $4;}')
    else
        ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
        SWAP_UUID=$(findmnt -no UUID -T /swap/swap.img)
        SWAP_OFFSET=$(filefrag -v /swap/swap.img|awk 'NR==4{gsub(/\./,"");print $4;}')
    fi
    
    emerge dev-util/ccache dev-vcs/git sys-fs/btrfs-progs sys-fs/xfsprogs sys-fs/e2fsprogs sys-fs/dosfstools sys-fs/ntfs3g sys-block/io-scheduler-udev-rules sys-fs/mdadm sys-apps/systemd sys-kernel/linux-firmware sys-firmware/sof-firmware

    mkdir -p /etc/dracut.conf.d
    if [[ "$LUKSED" == "y" ]]; then
        echo "kernel_cmdline+=\" root=UUID=$ROOT_UUID resume=UUID=$SWAP_UUID resume_offset=$SWAP_OFFSET rd.luks.uuid=$LUKS_UUID \"" >> /etc/dracut.conf.d/default.conf
        echo 'add_dracutmodules+=" btrfs crypt rootfs-block resume "' >> /etc/dracut.conf.d/default.conf
        echo 'hostonly="yes"' >> /etc/dracut.conf.d/default.conf
        echo 'persistent_policy="by-uuid"' >> /etc/dracut.conf.d/default.conf
        echo 'use_systemd="yes"' >> /etc/dracut.conf.d/default.conf
    else
        echo "kernel_cmdline+=\" root=UUID=$ROOT_UUID resume=UUID=$SWAP_UUID resume_offset=$SWAP_OFFSET \"" >> /etc/dracut.conf.d/default.conf
        echo 'add_dracutmodules+=" btrfs rootfs-block resume "' >> /etc/dracut.conf.d/default.conf
        echo 'hostonly=yes' >> /etc/dracut.conf.d/default.conf
        echo 'persistent_policy="by-uuid"' >> /etc/dracut.conf.d/default.conf
        echo 'use_systemd="yes"' >> /etc/dracut.conf.d/default.conf
    fi

    emerge sys-kernel/installkernel
    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        mkdir -p /boot/EFI/gentoo
        emerge sys-boot/grub sys-boot/mokutil sys-boot/efibootmgr app-crypt/efitools app-crypt/sbctl
        sbctl create-keys
        sbctl enroll-keys -m
    fi

    if [[ "$INTEL_CPU_MICROCODE" == "y" ]]; then
        emerge sys-firmware/intel-microcode
    fi

    if [[ "$BINHOST" == "y" ]]; then
        emerge sys-kernel/gentoo-kernel-bin
    else
        emerge sys-kernel/gentoo-kernel
    fi

    emerge sys-apps/zram-generator sys-fs/genfstab
    mkdir /etc/systemd/zram-generator.conf.d
    cat > /etc/systemd/zram-generator.conf.d/zram0-swap.conf <<EOF
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

    genfstab -U / >> /etc/fstab
    echo "$HOSTNAME" > /etc/hostname
    systemd-machine-id-setup
    systemd-firstboot --keymap="$SYSTEMD_LOCALE"
    emerge sys-apps/mlocate sys-boot/plymouth net-misc/chrony net-wireless/iw net-wireless/wpa_supplicant net-misc/dhcpcd app-admin/sudo net-misc/networkmanager
    systemctl enable chronyd.service
    plymouth-set-default-theme "$PLYMOUTH_THEME_SET"

    echo "[*] [CHROOT] GRUB configuration"
    if [[ "$LUKSED" == "y" ]]; then
        echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
        sed -i "s|^#GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"resume=UUID=$SWAP_UUID resume_offset=$SWAP_OFFSET rd.luks.uuid=$LUKS_UUID rd.luks.options=password-echo=no quiet rw splash\"|" /etc/default/grub
    else
        sed -i "s|^#GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"resume=UUID=$SWAP_UUID resume_offset=$SWAP_OFFSET quiet rw splash\"|" /etc/default/grub
    fi
    sed -i 's/#GRUB_GFXPAYLOAD_LINUX=/GRUB_GFXPAYLOAD_LINUX=keep/' /etc/default/grub

    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=gentoo --boot-directory=/boot

    if [[ "$BINHOST" == "y" ]]; then
        emerge --config sys-kernel/gentoo-kernel-bin
    else
        emerge --config sys-kernel/gentoo-kernel
    fi

    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        sbctl sign --save /boot/EFI/gentoo/grubx64.efi
    fi

    grub-mkconfig -o /boot/grub/grub.cfg

    echo "[!] [CHROOT] Set password for root user:"
    echo "root:$ROOT_PASS" | chpasswd

    echo "[!] [CHROOT] Set password for $USER_NAME user:"
    useradd -m -G users,wheel,audio,cdrom,usb,video -s /bin/bash "$USER_NAME"
    echo "${USER_NAME}:${USER_PASS}" | chpasswd

    echo "[*] [CHROOT] Enable sudo for the wheel group"
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

    echo "[*] [CHROOT] Change gentoo repo to git"
    mkdir -p /etc/portage/repos.conf/
    cat > /etc/portage/repos.conf/gentoo.conf <<EOF
[DEFAULT]
main-repo = gentoo

[gentoo]

# The sync-depth=1 option speeds up initial pull by fetching 
# only the latest Git commit and its immediate ancestors, 
# reducing the amount of downloaded Git history.
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

    echo "[*] [CHROOT] Final cleanup"
    rm /stage3-*.tar.*

    echo "[*] [CHROOT] Done. You can now type 'exit', unmount everything and reboot"
    swapoff /swap/swap.img
    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        sbctl status
        sbctl verify
    fi
    exit 0
fi

#BEGINNING
echo "[*] [NO-CHROOT] Clock synchronization"
chronyd -q

echo "[*] [NO-CHROOT] Deleting partition table"
sgdisk --zap-all "$DISK_INSTALL"

echo "[*] [NO-CHROOT] Creating a new GPT table"
parted -s "$DISK_INSTALL" mklabel gpt

echo "[*] [NO-CHROOT] Creating EFI partition"
parted -s "$DISK_INSTALL" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK_INSTALL" set 1 esp on

if [[ "$DEV_INSTALL" == "ssd" ]]; then
    mkfs.fat -F32 "${DISK_INSTALL}1"
else
    mkfs.fat -F32 "${DISK_INSTALL}p1"
fi

echo "[*] [NO-CHROOT] Creating Linux root partition with remaining disk space"
parted -s "$DISK_INSTALL" mkpart primary 513MiB 100%
parted -s "$DISK_INSTALL" type 2 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709

mkdir /mnt/gentoo || echo "Already exist"

if [[ "$LUKSED" == "y" ]]; then
    echo "[*] [NO-CHROOT] [LUKS] Encrypting root disk with LUKS: Create unlock password"
    cryptsetup luksFormat --key-size 512 "$ROOT_PART" || { echo "Errore password!"; exit 1; }

    echo "[*] [NO-CHROOT] [LUKS] Mounting root disk with LUKS: Enter unlock password"
    cryptsetup luksOpen "$ROOT_PART" root || { echo "Errore password!"; exit 1; }

    echo "[*] [NO-CHROOT] [LUKS] Btrfs formatting"
    mkfs.btrfs -f /dev/mapper/root

    echo "[*] [NO-CHROOT] [LUKS] Mounting"
    mount /dev/mapper/root /mnt/gentoo
else
    echo "[*] [NO-CHROOT] Btrfs formatting"
    mkfs.btrfs -f "$ROOT_PART"
    echo "[*] [NO-CHROOT] Mounting"
    mount "$ROOT_PART" /mnt/gentoo
fi


cd /mnt/gentoo
for subvol in @ @home @log @cache @swap; do
    btrfs subvolume create "$subvol"
done
cd ~
umount /mnt/gentoo

if [[ "$LUKSED" == "y" ]]; then
    echo "[*] [NO-CHROOT] [LUKS] Remounting subvolumes"
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@ /dev/mapper/root /mnt/gentoo
    mkdir -p /mnt/gentoo/{boot,home,var/cache,var/log,swap}
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@home  /dev/mapper/root /mnt/gentoo/home
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@log   /dev/mapper/root /mnt/gentoo/var/log
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@cache /dev/mapper/root /mnt/gentoo/var/cache
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@swap  /dev/mapper/root /mnt/gentoo/swap
else
    echo "[*] [NO-CHROOT] Remounting subvolumes"
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@ "$ROOT_PART" /mnt/gentoo
    mkdir -p /mnt/gentoo/{boot,home,var/cache,var/log,swap}
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@home  "$ROOT_PART" /mnt/gentoo/home
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@log   "$ROOT_PART" /mnt/gentoo/var/log
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@cache "$ROOT_PART" /mnt/gentoo/var/cache
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@swap  "$ROOT_PART" /mnt/gentoo/swap
fi

mount "$EFI_PART" /mnt/gentoo/boot

echo "[*] [NO-CHROOT] Creating swap file"
cd /mnt/gentoo
truncate -s 0 swap/swap.img
chattr +C swap/swap.img
fallocate -l "$SWAP_G" swap/swap.img
chmod 0600 swap/swap.img
mkswap swap/swap.img
swapon swap/swap.img

echo "[*] [NO-CHROOT] Downloading stage3"
cd /mnt/gentoo
LATEST=$(curl -s "$MIRROR/latest-stage3-amd64-desktop-systemd.txt")
STAGE3=$(echo "$LATEST" | grep 'stage3-amd64-desktop-systemd-.*\.tar\.xz' | cut -d' ' -f1)
wget "$MIRROR/$STAGE3"

echo "[*] [NO-CHROOT] Extracting stage3"
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

echo "[*] [NO-CHROOT] DNS configuration"
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

echo "[*] [NO-CHROOT] Mounting system filesystem (proc,sys,dev,run)"
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys && mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev && mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run && mount --make-slave /mnt/gentoo/run

echo "[*] [NO-CHROOT] Entering chroot..."
cp /root/gentoo-install.sh /mnt/gentoo/gentoo-install.sh
chmod +x /mnt/gentoo/gentoo-install.sh
chroot /mnt/gentoo /bin/bash
