#!/bin/bash
set -e
# build_new3.sh — PATCHATO: debootstrap robusto, uInitrd/uImage, boot.scr SATA 1:1 fallback 0:1

OURPATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
MBLBRANCH=unstable
RELEASE=unstable
ROOT_PASSWORD=debian
DISTRIBUTION=Debian
DATE=$(date +%Y%m%d-%H%M)
ARCH=powerpc
TARGET=mbl-debian
case "$TARGET" in
  /*) ;;
  *) TARGET="${OURPATH}/${TARGET}" ;;
esac

SOURCE=http://ftp.ports.debian.org/debian-ports
SOURCE_SRC=http://ftp.debian.org/debian
QEMU=/usr/bin/qemu-ppc
MKIMAGE=/usr/bin/mkimage
DTC=/usr/bin/dtc
PARTPROBE=/sbin/partprobe
DEBOOTSTRAP=/usr/sbin/debootstrap
DO_COMPRESS=1

BOOTSIZE=285212672
ROOTSIZE=4152360960
SWAPFILESIZE=768
BOOTUUID=$(uuidgen)
ROOTPARTUUID=$(uuidgen)
ROOTUUID=$(uuidgen)
BOOTPARTNAME="BOOT"
BOOTPARTNO=1
ROOTPARTNAME="mblroot"
ROOTPARTNO=2
IMAGESIZE=$(( BOOTSIZE + ROOTSIZE + (4*1024*1024) ))
IMAGE="${DISTRIBUTION}-${ARCH}-${RELEASE}-${MBLBRANCH}-${DATE}.img"

DEBOOTSTRAP_INCLUDE_PACKAGES="gzip,u-boot-tools,device-tree-compiler,binutils,bzip2,locales,aptitude,file,xz-utils,initramfs-tools,fdisk,gdisk,console-common,console-setup,console-setup-linux,parted,e2fsprogs,dropbear,dropbear-initramfs,keyboard-configuration,ca-certificates,debian-archive-keyring,debian-ports-archive-keyring,mdadm,dmsetup,bsdextrautils,zstd,libubootenv-tool"
APT_INSTALL_PACKAGES="needrestart zip unzip screen htop ethtool iperf3  openssh-server netcat-traditional net-tools curl wget systemd-timesyncd smartmontools hdparm cryptsetup psmisc  nfs-common nfs-kernel-server rpcbind samba rsync telnet btrfs-progs xfsprogs exfatprogs ntfs-3g dosfstools bcache-tools duperemove  udisks2 udisks2-btrfs udisks2-lvm2 unattended-upgrades watchdog lm-sensors uuid-runtime rng-tools-debian"

# --- Cleanup non distruttivo ---
mountpoint -q "$TARGET/boot" && /bin/umount -l "$TARGET/boot" || true
mountpoint -q "$TARGET/dev/pts" && /bin/umount "$TARGET/dev/pts" || true
mountpoint -q "$TARGET/dev" && /bin/umount "$TARGET/dev" || true
mountpoint -q "$TARGET/sys" && /bin/umount "$TARGET/sys" || true
mountpoint -q "$TARGET/proc" && /bin/umount "$TARGET/proc" || true
mountpoint -q "$TARGET" && /bin/umount -l "$TARGET" || true
/sbin/losetup -D || true

# --- Create image + GPT ---
fallocate -l "$IMAGESIZE" "$IMAGE"
sgdisk -o "$IMAGE"
sgdisk -n ${BOOTPARTNO}:0:+$(( BOOTSIZE / 512 ))s -t ${BOOTPARTNO}:8300 -c ${BOOTPARTNO}:"$BOOTPARTNAME" "$IMAGE"
sgdisk -n ${ROOTPARTNO}:0:+$(( ROOTSIZE / 512 ))s -t ${ROOTPARTNO}:8300 -c ${ROOTPARTNO}:"$ROOTPARTNAME" "$IMAGE"
sgdisk -u ${ROOTPARTNO}:$ROOTPARTUUID "$IMAGE"

# --- Setup loop ---
LOOPDEV="$(/sbin/losetup -f --show --partscan "${IMAGE}")"
$PARTPROBE "$LOOPDEV" || true
udevadm settle || true
sleep 1
BOOTP="${LOOPDEV}p${BOOTPARTNO}"
ROOTP="${LOOPDEV}p${ROOTPARTNO}"

# --- Filesystems ---
/sbin/mkfs.ext2 "$BOOTP" -O filetype -L "$BOOTPARTNAME" -m 0 -U "$BOOTUUID" -b 1024
/sbin/resize2fs "$BOOTP" $(( BOOTSIZE / 1024 - 128 ))
/sbin/mkfs.ext4 "$ROOTP" -L "$ROOTPARTNAME" -U "$ROOTUUID" -b 4096
/sbin/resize2fs "$ROOTP" $(( ROOTSIZE / 4096 - 32 ))

# --- Mount ---
mkdir -p "$TARGET"
mount "$ROOTP" "$TARGET" -t ext4
mkdir -p "$TARGET/boot"
mount "$BOOTP" "$TARGET/boot" -t ext2

# Swapfile
dd if=/dev/zero of="$TARGET/.swapfile" bs=1M count="$SWAPFILESIZE" status=progress
chmod 0600 "$TARGET/.swapfile"

# --- debootstrap (first stage) ---
source /etc/profile || true
"$DEBOOTSTRAP" --no-check-gpg --foreign --cache-dir="${OURPATH}/cache/debootstrap" --include="$DEBOOTSTRAP_INCLUDE_PACKAGES" --exclude="powerpc-utils,vim-tiny" --arch "$ARCH" "$RELEASE" "$TARGET" "$SOURCE"

# Bind-mounts
after_bind(){ :; }
mount --bind /proc "$TARGET/proc"
mount --bind /sys  "$TARGET/sys"
mount --bind /dev  "$TARGET/dev"
mount --bind /dev/pts "$TARGET/dev/pts"

# --- second stage + recovery ---
echo "force-unsafe-io" > "$TARGET/etc/dpkg/dpkg.cfg.d/force-unsafe-io"
mkdir -p "$TARGET/var/lib/dpkg/updates"
LANG=C.UTF-8 chroot "$TARGET" /debootstrap/debootstrap --second-stage || true
chroot "$TARGET" /usr/bin/env DEBIAN_FRONTEND=noninteractive dpkg --remove --force-remove-reinstreq --force-depends vim-tiny || true
chroot "$TARGET" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get purge -y vim-tiny vim-common || true
chroot "$TARGET" apt-mark hold vim-tiny || true
mkdir -p "$TARGET/etc/apt/preferences.d"
cat > "$TARGET/etc/apt/preferences.d/99-novim.pref" <<EOF
Package: vim*
Pin: release *
Pin-Priority: -1
EOF
chroot "$TARGET" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confnew" -f -y install || true
chroot "$TARGET" /usr/bin/env DEBIAN_FRONTEND=noninteractive dpkg --force-all --configure -a || true

# --- Overlay + system setup ---
if [[ -d "$OURPATH/overlay/fs" ]]; then
  rsync -aHAX --inplace "$OURPATH/overlay/fs/" "$TARGET/"
fi
cat > "$TARGET/etc/apt/apt.conf.d/50ports-tuning" <<APT
Acquire::Retries "5";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::ForceIPv4 "true";
APT
mkdir -p "$TARGET/etc/apt/sources.list.d/"
cat > "$TARGET/etc/apt/sources.list.d/debian.sources" <<SRC
Types: deb-src
URIs: ${SOURCE_SRC}
Suites: ${RELEASE}
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SRC
cat > "$TARGET/etc/apt/sources.list.d/debian-ports.sources" <<SRC
Types: deb
URIs: ${SOURCE}
Suites: ${RELEASE}
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-ports-archive-keyring.gpg
SRC
cat > "$TARGET/etc/fstab" <<FSTAB
UUID=${ROOTUUID} /     ext4 defaults 0 1
UUID=${BOOTUUID} /boot ext2 defaults,sync,nosuid,noexec 0 2
proc            /proc  proc defaults 0 0
none            /var/log tmpfs size=30M,mode=755,gid=0,uid=0 0 0
FSTAB

echo "mbl-debian" > "$TARGET/etc/hostname"
echo "127.0.1.1 mbl-debian" >> "$TARGET/etc/hosts"

mkdir -p "$TARGET/etc/systemd/network"
cat > "$TARGET/etc/systemd/network/20-ether.network" <<NET
[Match]
Type=ether

[Network]
DHCP=yes
NET

chroot "$TARGET" systemctl unmask systemd-networkd || true
chroot "$TARGET" systemctl unmask systemd-networkd.socket || true
chroot "$TARGET" systemctl unmask systemd-networkd-wait-online.service || true
chroot "$TARGET" systemctl enable systemd-networkd || true
chroot "$TARGET" systemctl enable systemd-networkd.socket || true
chroot "$TARGET" systemctl enable systemd-networkd-wait-online.service || true
chroot "$TARGET" systemctl enable systemd-resolved || true
chroot "$TARGET" systemctl disable networking || true

echo 'en_US.UTF-8 UTF-8' > "$TARGET/etc/locale.gen"
chroot "$TARGET" /usr/sbin/locale-gen || true
echo "root:${ROOT_PASSWORD}" | chroot "$TARGET" /usr/sbin/chpasswd
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/g' "$TARGET/etc/ssh/sshd_config" || true

# --- Pacchetti post + cleanup ---
chroot "$TARGET" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update || true
chroot "$TARGET" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y ${APT_INSTALL_PACKAGES} || true
chroot "$TARGET" apt-get clean
chroot "$TARGET" apt-get --purge -y autoremove || true
rm -rf "$TARGET/var/lib/apt/lists/*" "$TARGET/var/tmp/*" 2>/dev/null || true
rm -f "$TARGET/etc/ssh/ssh_host_*" || true

# --- Ensure initramfs, create uInitrd, uImage, boot.scr ---
if ! ls "$TARGET/boot"/initrd.img-* >/dev/null 2>&1; then
  echo "[INFO] No initrd found in rootfs/boot — creating"
  chroot "$TARGET" update-initramfs -c -k all || true
fi
if ls "$TARGET/boot"/initrd.img-* >/dev/null 2>&1; then
  INITRD_PATH=$(ls -1 "$TARGET/boot"/initrd.img-* | head -n1)
  echo "[INFO] Using initrd: $INITRD_PATH"
  "$MKIMAGE" -A ppc -O linux -T ramdisk -C gzip -n "Initrd-MBL" -d "$INITRD_PATH" "${OURPATH}/uInitrd"
  cp -v "${OURPATH}/uInitrd" "$TARGET/boot/"
else
  echo "[WARN] initrd still missing"
fi
if [[ -f "${OURPATH}/linux/arch/powerpc/boot/zImage" ]]; then
  echo "[INFO] Creating uImage from zImage"
  "$MKIMAGE" -A ppc -O linux -T kernel -C none -a 0x00000000 -e 0x00000000 -n "Linux-PPC" -d "${OURPATH}/linux/arch/powerpc/boot/zImage" "${OURPATH}/uImage"
  cp -v "${OURPATH}/uImage" "$TARGET/boot/" || true
fi

# DTB + root-device
mkdir -p "$TARGET/boot/boot"
if [[ -f "${OURPATH}/dts/wd-mybooklive.dtb" ]]; then
  cp -v "${OURPATH}/dts/wd-mybooklive.dtb" "$TARGET/boot/apollo3g.dtb"
fi
echo "UUID=${ROOTUUID}" > "$TARGET/boot/boot/root-device"

# boot.cmd -> boot.scr (sata 1:1, fallback 0:1)
BOOTCMD="${OURPATH}/boot.cmd"
cat > "$BOOTCMD" <<EOF
setenv initrd_high 0xffffffff
setenv fdt_high 0xffffffff
setenv bootargs "console=ttyS0,115200 root=UUID=${ROOTUUID} rw"

setenv dev1 'sata 1:1'
setenv dev0 'sata 0:1'

if ext2load ${dev1} 0x00800000 /uImage; then
  ext2load ${dev1} 0x01100000 /uInitrd
  ext2load ${dev1} 0x00f00000 /apollo3g.dtb
  bootm 0x00800000 0x01100000 0x00f00000
fi

if ext2load ${dev0} 0x00800000 /uImage; then
  ext2load ${dev0} 0x01100000 /uInitrd
  ext2load ${dev0} 0x00f00000 /apollo3g.dtb
  bootm 0x00800000 0x01100000 0x00f00000
fi

echo "ERROR: Unable to load /uImage from sata 1:1 or 0:1"
EOF
"$MKIMAGE" -A ppc -O linux -T script -C none -n "MBL Boot Script" -d "$BOOTCMD" "${OURPATH}/boot.scr"
cp -v "${OURPATH}/boot.scr" "$TARGET/boot/"
mkdir -p "$TARGET/boot/boot"
cp -v "${OURPATH}/boot.scr" "$TARGET/boot/boot/boot.scr"

# --- Unmount + zerofree + detach ---
mountpoint -q "$TARGET/boot" && /bin/umount -l "$TARGET/boot" || true
mountpoint -q "$TARGET/dev/pts" && /bin/umount "$TARGET/dev/pts" || true
mountpoint -q "$TARGET/dev" && /bin/umount "$TARGET/dev" || true
mountpoint -q "$TARGET/sys" && /bin/umount "$TARGET/sys" || true
mountpoint -q "$TARGET/proc" && /bin/umount "$TARGET/proc" || true
mountpoint -q "$TARGET" && /bin/umount -l "$TARGET" || true
/usr/sbin/zerofree -v "$BOOTP" || true
/usr/sbin/zerofree -v "$ROOTP" || true
/sbin/losetup -j "$IMAGE" | cut -d: -f1 | xargs -r -n1 /sbin/losetup -d || true

# --- Compressione ---
if [[ "$DO_COMPRESS" == "1" ]]; then
  echo "Compressing Image. This can take a while."
  if command -v pigz >/dev/null 2>&1; then pigz "$IMAGE"; else gzip "$IMAGE"; fi
fi
