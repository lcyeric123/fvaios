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
# FVAIOS Live Init Script v3

export PATH=/sbin:/bin:/usr/sbin:/usr/bin

# Mount essential filesystems
/bin/busybox mkdir -p /proc /sys /dev /tmp /run /media /sysroot
/bin/busybox --install -s

mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mount -t tmpfs tmpfs /dev
mount -t proc proc /proc
mount -t devpts devpts /dev/pts

[ -c /dev/null ] || mknod -m 666 /dev/null c 1 3
[ -c /dev/kmsg ] || mknod -m 660 /dev/kmsg c 1 11

# Load ALL USB and storage related modules
echo "Loading storage drivers..."
for mod in \
    usb-storage uas \
    sd_mod sr_mod \
    ahci libata \
    scsi_mod \
    vfat fat \
    isofs \
    loop \
    squashfs \
    ext4 \
    usbcore \
    ehci-hcd \
    xhci-hcd \
    ohci-hcd \
    usbhid; do
    modprobe $mod 2>/dev/null
done

# Wait longer for USB devices to enumerate
echo "Waiting for USB devices..."
sleep 5

# Trigger udev/mdev to create device nodes
echo "/sbin/mdev" > /proc/sys/kernel/hotplug 2>/dev/null
mdev -s 2>/dev/null

# Wait a bit more
sleep 2

echo "=== Block devices found ==="
ls -la /dev/sd* /dev/sr* /dev/nvme* /dev/loop* 2>/dev/null
echo "==========================="

# The key insight: when booting from USB, the USB device IS the boot media
# We need to find it and extract rootfs.squashfs from it

BOOT_MEDIA=""

# Strategy 1: Try all /dev/sd* devices (USB drives)
echo "Strategy 1: Scanning /dev/sd* devices..."
for dev in /dev/sda /dev/sdb /dev/sdc /dev/sdd; do
    [ -b "$dev" ] || continue
    
    # Skip the root device
    ROOT_DEV=$(cat /proc/mounts | grep " / " | head -1 | cut -d' ' -f1)
    case "$ROOT_DEV" in
        /dev/loop*) ;;  # OK to check sd devices
        "$dev") continue ;;  # Skip if this is root
    esac
    
    echo "  Checking $dev..."
    mkdir -p /media/check
    
    # Try mounting as ISO9660
    if mount -t iso9660 -o ro "$dev" /media/check 2>/dev/null; then
        if [ -f /media/check/FVAIOS/rootfs.squashfs ]; then
            BOOT_MEDIA="/media/check"
            echo "  FOUND on $dev (ISO9660)"
            break
        fi
        umount /media/check 2>/dev/null
    fi
    
    # Try partitions
    for part in 1 2 3 4; do
        [ -b "${dev}${part}" ] || continue
        echo "  Checking ${dev}${part}..."
        
        if mount -t iso9660 -o ro "${dev}${part}" /media/check 2>/dev/null; then
            if [ -f /media/check/FVAIOS/rootfs.squashfs ]; then
                BOOT_MEDIA="/media/check"
                echo "  FOUND on ${dev}${part} (ISO9660)"
                break 2
            fi
            umount /media/check 2>/dev/null
        fi
        
        if mount -t vfat -o ro "${dev}${part}" /media/check 2>/dev/null; then
            if [ -f /media/check/FVAIOS/rootfs.squashfs ]; then
                BOOT_MEDIA="/media/check"
                echo "  FOUND on ${dev}${part} (FAT)"
                break 2
            fi
            umount /media/check 2>/dev/null
        fi
    done
done

# Strategy 2: Try CD/DVD
if [ -z "$BOOT_MEDIA" ]; then
    echo "Strategy 2: Scanning CD/DVD devices..."
    for dev in /dev/sr0 /dev/sr1; do
        [ -b "$dev" ] || continue
        echo "  Checking $dev..."
        mkdir -p /media/check
        if mount -t iso9660 -o ro "$dev" /media/check 2>/dev/null; then
            if [ -f /media/check/FVAIOS/rootfs.squashfs ]; then
                BOOT_MEDIA="/media/check"
                echo "  FOUND on $dev (CD/DVD)"
                break
            fi
            umount /media/check 2>/dev/null
        fi
    done
fi

# Strategy 3: Check if squashfs is embedded in the boot device using losetup
if [ -z "$BOOT_MEDIA" ]; then
    echo "Strategy 3: Trying losetup to find embedded ISO..."
    # Find the device we booted from
    BOOT_DEV=""
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            Boot=*) BOOT_DEV="${arg#Boot=}" ;;
        esac
    done
    
    if [ -z "$BOOT_DEV" ] || [ ! -b "$BOOT_DEV" ]; then
        # Try to guess from GRUB
        # The boot device is usually the first USB/sd device
        for dev in /dev/sda /dev/sdb /dev/sdc; do
            [ -b "$dev" ] || continue
            BOOT_DEV="$dev"
            break
        done
    fi
    
    if [ -n "$BOOT_DEV" ] && [ -b "$BOOT_DEV" ]; then
        echo "  Boot device: $BOOT_DEV"
        
        # Try to find the squashfs directly on the raw device
        # When ISO is dd'd to USB, the squashfs is at a specific offset
        echo "  Searching for squashfs signature on $BOOT_DEV..."
        
        # Look for the squashfs magic bytes (hsqs or shsq)
        SQUASH_OFFSET=$(dd if="$BOOT_DEV" bs=1 count=4 2>/dev/null | od -A n -t x1 | head -1)
        
        # Try mounting the whole device as different filesystems
        mkdir -p /media/check
        for fstype in iso9660 vfat ext4; do
            if mount -t "$fstype" -o ro "$BOOT_DEV" /media/check 2>/dev/null; then
                if [ -f /media/check/FVAIOS/rootfs.squashfs ] || [ -f /media/check/boot/vmlinuz ]; then
                    BOOT_MEDIA="/media/check"
                    echo "  FOUND on $BOOT_DEV ($fstype)"
                    break
                fi
                umount /media/check 2>/dev/null
            fi
        done
    fi
fi

# Strategy 4: Look for squashfs anywhere
if [ -z "$BOOT_MEDIA" ]; then
    echo "Strategy 4: Searching all devices for rootfs.squashfs..."
    for dev in /dev/sd* /dev/sr*; do
        [ -b "$dev" ] || continue
        ROOT_DEV=$(cat /proc/mounts | grep " / " | head -1 | cut -d' ' -f1)
        [ "$dev" = "$ROOT_DEV" ] && continue
        
        mkdir -p /media/check
        if mount -o ro "$dev" /media/check 2>/dev/null; then
            if [ -f /media/check/FVAIOS/rootfs.squashfs ]; then
                BOOT_MEDIA="/media/check"
                echo "  FOUND on $dev"
                break
            fi
            umount /media/check 2>/dev/null
        fi
    done
fi

# Final check
if [ -z "$BOOT_MEDIA" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  ERROR: FVAIOS boot media not found!                ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
    echo "Debug info:"
    echo "  Kernel command line: $(cat /proc/cmdline)"
    echo "  Mounted filesystems:"
    cat /proc/mounts
    echo ""
    echo "  Available devices:"
    ls -la /dev/ 2>/dev/null
    echo ""
    exec /bin/sh
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FVAIOS rootfs found!                               ║"
echo "╚══════════════════════════════════════════════════════╝"

# Mount squashfs
echo "Mounting squashfs rootfs..."
mkdir -p /live
mount -t squashfs -o ro,loop "$BOOT_MEDIA/FVAIOS/rootfs.squashfs" /live

if [ ! -d /live/bin ]; then
    echo "ERROR: Failed to mount rootfs"
    exec /bin/sh
fi

# Setup overlay for write access
echo "Setting up overlay filesystem..."
mkdir -p /overlay/upper /overlay/work
mount -t tmpfs tmpfs /overlay

if mount -t overlay overlay -o lowerdir=/live,upperdir=/overlay/upper,workdir=/overlay/work /sysroot 2>/dev/null; then
    echo "Overlay mounted"
else
    echo "Copying rootfs to RAM..."
    mkdir -p /sysroot
    cp -a /live/* /sysroot/ 2>/dev/null
fi

# Mount system filesystems
echo "Preparing system..."
mkdir -p /sysroot/dev /sysroot/proc /sysroot/sys /sysroot/tmp /sysroot/run
mount --bind /dev /sysroot/dev
mount --bind /dev/pts /sysroot/dev/pts
mount -t proc proc /sysroot/proc
mount -t sysfs sysfs /sysroot/sys
mount -t tmpfs tmpfs /sysroot/tmp

# Copy DNS
cp /etc/resolv.conf /sysroot/etc/resolv.conf 2>/dev/null

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FVAIOS Live System Ready                           ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# Switch to new root
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
