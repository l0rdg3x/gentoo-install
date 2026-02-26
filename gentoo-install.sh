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
BINHOST_V3="y" #CHANGE: 'n' if you want to disable x86_64-v3 repo and use x86_64 instead
ROOT_PASS="Passw0rdd!" #CHANGE: Password for root user
USER_NAME="l0rdg3x" #CHANGE: non-root username
USER_PASS="Passw0rdd!" #CHANGE: Password for non root user 
ESELECT_PROF="default/linux/amd64/23.0/desktop/plasma/systemd" #CHANGE: Select your preferred profile: "eselect profile list | less" (only systemd profiles work with this script for now) [TODO]
MIRROR="https://distfiles.gentoo.org/releases/amd64/autobuilds" #CHANGE: Your preferred mirror for stage3 download

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
    rm /etc/profile.d/debug* || true
    mkdir -p /var/db/repos/gentoo/
    source /etc/profile
    emerge-webrsync

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

MAKEOPTS="-j$(nproc) -l$(nproc)"

EMERGE_DEFAULT_OPTS="--jobs $(nproc) --load-average $(nproc)"

FEATURES="\${FEATURES} candy parallel-fetch parallel-install"

USE="dist-kernel uki systemd"

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
    EXTRA_FEATURES=""

    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        EXTRA_USE+=" modules-sign secureboot"
        if [ ! -d /sys/firmware/efi/efivars ]; then
            mount -t efivarfs efivarfs /sys/firmware/efi/efivars || { echo "Error efivars mount"; exit 1; }
            chattr -i /sys/firmware/efi/efivars/*
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
        EXTRA_FEATURES+=" getbinpkg binpkg-request-signature"
    
        mkdir -p /etc/portage/binrepos.conf/
		SUFFIX=$([[ "$BINHOST_V3" == "y" ]] && echo "x86-64-v3" || echo "x86-64")
        cat > /etc/portage/binrepos.conf/gentoobinhost.conf <<EOF
[binhost]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/$SUFFIX
EOF
		getuto
    	emerge --sync
	fi

    if [[ -n "$EXTRA_USE" ]]; then
        sed -i "s/systemd/systemd${EXTRA_USE}/" /etc/portage/make.conf
    fi
    if [[ -n "$EXTRA_FEATURES" ]]; then
        sed -i "s/parallel-install/parallel-install${EXTRA_FEATURES}/" /etc/portage/make.conf
        sed -i 's/EMERGE_DEFAULT_OPTS="/&--usepkg=y --binpkg-changed-deps=y /' /etc/portage/make.conf
    fi

    echo "[*] [CHROOT] Setup CPU flags"
    mkdir -p /var/cache/ccache
    emerge --oneshot app-portage/cpuid2cpuflags
    echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

    echo "[*] [CHROOT] Set Localization"
    ln -sf ../usr/share/zoneinfo/"$TIMEZONE_SET" /etc/localtime
    echo -e "en_US.UTF-8 UTF-8\n$LOCALE_GEN_SET" > /etc/locale.gen
    locale-gen
    eselect locale set "$ESELECT_LOCALE_SET"
    env-update && source /etc/profile

    echo "[*] [CHROOT] Base installation"
    echo "sys-kernel/installkernel dracut uki" > /etc/portage/package.use/installkernel
    echo "sys-boot/grub shim" >> /etc/portage/package.use/grub
    echo "sys-boot/plymouth systemd" > /etc/portage/package.use/plymouth
    echo "sys-apps/systemd cryptsetup boot" > /etc/portage/package.use/systemd
    
    cat > /etc/portage/package.accept_keywords/pkgs <<EOF
app-crypt/sbctl ~amd64
sys-kernel/gentoo-kernel-bin ~amd64
sys-kernel/gentoo-kernel ~amd64
virtual/dist-kernel ~amd64
EOF

    mkdir -p /boot/EFI/gentoo
    emerge app-crypt/efitools app-crypt/sbctl
    #wget https://raw.githubusercontent.com/Deftera186/sbctl/8c7a57ed052f94b8f8eb32321c34736adfdf6ce7/contrib/kernel-install/91-sbctl.install -O /usr/lib/kernel/install.d/91-sbctl.install
    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        sbctl create-keys
    fi
	emerge sys-boot/shim

    emerge dev-util/ccache dev-vcs/git sys-fs/btrfs-progs sys-fs/xfsprogs sys-fs/e2fsprogs sys-fs/dosfstools sys-fs/ntfs3g sys-block/io-scheduler-udev-rules sys-fs/mdadm
    emerge sys-apps/systemd

    if [[ "$LUKSED" == "y" ]]; then
        LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
        ROOT_DEV="/dev/mapper/root"
    else
        ROOT_DEV="$ROOT_PART"
    fi

    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
    SWAP_UUID=$(findmnt -no UUID -T /swap/swap.img)
    SWAP_OFFSET=$(btrfs inspect-internal map-swapfile -r /swap/swap.img)

    mkdir -p /etc/kernel
    mkdir -p /etc/dracut.conf.d
    CMDLINE="root=UUID=$ROOT_UUID resume=UUID=$SWAP_UUID resume_offset=$SWAP_OFFSET quiet rw splash"
    
    if [[ "$LUKSED" == "y" ]]; then
    	CMDLINE+=" rd.luks.uuid=$LUKS_UUID"
    fi
    
    echo "$CMDLINE" > /etc/kernel/cmdline

    cat > /etc/dracut.conf.d/uki.conf <<EOF
uefi="yes"
hostonly="yes"
use_systemd="yes"
add_dracutmodules+=" btrfs $( [[ "$LUKSED" == "y" ]] && echo "crypt" ) resume "
EOF

    echo "[*] [CHROOT] Installazione Kernel (Generazione UKI)"
    KERNEL_PKG=$([[ "$BINHOST" == "y" ]] && echo "sys-kernel/gentoo-kernel-bin" || echo "sys-kernel/gentoo-kernel")
    emerge "$KERNEL_PKG"
    emerge sys-kernel/linux-firmware sys-firmware/sof-firmware
    [[ "$INTEL_CPU_MICROCODE" == "y" ]] && emerge sys-firmware/intel-microcode
    
    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        mkdir -p /boot/EFI/gentoo
        sbctl enroll-keys -m
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
    systemctl enable chronyd.service NetworkManager
    plymouth-set-default-theme "$PLYMOUTH_THEME_SET"

    echo "[*] [CHROOT] GRUB configuration"
    if [[ "$LUKSED" == "y" ]]; then
        echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
    fi
    sed -i 's/#GRUB_GFXPAYLOAD_LINUX=/GRUB_GFXPAYLOAD_LINUX=keep/' /etc/default/grub

    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=gentoo --boot-directory=/boot --shim /usr/share/shim/shimx64.efi --lockdown
        sbctl sign -s /boot/EFI/gentoo/grubx64.efi
        sbctl sign -s /boot/EFI/gentoo/shimx64.efi
        sbctl sign -s /boot/EFI/gentoo/MokManager.efi
        find /boot/EFI/Linux -name "*.efi" -exec sbctl sign -s {} \;
    else
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=gentoo --boot-directory=/boot
    fi

    if [[ "$BINHOST" == "y" ]]; then
        emerge --config sys-kernel/gentoo-kernel-bin
    else
        emerge --config sys-kernel/gentoo-kernel
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

    swapoff /swap/swap.img
    if [[ "$SECUREBOOT_MODSIGN" == "y" ]]; then
        sbctl status
        sbctl verify
        echo "[*] [CHROOT] Check that all files are signed"
        echo "[*] [CHROOT] Use  sbctl sign -s <file>  to sign a file"
    fi
	
    echo "[*] [CHROOT] Done. You can now type 'exit', unmount everything and reboot"
	rm -f /gentoo-install.sh
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

mkfs.fat -F32 "$EFI_PART"

echo "[*] [NO-CHROOT] Creating Linux root partition with remaining disk space"
parted -s "$DISK_INSTALL" mkpart primary 513MiB 100%
parted -s "$DISK_INSTALL" type 2 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709

mkdir -p /mnt/gentoo

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
for subvol in @ @home @log @cache @swap; do btrfs subvolume create "$subvol"; done
cd ~
umount /mnt/gentoo

MOUNT_OPTS="noatime,compress=zstd:3,ssd,discard=async"
ROOT_DEV_MNT=$([[ "$LUKSED" == "y" ]] && echo "/dev/mapper/root" || echo "$ROOT_PART")

mount -o $MOUNT_OPTS,subvol=@ "$ROOT_DEV_MNT" /mnt/gentoo
mkdir -p /mnt/gentoo/{boot,home,var/cache,var/log,swap}
mount -o $MOUNT_OPTS,subvol=@home  "$ROOT_DEV_MNT" /mnt/gentoo/home
mount -o $MOUNT_OPTS,subvol=@log   "$ROOT_DEV_MNT" /mnt/gentoo/var/log
mount -o $MOUNT_OPTS,subvol=@cache "$ROOT_DEV_MNT" /mnt/gentoo/var/cache
mount -o noatime,subvol=@swap      "$ROOT_DEV_MNT" /mnt/gentoo/swap

mount "$EFI_PART" /mnt/gentoo/boot

echo "[*] [NO-CHROOT] Creating swap file"
truncate -s 0 /mnt/gentoo/swap/swap.img
chattr +C /mnt/gentoo/swap/swap.img
btrfs property set /mnt/gentoo/swap/ compression none
fallocate -l "$SWAP_G" /mnt/gentoo/swap/swap.img
chmod 0600 /mnt/gentoo/swap/swap.img
mkswap /mnt/gentoo/swap/swap.img
swapon /mnt/gentoo/swap/swap.img

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
cd ~
cp "$0" /mnt/gentoo/gentoo-install.sh
chmod +x /mnt/gentoo/gentoo-install.sh
chroot /mnt/gentoo /bin/bash /gentoo-install.sh --chroot
