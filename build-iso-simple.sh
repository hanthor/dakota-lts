#!/bin/bash
set -euo pipefail

echo "=== Creating Dakota-LTS Boot ISO ==="

WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT
mkdir -p iso-build

# Extract UKI boot files (as non-root user)
echo "→ Preparing boot files..."
podman run --rm -v "$WORK:/work" localhost/dakota-lts:uki bash << 'EXTRACT'
cp -v /usr/lib/bootc/boot/efi/EFI/BOOT/BOOTX64.EFI /work/ 2>&1 | tail -1
for efi in /usr/lib/bootc/boot/efi/EFI/Linux/*.efi; do
  cp -v "$efi" /work/kernel.efi 2>&1 | tail -1
done
EXTRACT

# Create minimal ISO directory
mkdir -p "$WORK"/{EFI/BOOT,EFI/Linux,boot}
[ -f "$WORK/BOOTX64.EFI" ] && cp "$WORK/BOOTX64.EFI" "$WORK/EFI/BOOT/"
[ -f "$WORK/kernel.efi" ] && cp "$WORK/kernel.efi" "$WORK/EFI/Linux/"

# Create README
cat > "$WORK/README.txt" << 'README'
Dakota-LTS Bootable Installer
For testing and installation of bootc images
README

# Build ISO
ISO="iso-build/dakota-lts-installer-$(date +%Y%m%d-%H%M).iso"
echo "→ Building ISO: $ISO"

mkisofs -R -J -V "Dakota-LTS" \
  -o "$ISO" "$WORK" 2>&1 | grep -E "Extent|Output"

echo ""
ls -lh "$ISO"
echo "✅ ISO created successfully"
