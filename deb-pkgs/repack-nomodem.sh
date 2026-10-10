#!/bin/bash
# ==============================================================================
#  精简项目自带的两个 deb(不动原文件,产物放 deb-pkgs/out/)
#    1) firmware-ufi003        : 删掉 modem / GPS / ISDB-T / DRM 等用不到的固件
#                                (wcnss + wlan/prima 即 WiFi/BT 固件保留)
#    2) openstick-utils-all    : 去掉对 modemmanager 的依赖(不插卡)
#                                去掉换 SIM 用的 sim-changer 服务
#  用法: repack-nomodem.sh [deb-pkgs 目录]
# ==============================================================================
set -e

SRC="$(cd "${1:-$(dirname "$0")}" && pwd)"
OUT="$SRC/out"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ "$(id -u)" -ne 0 ]; then
    echo "repack-nomodem.sh: 建议以 root 运行(否则 deb 内文件属主可能不对,用 --root-owner-group 兜底)" >&2
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> 精简 firmware-ufi003"
dpkg-deb -R "$SRC/firmware-ufi003.deb" "$WORK/fw"
FW="$WORK/fw/usr/lib/firmware"
( cd "$FW" && rm -rf modem.* mba.mbn modem_pr isdbtmm.* nfc_test.bin )
echo -n "    删除后 /usr/lib/firmware 剩余: "
ls -1 "$FW" | tr '\n' ' '
echo
dpkg-deb -b --root-owner-group "$WORK/fw" "$OUT/firmware-ufi003-nomodem.deb"

echo "==> 精简 openstick-utils-all"
dpkg-deb -R "$SRC/openstick-utils-all.deb" "$WORK/osu"
# 去掉 modemmanager 依赖(不插卡,用不上 ModemManager)
sed -i 's/, *modemmanager//' "$WORK/osu/DEBIAN/control"
echo "    Depends: $(grep '^Depends:' "$WORK/osu/DEBIAN/control")"
# 换 SIM 卡的服务一并去掉
rm -f "$WORK/osu/usr/lib/systemd/system/openstick-sim-changer.service" \
      "$WORK/osu/usr/sbin/openstick-sim-changer.sh"
dpkg-deb -b --root-owner-group "$WORK/osu" "$OUT/openstick-utils-nomodem.deb"

echo "==> 产物"
ls -lh "$OUT"
