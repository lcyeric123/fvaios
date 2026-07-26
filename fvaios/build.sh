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
        cat > /etc/mkinitfs/mkinitfs.conf << MKINITFS_CONF
modules="isofs squashfs loop vfat fat ext4 usb-storage uas sd_mod sr_mod usbcore ehci-hcd xhci-hcd ohci-hcd scsi_mod libata ahci kbd"
quiet=""
MKINITFS_CONF

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

    # First, generate Alpine's initramfs with all needed modules
    chroot_run '
        KVER=$(ls /boot/vmlinuz-* 2>/dev/null | head -1 | sed "s|/boot/vmlinuz-||")
        if [ -n "$KVER" ]; then
            mkinitfs -c /etc/mkinitfs.conf -b / "$KVER" 2>/dev/null || true
        fi
    '

    # Now create a custom init script to replace Alpine's default
    # Alpine's default init looks for apkovl files which we don't have
    mkdir -p "$WORK_DIR/initrd_tmp"

    cat > "$WORK_DIR/initrd_tmp/init" << 'CUSTOM_INIT'
#!/bin/sh
# FVAIOS Live Init Script v7

export PATH=/sbin:/bin:/usr/sbin:/usr/bin

/bin/busybox mkdir -p /proc /sys /dev /tmp /run /media /sysroot
/bin/busybox --install -s

mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mount -t tmpfs tmpfs /dev
mount -t proc proc /proc
mount -t devpts devpts /dev/pts
[ -c /dev/null ] || mknod -m 666 /dev/null c 1 3

echo "Loading drivers..."
for mod in usb-storage uas sd_mod sr_mod scsi_mod libata ahci usbcore ehci-hcd xhci-hcd ohci-hcd isofs squashfs loop vfat fat; do
    modprobe $mod 2>/dev/null
done

echo "/sbin/mdev" > /proc/sys/kernel/hotplug 2>/dev/null
mdev -s 2>/dev/null
sleep 3
mdev -s 2>/dev/null
sleep 2

echo "=== /proc/partitions ==="
cat /proc/partitions
echo "========================"

BOOT_MEDIA=""
SQUASH_PATH=""

echo "Scanning for FVAIOS..."

for dev in /dev/sd[a-z]; do
    [ -b "$dev" ] || continue
    echo "  Testing $dev..."
    mkdir -p /media/check

    for offset in 0 2048 4096 8192 16384 32768 65536; do
        if mount -t iso9660 -o ro,loop,offset=$offset "$dev" /media/check 2>/dev/null; then
            for p in FVAIOS/rootfs.squashfs fvaios/rootfs.squashfs FVAIOS/ROOTFS.SQUASHFS; do
                if [ -f "/media/check/$p" ]; then
                    BOOT_MEDIA="/media/check"
                    SQUASH_PATH="/media/check/$p"
                    echo "  FOUND: $dev (iso9660 offset=$offset path=$p)"
                    break 3
                fi
            done
            umount /media/check 2>/dev/null
        fi
    done

    if mount -t iso9660 -o ro "$dev" /media/check 2>/dev/null; then
        for p in FVAIOS/rootfs.squashfs fvaios/rootfs.squashfs; do
            if [ -f "/media/check/$p" ]; then
                BOOT_MEDIA="/media/check"
                SQUASH_PATH="/media/check/$p"
                echo "  FOUND: $dev (iso9660 path=$p)"
                break 3
            fi
        done
        umount /media/check 2>/dev/null
    fi

    for fstype in vfat ext4; do
        if mount -t "$fstype" -o ro "$dev" /media/check 2>/dev/null; then
            echo "    $fstype mounted, listing contents..."
            ls -la /media/check/ 2>/dev/null
            for p in FVAIOS/rootfs.squashfs fvaios/rootfs.squashfs ROOTFS.SQUASHFS rootfs.squashfs; do
                if [ -f "/media/check/$p" ]; then
                    BOOT_MEDIA="/media/check"
                    SQUASH_PATH="/media/check/$p"
                    echo "  FOUND: $dev ($fstype path=$p)"
                    break 3
                fi
            done
            # Search recursively
            FOUND=$(find /media/check -iname "*squashfs*" 2>/dev/null | head -1)
            if [ -n "$FOUND" ]; then
                BOOT_MEDIA="/media/check"
                SQUASH_PATH="$FOUND"
                echo "  FOUND: $dev ($fstype find=$FOUND)"
                break 3
            fi
            umount /media/check 2>/dev/null
        fi
    done
done

if [ -z "$BOOT_MEDIA" ]; then
    for dev in /dev/sr0 /dev/sr1; do
        [ -b "$dev" ] || continue
        echo "  Testing $dev (CD/DVD)..."
        mkdir -p /media/check
        if mount -t iso9660 -o ro "$dev" /media/check 2>/dev/null; then
            if [ -f /media/check/FVAIOS/rootfs.squashfs ]; then
                BOOT_MEDIA="/media/check"
                SQUASH_PATH="$BOOT_MEDIA/FVAIOS/rootfs.squashfs"
                echo "  FOUND: $dev"
                break
            fi
            umount /media/check 2>/dev/null
        fi
    done
fi

if [ -z "$SQUASH_PATH" ]; then
    echo ""
    echo "ERROR: FVAIOS rootfs not found!"
    echo "Kernel: $(cat /proc/cmdline)"
    echo ""
    exec /bin/sh
fi

echo "Mounting $SQUASH_PATH..."
mkdir -p /live
mount -t squashfs -o ro,loop "$SQUASH_PATH" /live

if [ ! -d /live/bin ]; then
    echo "ERROR: Failed to mount squashfs"
    exec /bin/sh
fi

echo "Copying rootfs to RAM..."
mkdir -p /sysroot
cp -a /live/* /sysroot/ 2>/dev/null

mkdir -p /sysroot/dev /sysroot/proc /sysroot/sys /sysroot/tmp
mount --bind /dev /sysroot/dev
mount --bind /dev/pts /sysroot/dev/pts
mount -t proc proc /sysroot/proc
mount -t sysfs sysfs /sysroot/sys
mount -t tmpfs tmpfs /sysroot/tmp
cp /etc/resolv.conf /sysroot/etc/resolv.conf 2>/dev/null

echo "FVAIOS ready!"
exec chroot /sysroot /bin/sh -l
CUSTOM_INIT

    chmod +x "$WORK_DIR/initrd_tmp/init"

    # Now rebuild initramfs with our custom init
    INITRD=$(ls "$ROOTFS/boot/initramfs-"* 2>/dev/null | head -1)
    if [ -n "$INITRD" ]; then
        log_info "Rebuilding initramfs with custom init..."

        # Extract existing initramfs
        mkdir -p "$WORK_DIR/initrd_extract"
        cd "$WORK_DIR/initrd_extract"
        zcat "$INITRD" | cpio -id 2>/dev/null

        # Replace init script
        cp "$WORK_DIR/initrd_tmp/init" ./init
        chmod +x ./init

        # Repack initramfs
        find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -9 > "$INITRD"

        cd "$SCRIPT_DIR"
        rm -rf "$WORK_DIR/initrd_extract" "$WORK_DIR/initrd_tmp"

        log_info "Initramfs rebuilt with custom init"
    else
        log_warn "No initramfs found, using Alpine default"
    fi
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

menuentry "FVAIOS Live - Debug" {
    linux /boot/vmlinuz modprobe.blacklist=pcspkr,snd_pcsp debug
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
