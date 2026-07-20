#!/bin/sh
# customize.sh - run inside chroot

set -e

# repositories
cat > /etc/apk/repositories << EOF
https://dl-cdn.alpinelinux.org/alpine/v3.19/main
https://dl-cdn.alpinelinux.org/alpine/v3.19/community
EOF

apk update

# install packages from list (need zstd for ollama extraction)
apk add --no-cache zstd

grep -v '^\s*#' /packages.list | grep -v '^\s*$' | while read -r pkg; do
    apk add --no-cache "$pkg"
done

# set hostname
echo "fvaios" > /etc/hostname
echo "127.0.0.1 fvaios" >> /etc/hosts

# root auto login on tty1
sed -i 's|/sbin/getty|/sbin/getty --autologin root|g' /etc/inittab

# enable services
rc-update add sshd default
rc-update add nginx default
rc-update add php-fpm81 default

# install ollama using official script (ignore service setup errors)
echo "Installing ollama..."
curl -fsSL https://ollama.com/install.sh | sh || true

# Manually ensure binary is executable
chmod +x /usr/local/bin/ollama 2>/dev/null || true

# generate initramfs for live boot
echo "Generating initramfs..."
cat > /etc/mkinitfs/features.d/fvaios.modules << EOF
kernel/drivers/cdrom
kernel/fs/isofs
kernel/fs/squashfs
kernel/drivers/block/loop.ko
EOF
KVER=$(ls /lib/modules | head -1)
mkinitfs -o /boot/initramfs-lts $KVER

# clean up
rm /packages.list /customize.sh
rm -rf /var/cache/apk/*
