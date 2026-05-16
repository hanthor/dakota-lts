[group('info')]
default:
    @just --list

# ── Configuration ─────────────────────────────────────────────────────
export image_name := env("BUILD_IMAGE_NAME", "dakota-lts")
export image_tag  := env("BUILD_IMAGE_TAG", "latest")

export vm_ram  := env("VM_RAM", "8192")
export vm_cpus := env("VM_CPUS", "4")

# ── Build ─────────────────────────────────────────────────────────────
# Build without SSH (production default)
[group('build')]
build:
    podman build --pull=newer -t "{{image_name}}:{{image_tag}}" .

# Build with sshd enabled, authorized for the current user's key — debug only
[group('build')]
build-debug:
    #!/usr/bin/env bash
    set -euo pipefail
    PUBKEY=$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null || true)
    if [ -z "$PUBKEY" ]; then
        echo "ERROR: No SSH public key found in ~/.ssh/" >&2; exit 1
    fi
    podman build --pull=newer \
        --build-arg "SSH_PUBKEY=${PUBKEY}" \
        -t "{{image_name}}:{{image_tag}}" .

# ── Lint ─────────────────────────────────────────────────────────────
[group('test')]
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    SUDO_CMD=""; [ "$(id -u)" -ne 0 ] && SUDO_CMD="sudo"
    $SUDO_CMD podman run --rm --privileged --pull=never \
        "{{image_name}}:{{image_tag}}" bootc container lint

# ── Inspect kernel in built image ─────────────────────────────────────
[group('info')]
kernel-info:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Kernel modules ==="
    podman run --rm --pull=never "{{image_name}}:{{image_tag}}" ls /usr/lib/modules/
    echo "=== UKI ==="
    podman run --rm --pull=never "{{image_name}}:{{image_tag}}" \
        find /usr/lib/bootc/boot/efi/EFI/Linux /usr/lib/modules -name "*.efi" 2>/dev/null || true
    echo "=== os-release kernel version ==="
    podman run --rm --pull=never "{{image_name}}:{{image_tag}}" \
        grep KERNEL_VERSION /usr/lib/os-release || true

# ── bcvk (fast VM testing) ───────────────────────────────────────────
_ensure-bcvk:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v bcvk &>/dev/null; then exit 0; fi
    echo "bcvk not found. Attempting to install via cargo..."
    if command -v cargo &>/dev/null; then
        cargo install --locked --git https://github.com/bootc-dev/bcvk bcvk
    else
        echo "ERROR: bcvk not installed and cargo unavailable." >&2
        echo "  Fedora 42+: sudo dnf install bcvk" >&2
        exit 1
    fi

# Boot the built image instantly in an ephemeral VM via bcvk.
[group('test')]
boot-fast: _ensure-bcvk
    #!/usr/bin/env bash
    set -euo pipefail
    SUDO_CMD=""; [ "$(id -u)" -ne 0 ] && SUDO_CMD="sudo"
    if ! $SUDO_CMD podman image exists "{{image_name}}:{{image_tag}}"; then
        echo "ERROR: Image not found. Run 'just build' first." >&2
        exit 1
    fi
    echo "==> Booting {{image_name}}:{{image_tag}} in ephemeral VM (bcvk)..."
    echo "    RAM: {{vm_ram}}M, CPUs: {{vm_cpus}}"
    $SUDO_CMD bcvk ephemeral run-ssh \
        --memory "{{vm_ram}}M" \
        --vcpus "{{vm_cpus}}" \
        "localhost/{{image_name}}:{{image_tag}}"

# ── Generate bootable disk image ─────────────────────────────────────
[group('test')]
generate-bootable-image:
    #!/usr/bin/env bash
    set -euo pipefail
    SUDO_CMD=""; [ "$(id -u)" -ne 0 ] && SUDO_CMD="sudo"
    if ! $SUDO_CMD podman image exists "{{image_name}}:{{image_tag}}"; then
        echo "ERROR: Image not found. Run 'just build' first." >&2
        exit 1
    fi
    if [ ! -e bootable.raw ]; then
        echo "==> Creating 30G sparse disk image..."
        fallocate -l 30G bootable.raw
    fi
    echo "==> Installing OS to disk image via bootc..."
    $SUDO_CMD podman run --rm --privileged --pid=host \
        -v /var/lib/containers:/var/lib/containers \
        -v "$(pwd):/data" \
        --security-opt label=type:unconfined_t \
        localhost/{{image_name}}:{{image_tag}} \
        bootc install to-disk \
            --via-loopback /data/bootable.raw \
            --wipe \
            --filesystem ext4 \
            --bootloader grub2 \
            --composefs-backend \
            --karg console=ttyS0 \
            --karg systemd.firstboot=no
    echo "==> Done: bootable.raw"

# ── Boot VM ──────────────────────────────────────────────────────────
[group('test')]
boot-vm:
    #!/usr/bin/env bash
    set -euo pipefail
    DISK=$(realpath bootable.raw)
    [ -e "$DISK" ] || { echo "ERROR: Run 'just generate-bootable-image' first." >&2; exit 1; }

    OVMF_CODE=""
    for f in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd \
              /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd; do
        [ -f "$f" ] && OVMF_CODE="$f" && break
    done
    [ -z "$OVMF_CODE" ] && { echo "ERROR: OVMF not found. Install edk2-ovmf." >&2; exit 1; }

    OVMF_VARS=".ovmf-vars.fd"
    if [ ! -e "$OVMF_VARS" ]; then
        for f in /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd \
                 /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd; do
            [ -f "$f" ] && cp "$f" "$OVMF_VARS" && break
        done
    fi

    echo "==> Booting ${DISK} in QEMU (UEFI/KVM)..."
    qemu-system-x86_64 \
        -enable-kvm \
        -m "{{vm_ram}}" \
        -cpu host \
        -smp "{{vm_cpus}}" \
        -drive file="${DISK}",format=raw,if=virtio \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -device virtio-vga \
        -display gtk \
        -device virtio-keyboard \
        -device virtio-mouse \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
        -serial stdio

# ── Clean ─────────────────────────────────────────────────────────────
[group('build')]
clean:
    rm -f bootable.raw .ovmf-vars.fd
