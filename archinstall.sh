#!/bin/bash
#
# Hyprland Arch Linux Automated Installation Script
#
# WARNING: THIS SCRIPT WILL WIPE THE TARGET DISK. USE WITH CAUTION.
# ----------------------------------------------------------------------

# --- 1. CONFIGURATION VARIABLES ---
# These are the variables you MUST adjust before running the script.
# ----------------------------------------------------------------------

# Target Disk (e.g., /dev/sda, /dev/nvme0n1). BE CAREFUL!
DISK="/dev/sda"

# System Details
read -rp "Enter hostname: " HOSTNAME
read -rp "Enter username: " USER_NAME
read -rsp "Enter user password: " USER_PASS; echo
read -rsp "Enter root password: " ROOT_PASS; echo
TIME_ZONE="America/New_York" # Example: Europe/London, Asia/Tokyo

# Partition Sizes (in MiB for parted or percentages, but we'll use fdisk defaults)
# We assume a simple setup: /dev/diskN1 (EFI), /dev/diskN2 (SWAP), /dev/diskN3 (ROOT)

# List of essential packages for the desktop environment
ESSENTIAL_PACKAGES=(
    hyprland polkit-gnome xdg-desktop-portal-hyprland # Hyprland and necessary XDG components
    waybar wofi kitty feh                            # Bar, Launcher, Terminal, Wallpaper setter
    ttf-jetbrains-mono-nerd noto-fonts               # Fonts
    networkmanager                                   # Networking
    vim git sudo openssh                             # Utilities
    mesa                                             # Graphics drivers (basic for Intel/AMD)
)

# Graphics Driver Detection (adjust based on your hardware)
if lspci | grep -i "nvidia"; then
    echo "Nvidia detected. Adding nvidia-dkms and required utilities."
    ESSENTIAL_PACKAGES+=(nvidia-dkms nvidia-utils)
elif lspci | grep -i "amd"; then
    echo "AMD detected. Adding vulkan-radeon."
    ESSENTIAL_PACKAGES+=(vulkan-radeon)
elif lspci | grep -i "intel"; then
    echo "Intel detected. Adding vulkan-intel."
    ESSENTIAL_PACKAGES+=(vulkan-intel)
else
    echo "Graphics hardware uncertain. Installing basic Mesa drivers."
fi

# ----------------------------------------------------------------------
# --- 2. PRE-FLIGHT CHECKS ---
# ----------------------------------------------------------------------

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root."
   exit 1
fi

# List available disks and prompt user to select one
echo "Available disks:"
lsblk -d -e 7,11 -o NAME,SIZE,MODEL
echo ""
read -rp "Enter the device name to install to (e.g., sda, nvme0n1): " disk_choice
DISK="/dev/$disk_choice"

# Check if target disk is valid
if [[ ! -b "$DISK" ]]; then
    echo "Error: Disk $DISK not found or is not a block device."
    echo "Please edit the DISK variable in the script and try again."
    exit 1
fi

echo "--- Configuration Summary ---"
echo "Target Disk: $DISK (WARNING: ALL DATA WILL BE WIPED)"
echo "Hostname: $HOSTNAME"
echo "User: $USER_NAME"
echo "Packages: ${ESSENTIAL_PACKAGES[*]}"
echo "Timezone: $TIME_ZONE"
read -r -p "Do you want to proceed with the installation? (yes/No): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Installation cancelled by user."
    exit 0
fi

# ----------------------------------------------------------------------
# --- 3. DISK PREPARATION (Phase 1) ---
# ----------------------------------------------------------------------

echo "--- Partitioning $DISK ---"
# Clear existing partition table and create new partitions:
# 1. EFI partition (512M) - type 1
# 2. Linux swap (4GB) - type 19
# 3. Linux root (rest) - type 20
echo "Wiping existing partition table on $DISK..."
dd if=/dev/zero of="$DISK" bs=512 count=1 conv=notrunc &>/dev/null

echo "Creating new partitions..."
# Uses fdisk commands via a heredoc to automate partitioning
printf "g\nn\n1\n\n+512M\nt\n1\n\nn\n2\n\n+4G\nt\n2\n19\nn\n3\n\n\nt\n3\n20\nw\n" | fdisk "$DISK"

# Determine partition names (handle /dev/sda vs /dev/nvme0n1)
if [[ "$DISK" =~ "nvme" ]]; then
    EFI_PART="${DISK}p1"
    SWAP_PART="${DISK}p2"
    ROOT_PART="${DISK}p3"
else
    EFI_PART="${DISK}1"
    SWAP_PART="${DISK}2"
    ROOT_PART="${DISK}3"
fi

echo "Partitions created:"
echo "EFI: $EFI_PART | SWAP: $SWAP_PART | ROOT: $ROOT_PART"

echo "--- Formatting Partitions ---"
mkfs.fat -F32 "$EFI_PART"
mkswap "$SWAP_PART"
swapon "$SWAP_PART"
mkfs.ext4 -F "$ROOT_PART"

echo "--- Mounting Filesystems ---"
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

# ----------------------------------------------------------------------
# --- 4. BASE SYSTEM INSTALLATION (Phase 1) ---
# ----------------------------------------------------------------------

echo "--- Installing base packages and kernel ---"
pacstrap /mnt base linux linux-firmware $ESSENTIAL_PACKAGES

echo "--- Generating fstab ---"
genfstab -U /mnt >> /mnt/etc/fstab

# ----------------------------------------------------------------------
# --- 5. CHROOT CONFIGURATION FUNCTION (Phase 2 Definition) ---
# ----------------------------------------------------------------------
# The function to be executed inside the chroot environment

chroot_config() {
    echo "--- Phase 2: Configuring system inside chroot ---"

    # Timezone and Locale
    ln -sf "/usr/share/zoneinfo/$TIME_ZONE" /etc/localtime
    hwclock --systohc

    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf

    # Hostname
    echo "$HOSTNAME" > /etc/hostname
    cat <<EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

    # Root Password
    echo "Setting root password..."
    echo "root:$ROOT_PASS" | chpasswd

    # Bootloader (Systemd-boot)
    echo "--- Installing systemd-boot ---"
    bootctl install

    # Create boot entry for Arch Linux
    cat <<EOF > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img # Uncomment/change if using AMD
initrd  /initramfs-linux.img
options root=PARTUUID=$(blkid -s PARTUUID -o value $ROOT_PART) rw
EOF

    # Add ucode to pacstrap list for initial install if not already there
    # Install intel/amd ucode before making initramfs
    if lspci | grep -i "intel"; then
        pacman -S --noconfirm intel-ucode
        sed -i 's/^initrd/#initrd/' /boot/loader/entries/arch.conf
        sed -i '2iinitrd /intel-ucode.img' /boot/loader/entries/arch.conf
    elif lspci | grep -i "amd"; then
        pacman -S --noconfirm amd-ucode
        sed -i 's/^initrd/#initrd/' /boot/loader/entries/arch.conf
        sed -i '2iinitrd /amd-ucode.img' /boot/loader/entries/arch.conf
    fi

    mkinitcpio -P # Regenerate initramfs after ucode installation

    # Network
    systemctl enable NetworkManager

    # User Setup
    echo "--- Creating user $USER_NAME ---"
    useradd -m -g users -G wheel,video,audio,storage,input,power -s /bin/bash "$USER_NAME"
    echo "$USER_NAME:$USER_PASS" | chpasswd

    # Sudoers configuration (allow wheel group to use sudo)
    echo "Configuring sudoers..."
    echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

    # --- Hyprland Configuration ---
    echo "--- Setting up basic Hyprland config for $USER_NAME ---"
    HYPR_CONFIG_DIR="/home/$USER_NAME/.config/hypr"
    mkdir -p "$HYPR_CONFIG_DIR"
    chown -R "$USER_NAME":users "/home/$USER_NAME/.config"

    # Basic Hyprland configuration (stored directly in the script)
    cat <<EOF > "$HYPR_CONFIG_DIR/hyprland.conf"
# Monitor Setup
monitor=,preferred,auto,1

# Execute on startup
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP # Necessary for some apps
exec-once = systemctl --user import-environment DISPLAY WAYLAND_DISPLAY
exec-once = waybar & # Start the Waybar
exec-once = nm-applet & # Network Manager Applet
exec-once = feh --bg-fill /usr/share/backgrounds/archlinux/arch-stripes.jpg & # Default Arch Wallpaper

# Set programs that you use
\$terminal = kitty
\$menu = wofi --show drun

# Window rules
windowrulev2 = opacity 0.9 0.9,class:^(kitty)$

# General settings
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgb(88c0d0) rgb(81a1c1) 45deg
    col.inactive_border = rgb(3b4252)
    layout = dwindle
}

# Decoration
decoration {
    rounding = 10
    active_opacity = 1.0
    inactive_opacity = 1.0
    blur {
        enabled = true
        size = 3
        passes = 1
        new_optimizations = true
    }
}

# Bindings
bind = SUPER, Q, killactive,
bind = SUPER, M, exit,
bind = SUPER, Return, exec, \$terminal
bind = SUPER, D, exec, \$menu

# Move focus with mainMod + arrow keys
bind = SUPER, left, movefocus, l
bind = SUPER, right, movefocus, r
bind = SUPER, up, movefocus, u
bind = SUPER, down, movefocus, d

# Switch workspaces with mainMod + [0-9]
bind = SUPER, 1, workspace, 1
bind = SUPER, 2, workspace, 2
bind = SUPER, 3, workspace, 3
bind = SUPER, 4, workspace, 4
bind = SUPER, 5, workspace, 5
bind = SUPER, 6, workspace, 6
bind = SUPER, 7, workspace, 7
bind = SUPER, 8, workspace, 8
bind = SUPER, 9, workspace, 9
bind = SUPER, 0, workspace, 10
EOF

    # Basic Waybar configuration (for a functional setup)
    WAYBAR_CONFIG_DIR="/home/$USER_NAME/.config/waybar"
    mkdir -p "$WAYBAR_CONFIG_DIR"
    chown -R "$USER_NAME":users "$WAYBAR_CONFIG_DIR"

    cat <<EOF > "$WAYBAR_CONFIG_DIR/config"
{
    "layer": "top",
    "position": "top",
    "mod": "dock",
    "exclusive": true,
    "passthrough": false,
    "modules-left": ["hyprland/workspaces", "hyprland/window"],
    "modules-center": ["clock"],
    "modules-right": ["network", "pulseaudio", "battery", "backlight", "tray"]
}
EOF

    cat <<EOF > "$WAYBAR_CONFIG_DIR/style.css"
* {
    border: none;
    border-radius: 0;
    font-family: "JetBrains Mono Nerd Font", monospace;
    font-size: 14px;
}

window#waybar {
    background: #2e3440; /* Nord dark background */
    color: #eceff4; /* Nord light text */
}

#workspaces button:hover {
    background: #4c566a; /* Nord grey */
}

#workspaces button.active {
    background-color: #5e81ac; /* Nord blue */
}

#clock, #battery, #cpu, #memory, #disk, #temperature, #network, #pulseaudio, #tray {
    padding: 0 10px;
    margin: 0 5px;
    background-color: #3b4252; /* Nord darker grey */
    border-radius: 8px;
}
EOF

    echo "Finished Phase 2: System and Hyprland configured."
}

# ----------------------------------------------------------------------
# --- 6. EXECUTE CHROOT AND CLEANUP (Phase 1 Conclusion) ---
# ----------------------------------------------------------------------

# Export all necessary variables and the function itself into the chroot environment
export DISK HOSTNAME ROOT_PASS USER_NAME USER_PASS TIME_ZONE ROOT_PART
export -f chroot_config

echo "--- Entering Chroot Environment ---"
# Execute the configuration function inside the new system
arch-chroot /mnt /bin/bash -c "chroot_config"

echo "--- Unmounting and Cleanup ---"
umount -R /mnt
swapoff -a

echo "----------------------------------------------------------------------"
echo "--- INSTALLATION COMPLETE! ---"
echo "----------------------------------------------------------------------"
echo "The system is now installed."
echo "1. Run 'reboot' to restart your machine."
echo "2. Log in with user '$USER_NAME' and password '$USER_PASS'."
echo "3. Run 'Hyprland' to start the compositor."
echo "4. Use Super+Return to open Kitty terminal, and Super+D for Wofi launcher."
echo ""
#echo "!!! REMEMBER TO CHANGE YOUR PASSWORDS IMMEDIATELY !!!"
#echo "Root Password: $ROOT_PASS"
#echo "User Password: $USER_PASS"
#echo "----------------------------------------------------------------------"
