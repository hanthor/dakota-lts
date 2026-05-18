# Installing Dakota-LTS with Fisherman

This guide shows how to use [fisherman](https://github.com/tuna-os/fisherman) to install dakota-lts bootc images to disk or loopback devices.

## Prerequisites

- Fisherman installed: `git clone https://github.com/tuna-os/fisherman.git && cd fisherman && sudo meson setup build && sudo meson install -C build`
- `bootc` CLI (for host-based installs) or just `podman` (for containerized installs)
- Root or passwordless sudo access

## Basic Installation to Loopback Device

Create an install recipe for a 20GB loopback device:

```json
{
  "disk": "/dev/loop13",
  "filesystem": "xfs",
  "composeFsBackend": false,
  "bootloader": "systemd",
  "image": "ghcr.io/hanthor/dakota-lts:sdboot",
  "hostname": "dakota-lts",
  "encryption": {
    "type": "none"
  }
}
```

Save as `recipe-sdboot.json` and install:

```bash
# Create the backing file
fallocate -l 20G /var/home/user/dakota-lts-sdboot.raw
sudo losetup /dev/loop13 /var/home/user/dakota-lts-sdboot.raw

# Install via fisherman
sudo fisherman recipe-sdboot.json

# Detach the loop device (optional; leave attached for VM testing)
sudo losetup -d /dev/loop13
```

## Installation to Bare Metal / VM Disk

For direct disk installation, specify the actual block device:

```json
{
  "disk": "/dev/sda",
  "filesystem": "xfs",
  "bootloader": "systemd",
  "image": "ghcr.io/hanthor/dakota-lts:sdboot",
  "hostname": "dakota-lts-prod"
}
```

**WARNING**: This will partition and erase the disk. Ensure you've selected the correct device.

```bash
sudo fisherman recipe-prod.json
```

## UKI Variant with Secure Boot

The `:uki` variant uses shim→UKI chain for full Secure Boot support:

```json
{
  "disk": "/dev/loop14",
  "filesystem": "xfs",
  "bootloader": "systemd",
  "image": "ghcr.io/hanthor/dakota-lts:uki",
  "hostname": "dakota-lts-uki",
  "encryption": {"type": "none"}
}
```

When installed with the `:uki` variant:
- UEFI boots shim from `/boot/efi/EFI/BOOT/BOOTX64.EFI`
- Shim verifies and chainloads the signed UKI from `/boot/efi/EFI/Linux/`
- Full Secure Boot verification chain: MS CA → shim → UKI

Test in libvirt:

```bash
sudo virt-install \
  --name dakota-uki-test \
  --disk /dev/loop14 \
  --memory 4096 \
  --vcpus 4 \
  --os-variant fedora39 \
  --boot uefi \
  --graphics none \
  --import \
  --noreboot
```

## Verifying Installation

After installation, verify the system:

```bash
# Check kernel version (should be AlmaLinux 6.12 LTS)
uname -r

# Check bootc status
bootc status

# Verify bootc image
bootc status --json | jq .status.booted
```

## Encrypted Root Filesystem

For LUKS-encrypted installations:

```json
{
  "disk": "/dev/loop15",
  "filesystem": "xfs",
  "bootloader": "systemd",
  "image": "ghcr.io/hanthor/dakota-lts:sdboot",
  "encryption": {
    "type": "luks-passphrase",
    "passphrase": "secure-passphrase-here"
  }
}
```

## Using Composefs-Native Backend

Composefs reduces image size and improves startup time for composefs-native images:

```json
{
  "disk": "/dev/loop16",
  "filesystem": "xfs",
  "composeFsBackend": true,
  "bootloader": "systemd",
  "image": "ghcr.io/hanthor/dakota-lts:sdboot"
}
```

Note: Composefs-native currently requires kernel 6.10+ with composefs support. AlmaLinux 6.12 LTS includes this.

## Bootc Switch from Existing Installation

To upgrade a running Dakota/Bluefin system to dakota-lts:

```bash
# From a running Fedora 40+ / Bluefin system
sudo bootc switch ghcr.io/hanthor/dakota-lts:sdboot

# Reboot to apply
sudo systemctl reboot
```

The `:sdboot` variant is compatible with `bootc switch` from existing systemd-boot installs (Dakota, Bluefin, etc.). The `:latest` and `:uki` variants are for fresh installations.

## CI/CD Integration

For automated installations in CI:

```bash
# Generate recipe from template
envsubst < recipe-template.json > recipe-generated.json

# Install
sudo fisherman recipe-generated.json

# Verify
sudo bootc status --json | jq -e '.status.booted.image.imageId' > /dev/null
echo "Installation verified"
```

## Troubleshooting

### SELinux Context Errors
Fisherman includes an SELinux bypass shim for cross-distro installations (e.g., AlmaLinux on Fedora). If you see SELinux xattr errors, ensure you're running as root and the target filesystem is mounted with selinux disabled or permissive.

### Composefs Errors
If composefs-native fails to mount, verify:
- Kernel supports composefs: `modprobe erofs && modprobe overlay`
- Image was built with composefs support (bootc's 51bootc dracut module)
- Root filesystem has composefs capability

### Bootc Container Execution
Fisherman can run bootc via container (`podman run ... bootc`) or directly on the host. If container execution fails, ensure `podman` is installed and the container image is available locally or remotely accessible.

## References

- [Fisherman Documentation](https://github.com/tuna-os/fisherman)
- [Bootc Documentation](https://containers.github.io/bootc/)
- [Dakota Project](https://github.com/projectbluefin/dakota)
- [AlmaLinux 10 Bootc](https://github.com/AlmaLinux/almalinux-bootc)
