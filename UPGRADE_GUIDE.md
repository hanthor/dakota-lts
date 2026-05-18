# Upgrading from Dakota to Dakota-LTS

This guide explains how to upgrade an existing Dakota or Bluefin installation to dakota-lts, which variants support bootc switch, and the limitations of each.

## Quick Answer

| Scenario | Variant | Command | Notes |
|----------|---------|---------|-------|
| **Already using systemd-boot** | `:sdboot` | `sudo bootc switch ghcr.io/hanthor/dakota-lts:sdboot` | ✅ Seamless upgrade |
| **Already using GRUB** | Not supported | ❌ Fresh install required | Use Fedora → :latest or :uki |
| **Want Secure Boot** | `:uki` | Fresh install only | No bootc switch (needs UEFI + new ESP) |
| **Unsure / Conservative** | `:latest` | Fresh install recommended | Most compatible, works everywhere |

## Variant Comparison

### :sdboot - Recommended for Bootc Switch

**✅ Advantages**
- Compatible with existing Dakota/Bluefin systemd-boot installations
- Supports `bootc switch` upgrade from running system
- Modern bootloader (systemd-boot)
- Composefs support (when working with kernel 6.10+)
- No Secure Boot enforcement

**❌ Limitations**
- **No Secure Boot**: Uses standard systemd-boot, not signed
- Composefs-native blocked (upstream ostree-prepare-root issue)
- Requires UEFI firmware (BIOS/MBR not supported)
- Not suitable for security-critical deployments requiring SB

**Who should use**
- Users upgrading from Dakota/Bluefin
- Users wanting minimal friction upgrade path
- Developers/enthusiasts unconcerned with Secure Boot
- Systems with UEFI but not enforcing Secure Boot

**Bootc Switch Usage**
```bash
# From any Dakota/Bluefin installation with systemd-boot
sudo bootc switch ghcr.io/hanthor/dakota-lts:sdboot
sudo systemctl reboot
```

---

### :uki - Secure Boot Enforced

**✅ Advantages**
- **Full Secure Boot chain**: MS CA → shim → UKI (all signed)
- No GRUB (simpler, smaller attack surface)
- Fastest boot time (UKI is self-contained)
- AlmaLinux kernel signatures verified at each step
- Suitable for security-hardened deployments

**❌ Limitations**
- **Cannot use bootc switch** (different boot mechanism)
- Requires fresh installation to new disk/partition
- Requires UEFI with Secure Boot capable firmware
- Shim signature depends on AlmaLinux SB cert (revocation risk minimal but exists)
- UKI means kernel options harder to customize (sealed in image)

**Who should use**
- Security-critical deployments (government, finance, healthcare)
- Systems requiring UEFI + Secure Boot enforcement
- Users who want defense-in-depth boot verification
- New installations only (not upgrades)

**Installation Method**
```bash
# Create fisherman recipe (see FISHERMAN.md)
sudo fisherman recipe-uki.json

# Boot with UEFI firmware; Secure Boot chain verified automatically
```

**What happens at boot**
1. UEFI firmware loads shim from `/boot/efi/EFI/BOOT/BOOTX64.EFI`
2. Firmware verifies shim signature against Microsoft CA
3. Shim's system-table override verifies UKI PE image
4. Shim chainloads UKI from `/boot/efi/EFI/Linux/6.12.7-1000.el10.x86_64.efi`
5. Kernel boots with verified chain intact

---

### :latest - Conservative Default

**✅ Advantages**
- GRUB2 + bootupd for maximum compatibility
- Works with existing GRUB installations (with modifications)
- Secure Boot supported via bootupd shim chain
- Broadest hardware compatibility
- Well-tested boot path

**❌ Limitations**
- **Cannot use bootc switch** from non-GRUB systems
- GRUB complexity (larger attack surface)
- Slower boot than UKI
- Bootupd dependency adds management overhead
- Not suitable for minimal/immutable deployments

**Who should use**
- Fresh installations where you want conservative defaults
- Systems currently using GRUB2
- Deployments requiring GRUB features
- Users unconcerned with boot speed

**Installation Method**
```bash
# Requires fresh installation (bootc switch not supported)
sudo fisherman recipe-latest.json
```

**Secure Boot with :latest**
- Supported via bootupd shim chain
- Verified: MS CA → bootupd shim → GRUB → kernel
- More moving parts than :uki approach

---

## Decision Matrix

### I'm running Dakota / Bluefin with systemd-boot

✅ **Use `:sdboot`**
```bash
sudo bootc switch ghcr.io/hanthor/dakota-lts:sdboot
sudo systemctl reboot
```
- Seamless upgrade, no reinstall needed
- Same bootloader, no hardware changes
- Recommended: **Easiest path**

---

### I'm running Fedora / RHEL with GRUB

❌ **bootc switch not supported** (different bootloader)

**Option A: Fresh :latest install** (Conservative)
```bash
# Install dakota-lts:latest to new disk/partition
sudo fisherman recipe-latest.json
```
- Familiar GRUB bootloader
- Secure Boot available (via bootupd)

**Option B: Fresh :uki install** (Modern)
```bash
# Install dakota-lts:uki to new disk/partition
sudo fisherman recipe-uki.json
```
- No GRUB, pure Secure Boot chain
- Faster boot
- Requires UEFI firmware

**Option C: Dual boot**
```bash
# Keep Fedora/RHEL on existing partition
# Install dakota-lts on new partition
# Configure dual-boot in GRUB/UEFI
```

---

### I want maximum security (Secure Boot enforced)

✅ **Use `:uki`**
- Only variant with full Secure Boot chain
- MS CA → shim → UKI (all verified)
- No bootc switch; requires fresh installation
- Requires UEFI firmware with Secure Boot capable

```bash
sudo fisherman recipe-uki.json
# Boot with Secure Boot enabled in firmware
```

---

### I'm setting up a new system

**If starting fresh:**

1. **Easiest**: `:sdboot` - Modern, clean, minimal overhead
2. **Most compatible**: `:latest` - Broadest hardware support
3. **Most secure**: `:uki` - Full Secure Boot chain

**Recommendation**: Start with `:sdboot` unless you have specific GRUB requirements or need Secure Boot enforcement.

---

## Upgrading Between Variants

### From :latest → :sdboot
❌ **Not supported via bootc switch** (different bootloader)
- Requires fresh installation to new disk
- Or: repartition ESP and reinstall

### From :sdboot → :uki
❌ **Not supported via bootc switch** (different boot mechanism)
- Requires fresh installation to new disk
- Or: complete reinstall on existing disk

### From :uki → :sdboot / :latest
❌ **Not supported via bootc switch** (Secure Boot to non-SB)
- Requires disabling Secure Boot and fresh install
- Or: new disk installation

**General rule**: You can only bootc switch between bootloaders if both support the same underlying boot mechanism. `:sdboot` ↔ `:sdboot` works. Switching to/from `:uki` always requires fresh install.

---

## Composefs-Native Support

**Current Status**: ⚠️ Blocked upstream

| Variant | Composefs-Native | Note |
|---------|------------------|------|
| `:latest` | ❌ Not tested | GRUB + composefs not validated |
| `:sdboot` | ❌ Blocked | ostree-prepare-root path mismatch (upstream issue) |
| `:uki` | ❌ Blocked | Same ostree-prepare-root issue |

**Workaround**: Use `composeFsBackend: false` in fisherman recipes. Traditional rootfs works fine.

**Expected timeline**: When upstream ostree fixes the `/sysroot/ostree/repo` vs `/composefs/images/` path handling, composefs-native will be fully supported with all variants.

---

## Secure Boot Enforcement

### Checking if Secure Boot is enabled
```bash
# Check current state
mokutil --sb-state

# If enrolled, shows: "SecureBoot enabled"
# If not enrolled, shows: "SecureBoot disabled"
```

### Enabling Secure Boot
1. Reboot and enter firmware (DEL, F2, F12, etc.)
2. Find "Secure Boot" setting
3. Set to "Enabled"
4. Save and exit

### Which variants support Secure Boot

| Variant | SB Support | Verification Chain |
|---------|-----------|-------------------|
| `:latest` | ✅ Supported | MS CA → bootupd shim → GRUB → kernel |
| `:sdboot` | ❌ None | systemd-boot is unsigned |
| `:uki` | ✅ Full | MS CA → shim → UKI |

**Note**: `:sdboot` is unsigned, so Secure Boot will fail to load it. If you have Secure Boot enforced, use `:uki` or `:latest` instead.

---

## Hardware Requirements

| Feature | Requirement |
|---------|------------|
| All variants | x86-64 CPU with AVX2/BMI2 (AlmaLinux requirement) |
| Boot | UEFI firmware (BIOS/MBR not supported) |
| Secure Boot | UEFI with Secure Boot capable firmware |
| Composefs | Linux 6.10+ kernel with composefs modules |

### CPU Check
```bash
# Verify AVX2/BMI2 support
grep -o 'avx2\|bmi2' /proc/cpuinfo

# Both should be present
```

---

## Troubleshooting

### "bootc switch" fails with permission error
```
Error: permission denied, requires root
```
**Fix**: Use `sudo`
```bash
sudo bootc switch ghcr.io/hanthor/dakota-lts:sdboot
```

### "bootc switch" fails: "mismatched bootloaders"
```
Error: system is using GRUB, cannot switch to systemd-boot
```
**Fix**: Use fresh install instead
```bash
# Install to new disk/partition
sudo fisherman recipe-sdboot.json
```

### Secure Boot prevents :sdboot from booting
```
Error: MOK not enrolled, Secure Boot fails
```
**Fix**: Either disable Secure Boot, or switch to `:uki`/`:latest`
```bash
# Option 1: Disable Secure Boot in firmware
# Option 2: Fresh install of :uki variant
```

### Kernel panic on boot
```
Kernel panic - not syncing: No working init found
```
**Possible causes**:
- CPU doesn't support AVX2 (AlmaLinux requirement)
- Composefs modules not loaded
- Corrupted filesystem

**Fix**:
- Check CPU: `grep avx2 /proc/cpuinfo`
- Check composefs: `modprobe erofs && modprobe overlay`
- Reinstall image

---

## References

- [Bootc Documentation](https://containers.github.io/bootc/)
- [Dakota Project](https://github.com/projectbluefin/dakota)
- [AlmaLinux 10](https://almalinux.org/)
- [UEFI Secure Boot](https://en.wikipedia.org/wiki/Unified_Extensible_Firmware_Interface#Secure_Boot)
- [Fisherman Installer](https://github.com/tuna-os/fisherman)

---

## Summary

**For Dakota/Bluefin users**: Use `:sdboot` with `bootc switch` for seamless upgrade.

**For fresh installs**: Choose based on your needs:
- Want Secure Boot? → `:uki`
- Want conservative defaults? → `:latest`
- Want modern minimal setup? → `:sdboot`

**For security-critical deployments**: Use `:uki` for full Secure Boot chain.

**Cannot bootc switch**:
- Between different bootloaders
- From non-systemd-boot to `:sdboot`
- To/from `:uki` (requires fresh install)

All three variants run the same AlmaLinux 6.12 LTS kernel and Dakota GNOME OS userspace—choose based on your boot requirements.
