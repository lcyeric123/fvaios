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
# FVAIOS Live Init Script

export PATH=/sbin:/bin:/usr/sbin:/usr/bin

# Mount essential filesystems
/bin/busybox mkdir -p /proc /sys /dev /tmp /run
/bin/busybox --install -s

mount -t sysfs -o noexec,nosuid,nodev sysfs /sys
mount -t devtmpfs -o exec,nosuid,mode=0755 devtmpfs /dev 2>/dev/null \
    || mount -t tmpfs -o exec,nosuid,mode=0755 tmpfs /dev
mount -t proc -o noexec,nosuid,nodev proc /proc
mount -t devpts -o gid=5,mode=0620 devpts /dev/pts
mount -t tmpfs -o nodev,nosuid,noexec shm /dev/shm

# Create necessary device nodes
[ -c /dev/null ] || mknod -m 666 /dev/null c 1 3
[ -c /dev/kmsg ] || mknod -m 660 /dev/kmsg c 1 11
[ -c /dev/ptmx ] || mknod -m 666 /dev/ptmx c 5 2
[ -d /dev/pts ] || mkdir -m 755 /dev/pts

# Load required kernel modules
echo "Loading kernel modules..."
for mod in isofs squashfs loop vfat fat ext4 usb-storage sr_mod sd_mod ahci uas; do
    modprobe $mod 2>/dev/null
done

# Wait for devices to settle
echo "Waiting for devices..."
sleep 3

# Detect which device we booted from (the initramfs came from there)
BOOT_DEV=""
for cmdline_dev in $(cat /proc/cmdline | tr ' ' '\n' | grep -E "^Boot=" | cut -d= -f2); do
    BOOT_DEV="$cmdline_dev"
    break
done

# If not in cmdline, try to find it from /proc/mounts
if [ -z "$BOOT_DEV" ]; then
    BOOT_DEV=$(cat /proc/mounts | head -1 | awk '{print $1}')
fi

echo "Boot device detected: $BOOT_DEV"

# Find boot media containing FVAIOS
echo "Searching for FVAIOS rootfs..."
BOOT_MEDIA=""

# Function to check if a path contains FVAIOS
check_fvaios() {
    local path="$1"
    if [ -f "$path/FVAIOS/rootfs.squashfs" ]; then
        return 0
    fi
    return 1
}

# First, try the device we booted from
if [ -n "$BOOT_DEV" ] && [ -b "$BOOT_DEV" ]; then
    echo "Checking boot device $BOOT_DEV..."
    mkdir -p /media

    # Try different filesystem types on the boot device itself
    for fstype in iso9660 vfat ext4; do
        if mount -t "$fstype" -o ro "$BOOT_DEV" /media 2>/dev/null; then
            if check_fvaios /media; then
                BOOT_MEDIA="/media"
                echo "Found FVAIOS on boot device $BOOT_DEV ($fstype)"
                break
            fi
            umount /media 2>/dev/null
        fi
    done
fi

# Try all block devices if not found yet
if [ -z "$BOOT_MEDIA" ]; then
    for dev in $(ls /dev/sd* /dev/nvme* 2>/dev/null); do
        [ -b "$dev" ] || continue
        [ "$dev" = "$BOOT_DEV" ] && continue

        echo "Checking $dev..."
        mkdir -p /media

        for fstype in iso9660 vfat ext4; do
            if mount -t "$fstype" -o ro "$dev" /media 2>/dev/null; then
                if check_fvaios /media; then
                    BOOT_MEDIA="/media"
                    echo "Found FVAIOS on $dev ($fstype)"
                    break 2
                fi
                umount /media 2>/dev/null
            fi
        done

        # Also try partitions
        for part in 1 2 3 4; do
            [ -b "${dev}${part}" ] || continue
            echo "  Checking ${dev}${part}..."
            for fstype in iso9660 vfat ext4; do
                if mount -t "$fstype" -o ro "${dev}${part}" /media 2>/dev/null; then
                    if check_fvaios /media; then
                        BOOT_MEDIA="/media"
                        echo "Found FVAIOS on ${dev}${part} ($fstype)"
                        break 3
                    fi
                    umount /media 2>/dev/null
                fi
            done
        done
    done
fi

# Try CD/DVD as last resort
if [ -z "$BOOT_MEDIA" ]; then
    for dev in /dev/sr0 /dev/sr1; do
        [ -b "$dev" ] || continue
        echo "Checking $dev (CD/DVD)..."
        mkdir -p /media
        if mount -t iso9660 -o ro "$dev" /media 2>/dev/null; then
            if check_fvaios /media; then
                BOOT_MEDIA="/media"
                echo "Found FVAIOS on $dev"
                break
            fi
            umount /media 2>/dev/null
        fi
    done
fi

if [ -z "$BOOT_MEDIA" ]; then
    echo ""
    echo "============================================"
    echo "  ERROR: FVAIOS rootfs not found!"
    echo "============================================"
    echo ""
    echo "Available block devices:"
    cat /proc/partitions
    echo ""
    echo "Mount points:"
    cat /proc/mounts
    echo ""
    echo "Dropping to emergency shell..."
    exec /bin/sh
fi

# Mount the rootfs
echo ""
echo "Mounting FVAIOS root filesystem..."
mkdir -p /live

mount -t squashfs -o ro,loop "$BOOT_MEDIA/FVAIOS/rootfs.squashfs" /live

# Create overlay for write access
echo "Setting up overlay..."
mkdir -p /overlay/upper /overlay/work
mount -t tmpfs tmpfs /overlay

if mount -t overlay overlay -o lowerdir=/live,upperdir=/overlay/upper,workdir=/overlay/work /mnt 2>/dev/null; then
    echo "Overlay mounted"
else
    echo "Overlay failed, copying rootfs..."
    mkdir -p /mnt
    cp -a /live/* /mnt/ 2>/dev/null
fi

# Bind mount essential filesystems
echo "Preparing system..."
mkdir -p /mnt/dev /mnt/proc /mnt/sys /mnt/tmp /mnt/run /mnt/media
mount --bind /dev /mnt/dev
mount --bind /dev/pts /mnt/dev/pts
mount -t proc proc /mnt/proc
mount -t sysfs sysfs /mnt/sys
mount -t tmpfs tmpfs /mnt/tmp

# Copy resolv.conf
cp /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null

echo ""
echo "============================================"
echo "  FVAIOS Live System Ready"
echo "============================================"
echo ""

# Switch to new root
exec chroot /mnt /bin/sh -l
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
