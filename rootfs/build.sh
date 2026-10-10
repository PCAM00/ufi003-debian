#!/bin/bash
# ==============================================================================
#  UFI003 Debian rootfs 构建(in CI / 本地 root 环境运行)
#    - 发行版   : Debian 13 trixie,arm64
#    - apt 源   : 仅阿里云
#    - 内核     : boot-no-modem-oc.img(去 modem/GPS + 超频 1.2GHz)
#    - 定制     : 见 ../overlay/ 与 chroot.sh
# ==============================================================================
set -e

DIST=trixie
MIRROR="http://mirrors.aliyun.com/debian"

KERNEL_TAG=6.12.49-1
KERNEL_BASE="https://github.com/KyonLi/ufi003-kernel/releases/download/${KERNEL_TAG}"
BOOT_OC_URL="${KERNEL_BASE}/boot-no-modem-oc.img"
K_IMAGE_DEB_URL="${KERNEL_BASE}/linux-image-6.12.49-msm8916-g93a71ee9468d_6.12.49-g93a71ee9468d-1_arm64.deb"
K_DEV_URL="https://github.com/KyonLi/ufi003-kernel/releases/tag/${KERNEL_TAG}"
UUID=62ae670d-01b7-4c7d-8e72-60bcd00410b7

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

cd "$(dirname "$0")"

echo "=============================================================="
echo "[1/7] 下载内核:去 modem + 超频 1.2GHz"
echo "=============================================================="
mkdir -p ../kernel
rm -rf ../kernel/* >/dev/null 2>&1 || true
wget -O ../kernel/boot.img             "$BOOT_OC_URL"
wget -O ../kernel/boot-no-modem-oc.img "$BOOT_OC_URL"
wget -P ../kernel "$K_IMAGE_DEB_URL"

echo "=============================================================="
echo "[2/7] 精简项目自带 deb(去 modem/GPS 固件、去 modemmanager 依赖)"
echo "=============================================================="
bash ../deb-pkgs/repack-nomodem.sh ../deb-pkgs

echo "=============================================================="
echo "[3/7] debootstrap $DIST/arm64  ($MIRROR)"
echo "=============================================================="
rm -rf debian build debian-ufi003.img rootfs.img
mkdir -p debian
debootstrap --arch=arm64 --foreign "$DIST" debian "$MIRROR"
LANG=C LANGUAGE=C LC_ALL=C chroot debian /debootstrap/debootstrap --second-stage

echo "=============================================================="
echo "[4/7] 放入内核 deb / 项目 deb / overlay 覆盖层"
echo "=============================================================="
cp ../deb-pkgs/out/*.deb ../kernel/linux-image-*.deb chroot.sh debian/tmp/
mv -f ../kernel/linux-image-*.deb debian/tmp/
rsync -a --chown=root:root ../overlay/ debian/
chmod 600 debian/etc/NetworkManager/system-connections/*.nmconnection
chmod 755 debian/root/usb-mode.sh debian/usr/local/sbin/wifi-default-off.sh
chmod 700 debian/root

echo "=============================================================="
echo "[5/7] chroot 内定制"
echo "=============================================================="
for d in proc dev dev/pts sys; do mount --bind "/$d" "debian/$d"; done
trap 'for d in proc dev/pts dev sys; do umount "debian/$d" 2>/dev/null || true; done' EXIT
LANG=C LANGUAGE=C LC_ALL=C chroot debian /tmp/chroot.sh
for d in proc dev/pts dev sys; do umount "debian/$d"; done
trap - EXIT

echo "=============================================================="
echo "[6/7] 收集构建信息"
echo "=============================================================="
cp debian/etc/debian_version ./
mv -f debian/tmp/info.md ./
mv -f debian/tmp/verify.txt ./
echo >> info.md
echo "🔗 [linux-headers & linux-libc-dev]($K_DEV_URL)" >> info.md
rm -rf debian/tmp/* debian/root/.bash_history

echo "=============================================================="
echo "[7/7] 生成 ext4 / sparse 镜像"
echo "=============================================================="
SIZE=$(( $(du -ms debian | cut -f1) + 100 ))
echo "    rootfs 目录 $(du -ms debian | cut -f1)MB -> 镜像 ${SIZE}MB"
dd if=/dev/zero of=debian-ufi003.img bs=1M count="$SIZE"
mkfs.ext4 -q -L rootfs -U "$UUID" debian-ufi003.img
mkdir -p build
mount debian-ufi003.img build
rsync -aH debian/ build/
umount build
img2simg debian-ufi003.img rootfs.img
rm -rf debian-ufi003.img debian build
ls -lh rootfs.img
echo "==> 构建完成"
