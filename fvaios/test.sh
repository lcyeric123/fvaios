#!/bin/bash
set -euo pipefail

# FVAIOS Test Script
# Validates the build configuration

echo "FVAIOS Build Validation"
echo "======================="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if running as root
if [ "$(id -u)" -eq 0 ]; then
    echo -e "${YELLOW}Warning: Running as root. Build script requires root for chroot operations.${NC}"
fi

# Check build script syntax
echo "1. Checking build script syntax..."
if bash -n build.sh; then
    echo -e "${GREEN}   ✓ build.sh syntax OK${NC}"
else
    echo -e "${RED}   ✗ build.sh syntax error${NC}"
    exit 1
fi

# Check install script syntax
echo "2. Checking install script syntax..."
if bash -n rootfs/usr/local/bin/install; then
    echo -e "${GREEN}   ✓ install script syntax OK${NC}"
else
    echo -e "${RED}   ✗ install script syntax error${NC}"
    exit 1
fi

# Check if required files exist
echo "3. Checking required files..."
required_files=(
    "build.sh"
    "rootfs/usr/local/bin/install"
    "rootfs/etc/motd"
    "rootfs/boot/grub/grub.cfg"
    "LICENSE"
    "README.md"
)

for file in "${required_files[@]}"; do
    if [ -f "$file" ]; then
        echo -e "${GREEN}   ✓ $file exists${NC}"
    else
        echo -e "${RED}   ✗ $file missing${NC}"
        exit 1
    fi
done

# Check file permissions
echo "4. Checking file permissions..."
if [ -x "build.sh" ]; then
    echo -e "${GREEN}   ✓ build.sh is executable${NC}"
else
    echo -e "${YELLOW}   ! build.sh is not executable${NC}"
fi

if [ -x "rootfs/usr/local/bin/install" ]; then
    echo -e "${GREEN}   ✓ install script is executable${NC}"
else
    echo -e "${YELLOW}   ! install script is not executable${NC}"
fi

# Check dependencies
echo "5. Checking build dependencies..."
deps=("curl" "wget" "xorriso" "mksquashfs" "chroot" "mount" "umount" "tar" "grub-install")
missing=()

for dep in "${deps[@]}"; do
    if command -v "$dep" &>/dev/null; then
        echo -e "${GREEN}   ✓ $dep found${NC}"
    else
        echo -e "${YELLOW}   ! $dep not found${NC}"
        missing+=("$dep")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Missing dependencies: ${missing[*]}${NC}"
    echo "Install with: apk add ${missing[*]}"
fi

echo ""
echo "Validation complete!"
echo ""
echo "To build the ISO, run: sudo ./build.sh"
echo "Or use Make: sudo make"
