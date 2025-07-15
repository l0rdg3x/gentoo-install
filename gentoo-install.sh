#!/usr/bin/env bash
set -euo pipefail

########### CONFIG ############   NOTE: MAYBE 'dialog' ?????
HOSTNAME="gentoo-qemu" #CHANGE
TIMEZONE_SET="Europe/Rome" #CHANGE: Your timezone: search with "ls -l /usr/share/zoneinfo"
LOCALE_GEN_SET="it_IT ISO-8859-1\nit_IT.UTF-8 UTF-8" #CHANGE Search with "cat /usr/share/i18n/SUPPORTED" add separated with \n like in example
ESELECT_LOCALE_SET="it_IT.UTF8" #CHANGE: Select the eselect locale from ESELECT_LOCALE_SET, The UTF8 one: Example "it_IT.UTF-8" become "it_IT.UTF8" w/o dash like in example
SYSTEMD_LOCALE="it" #CHANGE: Systemd locale
PLYMOUTH_THEME_SET="solar" #CHANGE: your favourite plymouth theme: https://wiki.gentoo.org/wiki/Plymouth
RAID_SET="y" #CHANGE: "y" or "n" Do you want RAID1?
LUKSED="n" #CHANGE: Enable LUKS? "y" or "n"
LUKS_PASSWORD="1" #CHANGE: with your secure luks password
DEV_INSTALL="ssd" #CHANGE: "nvme" or "ssd"
SWAP_G="16" #CHANGE: SWAP GB
ROOT_PASS="Passw0rdd!" #CHANGE: Password for root user
USER_NAME="l0rdg3x" #CHANGE: non-root username
USER_PASS="Passw0rdd!" #CHANGE: Password for non root user 
ESELECT_PROF="default/linux/amd64/23.0/desktop/plasma/systemd" #CHANGE: Select your preferred profile: "eselect profile list | less" (only systemd profiles work with this script for now) [TODO]
MIRROR="https://mirror.leaseweb.com/gentoo/releases/amd64/autobuilds" #CHANGE: Your preferred mirror for stage3 download

if [[ "$DEV_INSTALL" == "nvme" ]]; then
    if [[ "$RAID_SET" == "y" ]]; then
        DISK_INSTALL1="/dev/nvme0n1" #CHANGE: With your nvme dev1 [RAID]
        DISK_INSTALL2="/dev/nvme0n2" #CHANGE: With your nvme dev2 [RAID]
        EFI_PART1="${DISK_INSTALL1}p1" #DO NOT CHANGE
        BOOT_PART1="${DISK_INSTALL1}p2" #DO NOT CHANGE
        ROOT_PART1="${DISK_INSTALL1}p3" #DO NOT CHANGE
        SWAP_PART1="${DISK_INSTALL1}p4" #DO NOT CHANGE
        EFI_PART2="${DISK_INSTALL2}p1" #DO NOT CHANGE
        BOOT_PART2="${DISK_INSTALL2}p2" #DO NOT CHANGE
        ROOT_PART2="${DISK_INSTALL2}p3" #DO NOT CHANGE
        SWAP_PART2="${DISK_INSTALL2}p4" #DO NOT CHANGE
    else
        DISK_INSTALL="/dev/nvme0n1" #CHANGE: With your nvme dev
        EFI_PART="${DISK_INSTALL}p1" #DO NOT CHANGE
        BOOT_PART="${DISK_INSTALL}p2" #DO NOT CHANGE
        ROOT_PART="${DISK_INSTALL}p3" #DO NOT CHANGEù
        SWAP_PART="${DISK_INSTALL}p4" #DO NOT CHANGE
    fi
fi
if [[ "$DEV_INSTALL" == "ssd" ]]; then
    if [[ "$RAID_SET" == "y" ]]; then
        DISK_INSTALL1="/dev/sda" #CHANGE: With your ssd dev1 [RAID]
        DISK_INSTALL2="/dev/sdb" #CHANGE: With your ssd dev2 [RAID]
        EFI_PART1="${DISK_INSTALL1}1" #DO NOT CHANGE
        BOOT_PART1="${DISK_INSTALL1}2" #DO NOT CHANGE
        ROOT_PART1="${DISK_INSTALL1}3" #DO NOT CHANGE
        SWAP_PART1="${DISK_INSTALL1}4" #DO NOT CHANGE
        EFI_PART2="${DISK_INSTALL2}1" #DO NOT CHANGE
        BOOT_PART2="${DISK_INSTALL2}2" #DO NOT CHANGE
        ROOT_PART2="${DISK_INSTALL2}3" #DO NOT CHANGE
        SWAP_PART2="${DISK_INSTALL2}4" #DO NOT CHANGE
    else
        DISK_INSTALL="/dev/sda" #CHANGE: With your ssd dev
        EFI_PART="${DISK_INSTALL}1" #DO NOT CHANGE
        BOOT_PART="${DISK_INSTALL}2" #DO NOT CHANGE
        ROOT_PART="${DISK_INSTALL}3" #DO NOT CHANGE
        SWAP_PART="${DISK_INSTALL}4" #DO NOT CHANGE
    fi
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
    if [[ "$LUKSED" == "y" ]]; then
        echo "sys-apps/systemd cryptsetup" > /etc/portage/package.use/systemd
        if [[ "$RAID_SET" == "y" ]]; then
            ROOT_UUID=$(blkid -s UUID -o value /dev/disk/by-label/cryptroot)
            LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART1")
            LUKS_UUID2=$(blkid -s UUID -o value "$ROOT_PART2")
            SWAP_UUID=$(blkid -s UUID -o value /dev/md1)
            cat <<EOF > /etc/crypttab
cryptroot1 UUID=$LUKS_UUID none luks
cryptroot2 UUID=$LUKS_UUID2 none luks
cryptswap UUID=$SWAP_UUID /root/swap.key luks
EOF
        else
            LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
            ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/root)
            SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")
            cat <<EOF > /etc/crypttab
cryptswap UUID=$SWAP_UUID /root/swap.key luks
EOF
        fi
    else
        if [[ "$RAID_SET" == "y" ]]; then
            ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART1")
            SWAP_UUID=$(blkid -s UUID -o value /dev/md1)
        else
            ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
            SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")
        fi
    fi
    
    emerge dev-util/ccache dev-vcs/git sys-fs/btrfs-progs sys-fs/xfsprogs sys-fs/e2fsprogs sys-fs/dosfstools sys-fs/ntfs3g sys-block/io-scheduler-udev-rules sys-fs/mdadm
    emerge sys-apps/systemd
    emerge sys-kernel/gentoo-kernel-bin
    emerge sys-kernel/linux-firmware
    emerge sys-firmware/sof-firmware
    if [[ "$LUKSED" == "y" ]]; then
        if [[ "$RAID_SET" == "y" ]]; then
            echo "kernel_cmdline+=\" root=UUID=$ROOT_UUID resume=UUID=$SWAP_UUID rd.luks.uuid=$LUKS_UUID rd.luks.uuid=$LUKS_UUID2 \"" >> /etc/dracut.conf
            echo 'add_dracutmodules+=" btrfs crypt dm rootfs-block resume mdraid "' >> /etc/dracut.conf
            echo 'install_items+=" /etc/crypttab "' >> /etc/dracut.conf
            echo 'install_items+=" /root/swap.key "' >> /etc/dracut.conf
            echo 'hostonly=no' >> /etc/dracut.conf
            echo 'use_fstab="yes"' >> /etc/dracut.conf
            echo 'add_fstab+=" /etc/fstab "' >> /etc/dracut.conf
            echo 'persistent_policy="by-uuid"' >> /etc/dracut.conf
            mdadm --detail --scan >> /etc/mdadm.conf
        else
            echo "kernel_cmdline+=\" root=UUID=$ROOT_UUID resume=UUID=$SWAP_UUID rd.luks.uuid=$LUKS_UUID \"" >> /etc/dracut.conf
            echo 'add_dracutmodules+=" btrfs crypt dm rootfs-block resume "' >> /etc/dracut.conf
            echo 'install_items+=" /etc/crypttab "' >> /etc/dracut.conf
            echo 'install_items+=" /root/swap.key "' >> /etc/dracut.conf
            echo 'hostonly=no' >> /etc/dracut.conf
            echo 'use_fstab="yes"' >> /etc/dracut.conf
            echo 'add_fstab+=" /etc/fstab "' >> /etc/dracut.conf
            echo 'persistent_policy="by-uuid"' >> /etc/dracut.conf
        fi
    else
        if [[ "$RAID_SET" == "y" ]]; then
            echo "kernel_cmdline+=\" root=UUID=$ROOT_UUID resume=UUID=$SWAP_UUID \"" >> /etc/dracut.conf
            echo 'add_dracutmodules+=" btrfs dm rootfs-block resume mdraid "' >> /etc/dracut.conf
            echo 'hostonly=no' >> /etc/dracut.conf
            echo 'use_fstab="yes"' >> /etc/dracut.conf
            echo 'add_fstab+=" /etc/fstab "' >> /etc/dracut.conf
            echo 'persistent_policy="by-uuid"' >> /etc/dracut.conf
            mdadm --detail --scan >> /etc/mdadm.conf
        else
            echo "kernel_cmdline+=\" root=UUID=$ROOT_UUID resume=UUID=$SWAP_UUID \"" >> /etc/dracut.conf
            echo 'add_dracutmodules+=" btrfs dm rootfs-block resume "' >> /etc/dracut.conf
            echo 'hostonly=no' >> /etc/dracut.conf
            echo 'use_fstab="yes"' >> /etc/dracut.conf
            echo 'add_fstab+=" /etc/fstab "' >> /etc/dracut.conf
            echo 'persistent_policy="by-uuid"' >> /etc/dracut.conf
        fi
    fi

    emerge sys-kernel/installkernel
    emerge sys-fs/zfs
    emerge sys-fs/genfstab
    genfstab -U / >> /etc/fstab
    echo "$HOSTNAME" > /etc/hostname
    systemd-machine-id-setup
    systemd-firstboot --keymap="$SYSTEMD_LOCALE"
    emerge sys-apps/mlocate sys-boot/plymouth net-misc/chrony net-wireless/iw net-wireless/wpa_supplicant net-misc/dhcpcd app-admin/sudo
    systemctl enable sshd
    systemctl enable chronyd.service
    plymouth-set-default-theme "$PLYMOUTH_THEME_SET"

    echo "[*] [CHROOT] GRUB configuration"
    if [[ "$LUKSED" == "y" ]]; then
        echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
        if [[ "$RAID_SET" == "y" ]]; then
            sed -i "s|^#GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"resume=UUID=$SWAP_UUID rd.luks.uuid=$LUKS_UUID rd.luks.uuid=$LUKS_UUID2 rd.luks.options=password-echo=no quiet rw splash\"|" /etc/default/grub
        else
            sed -i "s|^#GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"resume=UUID=$SWAP_UUID rd.luks.uuid=$LUKS_UUID rd.luks.options=password-echo=no quiet rw splash\"|" /etc/default/grub
        fi
    else
        sed -i "s|^#GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"resume=UUID=$SWAP_UUID quiet rw splash\"|" /etc/default/grub
    fi
    sed -i 's/#GRUB_GFXPAYLOAD_LINUX=/GRUB_GFXPAYLOAD_LINUX=keep/' /etc/default/grub
    if [[ "$RAID_SET" == "y" ]]; then
        grub-install --efi-directory=/boot/efi --bootloader-id=gentoo --removable --recheck --no-nvram --boot-directory=/boot
        grub-install --efi-directory=/boot/efi1 --bootloader-id=gentoo --removable --recheck --no-nvram --boot-directory=/boot
    else
        grub-install --efi-directory=/boot/efi --bootloader-id=gentoo --removable --recheck --no-nvram --boot-directory=/boot
    fi
    emerge --config sys-kernel/gentoo-kernel-bin
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

    exit 0
fi

#BEGINNING
echo "[*] [NO-CHROOT] Clock synchronization"
chronyd -q

# Case RAID
if [[ "$RAID_SET" == "y" ]]; then
    for DISK in $DISK_INSTALL1 $DISK_INSTALL2; do
        echo "[*] [NO-CHROOT] Deleting partition table"
        sgdisk --zap-all "$DISK"

        echo "[*] [NO-CHROOT] Creating a new GPT table"
        parted -s "$DISK" mklabel gpt

        echo "[*] [NO-CHROOT] Creating EFI partition"
        parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
        parted -s "$DISK" set 1 esp on

        if [[ "$DEV_INSTALL" == "ssd" ]]; then
            mkfs.fat -F32 "${DISK}1"
        else
            mkfs.fat -F32 "${DISK}p1"
        fi

        echo "[*] [NO-CHROOT] Creating boot partition"
        parted -s "$DISK" mkpart primary ext4 513MiB 1537MiB

        echo "[*] [NO-CHROOT] Calculating partition layout (no bc)"
        DISK_SIZE_MIB=$(parted -s "$DISK" unit MiB print | awk '/^Disk .*MiB/ {gsub("MiB","",$3); print int($3)}')
        SWAP_SIZE_MIB=$(( SWAP_G * 1024 ))
        ROOT_END_MIB=$(( DISK_SIZE_MIB - SWAP_SIZE_MIB ))

        echo "[*] [NO-CHROOT] Creating Linux root partition with remaining disk space"
        parted -s "$DISK" mkpart primary 1537MiB ${ROOT_END_MIB}MiB
        parted -s "$DISK" type 2 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709

        echo "[*] [NO-CHROOT] Creating swap partition"
        parted -s "$DISK" mkpart primary linux-swap ${ROOT_END_MIB}MiB 100%

        # Case RAID + LUKS
        if [[ "$LUKSED" == "y" ]]; then
            echo -n "$LUKS_PASSWORD" > /tmp/luks.key

            echo "[*] [NO-CHROOT] [LUKS] Encrypting root disk with LUKS: Create unlock password"
            if [[ "$DEV_INSTALL" == "ssd" ]]; then
                cryptsetup luksFormat --key-size 512 --key-file /tmp/luks.key --batch-mode "${DISK}3" || { echo "Errore password!"; exit 1; }
            else
                cryptsetup luksFormat --key-size 512 --key-file /tmp/luks.key --batch-mode "${DISK}p3" || { echo "Errore password!"; exit 1; }
            fi
            echo "[*] [NO-CHROOT] [LUKS] Mounting root disk with LUKS: Enter unlock password"
            if [[ "$DISK" == "$DISK_INSTALL1" ]]; then
                if [[ "$DEV_INSTALL" == "ssd" ]]; then
                    cryptsetup luksOpen --key-file /tmp/luks.key "${DISK}3" cryptroot1 || { echo "Errore password!"; exit 1; }
                else
                    cryptsetup luksOpen --key-file /tmp/luks.key "${DISK}p3" cryptroot1 || { echo "Errore password!"; exit 1; }
                fi
            fi
            if [[ "$DISK" == "$DISK_INSTALL2" ]]; then
                if [[ "$DEV_INSTALL" == "ssd" ]]; then
                    cryptsetup luksOpen --key-file /tmp/luks.key "${DISK}3" cryptroot2 || { echo "Errore password!"; exit 1; }
                else
                    cryptsetup luksOpen --key-file /tmp/luks.key "${DISK}p3" cryptroot2 || { echo "Errore password!"; exit 1; }
                fi
            fi
            rm -f /tmp/luks.key
        fi
    done

    echo "[*] RAID /boot"
    mdadm --create /dev/md0 --level=1 --raid-devices=2 "$BOOT_PART1" "$BOOT_PART2" --metadata=1.0 --bitmap=internal
    mkfs.ext4 /dev/md0

    if [[ "$LUKSED" == "y" ]]; then
        echo "[*] [NO-CHROOT] [LUKS] Btrfs formatting"
        mkfs.btrfs -f -m raid1 -d raid1 -L cryptroot /dev/mapper/cryptroot1 /dev/mapper/cryptroot2

        echo "[*] [NO-CHROOT] [LUKS] Mounting"
        mount /dev/disk/by-label/cryptroot /mnt/gentoo

        dd if=/dev/urandom of=/root/swap.key bs=1 count=32
        chmod 600 /root/swap.key

        mdadm --create /dev/md1 --level=1 --raid-devices=2 "$SWAP_PART1" "$SWAP_PART2" --metadata=1.0 --bitmap=internal
        cryptsetup luksFormat /dev/md1 --key-file /root/swap.key --batch-mode
        cryptsetup luksOpen --key-file /root/swap.key /dev/md1 cryptswap
        mkswap /dev/mapper/cryptswap
        swapon /dev/mapper/cryptswap

    else
        echo "[*] [NO-CHROOT] Btrfs formatting"
        mkfs.btrfs -f -m raid1 -d raid1 "$ROOT_PART1" "$ROOT_PART2"
        mount "$ROOT_PART1" /mnt/gentoo
        mdadm --create /dev/md1 --level=1 --raid-devices=2 "$SWAP_PART1" "$SWAP_PART2" --metadata=1.0 --bitmap=internal
        mkswap /dev/md1
        swapon /dev/md1
    fi
else #CASE NO RAID
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

    echo "[*] [NO-CHROOT] Creating boot partition"
    parted -s "$DISK_INSTALL" mkpart primary ext4 513MiB 1537MiB

    echo "[*] [NO-CHROOT] Calculating partition layout (no bc)"
    DISK_SIZE_MIB=$(parted -s "$DISK_INSTALL" unit MiB print | awk '/^Disk .*MiB/ {gsub("MiB","",$3); print int($3)}')
    SWAP_SIZE_MIB=$(( SWAP_G * 1024 ))
    ROOT_END_MIB=$(( DISK_SIZE_MIB - SWAP_SIZE_MIB ))

    echo "[*] [NO-CHROOT] Creating Linux root partition with remaining disk space"
    parted -s "$DISK_INSTALL" mkpart primary 1537MiB ${ROOT_END_MIB}MiB
    parted -s "$DISK_INSTALL" type 2 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709

    echo "[*] [NO-CHROOT] Creating swap partition"
    parted -s "$DISK_INSTALL" mkpart primary linux-swap ${ROOT_END_MIB}MiB 100%

    if [[ "$LUKSED" == "y" ]]; then
        echo "[*] [NO-CHROOT] [LUKS] Encrypting root disk with LUKS: Create unlock password"
        cryptsetup luksFormat --key-size 512 "$ROOT_PART" || { echo "Errore password!"; exit 1; }

        echo "[*] [NO-CHROOT] [LUKS] Mounting root disk with LUKS: Enter unlock password"
        cryptsetup luksOpen "$ROOT_PART" root || { echo "Errore password!"; exit 1; }

        echo "[*] [NO-CHROOT] [LUKS] Btrfs formatting"
        mkfs.btrfs -f /dev/mapper/root

        echo "[*] [NO-CHROOT] [LUKS] Mounting"
        mount /dev/mapper/root /mnt/gentoo

        dd if=/dev/urandom of=/root/swap.key bs=1 count=32
        chmod 600 /root/swap.key

        cryptsetup luksFormat "$SWAP_PART" --key-file /root/swap.key --batch-mode
        cryptsetup luksOpen --key-file /root/swap.key "$SWAP_PART" cryptswap
        mkswap /dev/mapper/cryptswap
        swapon /dev/mapper/cryptswap
    else
        echo "[*] [NO-CHROOT] Btrfs formatting"
        mkfs.btrfs -f "$ROOT_PART"
        echo "[*] [NO-CHROOT] Mounting"
        mount "$ROOT_PART" /mnt/gentoo

        mkswap "$SWAP_PART"
        swapon "$SWAP_PART"
    fi
fi

cd /mnt/gentoo
for subvol in @ @home @log @cache; do
    btrfs subvolume create "$subvol"
done
cd ~
umount /mnt/gentoo

if [[ "$LUKSED" == "y" ]]; then
    if [[ "$RAID_SET" == "y" ]]; then
        echo "[*] [NO-CHROOT] [LUKS] Remounting subvolumes"
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@ /dev/disk/by-label/cryptroot /mnt/gentoo
        mkdir -p /mnt/gentoo/{boot,home,var/cache,var/log}
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@home  /dev/disk/by-label/cryptroot /mnt/gentoo/home
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@log   /dev/disk/by-label/cryptroot /mnt/gentoo/var/log
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@cache /dev/disk/by-label/cryptroot /mnt/gentoo/var/cache
        mount /dev/md0 /mnt/gentoo/boot
    else
        echo "[*] [NO-CHROOT] [LUKS] Remounting subvolumes"
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@ /dev/mapper/root /mnt/gentoo
        mkdir -p /mnt/gentoo/{boot,home,var/cache,var/log}
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@home  /dev/mapper/root /mnt/gentoo/home
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@log   /dev/mapper/root /mnt/gentoo/var/log
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@cache /dev/mapper/root /mnt/gentoo/var/cache
        mount $BOOT_PART /mnt/gentoo/boot
    fi
else
    if [[ "$RAID_SET" == "y" ]]; then
        echo "[*] [NO-CHROOT] Remounting subvolumes"
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@ "$ROOT_PART1" /mnt/gentoo
        mkdir -p /mnt/gentoo/{boot,home,var/cache,var/log}
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@home  "$ROOT_PART1" /mnt/gentoo/home
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@log   "$ROOT_PART1" /mnt/gentoo/var/log
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@cache "$ROOT_PART1" /mnt/gentoo/var/cache
        mount /dev/md0 /mnt/gentoo/boot
    else
        echo "[*] [NO-CHROOT] Remounting subvolumes"
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@ "$ROOT_PART" /mnt/gentoo
        mkdir -p /mnt/gentoo/{boot,home,var/cache,var/log}
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@home  "$ROOT_PART" /mnt/gentoo/home
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@log   "$ROOT_PART" /mnt/gentoo/var/log
        mount -o defaults,noatime,space_cache=v2,compress=zstd,autodefrag,subvol=@cache "$ROOT_PART" /mnt/gentoo/var/cache
        mount $BOOT_PART /mnt/gentoo/boot
    fi
fi

mkdir -p /mnt/gentoo/boot/efi

if [[ "$RAID_SET" == "y" ]]; then
    mkdir -p /mnt/gentoo/boot/efi1
    mount "$EFI_PART1" /mnt/gentoo/boot/efi
    mount "$EFI_PART2" /mnt/gentoo/boot/efi1
else
    mount "$EFI_PART" /mnt/gentoo/boot/efi
fi

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
