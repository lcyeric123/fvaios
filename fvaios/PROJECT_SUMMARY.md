# FVAIOS Project Summary

## Overview

FVAIOS (Fast, Versatile, Advanced Operating System) is a custom Alpine Linux x86_64 Live ISO with pre-installed packages and a convenient installation script.

## Project Structure

```
fvaios/
├── build.sh                    # Main build script (9758 bytes)
├── CHANGELOG.md                # Version history
├── .gitignore                  # Git ignore rules
├── LICENSE                     # Apache License 2.0
├── Makefile                    # Build automation
├── PROJECT_SUMMARY.md          # This file
├── README.md                   # Project documentation
├── test.sh                     # Build validation script
└── rootfs/                     # Root filesystem overlay
    ├── boot/
    │   └── grub/
    │       └── grub.cfg        # GRUB bootloader configuration
    ├── etc/
    │   ├── init.d/
    │   │   └── ollama          # Ollama OpenRC service script
    │   ├── motd                # Login banner with FVAIOS logo
    │   └── network/
    │       └── interfaces      # Network configuration
    └── usr/
        └── local/
            └── bin/
                └── install     # Disk installation script
```

## File Descriptions

### Core Files

| File | Size | Description |
|------|------|-------------|
| `build.sh` | 9758 bytes | Main build script that downloads Alpine minirootfs, installs packages, creates squashfs, and generates bootable ISO |
| `rootfs/usr/local/bin/install` | 6781 bytes | Interactive CLI installer for writing FVAIOS to disk |
| `rootfs/etc/motd` | 456 bytes | Custom login banner displaying FVAIOS ASCII art logo |
| `rootfs/boot/grub/grub.cfg` | 423 bytes | GRUB bootloader configuration with multiple boot options |

### Configuration Files

| File | Size | Description |
|------|------|-------------|
| `rootfs/etc/init.d/ollama` | 512 bytes | OpenRC service script for Ollama AI runtime |
| `rootfs/etc/network/interfaces` | 287 bytes | Network configuration with DHCP and static IP options |

### Documentation Files

| File | Size | Description |
|------|------|-------------|
| `README.md` | 3761 bytes | Main project documentation with build and usage instructions |
| `CHANGELOG.md` | 989 bytes | Version history following Keep a Changelog format |
| `PROJECT_SUMMARY.md` | This file | Project structure overview |

### Build Files

| File | Size | Description |
|------|------|-------------|
| `Makefile` | 515 bytes | GNU Make automation for build and clean operations |
| `test.sh` | 2156 bytes | Build validation script checking syntax and dependencies |
| `.gitignore` | 153 bytes | Git ignore rules for build artifacts and editor files |

### License

| File | Size | Description |
|------|------|-------------|
| `LICENSE` | 11240 bytes | Apache License 2.0 full text |

## Features

### Pre-installed Packages

**System Tools:**
- sudo, shadow, openrc, busybox-extras

**Networking:**
- curl, wget, iproute2, nftables, dnsutils

**SSH:**
- openssh-server, openssh-client

**Utilities:**
- rsync, netcat-openbsd, tcpdump

**Editors & Files:**
- vim, nano, tree, tar, gzip, bzip2, xz, zip, unzip

**Disk Tools:**
- lsblk, blkid, fdisk, parted

**Monitoring:**
- htop, lsof

**Web Stack:**
- nginx, php81-fpm
- php81-curl, php81-json, php81-mbstring
- php81-fileinfo, php81-openssl

**AI Runtime:**
- ollama (installed via curl)

### Installation Features

- Interactive disk selection
- GPT partitioning (EFI + Boot + Root)
- GRUB bootloader (BIOS and UEFI support)
- Automatic service configuration
- Default user creation (fvaios/fvaios)

### Boot Options

1. **FVAIOS Live** - Standard live boot
2. **FVAIOS Live (RAM)** - Boot with RAM optimization
3. **FVAIOS Live (Text Mode)** - Console mode for serial terminals
4. **FVAIOS Live (Verbose)** - Debug boot with verbose output

## Build Process

1. **Download**: Fetches Alpine minirootfs from official mirrors
2. **Extract**: Unpacks minirootfs to work directory
3. **Chroot**: Enters chroot environment to install packages
4. **Configure**: Sets up system configuration and services
5. **Squash**: Creates compressed rootfs with squashfs
6. **Boot**: Generates GRUB configuration and boot files
7. **ISO**: Creates bootable ISO with xorriso

## Usage

### Building

```bash
# Option 1: Using build script
sudo ./build.sh

# Option 2: Using Make
sudo make

# Option 3: Validate first
./test.sh
sudo ./build.sh
```

### Installing

1. Boot from ISO
2. Run `install` command
3. Select target disk
4. Confirm formatting
5. Wait for completion
6. Reboot

### Default Credentials

- **Root**: root / fvaios
- **User**: fvaios / fvaios

## License

This project is licensed under the Apache License 2.0.

## Contributing

Contributions are welcome! Please follow standard GitHub workflow:
1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request
