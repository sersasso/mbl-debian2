# USAGE

This document explains how to use the provided build system to generate kernel artifacts, a Debian root filesystem, and a complete bootable disk image for the Western Digital MyBook Live.

## 1. Script Overview

### build-kernel.sh
Compiles the Linux kernel and produces:

- `uImage`
- `zImage`
- `apollo3g.dtb`

### build_new3.sh
Builds the Debian disk image and produces:

- GPT-partitioned image (BOOT ext2, ROOT ext4)  
- configured Debian root filesystem  
- `uInitrd` created from initramfs  
- U-Boot boot script `boot.scr`  
- kernel artifacts copied into BOOT partition

## 2. Kernel Build

```
$ ./build-kernel.sh
```

Optionally specify a kernel ref:

```
$ ./build-kernel.sh v6.19-rc3
```

Artifacts appear in project root:

```
uImage
zImage
apollo3g.dtb
```

## 3. Debian Image Build

```
$ sudo ./build_new3.sh
```

To log the output:

```
$ sudo ./build_new3.sh 2>&1 | tee build_logs/build-$(date +%F-%H%M%S).log
```

Image files:

```
Debian-powerpc-unstable-unstable-<timestamp>.img
Debian-powerpc-unstable-unstable-<timestamp>.img.gz
```

## 4. Flashing the Image

```
$ lsblk
$ sudo dd if=Debian-powerpc-unstable-unstable-*.img of=/dev/sdX \
      bs=4M status=progress conv=fsync
$ sync
```

## 5. Booting the Device

1. Insert disk into MyBook Live  
2. Connect Ethernet and serial console (115200 8N1)  
3. Power on

Expected boot:

```
Loading file "/boot/boot.scr" from sata device 1:1
## Executing script ...
Loading /uImage ... OK
Loading /uInitrd ... OK
Loading /apollo3g.dtb ... OK
## Booting kernel ...
```

## 6. Accessing the System after Boot

```
$ nmap -sn 192.168.1.0/24
$ ssh root@<MBL-IP>
```

Default password:

```
debian
```

## 7. Manual U-Boot Testing

```
ext2ls sata 1:1 /
ext2load sata 1:1 0x00800000 /uImage
iminfo 0x00800000
ext2load sata 1:1 0x01100000 /uInitrd
ext2load sata 1:1 0x00f00000 /apollo3g.dtb
bootm 0x00800000 0x01100000 0x00f00000
```

## 8. Cleaning Up

```
$ rm -rf linux mbl-debian build_logs
```

## 9. Partition Notes

```
sata 1:1 -> BOOT
sata 1:2 -> ROOT
```
