#!/bin/sh
# FVAIOS Debug Init - shows exactly what's happening

export PATH=/sbin:/bin:/usr/sbin:/usr/bin

/bin/busybox mkdir -p /proc /sys /dev /tmp /run /media /sysroot
/bin/busybox --install -s

mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mount -t tmpfs tmpfs /dev
mount -t proc proc /proc
mount -t devpts devpts /dev/pts
[ -c /dev/null ] || mknod -m 666 /dev/null c 1 3

echo ""
echo "========================================="
echo "  FVAIOS DEBUG MODE"
echo "========================================="
echo ""

# Load modules one by one and report
echo "=== Loading kernel modules ==="
for mod in usb-storage uas sd_mod sr_mod scsi_mod libata ahci \
           usbcore ehci-hcd xhci-hcd ohci-hcd \
           isofs squashfs loop vfat fat ext4; do
    if modprobe $mod 2>/dev/null; then
        echo "  [OK] $mod"
    else
        echo "  [FAIL] $mod"
    fi
done

echo ""
echo "=== Checking loaded modules ==="
lsmod 2>/dev/null || cat /proc/modules 2>/dev/null

echo ""
echo "=== Triggering mdev ==="
echo "/sbin/mdev" > /proc/sys/kernel/hotplug 2>/dev/null
mdev -s 2>/dev/null

echo ""
echo "=== Waiting 10 seconds for USB devices ==="
for i in $(seq 1 10); do
    echo -n "."
    sleep 1
    mdev -s 2>/dev/null
done
echo ""

echo ""
echo "=== /proc/partitions ==="
cat /proc/partitions

echo ""
echo "=== Block devices in /dev ==="
ls -la /dev/sd* /dev/sr* /dev/nvme* /dev/loop* 2>/dev/null || echo "No block devices found!"

echo ""
echo "=== USB devices ==="
ls -la /sys/bus/usb/devices/ 2>/dev/null || echo "No USB bus"

echo ""
echo "=== SCSI devices ==="
ls -la /sys/bus/scsi/devices/ 2>/dev/null || echo "No SCSI devices"

echo ""
echo "=== Kernel command line ==="
cat /proc/cmdline

echo ""
echo "=== dmesg (last 30 lines) ==="
dmesg 2>/dev/null | tail -30 || echo "dmesg not available"

echo ""
echo "========================================="
echo "  Type 'exit' to continue boot"
echo "========================================="
exec /bin/sh
