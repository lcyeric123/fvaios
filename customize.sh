#!/bin/sh
# customize.sh - run inside chroot

set -e

# repositories
cat > /etc/apk/repositories << EOF
https://dl-cdn.alpinelinux.org/alpine/v3.19/main
https://dl-cdn.alpinelinux.org/alpine/v3.19/community
EOF

apk update

# install zstd first (needed by ollama installer)
apk add --no-cache zstd

# install packages from list (including alpine-base for proper live boot)
grep -v '^\s*#' /packages.list | grep -v '^\s*$' | while read -r pkg; do
    apk add --no-cache "$pkg"
done

# install alpine-base if not already included (provides proper init scripts)
apk add --no-cache alpine-base 2>/dev/null || true

# set hostname
echo "fvaios" > /etc/hostname
echo "127.0.0.1 fvaios" >> /etc/hosts

# root auto login on tty1
sed -i 's|/sbin/getty|/sbin/getty --autologin root|g' /etc/inittab

# enable services
rc-update add sshd default
rc-update add nginx default
rc-update add php-fpm81 default

# install ollama using official script
echo "Installing ollama..."
curl -fsSL https://ollama.com/install.sh | sh || true
chmod +x /usr/local/bin/ollama 2>/dev/null || true

# create necessary directories for live boot
mkdir -p /media/cdrom /media/usb /media/mmcblk0p1

# generate proper initramfs for live boot with all required features
echo "Generating initramfs..."
cat > /etc/mkinitfs/features.d/fvaios.modules << 'EOF'
kernel/drivers/cdrom/cdrom.ko
kernel/drivers/scsi/sr_mod.ko
kernel/fs/isofs/isofs.ko
kernel/fs/squashfs/squashfs.ko
kernel/drivers/block/loop.ko
kernel/drivers/ata/ahci.ko
kernel/drivers/ata/ata_piix.ko
kernel/drivers/virtio/virtio_blk.ko
kernel/drivers/virtio/virtio_pci.ko
kernel/drivers/block/virtio_blk.ko
kernel/drivers/usb/storage/usb-storage.ko
kernel/fs/vfat/vfat.ko
kernel/fs/nls/nls_cp437.ko
kernel/fs/nls/nls_iso8859-1.ko
EOF

# Create the features list file
cat > /tmp/features.list << 'EOF'
base
squashfs
cdrom
usb
mmc
nvme
virtio
ext4
vfat
fvaios
EOF

KVER=$(ls /lib/modules | head -1)
mkinitfs -F "base squashfs cdrom usb mmc nvme virtio ext4 vfat fvaios" -o /boot/initramfs-lts $KVER

# Verify initramfs was created
ls -la /boot/initramfs-lts

# clean up
rm /packages.list /customize.sh
rm -rf /var/cache/apk/*
