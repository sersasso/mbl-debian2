#!/bin/bash
set -e

# ==============================
# Configurazione di base
# ==============================
OURPATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

MBLBRANCH=unstable
RELEASE=unstable
ROOT_PASSWORD=debian
DISTRIBUTION=Debian
DATE=$(date +%Y%m%d-%H%M)

ARCH=powerpc
TARGET=mbl-debian
SOURCE=http://ftp.ports.debian.org/debian-ports
SOURCE_SRC=http://ftp.debian.org/debian

# Su Debian SID non serve qemu-ppc-static; usiamo qemu-ppc via binfmt
QEMU=/usr/bin/qemu-ppc
MKIMAGE=/usr/bin/mkimage
DTC=/usr/bin/dtc
PARTPROBE=/sbin/partprobe
DEBOOTSTRAP=/usr/sbin/debootstrap

DO_COMPRESS=1

# ==============================
# HDD Image
# ==============================
BOOTSIZE=285212672   # 272 MiB
ROOTSIZE=4152360960  # ~ 4GiB
SWAPFILESIZE=768     # MiB

BOOTUUID=$(uuidgen)
ROOTPARTUUID=$(uuidgen)
ROOTUUID=$(uuidgen)

BOOTPARTNAME="BOOT"
BOOTPARTNO=1         # U-Boot script si aspettano che sia 1
ROOTPARTNAME="mblroot"
ROOTPARTNO=2

IMAGESIZE=$(("$BOOTSIZE" + "$ROOTSIZE" + (4 * 1024 * 1024 )))
IMAGE="$DISTRIBUTION-$ARCH-$RELEASE-$MBLBRANCH-$DATE.img"

MAKE_RAID=

die() { echo "[FATAL] $*" >&2; exit 1; }
to_k() { echo $(($1 / 1024))"k"; }

echo "=== Building Image '$IMAGE' ==="

# ==============================
# Verifica strumenti host
# ==============================
declare -a NEEDED=(
  "/usr/bin/uuidgen uuid-runtime"
  "$QEMU qemu-user-binfmt"
  "$MKIMAGE u-boot-tools"
  "$DTC device-tree-compiler"
  "$PARTPROBE parted"
  "$DEBOOTSTRAP debootstrap"
  "/usr/bin/git git"
  "/bin/mount mount"
  "/usr/bin/rsync rsync"
  "/sbin/gdisk gdisk"
  "/sbin/fdisk fdisk"
  "/usr/sbin/chroot coreutils"
  "/sbin/mkswap util-linux"
  "/usr/sbin/zerofree zerofree"
  "/usr/bin/powerpc-linux-gnu-gcc gcc-powerpc-linux-gnu"
  "/usr/bin/powerpc-linux-gnu-ld binutils-powerpc-linux-gnu"
)
for packaged in "${NEEDED[@]}"; do
  set -- ${packaged}
  [ -x "$1" ] || die "Can't find '$1'. Please install '$2'"
done

# Check informativo binfmt (non modifichiamo nulla sull’host)
if ! [ -f /proc/sys/fs/binfmt_misc/qemu-ppc ]; then
  echo "[INFO] qemu-ppc non risulta attivo in binfmt. Esegui una volta:"
  echo "      sudo apt-get install -y binfmt-support qemu-user-binfmt && sudo dpkg-reconfigure qemu-user-binfmt"
fi

# ==============================
# Pacchetti debootstrap / apt nel chroot
# ==============================
DEBOOTSTRAP_INCLUDE_PACKAGES="gzip,u-boot-tools,device-tree-compiler,binutils,\
bzip2,locales,aptitude,file,xz-utils,initramfs-tools,fdisk,gdisk,\
console-common,console-setup,console-setup-linux,parted,e2fsprogs,\
dropbear,dropbear-initramfs,keyboard-configuration,ca-certificates,\
debian-archive-keyring,debian-ports-archive-keyring,mdadm,dmsetup,\
bsdextrautils,zstd,libubootenv-tool"

APT_INSTALL_PACKAGES="needrestart zip unzip vim screen htop ethtool iperf3 \
openssh-server netcat-traditional net-tools curl wget systemd-timesyncd \
smartmontools hdparm cryptsetup psmisc \
nfs-common nfs-kernel-server rpcbind samba rsync telnet \
btrfs-progs xfsprogs exfatprogs ntfs-3g dosfstools \
bcache-tools duperemove \
udisks2 udisks2-btrfs udisks2-lvm2 unattended-upgrades \
watchdog lm-sensors uuid-runtime rng-tools-debian"

# ==============================
# Cleanup + trap
# ==============================
mountpoint -q "$TARGET" && /bin/umount -l "$TARGET" || true
/sbin/losetup -D || true
rm -rf "$TARGET" "$IMAGE"

cleanup() {
  set +e
  mountpoint -q "$TARGET/boot"    && /bin/umount -l "$TARGET/boot"
  mountpoint -q "$TARGET/proc"    && /bin/umount "$TARGET/proc"
  mountpoint -q "$TARGET/sys"     && /bin/umount "$TARGET/sys"
  mountpoint -q "$TARGET/dev/pts" && /bin/umount "$TARGET/dev/pts"
  mountpoint -q "$TARGET/dev"     && /bin/umount "$TARGET/dev"
  mountpoint -q "$TARGET"         && /bin/umount -l "$TARGET"
  [[ -n "$LOOPDEV" ]] && /sbin/losetup -d "$LOOPDEV" 2>/dev/null || true
  rm -rf "$TARGET" 2>/dev/null || true
}
trap cleanup EXIT

# ==============================
# Crea immagine + partiziona GPT
# ==============================
fallocate -l "$IMAGESIZE" "$IMAGE"

/sbin/gdisk "$IMAGE" <<-GPTEOF
  o
  y
  n
  $BOOTPARTNO

  +$(to_k $BOOTSIZE)
  c
  $BOOTPARTNAME
  n
  $ROOTPARTNO

  +$(to_k $ROOTSIZE)
  c
  $ROOTPARTNAME
  x
  c
  $ROOTPARTNO
  $ROOTPARTUUID
  m
  w
  y
GPTEOF

# Mappa con losetup (NO kpartx) → /dev/loopXp1/p2
LOOPDEV="$(/sbin/losetup -f --show --partscan "${IMAGE}")"
[ -n "$LOOPDEV" ] || die "Unable to allocate loop device"

$PARTPROBE "$LOOPDEV" || true
udevadm settle || sleep 1

BOOTP="${LOOPDEV}p${BOOTPARTNO}"
ROOTP="${LOOPDEV}p${ROOTPARTNO}"

# Retry per comparsa nodi p1/p2
for p in "$BOOTP" "$ROOTP"; do
  tries=0
  until [ -b "$p" ]; do
    tries=$((tries+1))
    echo "[WARN] Partition not present yet: $p (try $tries)"
    $PARTPROBE "$LOOPDEV" || true
    /sbin/partx -u "$LOOPDEV" || true
    udevadm settle || true
    sleep $(( tries > 3 ? 2 : 1 ))
    [ $tries -ge 6 ] && break
  done
  [ -b "$p" ] || die "Partition not found: $p"
done

# ==============================
# Kernel build
# ==============================
echo "=== Building kernel with apm82181_mbl_defconfig ==="

if [[ -d linux/debian ]]; then
  echo "Removing auto-generated linux/debian directory"
  rm -rf linux/debian
fi

./build-kernel.sh || die "Kernel build failed"

# ==============================
# Filesystems
# ==============================
/sbin/mkfs.ext2 "${BOOTP}" -O filetype -L "${BOOTPARTNAME}" -m 0 -U "${BOOTUUID}" -b 1024
/sbin/resize2fs "${BOOTP}" $(( BOOTSIZE / 1024 - 128 ))

/sbin/mkfs.ext4 "${ROOTP}" -L "${ROOTPARTNAME}" -U "${ROOTUUID}" -b 4096
/sbin/resize2fs "${ROOTP}" $(( ROOTSIZE / 4096 - 32 ))

mkdir -p "${TARGET}"
mount "${ROOTP}" "${TARGET}" -t ext4

dd if=/dev/zero of="${TARGET}/.swapfile" bs=1M count="${SWAPFILESIZE}" status=progress
chmod 0600 "${TARGET}/.swapfile"

mkdir -p "${TARGET}/boot/boot"
mount "${BOOTP}" "${TARGET}/boot" -t ext2
cp dts/wd-mybooklive.dtb      "${TARGET}/boot/apollo3g.dtb"
cp dts/wd-mybooklive.dtb.tmp  "${TARGET}/boot/apollo3g.dts" || true

echo "UUID=${ROOTUUID}" > "${TARGET}/boot/boot/root-device"

# ==============================
# debootstrap (first stage)
# ==============================
source /etc/profile
"${DEBOOTSTRAP}" --no-check-gpg --foreign \
  --include="$DEBOOTSTRAP_INCLUDE_PACKAGES" \
  --exclude="powerpc-utils" \
  --arch "$ARCH" "$RELEASE" "$TARGET" "$SOURCE"

# Bind-mount per chroot (OBBLIGATORI prima della second stage)
mount --bind /proc     "${TARGET}/proc"
mount --bind /sys      "${TARGET}/sys"
mount --bind /dev      "${TARGET}/dev"
mount --bind /dev/pts  "${TARGET}/dev/pts"

# second stage
LANG=C.UTF-8 /usr/sbin/chroot "${TARGET}" /debootstrap/debootstrap --second-stage

# ==============================
# Overlay FS (opzionale)
# ==============================
if [[ -d "$OURPATH/overlay/fs" ]]; then
  echo "Applying fs overlay"
  cp -vR "$OURPATH/overlay/fs/"* "$TARGET"
fi

# ==============================
# Install script nel chroot
# ==============================
mkdir -p "${TARGET}/dev/mapper"

cat <<-INSTALLEOF > "$TARGET/tmp/install-script.sh"
  #!/bin/bash -e
  export LANGUAGE=en_US.UTF-8
  export LANG=en_US.UTF-8
  export LC_ALL=en_US.UTF-8

  source /etc/profile

  mkdir -p /etc/apt/sources.list.d/
  cat <<-SRC > /etc/apt/sources.list.d/debian.sources
    Types: deb-src
    URIs: ${SOURCE_SRC}
    Suites: ${RELEASE}
    Components: main contrib non-free non-free-firmware
    Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
  SRC

  cat <<-SRC > /etc/apt/sources.list.d/debian-ports.sources
    Types: deb
    URIs: ${SOURCE}
    Suites: ${RELEASE}
    Components: main contrib non-free non-free-firmware
    Signed-By: /usr/share/keyrings/debian-ports-archive-keyring.gpg
  SRC

  cat <<-FSTABEOF > /etc/fstab
    UUID=${ROOTUUID}  /      ext4  defaults                      0 1
    UUID=${BOOTUUID}  /boot  ext2  defaults,sync,nosuid,noexec   0 2
    proc              /proc  proc  defaults                      0 0
    none              /var/log  tmpfs  size=30M,mode=755,gid=0,uid=0  0 0
  FSTABEOF

  echo "${TARGET}" > /etc/hostname
  echo "127.0.1.1  ${TARGET}" >> /etc/hosts

  mkdir -p /etc/systemd/network
  cat <<-NETOF > /etc/systemd/network/20-ether.network
    [Match]
    Type=ether
    [Network]
    DHCP=yes
  NETOF

  systemctl enable systemd-networkd || true
  systemctl disable networking || true

  cat <<-CONSET > /tmp/debconf.set
    console-common console-data/keymap/policy select  Select keymap from full list
    console-common console-data/keymap/full   select  us
    iperf3        iperf3/start_daemon        string  false
  CONSET
  ( export DEBIAN_FRONTEND=noninteractive; debconf-set-selections /tmp/debconf.set )

  echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
  /usr/sbin/locale-gen

  echo "root:${ROOT_PASSWORD}" | /usr/sbin/chpasswd
  echo 'RAMTMP=yes' >> /etc/default/tmpfs
  rm -f /etc/udev/rules.d/70-persistent-net.rules

  cat <<-FWCONF > /etc/fw_env.config
  # MTD device name  Device offset  Env. size  Flash sector size  Number of sectors
  /dev/mtd1         0x0000         0x1000     0x1000             1
  /dev/mtd1         0x1000         0x1000     0x1000             1
  FWCONF

  apt update || true
  apt install -f -y || true
  apt install -y ${APT_INSTALL_PACKAGES} || true

  [[ -f /root/.ssh/authorized_keys ]] || sed -i 's|#PermitRootLogin prohibit-password|PermitRootLogin yes|g' /etc/ssh/sshd_config

  update-rc.d first_boot defaults || true
  update-rc.d first_boot enable   || true

  /usr/bin/passwd -e root || true
  chmod 0770 /boot /root  || true

  apt clean
  apt-get --purge -y autoremove || true
  rm -rf /var/lib/apt/lists/* /var/tmp/*
  rm -f /tmp/debconf.set
  apt-mark minimize-manual -y || true

  rm -f /etc/ssh/ssh_host_*
  rm /tmp/install-script.sh
INSTALLEOF

chmod a+x "$TARGET/tmp/install-script.sh"
LANG=C.UTF-8 /usr/sbin/chroot "${TARGET}" /tmp/install-script.sh

sleep 1

# ==============================
# Unmount e zerofree
# ==============================
mountpoint -q "$TARGET/boot"     && /bin/umount -l "$TARGET/boot"
mountpoint -q "$TARGET/proc"     && /bin/umount "$TARGET/proc"
mountpoint -q "$TARGET/sys"      && /bin/umount "$TARGET/sys"
mountpoint -q "$TARGET/dev/pts"  && /bin/umount "$TARGET/dev/pts"
mountpoint -q "$TARGET/dev"      && /bin/umount "$TARGET/dev"
mountpoint -q "$TARGET"          && /bin/umount -l "$TARGET"

/usr/sbin/zerofree -v "$BOOTP"
/usr/sbin/zerofree -v "$ROOTP"

[[ $MAKE_RAID ]] && {
  dd if=boot-md0-raid1 of="$BOOTP" bs=1K seek=$(( BOOTSIZE / 1024 - 8 )) status=noxfer
  dd if=root-md1-raid1 of="$ROOTP" bs=1k seek=$(( ROOTSIZE / 1024 - 64)) status=noxfer
}

/sbin/losetup -d "$LOOPDEV"

# ==============================
# Compressione
# ==============================
if [[ "$DO_COMPRESS" ]]; then
  echo "Compressing Image. This can take a while."
  if command -v pigz >/dev/null 2>&1; then
    pigz "$IMAGE"
  else
    gzip "$IMAGE"
  fi
fi
