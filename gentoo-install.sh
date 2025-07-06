#!/usr/bin/env bash
set -euo pipefail

########### CONFIG ############
HOSTNAME="gentoo-qemu" #CHANGE
TIMEZONE_SET="Europe/Rome" #CHANGE: Your timezone: search with "ls -l /usr/share/zoneinfo"
LOCALE_GEN_SET="it_IT ISO-8859-1\nit_IT.UTF-8 UTF-8" #CHANGE Search with "cat /usr/share/i18n/SUPPORTED" add separated with \n like in example
ESELECT_LOCALE_SET="it_IT.UTF8" #CHANGE: Select the eselect locale from ESELECT_LOCALE_SET, The UTF8 one: Example "it_IT.UTF-8" become "it_IT.UTF8" w/o dash like in example
PLYMOUTH_THEME_SET="solar" #CHANGE: your favourite plymouth theme: https://wiki.gentoo.org/wiki/Plymouth
RAID_SET="y" #CHANGE: "y" or "n" Do you want RAID1?
LUKSED="y" #CHANGE: Enable LUKS? "y" or "n"
DEV_INSTALL="ssd" #CHANGE: "nvme" or "ssd"
SWAP_G="16G" #CHANGE: SWAP GB
USER_NAME="l0rdg3x" #CHANGE: non-root username
ESELECT_PROF="default/linux/amd64/23.0/desktop/plasma/systemd" #CHANGE: Select your preferred profile: "eselect profile list | less" (only systemd profiles work with this script for now) [TODO]
MIRROR="https://mirror.leaseweb.com/gentoo/releases/amd64/autobuilds" #CHANGE: Your preferred mirror for stage3 download
EFI_SIZE="512MiB" #DO NOT CHANGE
BOOT_SIZE="1GiB" #DO NOT CHANGE

if [[ "$DEV_INSTALL" == "nvme" ]]; then
    [[ "$RAID_SET" == "y" ]]; then
        DISK_INSTALL1="/dev/nvme0n1" #CHANGE: With your nvme dev1 [RAID]
        DISK_INSTALL2="/dev/nvme0n2" #CHANGE: With your nvme dev2 [RAID]
        EFI_PART1="${DISK_INSTALL1}p1" #DO NOT CHANGE
        BOOT_PART1="${DISK_INSTALL1}p2" #DO NOT CHANGE
        ROOT_PART1="${DISK_INSTALL1}p3" #DO NOT CHANGE
        EFI_PART2="${DISK_INSTALL2}p1" #DO NOT CHANGE
        BOOT_PART2="${DISK_INSTALL2}p2" #DO NOT CHANGE
        ROOT_PART2="${DISK_INSTALL2}p3" #DO NOT CHANGE
    fi
    DISK_INSTALL="/dev/nvme0n1" #CHANGE: With your nvme dev
    EFI_PART="${DISK_INSTALL}p1" #DO NOT CHANGE
    BOOT_PART="${DISK_INSTALL}p2" #DO NOT CHANGE
    ROOT_PART="${DISK_INSTALL}p3" #DO NOT CHANGE
fi
if [[ "$DEV_INSTALL" == "ssd" ]]; then
    [[ "$RAID_SET" == "y" ]]; then
        DISK_INSTALL1="/dev/sda" #CHANGE: With your ssd dev1 [RAID]
        DISK_INSTALL2="/dev/sdb" #CHANGE: With your ssd dev2 [RAID]
        EFI_PART1="${DISK_INSTALL1}1" #DO NOT CHANGE
        BOOT_PART1="${DISK_INSTALL1}2" #DO NOT CHANGE
        ROOT_PART1="${DISK_INSTALL1}3" #DO NOT CHANGE
        EFI_PART2="${DISK_INSTALL2}1" #DO NOT CHANGE
        BOOT_PART2="${DISK_INSTALL2}2" #DO NOT CHANGE
        ROOT_PART2="${DISK_INSTALL2}3" #DO NOT CHANGE
    fi
    DISK_INSTALL="/dev/sda" #CHANGE: With your ssd dev
    EFI_PART="${DISK_INSTALL}1" #DO NOT CHANGE
    BOOT_PART="${DISK_INSTALL}2" #DO NOT CHANGE
    ROOT_PART="${DISK_INSTALL}3" #DO NOT CHANGE
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
    cat > /etc/portage/make.conf <<'EOF' #CHANGE: USE, flags or VIDEO_CARDS, this is nearly to default
# ====================
# = GENTOO MAKE.CONF =
# ====================

COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
RUSTFLAGS="${RUSTFLAGS} -C target-cpu=native"

MAKEOPTS="-j4 -l4"

EMERGE_DEFAULT_OPTS="--jobs 4 --load-average 4"

FEATURES="${FEATURES} getbinpkg candy parallel-fetch parallel-install binpkg-request-signature"

USE="dist-kernel"

ACCEPT_LICENSE="*"

GRUB_PLATFORMS="efi-64"

VIDEO_CARDS=""

# This sets the language of build output to English.
# Please keep this setting intact when reporting bugs.
LC_MESSAGES=C.utf8


EOF

    echo "[*] [CHROOT] Select Mirror list (wait 3 secs)"
    sleep 3
    mirrorselect -i -o >> /etc/portage/make.conf

    mkdir -p /etc/portage/binrepos.conf/
    cat > /etc/portage/binrepos.conf/gentoobinhost.conf <<EOF #CHANGE: This is the default binhost repo, change if you want: https://www.gentoo.org/downloads/mirrors/ choose "x86-64-v3" for modern CPU
[binhost]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64-v3
EOF

    getuto
    emerge --sync

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
    emerge dev-util/ccache
    emerge dev-vcs/git
    emerge sys-fs/btrfs-progs
    emerge sys-fs/xfsprogs
    emerge sys-fs/e2fsprogs
    emerge sys-fs/dosfstools
    emerge sys-fs/f2fs-tools
    emerge sys-fs/ntfs3g
    emerge sys-fs/zfs
    emerge sys-block/io-scheduler-udev-rules
    emerge sys-fs/mdadm
    echo "sys-kernel/installkernel grub dracut" > /etc/portage/package.use/installkernel
    if [[ "$LUKSED" == "y" ]]; then ######################################                SEI QUI!!!!
        echo "sys-apps/systemd cryptsetup" > /etc/portage/package.use/systemd
        LUKS_UUID=$(blkid "$ROOT_PART" | grep -oP ' UUID="\K[^"]+')
        ROOT_UUID=$(blkid /dev/mapper/root | grep -oP ' UUID="\K[^"]+')
    fi
    emerge sys-apps/systemd
    emerge sys-kernel/gentoo-kernel-bin
    emerge sys-kernel/linux-firmware
    emerge sys-firmware/sof-firmware
    if [[ "$LUKSED" == "y" ]]; then
        echo "kernel_cmdline+=\" root=UUID=$ROOT_UUID rd.luks.uuid=$LUKS_UUID \"" >> /etc/dracut.conf
        echo 'add_dracutmodules+=" crypt dm rootfs-block "' >> /etc/dracut.conf
    fi
    emerge sys-kernel/installkernel
    emerge sys-fs/genfstab
    genfstab -U / >> /etc/fstab
    echo "$HOSTNAME" > /etc/hostname
    systemd-machine-id-setup
    systemd-firstboot --prompt
    emerge sys-apps/mlocate
    systemctl enable sshd
    emerge net-misc/chrony
    systemctl enable chronyd.service
    echo "sys-boot/plymouth systemd" > /etc/portage/package.use/plymouth
    emerge sys-boot/plymouth
    plymouth-set-default-theme "$PLYMOUTH_THEME_SET"
    emerge net-wireless/iw net-wireless/wpa_supplicant
    emerge net-misc/dhcpcd

    echo "[*] [CHROOT] GRUB configuration"
    if [[ "$LUKSED" == "y" ]]; then
        echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
        sed -i "s/#GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX=\"rd.luks.uuid=luks-$LUKS_UUID rd.luks.options=password-echo=no quiet rw splash"/g\" /etc/default/grub
    else
        sed -i "s/#GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX=\"quiet rw splash"/g\" /etc/default/grub
    fi
    sed -i 's/#GRUB_GFXPAYLOAD_LINUX=/GRUB_GFXPAYLOAD_LINUX=keep/' /etc/default/grub
    grub-install --efi-directory=/boot
    emerge --config sys-kernel/gentoo-kernel-bin
    grub-mkconfig -o /boot/grub/grub.cfg

    echo "[!] [CHROOT] Set password for root user:"
    passwd

    echo "[!] [CHROOT] Set password for $USER_NAME user:"
    useradd -m -G users,wheel,audio,cdrom,usb,video -s /bin/bash "$USER_NAME"
    passwd "$USER_NAME"

    echo "[*] [CHROOT] Enable sudo for the wheel group"
    emerge app-admin/sudo
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

    exit 0
fi

echo "[*] [NO-CHROOT] Clock synchronization"
chronyd -q

# Case RAID
[[ "$RAID_SET" == "y" ]]; then
    for DISK in $DISK_INSTALL1 $DISK_INSTALL2; do
        echo "[*] [NO-CHROOT] Deleting partition table"
        sgdisk --zap-all "$DISK"

        echo "[*] [NO-CHROOT] Creating a new GPT table"
        parted -s "$DISK" mklabel gpt

        echo "[*] [NO-CHROOT] Creating $EFI_SIZE EFI partition"
        parted -s "$DISK" mkpart ESP fat32 1MiB $EFI_SIZE
        parted -s "$DISK" set 1 esp on

        echo "[*] [NO-CHROOT] Creating $BOOT_SIZE boot partition"
        parted -s "$DISK" mkpart primary ext4 $EFI_SIZE $(echo "$EFI_SIZE + $BOOT_SIZE" | bc)

        echo "[*] [NO-CHROOT] Creating Linux root partition with remaining disk space"
        parted -s "$DISK" mkpart primary $(echo "$EFI_SIZE + $BOOT_SIZE" | bc) 100%
        parted -s "$DISK" type 2 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709

        echo "[*] ------RAID /boot"
        mdadm --create /dev/md0 --level=1 --raid-devices=2 ${DISK1}2 ${DISK2}2 --metadata=1.0
        mkfs.ext4 /dev/md0
        
        # Case RAID + LUKS
        if [[ "$LUKSED" == "y" ]]; then
            echo "[*] [NO-CHROOT] [LUKS] Encrypting root disk with LUKS: Create unlock password"
            cryptsetup luksFormat --key-size 512 "${DISK}3" || { echo "Errore password!"; exit 1; }

            echo "[*] [NO-CHROOT] [LUKS] Mounting root disk with LUKS: Enter unlock password"
            if [[ "$DISK" == "$DISK_INSTALL1" ]]; then
                if [[ "$DEV_INSTALL" == "ssd" ]]; then
                    cryptsetup luksOpen "${DISK}3" root1 || { echo "Errore password!"; exit 1; }
                else
                    cryptsetup luksOpen "${DISK}p3" root1 || { echo "Errore password!"; exit 1; }
                fi
            fi
            if [[ "$DISK" == "$DISK_INSTALL2" ]]; then
                cryptsetup luksOpen "${DISK}3" root2 || { echo "Errore password!"; exit 1; }
            fi
        fi
    done
    
    if [[ "$LUKSED" == "y" ]]; then
        echo "[*] [NO-CHROOT] [LUKS] Btrfs formatting"
        mkfs.btrfs -m raid1 -d raid1 /dev/mapper/root1 /dev/mapper/root2

        echo "[*] [NO-CHROOT] [LUKS] Mounting"
        mount /dev/mapper/root1 /mnt/gentoo
    else
        echo "[*] [NO-CHROOT] [LUKS----] Btrfs formatting"
        mkfs.btrfs -m raid1 -d raid1 "$ROOT_PART1" "$ROOT_PART2"
        mount "$ROOT_PART1" /mnt/gentoo
    done
else #CASE NO RAID
    echo "[*] [NO-CHROOT] Deleting partition table"
    sgdisk --zap-all "$DISK_INSTALL"

    echo "[*] [NO-CHROOT] Creating a new GPT table"
    parted -s "$DISK_INSTALL" mklabel gpt

    echo "[*] [NO-CHROOT] Creating $EFI_SIZE EFI partition"
    parted -s "$DISK_INSTALL" mkpart ESP fat32 1MiB $EFI_SIZE
    parted -s "$DISK_INSTALL" set 1 esp on

    echo "[*] [NO-CHROOT] Creating $BOOT_SIZE boot partition"
    parted -s "$DISK_INSTALL" mkpart primary ext4 $EFI_SIZE $(echo "$EFI_SIZE + $BOOT_SIZE" | bc)

    echo "[*] [NO-CHROOT] Creating Linux root partition with remaining disk space"
    parted -s "$DISK_INSTALL" mkpart primary $(echo "$EFI_SIZE + $BOOT_SIZE" | bc) 100%
    parted -s "$DISK_INSTALL" type 2 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709

    if [[ "$LUKSED" == "y" ]]; then
        echo "[*] [NO-CHROOT] [LUKS] Encrypting root disk with LUKS: Create unlock password"
        cryptsetup luksFormat --key-size 512 "$ROOT_PART" || { echo "Errore password!"; exit 1; }

        echo "[*] [NO-CHROOT] [LUKS] Mounting root disk with LUKS: Enter unlock password"
        cryptsetup luksOpen "$ROOT_PART" root || { echo "Errore password!"; exit 1; }

        echo "[*] [NO-CHROOT] [LUKS] Btrfs formatting"
        mkfs.btrfs /dev/mapper/root

        echo "[*] [NO-CHROOT] [LUKS] Mounting"
        mount /dev/mapper/root /mnt/gentoo
    else
        echo "[*] [NO-CHROOT] Btrfs formatting"
        mkfs.btrfs "$ROOT_PART"
        echo "[*] [NO-CHROOT] Mounting"
        mount "$ROOT_PART" /mnt/gentoo
    fi
fi

cd /mnt/gentoo
for subvol in @ @home @log @cache @swap; do
    btrfs subvolume create "$subvol"
done
cd ~
umount /mnt/gentoo




if [[ "$LUKSED" == "y" ]]; then
    if [[ "$RAID_SET" == "y" ]]; then
        echo "[*] [NO-CHROOT] [LUKS] Remounting subvolumes"
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@ /dev/mapper/root1 /mnt/gentoo
        mkdir -p /mnt/gentoo/{boot,home,var/cache,var/log,swap}
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@home  /dev/mapper/root1 /mnt/gentoo/home
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@log   /dev/mapper/root1 /mnt/gentoo/var/log
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@cache /dev/mapper/root1 /mnt/gentoo/var/cache
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@swap  /dev/mapper/root1 /mnt/gentoo/swap
    else
        echo "[*] [NO-CHROOT] [LUKS] Remounting subvolumes"
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@ /dev/mapper/root /mnt/gentoo
        mkdir -p /mnt/gentoo/{boot,home,var/cache,var/log,swap}
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@home  /dev/mapper/root /mnt/gentoo/home
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@log   /dev/mapper/root /mnt/gentoo/var/log
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@cache /dev/mapper/root /mnt/gentoo/var/cache
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@swap  /dev/mapper/root /mnt/gentoo/swap
    fi
else
    echo "[*] [NO-CHROOT] Remounting subvolumes"
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@ "$ROOT_PART" /mnt/gentoo
    mkdir -p /mnt/gentoo/{boot,home,var/cache,var/log,swap}
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@home  "$ROOT_PART" /mnt/gentoo/home
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@log   "$ROOT_PART" /mnt/gentoo/var/log
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@cache "$ROOT_PART" /mnt/gentoo/var/cache
    mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@swap  "$ROOT_PART" /mnt/gentoo/swap
fi

echo "[*] [NO-CHROOT] Mounting /boot + EFI"
mount /dev/md0 /mnt/gentoo/boot
mount "$EFI_PART" /mnt/gentoo/boot/efi

echo "[*] [NO-CHROOT] Creating swap file"
cd /mnt/gentoo
truncate -s 0 swap/swap.img
chattr +C swap/swap.img
fallocate -l "$SWAP_G" swap/swap.img
chmod 0600 swap/swap.img
mkswap swap/swap.img
swapon swap/swap.img

echo "[*] [NO-CHROOT] Downloading stage3"
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
