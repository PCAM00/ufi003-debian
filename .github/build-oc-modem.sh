#!/bin/bash
# ==============================================================================
#  按板子生成「带基带」boot 镜像(已带 headless GPU 内核)
#    - Image.gz + ramdisk + cmdline:从内核 release 的 boot.img 里取
#    - DTB:从内核 deb 里按板子取,另生成一份加 3 档 1.2GHz OPP 的
#    - 纯 Python 重打包(不依赖 mkbootimg;id 字段按上游算法)
#  用法:
#    BOARD=ufi003 DTB_NAME=msm8916-thwc-ufi003  bash .github/build-oc-modem.sh
#    BOARD=jz02   DTB_NAME=msm8916-thwc-jz02v10 bash .github/build-oc-modem.sh
#  产物: kernel/boot-<board>.img(原频)+ kernel/boot-<board>-oc.img(1.2GHz)
# ==============================================================================
set -e
set -o pipefail

KERNEL_TAG="${KERNEL_TAG:-kernel-gpu-1}"
BASE="${KERNEL_BASE:-https://github.com/PCAM00/ufi003-kernel/releases/download/${KERNEL_TAG}}"
BOARD="${BOARD:-ufi003}"
DTB_NAME="${DTB_NAME:-msm8916-thwc-ufi003}"
DL="${DL_PREFIX:-}"

cd "$(dirname "$0")/.."
OUT="$(pwd)/kernel"
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "==> [1/4] 下载 boot.img 与内核 deb(BOARD=$BOARD,DTB=$DTB_NAME)"
if [ -z "${DEB_NAME:-}" ]; then
    DEB_NAME=$(curl -fsSL "https://api.github.com/repos/PCAM00/ufi003-kernel/releases/tags/${KERNEL_TAG}" \
        | python3 -c "import sys,json;print(next(a['name'] for a in json.load(sys.stdin)['assets'] if a['name'].startswith('linux-image-')))")
    echo "    deb = $DEB_NAME"
fi
wget -q -O boot.img "${DL}${BASE}/boot.img"
wget -q -O k.deb   "${DL}${BASE}/${DEB_NAME}"
ls -l boot.img k.deb

echo "==> [2/4] 从 deb 提取 $DTB_NAME.dtb"
python3 - "$DTB_NAME" <<'PY'
import lzma, tarfile, io, sys
dtb = sys.argv[1]
d = open('k.deb', 'rb').read()
i = d.index(b'data.tar'); sz = int(d[i+48:i+58].strip())
with lzma.open(io.BytesIO(d[i+60:i+60+sz])) as x:
    with tarfile.open(fileobj=x, mode='r:') as t:
        for m in t.getmembers():
            if m.name.endswith('/qcom/' + dtb + '.dtb'):
                open('board.dtb', 'wb').write(t.extractfile(m).read())
                print('取到', m.name, m.size, '字节')
                break
        else:
            raise SystemExit('deb 里没找到 ' + dtb + '.dtb')
PY

echo "==> [3/4] 生成 1.2GHz DTB 并重打包两个 boot"
dtc -I dtb -O dts board.dtb -o board.dts
python3 - <<'PY'
import re
src = open('board.dts', encoding='utf-8').read()
m = re.search(r'\n(\s*)opp-998400000 \{\n\s+opp-hz = <0x00 0x3b826000>;\n(\s*)\};', src)
assert m, '没找到 opp-998400000 锚点'
ind = m.group(1)
add = ''.join(f'\n{ind}opp-{hz} {{\n{ind}\topp-hz = <0x00 0x{hz:x}>;\n{ind}}};'
              for hz in (1094400000, 1152000000, 1209600000))
open('board.dts', 'w', encoding='utf-8').write(src[:m.end()] + add + src[m.end():])
print('已插入 3 档 OPP')
PY
dtc -I dts -O dtb board.dts -o board-oc.dtb
# 注意:不能用 "xxx | grep -q"(grep -q 命中即关管道 -> 上游 SIGPIPE,pipefail 判失败)
CHECK=$(dtc -I dtb -O dts board-oc.dtb 2>/dev/null) || { echo "反编译校验失败" >&2; exit 1; }
case "$CHECK" in
    *0x48190800*) echo "校验: 1.2GHz OPP 已写入 OK" ;;
    *) echo "校验失败:新 DTB 里没有 1.2GHz OPP" >&2; exit 1 ;;
esac

python3 - <<'PY'
import struct, hashlib
d = open('boot.img', 'rb').read()
assert d[:8] == b'ANDROID!', '不是 Android boot 镜像'
ksize,kaddr,rsize,raddr,ssize,saddr,tags,page,hver,osver = struct.unpack_from('<10I', d, 8)
assert hver == 0, f'header_version={hver},只支持 v0'
def align(n): return (n + page - 1) // page * page
k = d[page:page+ksize]
r = d[page+align(ksize):page+align(ksize)+rsize]
i = k.rfind(b'\xd0\x0d\xfe\xed')
assert i > 0, 'kernel blob 里没找到 DTB'
image = k[:i]
cmd = d[64:576].rstrip(b'\0')

def pack(dtb_bytes, out):
    kb = image + dtb_bytes
    sha = hashlib.sha1()
    sha.update(kb); sha.update(struct.pack('<I', len(kb)))
    sha.update(r);  sha.update(struct.pack('<I', len(r)))
    sha.update(struct.pack('<I', 0))
    hdr = struct.pack('<8s10I16s512s', b'ANDROID!', len(kb), kaddr, len(r), raddr,
                      ssize, saddr, tags, page, hver, osver, b'', cmd.ljust(512, b'\0'))
    hdr += sha.digest() + b'\0' * 12          # id = SHA1(20B) + 12B 零
    hdr += b'\0' * (1632 - len(hdr))          # v0 头完整 1632
    o = hdr + b'\0' * (page - len(hdr))
    o += kb + b'\0' * (align(len(kb)) - len(kb))
    o += r  + b'\0' * (align(len(r)) - len(r))
    open(out, 'wb').write(o)
    print(out, len(o), '字节')
    return o

stock = pack(open('board.dtb', 'rb').read(),    'boot-stock.img')
oc    = pack(open('board-oc.dtb', 'rb').read(), 'boot-oc-modem.img')
assert len(oc) != len(stock)
print('结构校验通过')
PY

echo "==> [4/4] 拷出"
cp boot-oc-modem.img "$OUT/boot-$BOARD-oc.img"
cp boot-stock.img    "$OUT/boot-$BOARD.img"
ls -l "$OUT"/boot-"$BOARD"*.img
md5sum "$OUT"/boot-"$BOARD"*.img
echo "==> 完成: BOARD=$BOARD"
