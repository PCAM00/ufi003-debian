#!/bin/bash
# ==============================================================================
#  UFI003 Debian rootfs 构建(in CI / 本地 root 环境运行)
#    - 发行版 : Debian 13 trixie, arm64
#    - apt 源 : 仅阿里云
#    - 变体   : VARIANT=nomodem(默认:去 modem/GPS + 1.2GHz)
#               VARIANT=modem  (带基带,rootfs 配套 boot-modem / boot-oc-modem 镜像)
#    - 定制   : 见 ../overlay/ 与 chroot.sh
#  用法: VARIANT=nomodem|modem ./build.sh
#  同一工作目录可连跑两个变体:debootstrap 只做一次(存 debian-base),之后每次 cp -a 再定制
# ==============================================================================
set -e
set -o pipefail

VARIANT="${VARIANT:-nomodem}"
DIST=trixie
# 构建期用 Debian 官方源:CI runner 在海外,debootstrap 是"一个包一次 wget",
# 从阿里云拉会慢到离谱。★ 成品系统里的 apt 源仍然是「只有阿里云」,
# 由 overlay/etc/apt/sources.list 覆盖,与这里无关。
BOOTSTRAP_MIRROR="http://deb.debian.org/debian"

KERNEL_TAG=6.12.49-1
KERNEL_BASE="https://github.com/KyonLi/ufi003-kernel/releases/download/${KERNEL_TAG}"
BOOT_OC_URL="${KERNEL_BASE}/boot-no-modem-oc.img"   # 无基带 + 1.2GHz
BOOT_MODEM_URL="${KERNEL_BASE}/boot.img"            # 带基带(原频;1.2GHz 版由 .github/build-oc-modem.sh 另打)
K_IMAGE_DEB_URL="${KERNEL_BASE}/linux-image-6.12.49-msm8916-g93a71ee9468d_6.12.49-g93a71ee9468d-1_arm64.deb"
K_DEV_URL="https://github.com/KyonLi/ufi003-kernel/releases/tag/${KERNEL_TAG}"
UUID=62ae670d-01b7-4c7d-8e72-60bcd00410b7

BASE="debian-base"            # 只做一次 debootstrap 的干净底
WORK="debian-${VARIANT}"      # 本次定制的工作目录
IMG_OUT="rootfs.img"          # nomodem 保持原名
if [ "$VARIANT" = "modem" ]; then IMG_OUT="rootfs-modem.img"; fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

cd "$(dirname "$0")"

echo "=============================================================="
echo "[1/7] 内核 boot 镜像与内核 deb"
echo "=============================================================="
mkdir -p ../kernel
rm -rf build "${WORK}" "${IMG_OUT}" debian-ufi003.img
if [ "$VARIANT" = "modem" ]; then
    wget -O ../kernel/boot-modem.img "$BOOT_MODEM_URL"
else
    wget -O ../kernel/boot.img             "$BOOT_OC_URL"
    wget -O ../kernel/boot-no-modem-oc.img "$BOOT_OC_URL"
fi
if [ ! -f ../kernel/linux-image-*.deb ]; then
    wget -P ../kernel "$K_IMAGE_DEB_URL"
fi

echo "=============================================================="
echo "[2/7] 项目自带 deb"
echo "=============================================================="
if [ "$VARIANT" = "nomodem" ]; then
    bash ../deb-pkgs/repack-nomodem.sh ../deb-pkgs
fi

echo "=============================================================="
echo "[3/7] debootstrap $DIST/arm64(只做一次,存 ${BASE})"
echo "=============================================================="
# debootstrap 必须能校验 Release 签名,否则基础系统是"未经验证"下载来的
KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
if [ ! -s "$KEYRING" ]; then
    echo "!! 缺少 $KEYRING,debootstrap 无法校验签名,拒绝构建" >&2
    exit 1
fi
if [ ! -x "${BASE}/usr/bin/apt" ]; then
    rm -rf "${BASE}"
    mkdir -p "${BASE}"
    debootstrap --arch=arm64 --foreign "$DIST" "${BASE}" "$BOOTSTRAP_MIRROR" 2>&1 | tee /tmp/debootstrap.log
    if grep -q "Cannot check Release signature" /tmp/debootstrap.log; then
        echo "!! debootstrap 未能校验 Release 签名,拒绝继续" >&2
        exit 1
    fi
    LANG=C LANGUAGE=C LC_ALL=C chroot "${BASE}" /debootstrap/debootstrap --second-stage
fi

echo "=============================================================="
echo "[4/7] 复制干净底 + 塞入 deb / overlay"
echo "=============================================================="
rm -rf "${WORK}"
cp -a "${BASE}" "${WORK}"
if [ "$VARIANT" = "nomodem" ]; then
    cp ../deb-pkgs/out/*.deb "${WORK}/tmp/"
else
    cp ../deb-pkgs/firmware-ufi003.deb ../deb-pkgs/openstick-utils-all.deb "${WORK}/tmp/"
fi
cp ../kernel/linux-image-*.deb chroot.sh "${WORK}/tmp/"
rsync -a --chown=root:root ../overlay/ "${WORK}/"
chmod 600 "${WORK}"/etc/NetworkManager/system-connections/*.nmconnection
chmod 755 "${WORK}/root/usb-mode.sh" "${WORK}/root/imei.sh" \
          "${WORK}/usr/bin/rpmsgexport" "${WORK}/usr/local/share/diag-tools/"*.py
chmod 700 "${WORK}/root"

echo "=============================================================="
echo "[5/7] chroot 内定制(VARIANT=${VARIANT})"
echo "=============================================================="
for d in proc dev dev/pts sys; do mount --bind "/$d" "${WORK}/$d"; done
trap 'for d in proc dev/pts dev sys; do umount "${WORK}/$d" 2>/dev/null || true; done' EXIT
VARIANT="$VARIANT" LANG=C LANGUAGE=C LC_ALL=C chroot "${WORK}" /tmp/chroot.sh
for d in proc dev/pts dev sys; do umount "${WORK}/$d"; done
trap - EXIT

echo "=============================================================="
echo "[6/7] 收集构建信息"
echo "=============================================================="
cp "${WORK}/etc/debian_version" ./
mv -f "${WORK}/tmp/info.md"    "./info-${VARIANT}.md"
mv -f "${WORK}/tmp/verify.txt" "./verify-${VARIANT}.txt"
echo >> "info-${VARIANT}.md"
echo "🔗 [linux-headers & linux-libc-dev]($K_DEV_URL)" >> "info-${VARIANT}.md"
rm -rf "${WORK}"/tmp/* "${WORK}/root/.bash_history"

echo "=============================================================="
echo "[7/7] 生成 ext4 / sparse 镜像"
echo "=============================================================="
SIZE=$(( $(du -ms "${WORK}" | cut -f1) + 100 ))
echo "    ${WORK} $(du -ms "${WORK}" | cut -f1)MB -> 镜像 ${SIZE}MB"
dd if=/dev/zero of=debian-ufi003.img bs=1M count="$SIZE"
mkfs.ext4 -q -L rootfs -U "$UUID" debian-ufi003.img
mkdir -p build
mount debian-ufi003.img build
rsync -aH "${WORK}/" build/
umount build
img2simg debian-ufi003.img "${IMG_OUT}"
rm -rf debian-ufi003.img build
ls -lh "${IMG_OUT}"
echo "==> 构建完成(VARIANT=${VARIANT})"
