#!/bin/sh
# customize.sh - run inside chroot

set -e

# repositories
cat > /etc/apk/repositories << EOF
https://dl-cdn.alpinelinux.org/alpine/v3.19/main
https://dl-cdn.alpinelinux.org/alpine/v3.19/community
EOF

apk update

# install zstd first
apk add --no-cache zstd

# install packages from list
grep -v '^\s*#' /packages.list | grep -v '^\s*$' | while read -r pkg; do
    apk add --no-cache "$pkg"
done

# install alpine-base for proper init scripts
apk add --no-cache alpine-base

# set hostname
echo "fvaios" > /etc/hostname
echo "127.0.0.1 fvaios" >> /etc/hosts

# root auto login
sed -i 's|/sbin/getty|/sbin/getty --autologin root|g' /etc/inittab

# enable services
rc-update add sshd default
rc-update add nginx default
rc-update add php-fpm81 default

# install ollama
echo "Installing ollama..."
curl -fsSL https://ollama.com/install.sh | sh || true
chmod +x /usr/local/bin/ollama 2>/dev/null || true

# create media directories
mkdir -p /media/cdrom /media/usb

# generate initramfs with proper features
echo "Generating initramfs..."
KVER=$(ls /lib/modules | head -1)

cat > /etc/mkinitfs/features.d/fvaios.modules << 'EOF'
kernel/drivers/cdrom
kernel/drivers/scsi
kernel/fs/isofs
kernel/fs/squashfs
kernel/drivers/block/loop.ko
kernel/drivers/ata
kernel/drivers/virtio
kernel/drivers/usb/storage
kernel/fs/vfat
kernel/fs/nls
EOF

mkinitfs -F "base squashfs cdrom usb mmc nvme virtio ext4 vfat fvaios" \
  -o /boot/initramfs-lts $KVER

# clean up
rm /packages.list /customize.sh
rm -rf /var/cache/apk/*
