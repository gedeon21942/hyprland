#!/bin/bash
#
# Minimal Arch Linux + Hyprland Setup Script
# WARNING: THIS WILL ERASE THE TARGET DISK!
# Run as root from an Arch ISO live environment.

set -e

# Prompt for disk, hostname, username, and passwords
lsblk
read -rp "Enter target disk (e.g., /dev/sda): " DISK
read -rp "Enter hostname: " HOSTNAME
read -rp "Enter username: " USER
read -rsp "Enter user password: " USER_PASS; echo
read -rsp "Enter root password: " ROOT_PASS; echo

# Partition, format, and mount
sgdisk -Z "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
sgdisk -n 2:0:0 -t 2:8300 "$DISK"
mkfs.fat -F32 "${DISK}1"
mkfs.ext4 "${DISK}2"
mount "${DISK}2" /mnt
mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot

# Install base system
pacstrap /mnt base linux linux-firmware sudo vim networkmanager git

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Get PARTUUID for root partition before chroot
ROOT_PARTUUID=$(blkid -s PARTUUID -o value ${DISK}2)

# Chroot and configure
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "$HOSTNAME" > /etc/hostname
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

echo root:$ROOT_PASS | chpasswd

useradd -m -G wheel "$USER"
echo "$USER:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

systemctl enable NetworkManager

# Install Hyprland and minimal desktop
pacman -S --noconfirm hyprland xorg-xwayland waybar rofi kitty ttf-jetbrains-mono-nerd noto-fonts

# Install systemd-boot (for UEFI)
bootctl install

cat <<BOOT > /boot/loader/loader.conf
default arch
timeout 3
console-mode max
editor no
BOOT

cat <<ARCH > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=$ROOT_PARTUUID rw
ARCH
EOF

echo "Installation complete! You can reboot now."