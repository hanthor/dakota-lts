#!/bin/bash
# Dakota-LTS Interactive Installer
set -euo pipefail

VARIANTS=(
  "latest"        "Dakota LTS - GRUB + Secure Boot (most compatible)"
  "sdboot"        "Dakota LTS - systemd-boot (bootc switch compatible)"
  "uki"           "Dakota LTS - shim→UKI (full Secure Boot, no GRUB)"
  "latest-nvidia" "Dakota LTS + NVIDIA - GRUB + Secure Boot"
  "sdboot-nvidia" "Dakota LTS + NVIDIA - systemd-boot"
  "uki-nvidia"    "Dakota LTS + NVIDIA - shim→UKI Secure Boot"
)

REGISTRY="ghcr.io/hanthor/dakota-lts"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() {
  echo -e "${RED}Error: $*${NC}" >&2
  exit 1
}

info() {
  echo -e "${GREEN}→${NC} $*"
}

warn() {
  echo -e "${YELLOW}!${NC} $*"
}

# Check prerequisites
check_prereqs() {
  command -v whiptail >/dev/null || error "whiptail not found"
  command -v fisherman >/dev/null || error "fisherman not found"
  command -v lsblk >/dev/null || error "lsblk not found"
  command -v bootc >/dev/null || error "bootc not found (running on non-bootc system?)"
}

# Menu: select variant
select_variant() {
  local choice
  choice=$(whiptail --title "Dakota-LTS Installer" --menu "Choose variant:" 18 70 6 "${VARIANTS[@]}" 3>&1 1>&2 2>&3)
  echo "$choice"
}

# Menu: select target disk
select_disk() {
  local disks=()
  local descriptions=()

  # Get all block devices (excluding loop, zram, etc.)
  while IFS= read -r line; do
    if [[ "$line" =~ ^/dev/(nvme|sda|sdb|vda|vdb) ]]; then
      local size=$(lsblk -dn -o SIZE "$line" 2>/dev/null | head -1)
      disks+=("$line" "$size")
    fi
  done < <(lsblk -dn -o NAME | grep -E "^(nvme|sda|sdb|vda|vdb)")

  if [ ${#disks[@]} -eq 0 ]; then
    error "No suitable block devices found. Cannot proceed."
  fi

  local choice
  choice=$(whiptail --title "Select Target Disk" --menu "WARNING: This will ERASE the selected disk!\n\nChoose installation target:" 15 70 10 "${disks[@]}" 3>&1 1>&2 2>&3)

  if [ -z "$choice" ]; then
    error "No disk selected"
  fi

  # Confirm
  if ! whiptail --title "Confirm" --yesno "Install to $choice?\nAll data will be erased!" 10 60; then
    error "Installation cancelled"
  fi

  echo "$choice"
}

# Menu: LUKS encryption
select_luks() {
  if whiptail --title "Encryption" --yesno "Enable LUKS disk encryption?" 10 60; then
    echo "yes"
  else
    echo "no"
  fi
}

# Get LUKS passphrase
get_passphrase() {
  local pass1 pass2
  while true; do
    pass1=$(whiptail --title "Set LUKS Passphrase" --passwordbox "Enter passphrase:" 10 60 3>&1 1>&2 2>&3)
    pass2=$(whiptail --title "Confirm Passphrase" --passwordbox "Confirm passphrase:" 10 60 3>&1 1>&2 2>&3)

    if [ "$pass1" = "$pass2" ]; then
      echo "$pass1"
      return 0
    else
      whiptail --title "Error" --msgbox "Passphrases do not match. Try again." 10 60
    fi
  done
}

# Get hostname
get_hostname() {
  local hostname
  hostname=$(whiptail --title "Hostname" --inputbox "Enter hostname:" 10 60 "dakota-lts" 3>&1 1>&2 2>&3)
  [ -n "$hostname" ] || hostname="dakota-lts"
  echo "$hostname"
}

# Create fisherman recipe
create_recipe() {
  local variant=$1
  local disk=$2
  local luks=$3
  local passphrase=$4
  local hostname=$5
  local recipe_file="/tmp/dakota-install-recipe.json"

  cat > "$recipe_file" << EOF
{
  "disk": "$disk",
  "filesystem": "xfs",
  "bootloader": "systemd",
  "image": "$REGISTRY:$variant",
  "hostname": "$hostname",
  "encryption": {
EOF

  if [ "$luks" = "yes" ]; then
    cat >> "$recipe_file" << EOF
    "type": "luks-passphrase",
    "passphrase": "$passphrase"
EOF
  else
    cat >> "$recipe_file" << EOF
    "type": "none"
EOF
  fi

  cat >> "$recipe_file" << EOF
  }
}
EOF

  echo "$recipe_file"
}

# Run installation
run_install() {
  local recipe=$1
  local disk=$2

  info "Starting installation..."
  info "Recipe: $recipe"

  # Use fisherman to install
  sudo fisherman "$recipe" || error "Fisherman installation failed"

  info "Installation complete!"

  # Reboot prompt
  if whiptail --title "Success" --yesno "Installation successful!\n\nReboot now?" 10 60; then
    info "Rebooting..."
    sudo systemctl reboot
  else
    warn "Remember to reboot to boot into the installed system"
  fi
}

# Main flow
main() {
  info "Dakota-LTS Installer"

  check_prereqs

  echo ""
  info "Detecting available disks..."

  local variant
  variant=$(select_variant)
  info "Selected variant: $variant"

  local disk
  disk=$(select_disk)
  info "Target disk: $disk"

  local luks
  luks=$(select_luks)
  if [ "$luks" = "yes" ]; then
    info "LUKS encryption enabled"
    local passphrase
    passphrase=$(get_passphrase)
  else
    info "No encryption"
    passphrase=""
  fi

  local hostname
  hostname=$(get_hostname)
  info "Hostname: $hostname"

  echo ""
  whiptail --title "Ready to Install" --msgbox "\
Variant: $variant
Target: $disk
Encryption: $luks
Hostname: $hostname

Installation will begin. This may take 10-20 minutes." 12 70

  local recipe
  recipe=$(create_recipe "$variant" "$disk" "$luks" "$passphrase" "$hostname")

  run_install "$recipe" "$disk"
}

# Trap errors
trap 'error "Installation failed"' ERR

# Run
main "$@"
