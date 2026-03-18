#!/usr/bin/env bash
set -Eeuo pipefail

ARCH=powerpc
PARALLEL=$(getconf _NPROCESSORS_ONLN)
CROSS_COMPILE=${CROSS_COMPILE:-powerpc-linux-gnu-}

OURPATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LINUX_DIR="${OURPATH}/linux"
LINUX_VER="${1:-v6.19-rc3}"
LINUX_LOCAL="${OURPATH}/cached-linux"
LINUX_GIT="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"

DTS_DIR="${OURPATH}/dts"
DTS_MBL="${DTS_DIR}/wd-mybooklive.dts"
DTB_MBL="${DTS_DIR}/wd-mybooklive.dtb"

KERNEL_OUT="${KERNEL_OUT:-$OURPATH}"
ROOTFS_DIR="${ROOTFS_DIR:-$OURPATH/rootfs}"

echo "[INFO] linux dir: $LINUX_DIR"
rm -rf "$LINUX_DIR"
if [[ -d "$LINUX_LOCAL" ]]; then
  git clone --local "$LINUX_LOCAL" "$LINUX_DIR"
else
  git clone "$LINUX_GIT" "$LINUX_DIR"
fi

if [[ -n "$LINUX_VER" ]]; then
  (cd "$LINUX_DIR"; git checkout -b mbl-dev "$LINUX_VER")
fi

# Overlay/Patch opzionali
if [[ -d "$OURPATH/overlay/kernel/" ]]; then
  echo "[INFO] Applying kernel overlay"
  rsync -a --exclude '.config' "$OURPATH/overlay/kernel/" "$LINUX_DIR/"
fi
if [[ -d "$OURPATH/overlay/kernel-${LINUX_VER%%.*}/" ]]; then
  echo "[INFO] Applying version-specific kernel overlay"
  rsync -a --exclude '.config' "$OURPATH/overlay/kernel-${LINUX_VER%%.*}/" "$LINUX_DIR/"
fi
if [[ -d "$OURPATH/patches/kernel/" ]]; then
  for p in "$OURPATH/patches/kernel/"*.patch; do
    [[ -f "$p" ]] || continue
    echo "[INFO] Applying patch $p"
    (cd "$LINUX_DIR"; git am "$p")
  done
fi

# DTB MBL (32KiB)
cpp -nostdinc -x assembler-with-cpp \
   -I "$DTS_DIR" \
   -I "$LINUX_DIR/include/" \
   -undef -D__DTS__ "$DTS_MBL" -o "${DTB_MBL}.tmp"
dtc -O dtb -i "$DTS_DIR" -S 32768 -o "$DTB_MBL" "${DTB_MBL}.tmp"

echo "[INFO] Using apm82181_mbl_defconfig"
(cd "$LINUX_DIR"; rm -f .config; make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" apm82181_mbl_defconfig)

# Enforce simboli chiave (console seriale, SATA DWC, EMAC, early printk)
KCFG(){ "$LINUX_DIR/scripts/config" --file "$LINUX_DIR/.config" "$@"; }
KCFG --enable CONFIG_TTY
KCFG --enable CONFIG_VT
KCFG --enable CONFIG_VT_CONSOLE
KCFG --enable CONFIG_SERIAL_8250
KCFG --enable CONFIG_SERIAL_8250_CONSOLE
KCFG --enable CONFIG_SERIAL_8250_OF
KCFG --enable CONFIG_SERIAL_OF_PLATFORM
KCFG --enable CONFIG_EARLY_PRINTK
KCFG --enable CONFIG_PPC_EARLY_DEBUG
KCFG --enable CONFIG_PPC_EARLY_DEBUG_44x
KCFG --enable CONFIG_DEVTMPFS
KCFG --enable CONFIG_DEVTMPFS_MOUNT
KCFG --enable CONFIG_ATA
KCFG --enable CONFIG_SATA_DWC_OLD || true
KCFG --enable CONFIG_SATA_DWC || true
KCFG --enable CONFIG_SCSI
KCFG --enable CONFIG_BLK_DEV_SD
KCFG --enable CONFIG_EXT4_FS
KCFG --enable CONFIG_CRC32C_GENERIC
KCFG --enable CONFIG_NET
KCFG --enable CONFIG_INET
KCFG --disable CONFIG_IPV6
KCFG --enable CONFIG_IBM_EMAC
KCFG --enable CONFIG_MII
KCFG --enable CONFIG_FIXED_PHY
KCFG --disable CONFIG_MODULES

make -C "$LINUX_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
make -C "$LINUX_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$PARALLEL" zImage dtbs

cp -v "$LINUX_DIR/arch/powerpc/boot/zImage" "$KERNEL_OUT/"
cp -v "$DTB_MBL" "$KERNEL_OUT/apollo3g.dtb"

# Crea uImage legacy da zImage
mkimage -A ppc -O linux -T kernel -C none \
  -a 0x00000000 -e 0x00000000 \
  -n "Linux-PPC" \
  -d "$LINUX_DIR/arch/powerpc/boot/zImage" \
  "$KERNEL_OUT/uImage"

echo "[OK] Kernel artifacts ready in: $KERNEL_OUT"
