#!/bin/bash
# ==============================================================================
#  打一个「带基带 + 1.2GHz」的 boot 镜像
#    官方 boot.img(带基带)的 kernel(Image.gz)+ ramdisk + cmdline 不变,
#    只把追加的 DTB 换成「官方 modem DTB + 3 档 1.2GHz OPP」的新 DTB。
#  依赖最小化: wget + python3 + dtc(deb 提取与 boot 重打包都是纯 Python,
#  不依赖 dpkg-deb / mkbootimg,避开各发行版 mkbootimg 参数差异)。
#  产物: kernel/boot-oc-modem.img
#  本地调试: DL_PREFIX=https://ghfast.top/ bash .github/build-oc-modem.sh
# ==============================================================================
set -e
set -o pipefail

KERNEL_TAG=6.12.49-1
BASE="https://github.com/KyonLi/ufi003-kernel/releases/download/${KERNEL_TAG}"
BOOT_URL="${DL_PREFIX:-}${BASE}/boot.img"
DEB_URL="${DL_PREFIX:-}${BASE}/linux-image-6.12.49-msm8916-g93a71ee9468d_6.12.49-g93a71ee9468d-1_arm64.deb"

cd "$(dirname "$0")/.."
OUT="$(pwd)/kernel"          # 输出目录用绝对路径(WORK 在 /tmp,../kernel 会指错)
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "==> [1/4] 下载 boot.img + 内核 deb"
wget -q -O boot.img "$BOOT_URL"
wget -q -O k.deb   "$DEB_URL"
ls -l boot.img k.deb

echo "==> [2/4] 从 deb 取 modem DTB(纯 Python),dtc 加 1.2GHz OPP"
python3 - <<'PY'
import lzma, tarfile, io
d = open('k.deb','rb').read()
i = d.index(b'data.tar')
sz = int(d[i+48:i+58].strip())
with lzma.open(io.BytesIO(d[i+60:i+60+sz])) as x:
    with tarfile.open(fileobj=x, mode='r:') as t:
        for m in t.getmembers():
            if m.name.endswith('/qcom/msm8916-thwc-ufi003.dtb'):
                open('modem.dtb','wb').write(t.extractfile(m).read())
                print('取到', m.name, m.size, '字节')
                break
        else:
            raise SystemExit('deb 里没找到 thwc-ufi003.dtb')
PY
dtc -I dtb -O dts modem.dtb -o modem.dts
python3 - <<'PY'
import re
src = open('modem.dts', encoding='utf-8').read()
m = re.search(r'\n(\s*)opp-998400000 \{\n\s+opp-hz = <0x00 0x3b826000>;\n(\s*)\};', src)
assert m, '没找到 opp-998400000 锚点'
ind = m.group(1)
add = ''.join(f'\n{ind}opp-{hz} {{\n{ind}\topp-hz = <0x00 0x{hz:x}>;\n{ind}}};'
              for hz in (1094400000, 1152000000, 1209600000))
open('modem.dts', 'w', encoding='utf-8').write(src[:m.end()] + add + src[m.end():])
print('已插入 3 档 OPP')
PY
dtc -I dts -O dtb modem.dts -o modem-oc.dtb
# 注意:不能用 `dtc ... | grep -q` + pipefail —— grep -q 提前关管道会让 dtc 吃 SIGPIPE(141),
# pipefail 会把整条管道判为失败
CHECK=$(dtc -I dtb -O dts modem-oc.dtb 2>/dev/null) || { echo "反编译校验失败" >&2; exit 1; }
if ! printf '%s' "$CHECK" | grep -q "0x48190800"; then
    echo "校验失败:新 DTB 里没有 1.2GHz OPP" >&2; exit 1
fi
echo "校验: 1.2GHz OPP 已写入 OK"

echo "==> [3/4] 纯 Python 重打包(换 DTB,保留 kernel/ramdisk/cmdline)"
python3 - <<'PY'
import struct
d = open('boot.img','rb').read()
assert d[:8] == b'ANDROID!', '不是 Android boot 镜像'
ksize,kaddr,rsize,raddr,ssize,saddr,tags,page,hver,osver = struct.unpack_from('<10I', d, 8)
assert hver == 0, f'header_version={hver},只支持 v0'
print(f'原镜像: kernel={ksize} ramdisk={rsize} page={page} hver={hver}')

def align(n): return (n + page - 1) // page * page

k = d[page:page+ksize]
r = d[page+align(ksize):page+align(ksize)+rsize]
i = k.rfind(b'\xd0\x0d\xfe\xed')
assert i > 0, 'kernel blob 里没找到 DTB'
image_gz = k[:i]
new_dtb = open('modem-oc.dtb','rb').read()
kernel_blob = image_gz + new_dtb

# 与上游 mkbootimg 相同的参数:
#   --base 0x80000000 --kernel_offset 0x00080000 --ramdisk_offset 0x02000000
#   --tags_offset 0x01e00000 --second_offset 0x00f00000 --pagesize 2048
# id 字段 = sha1(kernel,ksize,ramdisk,rsize,second,ssize) 前 20 字节 + 12 字节补零
import hashlib
cmd = b'earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e console=ttyMSM0,115200 no_framebuffer=true rw'
name = b''
sha = hashlib.sha1()
sha.update(kernel_blob); sha.update(struct.pack('<I', len(kernel_blob)))
sha.update(r); sha.update(struct.pack('<I', len(r)))
sha.update(struct.pack('<I', 0))
img_id = sha.digest() + b'\0' * 12
hdr = struct.pack('<8s10I16s512s', b'ANDROID!',
    len(kernel_blob), 0x80008000, len(r), 0x82000000, 0, 0x80f00000, 0x81e00000,
    page, 0, 0, name, cmd.ljust(512, b'\0'))
# v0 完整头 = 576 + id(32) + extra_cmdline(1024) = 1632,与 mkbootimg 一致
hdr += img_id
hdr += b'\0' * (1632 - len(hdr))

out = hdr
out += b'\0' * (page - len(out))          # 补到 page(2048)
out += kernel_blob
out += b'\0' * (align(len(kernel_blob)) - len(kernel_blob))
out += r
out += b'\0' * (align(len(r)) - len(r))
open('boot-oc-modem.img','wb').write(out)
print('新镜像:', len(out), '字节')

# 回读校验
d2 = open('boot-oc-modem.img','rb').read()
k2, r2 = struct.unpack_from('<2I', d2, 8)
print(f'回读: kernel_size={k2} kernel_addr={r2:#x} hver={struct.unpack_from("<I", d2, 40)[0]}')
assert d2 == out
assert new_dtb in d2, '新 DTB 没进镜像'
assert d2[page:page+len(kernel_blob)] == kernel_blob, 'kernel blob 位置/内容不对'
assert d2[page+align(len(kernel_blob)):page+align(len(kernel_blob))+len(r)] == r, 'ramdisk 位置/内容不对'
print('结构校验通过')
PY

echo "==> [4/4] 拷出"
cp boot-oc-modem.img "$OUT/boot-oc-modem.img"
ls -l "$OUT/boot-oc-modem.img"
md5sum "$OUT/boot-oc-modem.img"
echo "==> boot-oc-modem.img 完成"
