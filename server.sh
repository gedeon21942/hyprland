#!/bin/bash
#
# Minimal Arch Linux Server Setup Script (with GRUB)
# WARNING: THIS WILL ERASE THE TARGET DISK!
# Run as root from an Arch ISO live environment.

set -e

# List disks and prompt for target
lsblk
read -rp "Enter target disk (e.g., /dev/sda): " DISK
read -rp "Enter hostname: " HOSTNAME
read -rp "Enter username: " USER
read -rsp "Enter user password: " USER_PASS; echo
read -rsp "Enter root password: " ROOT_PASS; echo

# Partition, format, and mount (UEFI only)
sgdisk -Z "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
sgdisk -n 2:0:0 -t 2:8300 "$DISK"
mkfs.fat -F32 "${DISK}1"
mkfs.ext4 "${DISK}2"
mount "${DISK}2" /mnt
mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot

# Install base system
pacstrap /mnt base linux linux-firmware sudo vim networkmanager openssh grub efibootmgr

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

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
systemctl enable sshd

# Install GRUB for UEFI
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

# If you want BIOS/MBR support as well, uncomment the next line:
# grub-install --target=i386-pc "$DISK"

grub-mkconfig -o /boot/grub/grub.cfg

EOF

echo "Installation complete! You can reboot now."