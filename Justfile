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

# ── ISO Building (Local) ─────────────────────────────────────────────
[group('iso')]
build-all-images:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Building all 7 images..."

    VARIANTS=(
        "Containerfile:latest"
        "Containerfile.sdboot:sdboot"
        "Containerfile.uki:uki"
        "Containerfile.nvidia:latest-nvidia"
        "Containerfile.sdboot-nvidia:sdboot-nvidia"
        "Containerfile.uki-nvidia:uki-nvidia"
        "Containerfile.installer:installer-latest"
    )

    PUBKEY=$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null || true)

    for variant in "${VARIANTS[@]}"; do
        IFS=: read -r containerfile tag <<< "$variant"
        echo ""
        echo "==> Building dakota-lts:$tag from $containerfile..."
        BUILD_ARGS=""
        if [ -n "$PUBKEY" ]; then
            BUILD_ARGS="--build-arg SSH_PUBKEY=${PUBKEY}"
        fi
        podman build --pull=newer $BUILD_ARGS \
            -f "$containerfile" \
            -t "dakota-lts:$tag" \
            .
    done
    echo ""
    echo "==> All images built successfully"
    podman images | grep dakota-lts

# Install tacklebox if not present
[group('iso')]
_ensure-tacklebox:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v tacklebox &>/dev/null; then
        echo "tacklebox already installed"
        exit 0
    fi
    echo "Installing tacklebox from source..."
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT
    git clone https://github.com/tuna-os/tacklebox.git "$TEMP_DIR"
    cd "$TEMP_DIR"
    meson setup build
    sudo meson install -C build --skip-subprojects
    echo "tacklebox installed successfully"

# Build ISO locally with tacklebox
[group('iso')]
build-iso: _ensure-tacklebox build-all-images
    #!/usr/bin/env bash
    set -euo pipefail

    ISO_DIR="$(pwd)/iso-build"
    mkdir -p "$ISO_DIR"

    echo "==> ISO build directory: $ISO_DIR"
    echo "==> Copying tacklebox recipe..."
    cp tacklebox-recipe.json "$ISO_DIR/"

    cd "$ISO_DIR"

    echo "==> Tagging images for offline store..."
    podman tag dakota-lts:latest localhost/dakota-lts:latest
    podman tag dakota-lts:sdboot localhost/dakota-lts:sdboot
    podman tag dakota-lts:uki localhost/dakota-lts:uki
    podman tag dakota-lts:latest-nvidia localhost/dakota-lts:latest-nvidia
    podman tag dakota-lts:sdboot-nvidia localhost/dakota-lts:sdboot-nvidia
    podman tag dakota-lts:uki-nvidia localhost/dakota-lts:uki-nvidia

    # Update recipe to use local images
    sed -i 's|ghcr.io/hanthor/dakota-lts:|localhost/dakota-lts:|g' tacklebox-recipe.json

    echo "==> Building ISO with tacklebox..."
    echo "    (This will take 10-20 minutes - deduplicating and compressing images)"
    sudo tacklebox build tacklebox-recipe.json \
        --iso "dakota-lts-installer-$(date -u +%Y%m%d).iso" \
        -v

    echo ""
    echo "==> ISO build complete!"
    ls -lh *.iso

# Test ISO in QEMU
[group('iso')]
boot-iso:
    #!/usr/bin/env bash
    set -euo pipefail

    ISO_FILE=$(ls -1 iso-build/*.iso 2>/dev/null | head -1)
    if [ -z "$ISO_FILE" ]; then
        echo "ERROR: No ISO found. Run 'just build-iso' first." >&2
        exit 1
    fi

    echo "==> Found ISO: $ISO_FILE"
    echo "==> Booting from ISO (UEFI/Secure Boot)..."
    echo ""
    echo "Boot instructions:"
    echo "  1. Select variant from the installer menu"
    echo "  2. Select target disk (optional: create test disk with 'just create-test-disk')"
    echo "  3. Choose LUKS encryption (yes/no)"
    echo "  4. Enter hostname"
    echo "  5. Confirm and install"
    echo ""

    OVMF_CODE=""
    for f in /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd /usr/share/edk2/ovmf/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd; do
        [ -f "$f" ] && OVMF_CODE="$f" && break
    done
    [ -z "$OVMF_CODE" ] && { echo "ERROR: OVMF not found. Install edk2-ovmf." >&2; exit 1; }

    OVMF_VARS="/tmp/.ovmf-iso-vars.fd"
    for f in /usr/share/edk2/ovmf/OVMF_VARS.secboot.fd /usr/share/edk2/ovmf/OVMF_VARS.fd \
             /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd; do
        [ -f "$f" ] && cp "$f" "$OVMF_VARS" && break
    done

    qemu-system-x86_64 \
        -enable-kvm \
        -m {{vm_ram}} \
        -cpu host \
        -smp {{vm_cpus}} \
        -cdrom "$ISO_FILE" \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -device virtio-vga \
        -display gtk \
        -device virtio-keyboard \
        -device virtio-mouse \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0 \
        -serial stdio

# Create test disk for ISO installation
[group('iso')]
create-test-disk:
    #!/usr/bin/env bash
    set -euo pipefail
    DISK="iso-test-disk.raw"
    if [ -e "$DISK" ]; then
        echo "Test disk already exists: $DISK"
        exit 0
    fi
    echo "Creating 30GB sparse test disk..."
    fallocate -l 30G "$DISK"
    echo "Created: $DISK"
    echo "To use with ISO installer:"
    echo "  1. Boot ISO: just boot-iso"
    echo "  2. In installer menu, select /dev/vda as target disk"
    echo "  3. Installation will proceed to vda"

# ── Clean ─────────────────────────────────────────────────────────────
[group('build')]
clean:
    rm -f bootable.raw .ovmf-vars.fd
    rm -rf iso-build
    rm -f iso-test-disk.raw /tmp/.ovmf-iso-vars.fd

[group('build')]
clean-all: clean
    podman rmi -f dakota-lts:* 2>/dev/null || true
    echo "Cleaned all images and build artifacts"
