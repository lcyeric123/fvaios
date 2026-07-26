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

VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "1.0.0")
ISO_NAME="fvaios-${VERSION}-x86_64.iso"
GITHUB_TOKEN="${GITHUB_TOKEN:-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}"
GITHUB_REPO="lcyeric123/fvaios"
USE_RELEASE=false
for arg in "$@"; do [ "$arg" = "--release" ] && USE_RELEASE=true; done

chroot_run() {
    cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true
    chroot "$ROOTFS" /bin/sh -c "$1"
}

download_rootfs() {
    mkdir -p "$BUILD_DIR"
    [ -f "$BUILD_DIR/$MINIROOTFS_TAR" ] && log_info "Minirootfs cached" && return
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
}

install_ollama() {
    log_info "Installing ollama..."
    chroot_run 'curl -fsSL https://ollama.com/install.sh | sh' || log_warn "Ollama install skipped"
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

create_squashfs() {
    log_info "Creating squashfs..."
    mkdir -p "$BUILD_DIR/live"
    mksquashfs "$ROOTFS" "$BUILD_DIR/live/rootfs.squashfs" \
        -comp xz -b 1M -noappend -quiet
    log_info "Squashfs: $(du -h "$BUILD_DIR/live/rootfs.squashfs" | cut -f1)"
}

create_iso() {
    log_info "Creating ISO with Alpine-style structure..."

    local ISO_DIR="$BUILD_DIR/iso"
    rm -rf "$ISO_DIR"

    # Create Alpine-style directory structure
    mkdir -p "$ISO_DIR/boot/grub"
    mkdir -p "$ISO_DIR/apks/x86_64"
    mkdir -p "$ISO_DIR/media/fvaios"

    # Find kernel and initramfs
    local KERNEL=$(ls "$ROOTFS/boot/vmlinuz-"* 2>/dev/null | head -1)
    local INITRD=$(ls "$ROOTFS/boot/initramfs-"* 2>/dev/null | head -1)

    [ -z "$KERNEL" ] && die "No kernel found"
    cp "$KERNEL" "$ISO_DIR/boot/vmlinuz"
    [ -n "$INITRD" ] && cp "$INITRD" "$ISO_DIR/boot/initramfs"

    # Copy squashfs to media directory (Alpine looks here)
    cp "$BUILD_DIR/live/rootfs.squashfs" "$ISO_DIR/media/fvaios/"

    # Create .boot_repository file (REQUIRED by Alpine init)
    touch "$ISO_DIR/apks/.boot_repository"

    # Create .alpine-release
    echo "${ALPINE_VER}.1" > "$ISO_DIR/.alpine-release"

    # GRUB config - use Alpine's boot parameters
    cat > "$ISO_DIR/boot/grub/grub.cfg" << 'EOF'
set default=0
set timeout=5
set gfxmode=auto
insmod all_video

menuentry "FVAIOS Live" {
    linux /boot/vmlinuz modprobe.blacklist=pcspkr,snd_pcsp quiet
    initrd /boot/initramfs
}

menuentry "FVAIOS Live - Debug" {
    linux /boot/vmlinuz modprobe.blacklist=pcspkr,snd_pcsp debug
    initrd /boot/initramfs
}

menuentry "FVAIOS Live - Text Mode" {
    linux /boot/vmlinuz modprobe.blacklist=pcspkr,snd_pcsp console=ttyS0,115200
    initrd /boot/initramfs
}
EOF

    # Use grub-mkrescue
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
    [ "$USE_RELEASE" = false ] && return

    log_info "Creating GitHub release v${VERSION}..."

    local RELEASE_JSON=$(curl -s -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        https://api.github.com/repos/$GITHUB_REPO/releases \
        -d "{\"tag_name\":\"v${VERSION}\",\"name\":\"FVAIOS v${VERSION}\"}")

    local RELEASE_ID=$(echo "$RELEASE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

    [ -z "$RELEASE_ID" ] && log_warn "Failed to create release" && return

    log_info "Uploading ISO..."
    curl -s -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$BUILD_DIR/$ISO_NAME" \
        "https://uploads.github.com/repos/$GITHUB_REPO/releases/$RELEASE_ID/assets?name=$ISO_NAME" > /dev/null

    log_info "Release: https://github.com/$GITHUB_REPO/releases/tag/v${VERSION}"
}

main() {
    log_info "========== FVAIOS Build v${VERSION} =========="
    download_rootfs
    setup_rootfs
    install_packages
    install_ollama
    configure_system
    copy_overlay
    create_squashfs
    create_iso
    log_info "========== BUILD COMPLETE =========="
    create_github_release
}

main "$@"
