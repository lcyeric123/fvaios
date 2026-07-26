# FVAIOS - Fast, Versatile, Advanced Operating System

A custom Alpine Linux x86_64 Live ISO with pre-installed packages and a convenient installation script.

## Features

- **Live Mode**: Runs entirely from RAM for maximum performance
- **Pre-installed Packages**: Includes essential tools, web server, and development utilities
- **Easy Installation**: Simple CLI installer to write system to disk
- **Ollama Integration**: Pre-installed AI runtime for local language models
- **Modern Stack**: Nginx, PHP 8.1, OpenRC init system

## Pre-installed Packages

### System Tools
- sudo, shadow, openrc, busybox-extras
- curl, wget, iproute2, nftables
- dnsutils, openssh-server, openssh-client
- rsync, netcat-openbsd, tcpdump

### Editors & Utilities
- vim, nano, tree
- tar, gzip, bzip2, xz, zip, unzip
- lsblk, blkid, fdisk, parted
- htop, lsof

### Web Stack
- nginx
- php81-fpm
- php81-curl, php81-json, php81-mbstring
- php81-fileinfo, php81-openssl

### AI Runtime
- ollama (installed via curl)

## Building the ISO

### Prerequisites

You need a Linux system with the following packages installed:

```bash
# Alpine Linux
apk add curl wget xorriso squashfs-tools grub grub-bios efibootmgr dosfstools e2fsprogs

# Ubuntu/Debian
apt install curl wget xorriso squashfs-tools grub-pc-bin grub-efi-amd64-bin efibootmgr dosfstools e2fsprogs
```

### Build Steps

1. Clone the repository:
```bash
git clone https://github.com/yourusername/fvaios.git
cd fvaios
```

2. Make the build script executable:
```bash
chmod +x build.sh
```

3. Run the build script:
```bash
sudo ./build.sh
```

4. The ISO will be created in the `build/` directory:
```
build/fvaios-1.0.0-x86_64.iso
```

## Installation

### Boot from ISO

1. Write the ISO to a USB drive or mount in a VM
2. Boot from the media
3. You will be logged in automatically as root

### Install to Disk

1. Type `install` and press Enter
2. Follow the on-screen instructions:
   - Select the target disk
   - Confirm formatting (all data will be erased)
   - Wait for installation to complete
   - Reboot when prompted

### Default Credentials

| User  | Password |
|-------|----------|
| root  | fvaios   |
| fvaios| fvaios   |

**Important**: Change these passwords immediately after installation!

## Usage

### Accessing Services

- **SSH**: `ssh root@<ip-address>`
- **Web Server**: `http://<ip-address>`
- **Ollama**: `ollama serve` (run manually or add to startup)

### Ollama

Ollama is pre-installed but not enabled by default. To use it:

```bash
# Start the Ollama server
ollama serve &

# Pull a model
ollama pull llama2

# Run a model
ollama run llama2
```

## Project Structure

```
fvaios/
├── build.sh              # Main build script
├── LICENSE               # Apache License 2.0
├── README.md             # This file
└── rootfs/               # Root filesystem overlay
    ├── etc/
    │   └── motd          # Login banner
    └── usr/
        └── local/
            └── bin/
                └── install  # Installation script
```

## Configuration

### Network

The system uses DHCP by default. To configure a static IP:

```bash
vi /etc/network/interfaces
```

### Services

Services can be managed with OpenRC:

```bash
rc-service nginx start
rc-update add nginx default
```

## Contributing

Contributions are welcome! Please submit pull requests or issues on GitHub.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Alpine Linux](https://alpinelinux.org/) - The base distribution
- [Ollama](https://ollama.com/) - Local AI runtime
- [Nginx](https://nginx.org/) - Web server
- [OpenRC](https://github.com/OpenRC/openrc) - Init system
