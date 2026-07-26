#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR/work"
BUILD_DIR="$SCRIPT_DIR/build"
ROOTFS_OVERLAY="$SCRIPT_DIR/rootfs"
ALPINE_VER="3.19"
MINIROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/releases/x86_64/alpine-minirootfs-${ALPINE_VER}.1-x86_64.tar.gz"
MINIROOTFS_TAR="alpine-minirootfs-${ALPINE_VER}.1-x86_64.tar.gz"
ROOTFS=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
die()       { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Version management
get_version() {
    local ver_file="$SCRIPT_DIR/VERSION"
    if [ -f "$ver_file" ]; then
        cat "$ver_file"
    else
        echo "1.0.0"
    fi
}

bump_version() {
    local ver_file="$SCRIPT_DIR/VERSION"
    local current=$(get_version)
    local major minor patch
    IFS='.' read -r major minor patch <<< "$current"
    patch=$((patch + 1))
    echo "${major}.${minor}.${patch}" > "$ver_file"
    echo "${major}.${minor}.${patch}"
}

VERSION=$(get_version)
ISO_NAME="fvaios-${VERSION}-x86_64.iso"
GITHUB_TOKEN="${GITHUB_TOKEN:-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}"
GITHUB_REPO="lcyeric123/fvaios"

# Check if --release flag is passed
USE_RELEASE=false
for arg in "$@"; do
    [ "$arg" = "--release" ] && USE_RELEASE=true
done

chroot_run() {
    cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true
    chroot "$ROOTFS" /bin/sh -c "$1"
}

download_rootfs() {
    mkdir -p "$BUILD_DIR"
    if [ -f "$BUILD_DIR/$MINIROOTFS_TAR" ]; then
        log_info "Minirootfs cached"
        return
    fi
    log_info "Downloading alpine-minirootfs..."
    wget -q --show-progress -O "$BUILD_DIR/$MINIROOTFS_TAR" "$MINIROOTFS_URL"
}

setup_rootfs() {
    log_info "Extracting rootfs..."
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR/rootfs"
    tar -xzf "$BUILD_DIR/$MINIROOTFS_TAR" -C "$WORK_DIR/rootfs"
    ROOTFS="$WORK_DIR/rootfs"
}

install_packages() {
    log_info "Installing packages..."
    chroot_run '
        echo "https://dl-cdn.alpinelinux.org/alpine/v'${ALPINE_VER}'/main" > /etc/apk/repositories
        echo "https://dl-cdn.alpinelinux.org/alpine/v'${ALPINE_VER}'/community" >> /etc/apk/repositories
        apk update
        apk add \
            sudo shadow openrc busybox-extras \
            curl wget iproute2 nftables \
            openssh-server openssh-client \
            rsync tcpdump \
            vim nano tree \
            tar gzip bzip2 xz zip unzip \
            util-linux lsblk blkid parted \
            htop lsof \
            nginx php81-fpm php81-curl php81-mbstring php81-openssl \
            grub grub-bios efibootmgr dosfstools e2fsprogs \
            mkinitfs linux-lts
    '

    # Configure mkinitfs to include necessary modules
    chroot_run '
        # Ensure mkinitfs includes live boot modules
        sed -i "s|^modules=.*|modules=\"isofs squashfs loop vfat fat ext4 usb-storage sr_mod sd-mod kbd\"|" /etc/mkinitfs/mkinitfs.conf 2>/dev/null || true

        # Regenerate initramfs with proper modules
        KVER=$(ls /boot/vmlinuz-* 2>/dev/null | head -1 | sed "s|/boot/vmlinuz-||")
        if [ -n "$KVER" ]; then
            mkinitfs -c /etc/mkinitfs.conf -b / "$KVER" 2>/dev/null || true
        fi
    '
}

install_ollama() {
    log_info "Installing ollama..."
    chroot_run 'curl -fsSL https://ollama.com/install.sh | sh' || log_warn "Ollama install skipped (non-critical)"
}

configure_system() {
    log_info "Configuring system..."
    chroot_run '
        echo "root:fvaios" | chpasswd
        sed -i "s/#PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config 2>/dev/null || true
        echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers
        adduser -D -s /bin/sh fvaios 2>/dev/null || true
        echo "fvaios:fvaios" | chpasswd
        usermod -aG wheel fvaios 2>/dev/null || true
        echo "fvaios" > /etc/hostname
        echo "UTC" > /etc/timezone
        rc-update add nginx default 2>/dev/null || true
        rc-update add php-fpm81 default 2>/dev/null || true
        rc-update add sshd default 2>/dev/null || true
        rc-update add networking boot 2>/dev/null || true
        apk cache clean 2>/dev/null || true
    '
}

copy_overlay() {
    log_info "Copying rootfs overlay..."
    cp -a "$ROOTFS_OVERLAY"/. "$ROOTFS/"
    chmod +x "$ROOTFS/usr/local/bin/install" 2>/dev/null || true
    ln -sf /usr/local/bin/install "$ROOTFS/usr/bin/install" 2>/dev/null || true
}

generate_initramfs() {
    log_info "Generating initramfs..."
    chroot_run '
        KVER=$(ls /boot/vmlinuz-* 2>/dev/null | head -1 | sed "s|/boot/vmlinuz-||")
        if [ -n "$KVER" ]; then
            mkinitfs -c /etc/mkinitfs.conf -b / "$KVER" 2>/dev/null || true
        fi

        INITRD=$(ls /boot/initramfs-* 2>/dev/null | head -1)
        if [ -z "$INITRD" ]; then
            echo "Creating minimal initramfs..."
            mkdir -p /tmp/ir
            cat > /tmp/ir/init << "INEOF"
#!/bin/sh
export PATH=/sbin:/bin:/usr/sbin:/usr/bin

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp

# Load required kernel modules
modprobe isofs 2>/dev/null || true
modprobe squashfs 2>/dev/null || true
modprobe loop 2>/dev/null || true
modprobe vfat 2>/dev/null || true
modprobe fat 2>/dev/null || true
modprobe ext4 2>/dev/null || true
modprobe usb-storage 2>/dev/null || true
modprobe sr_mod 2>/dev/null || true

# Wait for devices to settle
sleep 2

# Function to find and mount boot media
find_boot_media() {
    # Try CD/DVD first
    for dev in /dev/sr0 /dev/sr1 /dev/cdrom; do
        [ -b "$dev" ] || continue
        echo "Trying $dev..."
        mount -t iso9660 -o ro "$dev" /media 2>/dev/null || continue
        if [ -f /media/FVAIOS/rootfs.squashfs ]; then
            echo "Found boot media on $dev"
            return 0
        fi
        # Check for boot directory structure
        if [ -f /media/boot/vmlinuz ]; then
            echo "Found boot media on $dev"
            return 0
        fi
        umount /media 2>/dev/null
    done

    # Try USB and other block devices
    for dev in /dev/sd[a-z] /dev/sd[a-z][0-9] /dev/nvme[0-9]n[0-9]p[0-9] /dev/mmcblk[0-9]p[0-9]; do
        [ -b "$dev" ] || continue
        echo "Trying $dev..."
        mount -t iso9660 -o ro "$dev" /media 2>/dev/null || continue
        if [ -f /media/FVAIOS/rootfs.squashfs ]; then
            echo "Found boot media on $dev"
            return 0
        fi
        if [ -f /media/boot/vmlinuz ]; then
            echo "Found boot media on $dev"
            return 0
        fi
        umount /media 2>/dev/null
    done

    # Try FAT/exFAT for USB
    for dev in /dev/sd[a-z]1 /dev/sd[a-z]2 /dev/nvme[0-9]n1p1; do
        [ -b "$dev" ] || continue
        echo "Trying $dev (FAT)..."
        mount -t vfat -o ro "$dev" /media 2>/dev/null || continue
        if [ -f /media/FVAIOS/rootfs.squashfs ]; then
            echo "Found boot media on $dev"
            return 0
        fi
        umount /media 2>/dev/null
    done

    return 1
}

# Find boot media
if ! find_boot_media; then
    echo ""
    echo "========================================="
    echo "  ERROR: Boot media not found!"
    echo "========================================="
    echo ""
    echo "Available block devices:"
    ls -la /dev/sd* /dev/nvme* /dev/sr* 2>/dev/null || echo "No devices found"
    echo ""
    echo "Dropping to emergency shell..."
    echo "Type 'exit' to reboot."
    exec /bin/sh
fi

# Check for squashfs
if [ -f /media/FVAIOS/rootfs.squashfs ]; then
    echo "Mounting squashfs rootfs..."
    mkdir -p /live
    mount -t squashfs -o ro,loop /media/FVAIOS/rootfs.squashfs /live
elif [ -f /media/boot/vmlinuz ]; then
    # Direct boot from media (non-squashfs)
    echo "Direct boot mode..."
    mkdir -p /live
    cp -a /media/* /live/ 2>/dev/null || true
fi

# Create overlay for write access
echo "Setting up overlay filesystem..."
mkdir -p /overlay/upper /overlay/work /overlay/lower
mount -t tmpfs tmpfs /overlay

# Use overlayfs if available, otherwise copy
if mount -t overlay overlay -o lowerdir=/live,upperdir=/overlay/upper,workdir=/overlay/work /mnt 2>/dev/null; then
    echo "Overlay mounted successfully"
else
    echo "Overlay not available, copying rootfs..."
    mkdir -p /mnt
    cp -a /live/* /mnt/ 2>/dev/null || true
fi

# Bind mount essential filesystems
echo "Mounting system filesystems..."
mkdir -p /mnt/dev /mnt/proc /mnt/sys /mnt/tmp /mnt/run
mount --bind /dev /mnt/dev
mount --bind /dev/pts /mnt/dev/pts
mount -t proc proc /mnt/proc
mount -t sysfs sysfs /mnt/sys
mount -t tmpfs tmpfs /mnt/tmp

# Copy resolv.conf for networking
cp /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null || true

echo "Switching to root filesystem..."
exec chroot /mnt /bin/sh -l
INEOF
            chmod +x /tmp/ir/init
            cd /tmp/ir
            find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -9 > /boot/initramfs-lts
            cd /
            rm -rf /tmp/ir
        fi
    '
}

create_squashfs() {
    log_info "Creating squashfs..."
    mkdir -p "$BUILD_DIR/live"
    mksquashfs "$ROOTFS" "$BUILD_DIR/live/rootfs.squashfs" \
        -comp xz -b 1M -noappend -quiet
    log_info "Squashfs: $(du -h "$BUILD_DIR/live/rootfs.squashfs" | cut -f1)"
}

create_iso() {
    log_info "Creating ISO with grub-mkrescue..."

    local ISO_DIR="$BUILD_DIR/iso"
    rm -rf "$ISO_DIR"
    mkdir -p "$ISO_DIR/boot/grub"
    mkdir -p "$ISO_DIR/FVAIOS"

    local KERNEL=$(ls "$ROOTFS/boot/vmlinuz-"* 2>/dev/null | head -1)
    local INITRD=$(ls "$ROOTFS/boot/initramfs-"* 2>/dev/null | head -1)

    [ -z "$KERNEL" ] && die "No kernel found"
    cp "$KERNEL" "$ISO_DIR/boot/vmlinuz"
    [ -n "$INITRD" ] && cp "$INITRD" "$ISO_DIR/boot/initramfs"

    cp "$BUILD_DIR/live/rootfs.squashfs" "$ISO_DIR/FVAIOS/"

    cat > "$ISO_DIR/boot/grub/grub.cfg" << 'EOF'
set default=0
set timeout=5
set gfxmode=auto
insmod all_video

menuentry "FVAIOS Live" {
    linux /boot/vmlinuz modprobe.blacklist=pcspkr,snd_pcsp quiet
    initrd /boot/initramfs
}

menuentry "FVAIOS Live - Text Mode" {
    linux /boot/vmlinuz modprobe.blacklist=pcspkr,snd_pcsp console=ttyS0,115200
    initrd /boot/initramfs
}

menuentry "FVAIOS Live - Verbose" {
    linux /boot/vmlinuz modprobe.blacklist=pcspkr,snd_pcsp
    initrd /boot/initramfs
}
EOF

    cd "$BUILD_DIR"
    grub-mkrescue \
        --modules="part_msdos part_gpt iso9660" \
        -o "$BUILD_DIR/$ISO_NAME" \
        "$ISO_DIR" \
        2>&1

    cd "$SCRIPT_DIR"

    log_info "ISO: $BUILD_DIR/$ISO_NAME ($(du -h "$BUILD_DIR/$ISO_NAME" | cut -f1))"
}

create_github_release() {
    if [ "$USE_RELEASE" = false ]; then
        return
    fi

    log_info "Creating GitHub release v${VERSION}..."

    # Create release
    local RELEASE_JSON=$(curl -s -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        https://api.github.com/repos/$GITHUB_REPO/releases \
        -d "{\"tag_name\":\"v${VERSION}\",\"name\":\"FVAIOS v${VERSION}\",\"body\":\"## FVAIOS v${VERSION}\"}")

    local RELEASE_ID=$(echo "$RELEASE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

    if [ -z "$RELEASE_ID" ]; then
        log_warn "Failed to create GitHub release"
        log_warn "Response: $RELEASE_JSON"
        return
    fi

    log_info "Release ID: $RELEASE_ID"

    # Upload ISO
    log_info "Uploading ISO to GitHub release..."
    local UPLOAD_RESULT=$(curl -s -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$BUILD_DIR/$ISO_NAME" \
        "https://uploads.github.com/repos/$GITHUB_REPO/releases/$RELEASE_ID/assets?name=$ISO_NAME")

    local STATE=$(echo "$UPLOAD_RESULT" | grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ "$STATE" = "uploaded" ]; then
        log_info "ISO uploaded successfully!"
        log_info "Release: https://github.com/$GITHUB_REPO/releases/tag/v${VERSION}"
    else
        log_warn "Upload may have failed"
    fi
}

main() {
    log_info "========================================="
    log_info "  FVAIOS Build System v${VERSION}"
    log_info "========================================="

    download_rootfs
    setup_rootfs
    install_packages
    install_ollama
    configure_system
    copy_overlay
    generate_initramfs
    create_squashfs
    create_iso

    log_info ""
    log_info "========================================="
    log_info "  BUILD COMPLETE"
    log_info "  ISO: $BUILD_DIR/$ISO_NAME"
    log_info "========================================="

    create_github_release
}

main "$@"
