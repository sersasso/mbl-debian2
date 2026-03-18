# INSTALL

## 1. Overview

This document describes the installation procedure for generating and deploying a Debian Sid/Unstable root filesystem and kernel image for the Western Digital MyBook Live (APM82181).  
The build system in this repository provides the scripts required to construct:

- a PowerPC Linux kernel (`uImage`, `apollo3g.dtb`)  
- a complete Debian root filesystem (powerpc, unstable)  
- a bootable GPT disk image suitable for the MyBook Live  
- U-Boot loader artifacts (`boot.scr`, `uInitrd`)  

The resulting system boots directly on the hardware and provides a standard Debian environment with systemd, systemd-networkd, and SSH enabled.

This document is intended for system integrators, developers, and advanced users familiar with Debian package management, cross-compilation, and embedded systems.

## 2. Build Host Requirements

### 2.1. Operating System
A Debian Sid/Unstable system (physical or virtual) with at least **20 GiB** of available disk space and root privileges is required.

### 2.2. Enable PowerPC Architecture

```
# dpkg --add-architecture powerpc
# apt update
```

### 2.3. Install Debian Ports Keyring

```
# apt install debian-ports-archive-keyring
```

### 2.4. Add Debian Ports Repository

```
# echo "deb [arch=powerpc] http://deb.debian.org/debian-ports/ sid main contrib non-free non-free-firmware" \
    > /etc/apt/sources.list.d/powerpc-ports.list
# apt update
```

### 2.5. Required Packages

```
# apt install \
      bc binfmt-support build-essential debootstrap device-tree-compiler \
      dosfstools fakeroot git kpartx lvm2 parted python3-dev qemu-system \
      qemu-user-static swig wget u-boot-tools gdisk fdisk kernel-package \
      uuid-runtime gcc-powerpc-linux-gnu binutils-powerpc-linux-gnu \
      libssl-dev:powerpc rsync zerofree ca-certificates xz-utils zstd pigz
```

Because the generator relies on `losetup`, `kpartx`, `partprobe`, and GPT device-mapper handling, containerized build environments (Docker, Podman, LXC) are not recommended.

## 3. Directory Structure

```
mbl-debian2/
  build-kernel.sh
  build_new3.sh
  apm82181_mbl_defconfig
  dts/wd-mybooklive.dts
  patches/kernel/
  overlay/kernel/
  overlay/fs/
  cache/debootstrap/
```

## 4. Kernel Build Procedure

```
$ ./build-kernel.sh
```

This script:

- clones the Linux kernel source tree  
- applies patches and DTS overlays  
- loads the `apm82181_mbl_defconfig`  
- forces configuration of:
  - SATA DesignWare 460EX  
  - 8250/OF serial console  
  - IBM EMAC networking  
  - early printk  
- builds the PowerPC kernel (`zImage`)  
- generates the legacy `uImage` required by the MyBook Live  
- generates `apollo3g.dtb`

Kernel artifacts will appear in the project root:

```
uImage
zImage
apollo3g.dtb
```

## 5. Root Filesystem and Image Generation

```
$ sudo ./build_new3.sh
```

This script:

1. Creates a GPT disk image (BOOT ext2, ROOT ext4)  
2. Runs PowerPC debootstrap (first stage)  
3. Performs second-stage dpkg configuration  
4. Applies filesystem overlays  
5. Configures SSH, networkd, locale, fstab  
6. Generates initramfs and `uInitrd`  
7. Installs kernel artifacts and `boot.scr`  
8. Writes `/boot/boot/root-device` with UUID  
9. Optionally compresses the final image

Output:

```
Debian-powerpc-unstable-unstable-<timestamp>.img
Debian-powerpc-unstable-unstable-<timestamp>.img.gz
```

## 6. Flashing the Image to Disk

```
$ lsblk
$ sudo dd if=Debian-powerpc-unstable-unstable-*.img of=/dev/sdX \
      bs=4M status=progress conv=fsync
$ sync
```

## 7. First Boot on the MyBook Live

1. Insert disk into MyBook Live  
2. Connect Ethernet  
3. Connect serial console (115200 8N1)  
4. Power on

Expected:

```
Loading file "/boot/boot.scr" from sata device 1:1
## Executing script ...
Loading /uImage ... OK
Loading /uInitrd ... OK
Loading /apollo3g.dtb ... OK
## Booting kernel ...
```

## 8. Accessing the System

```
$ nmap -sn 192.168.1.0/24
$ ssh root@<MBL-IP>
```

Default password:

```
debian
```

## 9. Manual U-Boot Testing

```
ext2ls sata 1:1 /
ext2load sata 1:1 0x00800000 /uImage
iminfo 0x00800000
ext2load sata 1:1 0x01100000 /uInitrd
ext2load sata 1:1 0x00f00000 /apollo3g.dtb
bootm 0x00800000 0x01100000 0x00f00000
```

## 10. Notes

MyBook Live SATA mapping:

```
sata 1:1 -> BOOT
sata 1:2 -> ROOT
```

## 11. Summary

Build:

```
$ ./build-kernel.sh
$ sudo ./build_new3.sh
```

Flash:

```
$ sudo dd if=image.img of=/dev/sdX bs=4M
```

Boot -> login -> use the system.
