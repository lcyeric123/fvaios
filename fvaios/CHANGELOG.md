# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-07-26

### Added

- Initial release of FVAIOS
- Alpine Linux x86_64 base system
- Live mode with RAM execution
- CLI installation script
- Pre-installed packages:
  - System tools: sudo, shadow, openrc, busybox-extras
  - Networking: curl, wget, iproute2, nftables, dnsutils
  - SSH: openssh-server, openssh-client
  - Utilities: rsync, netcat-openbsd, tcpdump
  - Editors: vim, nano, tree
  - Archives: tar, gzip, bzip2, xz, zip, unzip
  - Disk tools: lsblk, blkid, fdisk, parted
  - Monitoring: htop, lsof
  - Web stack: nginx, php81-fpm, php81-curl, php81-json, php81-mbstring, php81-fileinfo, php81-openssl
  - AI runtime: ollama
- Custom MOTD banner
- GRUB bootloader support (BIOS and UEFI)
- Apache License 2.0
