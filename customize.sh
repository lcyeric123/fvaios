#!/bin/sh
# customize.sh - run inside chroot

set -e

# repositories
cat > /etc/apk/repositories << EOF
https://dl-cdn.alpinelinux.org/alpine/v3.19/main
https://dl-cdn.alpinelinux.org/alpine/v3.19/community
EOF

apk update

# install packages from list
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

# install ollama binary (direct download)
echo "Installing ollama..."
apk add --no-cache zstd
curl -fsSL "https://github.com/ollama/ollama/releases/latest/download/ollama-linux-amd64.tgz" -o /tmp/ollama.tgz
tar -xzf /tmp/ollama.tgz -C /usr/local
chmod +x /usr/local/bin/ollama
rm -f /tmp/ollama.tgz

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
