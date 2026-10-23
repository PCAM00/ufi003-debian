#!/usr/bin/env python3
# ==============================================================================
#  nasdump —— 抓 modem 的 DIAG 流,用来验证 IMEI(不需要空口/SDR)
# ------------------------------------------------------------------------------
#  原理:diag-router 把 modem 的 DIAG 通道接到抽象 unix socket;
#        ① 打开调制解调器调试消息全量 mask -> modem 会把它自己认为的
#           IMEI/附着过程打印出来(多数固件有 "IMEI:" / "attach" 之类)
#        ② 同时在原始字节流里搜 LTE NAS 消息(07 41 = Attach Request,
#           07 48 = TAU Request),找到 EPS mobile identity(IE 0x49,
#           identity type 3 = IMEISV)并按 3GPP 24.301 解出 16 位 IMEISV
#
#  用法(需 root、diag-router 在跑、modem 已加载):
#      nasdump.py                 # 摘要:只显示含关键字的行 + 解出的 IMEISV
#      nasdump.py --all           # 显示所有调试消息(噪音大)
#      nasdump.py --raw           # 只打印原始帧 hex(供离线分析/贴日志)
#      nasdump.py -o /root/cap.log # 同时写文件
#      Ctrl-C 结束
#
#  典型用法:插正规卡 -> 拨号/触发附着 -> 运行本脚本 -> 看到 IMEISV 与
#            imei.sh get 一致 = 网络收到的就是这个号
# ==============================================================================
import os
import struct
import sys
import time

TOOLS = os.environ.get('DIAG_TOOLS', '/usr/local/share/diag-tools')
sys.path.insert(0, TOOLS)

try:
    from diag import Diag
except ImportError:
    print(f'找不到 {TOOLS}/diag.py(这版固件没带 diag-tools?)', file=sys.stderr)
    sys.exit(2)

# ---- DIAG 命令号 -----------------------------------------------------------
DIAG_CMD_LOG_F = 0x10          # 调制解调器日志包
DIAG_EXT_MSG_F = 121
DIAG_EXT_MSG_CONFIG_F = 125
MSG_EXT_SUBCMD_SET_ALL_RT_MASKS = 5

# 子系统名(只列常用的,其余显示编号)
SUBSYS = {
    7: 'DIAG', 8: 'DSM', 9: 'FS', 10: 'HS', 11: 'MDSP', 12: 'QDSP', 13: 'REX',
    14: 'RF', 15: 'SD', 16: 'SIO', 5000: 'DS', 5025: 'DS_3GPP', 5026: 'DS_LTE',
    3006: 'NAS_CNM', 3007: 'NAS_MM', 3010: 'NAS_REG', 3011: 'NAS_SM',
    9500: 'LTE', 9509: 'LTE_ML1', 1000: '1X', 2000: 'HDR',
}

# 关键字:命中就打印(摘要模式)
KW = ('imei', 'imeisv', 'attach', 'emm', 'tau ', 'tmsi', 'imsi', 'identity',
      'equipment', 'esn', 'meid')

ARG_RAW = '--raw' in sys.argv
ARG_ALL = '--all' in sys.argv
OUT = None
if '-o' in sys.argv:
    OUT = sys.argv[sys.argv.index('-o') + 1]

log = open(OUT, 'a', buffering=1) if OUT else None


def out(line):
    print(line)
    if log:
        log.write(line + '\n')


# ---- IMEISV / NAS 解析 ------------------------------------------------------
def decode_eps_mobile_identity(val):
    """3GPP 24.301 §9.9.3.12:E  PS mobile identity
    octet1: bits1-3 = 类型(1=IMSI,2=IMEI,3=IMEISV), bit4 = odd, bits5-8 = 第 1 位数字
    之后每字节两个数字,低半字节在先,0xF 结束
    """
    idtype = val[0] & 0x07
    digits = str((val[0] >> 4) & 0x0f)
    for b in val[1:]:
        lo, hi = b & 0x0f, (b >> 4) & 0x0f
        if lo == 0x0f:
            break
        digits += str(lo)
        if hi == 0x0f:
            break
        digits += str(hi)
    return idtype, digits


def try_parse_nas(data, tag=''):
    """在 data 里找 LTE NAS 消息,解 EPS mobile identity(IMEISV)"""
    hits = []
    # 0x41 Attach Req / 0x48 TAU Req / 0x42 Attach Acc / 0x43 Attach Cpl
    # 0x55 Identity Request / 0x56 Identity Response <= IMEISV 常在响应里
    for pat, name in ((b'\x07\x56', 'Identity Response'),
                      (b'\x07\x55', 'Identity Request'),
                      (b'\x07\x41', 'Attach Request'),
                      (b'\x07\x48', 'TAU Request'),
                      (b'\x07\x42', 'Attach Accept'),
                      (b'\x07\x43', 'Attach Complete')):
        start = 0
        while True:
            i = data.find(pat, start)
            if i < 0:
                break
            start = i + 2
            # 从报文头往后扫 IE:找 0x49 <len 5..8> 且 identity type nibble == 3
            for j in range(i, min(len(data) - 9, i + 400)):
                if data[j] != 0x49:
                    continue
                ln = data[j + 1]
                if not 6 <= ln <= 9:          # IMSI/IMEI=8 字节,IMEISV=9 字节
                    continue
                if j + 2 + ln > len(data):
                    continue
                idtype, digits = decode_eps_mobile_identity(data[j + 2:j + 2 + ln])
                if idtype in (2, 3) and len(digits) >= 14:   # 2=IMEI 3=IMEISV
                    hits.append((name, 'IMEISV' if idtype == 3 else 'IMEI', digits))
                elif idtype == 1 and len(digits) >= 10:      # 1=IMSI
                    hits.append((name, 'IMSI', digits))
    return hits


# ---- 帧处理 ----------------------------------------------------------------
def handle_frame(pkt):
    if len(pkt) < 4:
        return
    if pkt[0] == 0x7e:                   # 带转义的帧
        body = pkt[1:-1] if pkt[-1] == 0x7e else pkt[1:]
        pkt = body
    if len(pkt) < 4:
        return
    cmd = pkt[0]
    data = pkt[1:]

    if ARG_RAW:
        out('RAW %02x %s' % (cmd, data.hex()))

    if cmd == DIAG_CMD_LOG_F:
        # 日志包:跳过前 8 字节头(时间戳等),整段搜 NAS
        hits = try_parse_nas(data)
        for name, kind, digits in hits:
            out('★ NAS %s -> %s = %s' % (name, kind, digits))
        if hits and not ARG_RAW:
            out('   [log code 0x%04x] %s' % (struct.unpack_from('<H', data, 0)[0], data[:48].hex()))
        return

    if cmd in (DIAG_EXT_MSG_F, 126, 146, 153, 152):
        # 调试消息:尽力解出子系统 + 文本,打印含关键字的行
        ssid = None
        text = ''
        raw = data.hex()
        for off in (0, 1, 2, 3, 4, 5, 6):
            if off + 10 <= len(data):
                cand = struct.unpack_from('<H', data, off + 8)[0] if off + 10 <= len(data) else 0
                if cand in SUBSYS:
                    ssid = cand
                    break
        printable = ''.join(chr(b) if 32 <= b < 127 else ' ' for b in data)
        text = ' '.join(printable.split())
        line = '[%s] %s' % (SUBSYS.get(ssid, ssid), text[:300])
        low = text.lower()
        if ARG_ALL or any(k in low for k in KW):
            out(line)
        # 调试消息里也可能直接带 NAS 字节串
        hits = try_parse_nas(data)
        for name, kind, digits in hits:
            out('★ (msg) NAS %s -> %s = %s' % (name, kind, digits))
        return

    # 其它命令:原始模式才打印
    if ARG_RAW:
        out('RAW-nonlog %02x %s' % (cmd, data[:200].hex()))


def main():
    try:
        d = Diag()
    except Exception as e:
        print('连不上 diag-router:%s' % e, file=sys.stderr)
        print('先确认: systemctl status diag-router;ls /dev/rpmsg/hexagon/', file=sys.stderr)
        return 2

    # 打开调试消息全量 mask(和 diag-tools 的 diag-log.py 同款)
    try:
        d.send_cmd(DIAG_EXT_MSG_CONFIG_F, MSG_EXT_SUBCMD_SET_ALL_RT_MASKS,
                   data=struct.pack('<xI', 0xFFFFFFFF))
        out('# 已打开调试消息全量 mask')
    except Exception as e:
        out('# 设置 mask 失败(继续抓):%s' % e)

    out('# 开始抓取,插卡/拨号触发附着后观察;Ctrl-C 结束')
    out('# 模式:%s' % ('raw' if ARG_RAW else ('all' if ARG_ALL else '摘要(关键字)')))
    sock = d.sk
    sock.settimeout(1.0)
    n = 0
    while True:
        try:
            pkt = sock.recv(8192)
        except TimeoutError:
            continue
        except KeyboardInterrupt:
            break
        if not pkt:
            continue
        n += 1
        try:
            handle_frame(pkt)
        except Exception as e:
            if ARG_RAW:
                out('# 解析异常 %s' % e)
    out('# 共收到 %d 帧' % n)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print()
