#!/usr/bin/env python3
# NV 项读写。基于 diag-tools(https://git.abscue.de/affe_null/diag-tools,GPL-3)
# 的 diag.py;写入部分为本仓库补充(NV_WRITE_F = 39)。
#
#   diag-nv.py read <item>                 读(默认 550 = IMEI)
#   diag-nv.py write <item> <128字节hex>    写(需先 diag-spc.py 解锁)
#   diag-nv.py set-imei <15位IMEI>          读 550 -> 改 IMEI -> 写回 -> 复核
import sys
import struct
from diag import Diag

DIAG_NV_READ_F = 38
DIAG_NV_WRITE_F = 39
ITEM_IMEI = 550


def hexdump(data):
    out = []
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        h = ' '.join('%02x' % b for b in chunk)
        a = ''.join(chr(b) if 0x20 <= b <= 0x7e else '.' for b in chunk)
        out.append('%04x  %-47s  %s' % (i, h, a))
    return '\n'.join(out)


def nv_read(num):
    d = Diag()
    rsp = d.send_cmd(DIAG_NV_READ_F, data=struct.pack('<H128sH', num, b'\0' * 128, 0))
    return rsp[3:]


def nv_write(num, payload):
    payload = payload[:128].ljust(128, b'\0')
    d = Diag()
    rsp = d.send_cmd(DIAG_NV_WRITE_F, data=struct.pack('<H128sH', num, payload, 0))
    return rsp


def find_imei(payload):
    """在 128 字节里找 IMEI:优先 15 位 ASCII,其次 8 字节 BCD"""
    # ASCII:15 位数字连续出现
    for i in range(0, len(payload) - 15):
        seg = payload[i:i + 15]
        if all(0x30 <= b <= 0x39 for b in seg):
            return ('ascii', i, seg.decode())
    # BCD:8 字节,每 nibble 一位,允许 0xF 填充(通常 15 位 + 1 nibble 补 F)
    for i in range(0, len(payload) - 8):
        seg = payload[i:i + 8]
        digits = ''
        ok = True
        for b in seg:
            hi, lo = b >> 4, b & 0x0f
            if hi > 9:
                ok = False
                break
            digits += str(hi)
            if lo == 0x0f:
                break
            if lo > 9:
                ok = False
                break
            digits += str(lo)
        if ok and len(digits) == 15:
            return ('bcd', i, digits)
    return (None, -1, None)


def patch_imei(payload, imei):
    kind, off, cur = find_imei(payload)
    payload = bytearray(payload)
    if kind == 'ascii':
        payload[off:off + 15] = imei.encode()
    elif kind == 'bcd':
        b = bytearray(8)
        for i in range(15):
            d = int(imei[i])
            if i % 2 == 0:
                b[i // 2] = (d << 4) | (b[i // 2] & 0x0f)
            else:
                b[i // 2] = (b[i // 2] & 0xf0) | d
        if 15 % 2:
            b[7] = (b[7] & 0xf0) | 0x0f
        payload[off:off + 8] = bytes(b)
    else:
        raise RuntimeError('在 NV550 里没找到 IMEI 字段,不敢改(把 read 的输出发我看)')
    return bytes(payload)


def main():
    if len(sys.argv) < 2:
        print(__doc__ or '用法见文件头注释')
        return 1
    cmd = sys.argv[1]
    if cmd == 'read':
        num = int(sys.argv[2]) if len(sys.argv) > 2 else ITEM_IMEI
        data = nv_read(num)
        kind, off, imei = find_imei(data)
        print(hexdump(data))
        if imei:
            print('\n识别到 IMEI(%s,@0x%02x): %s' % (kind, off, imei))
        return 0
    if cmd == 'write':
        num = int(sys.argv[2])
        payload = bytes.fromhex(sys.argv[3])
        rsp = nv_write(num, payload)
        print('写入返回: %s' % rsp.hex())
        return 0
    if cmd == 'set-imei':
        imei = sys.argv[2]
        if len(imei) != 15 or not imei.isdigit():
            print('IMEI 必须是 15 位数字')
            return 1
        data = nv_read(ITEM_IMEI)
        new = patch_imei(data, imei)
        print('原:'); print(hexdump(data))
        print('新:'); print(hexdump(new))
        rsp = nv_write(ITEM_IMEI, new)
        print('写入返回: %s' % rsp.hex())
        back = nv_read(ITEM_IMEI)
        kind, off, got = find_imei(back)
        print('复核读回: %s' % (got or '(没识别到)'))
        return 0 if got == imei else 3
    print(__doc__ or '未知命令')
    return 1


if __name__ == '__main__':
    sys.exit(main())
