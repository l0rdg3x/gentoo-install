# Gentoo Installation Script

An installation script for Gentoo Linux with systemd support, featuring LUKS encryption, Btrfs filesystem, and Plymouth boot splash.
Desktop use only. (Read TODO)

---

**Warning**: This script performs destructive operations on your disk. Always backup important data before running the installation script. Test in a virtual machine first if you're unsure about the process.

**Warning**: This script require some interactions and pre configurations.

## Features

- **Semi-Automated Installation**: Streamlined Gentoo installation process
- **LUKS Encryption**: Optional full disk encryption support
- **Btrfs Filesystem**: Modern filesystem with subvolumes for better organization and snapshot
- **Plymouth Boot Splash**: Customizable boot splash screen
- **Systemd Support**: Only systemd profiles supported (OpenRC support planned)
- **Binary Packages**: Utilizes Gentoo's binary package repository for faster installation (Read TODO)
- **Hardware Support**: Supports both NVMe and SATA SSD drives

## Prerequisites

- Boot from Gentoo LiveCD or minimal installation ISO
- AMD64 architecture (x86_64)
- Internet connection
- Basic knowledge of disk partitioning and Linux systems

## Installation Steps

### 1. Prepare the Script

Boot from the Gentoo LiveCD or minimal installation ISO, copy the script to your system and do all as root user:

```bash
# Copy the script to /root/gentoo-install.sh
cp gentoo-install.sh /root/gentoo-install.sh

# Make it executable
chmod +x /root/gentoo-install.sh
```

#### Key Configuration Options

Read che CONFIG part of the script for more info

- **HOSTNAME**: Set your system hostname
- **TIMEZONE_SET**: Configure your timezone (e.g., "Europe/Rome")
- **LOCALE_GEN_SET**: Set your locale preferences
- **LUKSED**: Enable/disable LUKS encryption ("y" or "n")
- **DEV_INSTALL**: Choose drive type ("nvme" or "ssd")
- **DISK_INSTALL**: Specify the target disk device
- **SWAP_G**: Set swap file size (e.g., "16G")
- **USER_NAME**: Create a non-root user account
- **ESELECT_PROF**: Choose your Gentoo profile
- **PLYMOUTH_THEME_SET**: Select Plymouth theme

### 2. Configure the Script

Edit the script to customize your installation. Look for sections marked with `#CHANGE`:

```bash
nano /root/gentoo-install.sh
```



### 3. Run the Installation

Start the installation process:

```bash
/root/gentoo-install.sh
```

The script will:
- Partition and format your disk
- Set up LUKS encryption (if enabled)
- Create Btrfs subvolumes
- Download and extract the stage3 tarball
- Enter chroot environment automatically

### 4. Complete the Chroot Installation

When the first part completes and you're in the chroot environment, run:

```bash
./gentoo-install.sh --chroot
```

This will:
- Synchronize Portage
- Configure the system profile
- Install the kernel and essential packages
- Set up GRUB bootloader
- Configure users and passwords
- Enable essential services

### 5. Finalize Installation

After the chroot phase completes:

```bash
exit
swapoff /mnt/gentoo/swap/swap.img
umount -R /mnt/gentoo
reboot
```

## Filesystem Layout

The script creates the following Btrfs subvolumes:

- `@`: Root filesystem
- `@home`: User home directories
- `@log`: System logs (`/var/log`)
- `@cache`: Package cache (`/var/cache`)
- `@swap`: Swap file location

## Disk Partitioning

The script creates a GPT partition table with:

- **Partition 1**: 1GiB EFI System Partition (FAT32)
- **Partition 2**: Remaining space for Linux root (Btrfs)

## Security Features

- **LUKS Encryption**: Full disk encryption with AES-256
- **User Security**: Non-root user with sudo access

## Customization

### Make.conf Configuration

The script includes a basic `make.conf` with:
- Native CPU optimizations
- Parallel compilation settings
- Binary package support
- Distribution kernel USE flag

### Package Selection

Default packages include:
- `gentoo-kernel-bin`: Pre-compiled kernel
- `systemd`: System and service manager
- `plymouth`: Boot splash screen
- `btrfs-progs`: Btrfs utilities
- Essential filesystem tools

### Common Issues

1. **Script Fails**: Check disk device paths in configuration
2. **LUKS Password**: Ensure strong password for encryption
3. **Network Issues**: Verify internet connection before starting
4. **Partition Errors**: Make sure target disk is unmounted

## Supported Hardware

- **CPU**: AMD64 (x86_64) architecture only
- **Storage**: NVMe and SATA SSDs
- **Graphics**: Configurable via VIDEO_CARDS in make.conf
- **Network**: Automatic DHCP configuration

## Post-Installation

After successful installation and reboot:

1. Connect to internet: the packages net-wireless/iw net-wireless/wpa_supplicant net-misc/dhcpcd are already installed: https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Networking
2. Update the system: `emerge --update --deep --newuse @world`
3. Install additional software as needed
4. Configure desktop environment (if desktop profile selected)
5. Set up additional users and services

## TODO

### More important (not in order)

- [ ] Option for setup full source based (ignoring binhost)
- [ ] Option for server use or desktop use (different stage3)
- [ ] Implement Secureboot
- [ ] Implement precheck before installation starts
- [ ] Binhost: Select for packages "x86-64" or "x86-64-v3"

### Less important (not in order)

- [ ] Modules and kernel signing
- [ ] Add OpenRC profile support
- [ ] Implement multi-architecture support (ARM64)
- [ ] Implement RAID configuration support
- [ ] Implement custom kernel configuration (Maybe)

## Contributing

Contributions and forks are welcome! Please feel free to submit pull requests or open issues for:

- Bug fixes
- Feature enhancements
- Documentation improvements
- Hardware compatibility updates
