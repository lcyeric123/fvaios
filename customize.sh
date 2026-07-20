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

# install ollama using official script
echo "Installing ollama..."
curl -fsSL https://ollama.com/install.sh | sh || true
chmod +x /usr/local/bin/ollama 2>/dev/null || true

# clean up
rm /packages.list /customize.sh
rm -rf /var/cache/apk/*
