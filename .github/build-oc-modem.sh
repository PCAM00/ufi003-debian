#!/bin/bash
# ==============================================================================
#  打一个「带基带 + 1.2GHz」的 boot 镜像:
#    官方 boot.img(带基带)的 kernel(Image.gz)+ ramdisk + cmdline 不变,
#    只把追加的 DTB 换成"官方 modem DTB + 3 档 1.2GHz OPP"的新 DTB。
#  产物: kernel/boot-oc-modem.img
# ==============================================================================
set -e
set -o pipefail

KERNEL_TAG=6.12.49-1
BASE="https://github.com/KyonLi/ufi003-kernel/releases/download/${KERNEL_TAG}"
BOOT_URL="${BASE}/boot.img"
DEB_URL="${BASE}/linux-image-6.12.49-msm8916-g93a71ee9468d_6.12.49-g93a71ee9468d-1_arm64.deb"
CMD_LINE="earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e console=ttyMSM0,115200 no_framebuffer=true rw"

cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "==> [1/5] 下载 boot.img(带基带)与内核 deb"
wget -q -O boot.img "$BOOT_URL"
wget -q -O k.deb "$DEB_URL"

echo "==> [2/5] 解析 boot.img(header v0,纯 Python,不依赖 unpack_bootimg)"
python3 - <<'PY'
import struct, os
d = open('boot.img','rb').read()
assert d[:8] == b'ANDROID!', '不是 Android boot 镜像'
ksize, kaddr, rsize, raddr, ssize, saddr, tags, page, hver, osver = struct.unpack_from('<10I', d, 8)
assert hver == 0, f'header_version={hver},脚本只支持 v0'
def align(n): return (n + page - 1) // page * page
koff = page
roff = page + align(ksize)
open('u-kernel', 'wb').write(d[koff:koff+ksize])
open('u-ramdisk', 'wb').write(d[roff:roff+rsize])
print(f'    kernel {ksize}B, ramdisk {rsize}B, page {page}, hver {hver}')
PY

echo "==> [3/5] 从内核 deb 取官方 modem DTB,插入 1.2GHz OPP"
dpkg-deb -x k.deb d
cp d/usr/lib/linux-image-*/qcom/msm8916-thwc-ufi003.dtb ./modem.dtb
echo "    原 DTB: $(stat -c%s modem.dtb) 字节"
dtc -I dtb -O dts modem.dtb -o modem.dts
python3 - <<'PY'
import re
src = open('modem.dts', encoding='utf-8').read()
m = re.search(r'\n(\s*)opp-998400000 \{\n\s+opp-hz = <0x00 0x3b826000>;\n(\s*)\};', src)
assert m, '没找到 opp-998400000 锚点'
ind = m.group(1)
add = ''
for hz in (1094400000, 1152000000, 1209600000):
    add += f'\n{ind}opp-{hz} {{\n{ind}\topp-hz = <0x00 0x{hz:x}>;\n{ind}}};'
src = src[:m.end()] + add + src[m.end():]
open('modem.dts', 'w', encoding='utf-8').write(src)
PY
dtc -I dts -O dtb modem.dts -o modem-oc.dtb
echo "    新 DTB: $(stat -c%s modem-oc.dtb) 字节"
# 校验:新 DTB 里应该有 1209600000
if ! dtc -I dtb -O dts modem-oc.dtb 2>/dev/null | grep -q "0x48190800"; then
    echo "!! 校验失败:新 DTB 里没有 1.2GHz OPP" >&2; exit 1
fi
echo "    校验: 1.2GHz OPP 已写入 ✓"

echo "==> [4/5] 剥掉 kernel blob 里旧 DTB,接上新 DTB"
python3 - <<'PY'
d = open('u-kernel','rb').read()
i = d.rfind(b'\xd0\x0d\xfe\xed')
assert i > 0, 'kernel blob 里没找到 DTB'
open('Image.gz','wb').write(d[:i])
print(f'    Image.gz {i} 字节, 剥掉的旧 DTB {len(d)-i} 字节')
PY
cat Image.gz modem-oc.dtb > kernel-dtb

echo "==> [5/5] mkbootimg 打新镜像"
mkbootimg \
    --base 0x80000000 \
    --kernel_offset 0x00080000 \
    --ramdisk_offset 0x02000000 \
    --tags_offset 0x01e00000 \
    --pagesize 2048 \
    --second_offset 0x00f00000 \
    --ramdisk u-ramdisk \
    --cmdline "$CMD_LINE" \
    --kernel kernel-dtb \
    --output ../kernel/boot-oc-modem.img

ls -l ../kernel/boot-oc-modem.img
echo "==> boot-oc-modem.img 完成"
