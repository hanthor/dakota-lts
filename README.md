# dakota-lts

A [bootc](https://bootc.dev) image combining the **Dakota GNOME OS userspace** with the
**AlmaLinux 10 LTS kernel** (Linux 6.12, signed with AlmaLinux's Secure Boot key).

## What this is

[Dakota](https://github.com/projectbluefin/dakota) is a GNOME OS derivative built from
source via BuildStream. Its kernel is custom-compiled and carries no trusted Secure Boot
signature. This project replaces only the kernel with AlmaLinux 10's, giving you:

- **Full GNOME OS userspace** — unchanged from Dakota
- **Linux 6.12 LTS kernel** — AlmaLinux's RHEL-compatible build, maintained through 2026+
- **Trusted Secure Boot chain** — `MS CA → AlmaLinux shim → GRUB → kernel` works on
  any UEFI system with Secure Boot enabled, no key enrollment required

## Image

```
ghcr.io/hanthor/dakota-lts:latest
```

Tags:
- `latest` — most recent build
- `<kernel-version>` — e.g. `6.12.0-124.55.3.el10_1.x86_64`
- `<git-sha>` — exact commit

## Quick start

```bash
# Install to a disk (replace /dev/sdX)
sudo bootc install to-disk --bootloader grub /dev/sdX

# Or pull and inspect locally
podman pull ghcr.io/hanthor/dakota-lts:latest
podman run --rm ghcr.io/hanthor/dakota-lts:latest uname -r
```

## Local build & test

```bash
# Build (production — no SSH)
just build

# Build with SSH enabled for the current user (debug only)
just build-debug

# Generate a bootable raw disk image
just generate-bootable-image

# Boot in QEMU
just boot-vm

# Check kernel baked into the image
just kernel-info
```

## How it works

The `Containerfile` is a two-stage build:

1. **`alma` stage** — pulls `quay.io/almalinuxorg/almalinux-bootc:10`, installs the
   kernel and bootupd payload (shim + GRUB EFI files)
2. **`dakota` stage** — starts from `ghcr.io/projectbluefin/dakota:latest`, removes its
   source-built kernel, and drops in the AlmaLinux kernel + bootupd chain

The kernel version is detected dynamically so daily CI rebuilds automatically track
AlmaLinux kernel updates.

## Secure Boot

The boot chain on a UEFI system is:

```
Firmware → AlmaLinux shim (MS-trusted) → GRUB (AlmaLinux-signed) → kernel (AlmaLinux-signed)
```

No custom key enrollment is required.

## CI

Builds run daily at 15:00 UTC (two hours after Dakota's scheduled build, ensuring the
latest Dakota base is always available) and publish to GHCR with `packages: write`.
