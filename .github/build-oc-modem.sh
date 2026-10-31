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
NOMODEM="${NOMODEM:-0}"      # 1 = 去掉基带:删掉 DTB 里的 mpss 保留内存区
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
NOMODEM="$NOMODEM" python3 - <<'PY'
import os, re
nomodem = os.environ.get('NOMODEM', '0') == '1'
src = open('board.dts', encoding='utf-8').read()

def drop_node(text, name):
    """删除 name { ... } 整个块(按花括号配对)"""
    m = re.search(r'\n(\s*)' + re.escape(name) + r' \{', text)
    if not m:
        return text, False
    i = text.index('{', m.start())
    depth = 0
    for j in range(i, len(text)):
        if text[j] == '{': depth += 1
        elif text[j] == '}':
            depth -= 1
            if depth == 0:
                # 连同前面的空白和后面的分号一起删
                end = j + 1
                if end < len(text) and text[end] == ';': end += 1
                while end < len(text) and text[end] == '\n': end += 1
                return text[:m.start()] + '\n' + text[end:], True
    return text, False

if nomodem:
    # 去基带的关键:删掉 mpss 保留内存区(modem remoteproc 会 probe 失败)
    for node in ('mpss@86800000', 'mpss@0'):
        src, ok = drop_node(src, node)
        print(f'  去基带: {"已删除 " + node if ok else node + " 不存在"}')

# 加 3 档 OPP(1.2GHz)——幂等:若已存在就跳过
if 'opp-1209600000' in src:
    print('DTB 里已有 1.2GHz OPP,跳过插入')
else:
    m = re.search(r'\n(\s*)opp-998400000 \{\n\s+opp-hz = <0x00 0x3b826000>;\n(\s*)\};', src)
    assert m, '没找到 opp-998400000 锚点'
    ind = m.group(1)
    add = ''.join(f'\n{ind}opp-{hz} {{\n{ind}\topp-hz = <0x00 0x{hz:x}>;\n{ind}}};'
                  for hz in (1094400000, 1152000000, 1209600000))
    src = src[:m.end()] + add + src[m.end():]
    print('已插入 3 档 OPP')
open('board.dts', 'w', encoding='utf-8').write(src)
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
assert oc != stock, 'oc 与原频镜像内容相同,OPP 没生效'
# 按内容校验(不能按大小:去基带删节点会抵消加 OPP 带来的增长)
OPP_MARK = bytes.fromhex('48190800')      # 1209600000 的低 4 字节
assert OPP_MARK in oc,    'oc 镜像里没有 1.2GHz OPP'
assert OPP_MARK not in stock, '原频镜像里不该有 1.2GHz OPP'
print('结构校验通过(OPP 标记已确认)')
PY

echo "==> [4/4] 拷出"
SUF="$BOARD"; [ "$NOMODEM" = "1" ] && SUF="$BOARD-nomodem"
cp boot-oc-modem.img "$OUT/boot-$SUF-oc.img"
cp boot-stock.img    "$OUT/boot-$SUF.img"
ls -l "$OUT"/boot-"$SUF"*.img
md5sum "$OUT"/boot-"$SUF"*.img
echo "==> 完成: BOARD=$BOARD NOMODEM=$NOMODEM"
