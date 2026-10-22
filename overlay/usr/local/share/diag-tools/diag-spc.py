#!/usr/bin/env python3
# 来自 https://git.abscue.de/affe_null/diag-tools(GPL-3,作者 Affe Null)
# 发 SPC(Service Programming Code),默认 000000 = 303030303030
# 需要先解锁才能写 NV 项(否则 diag 返回 error 66 / 状态 0x42)
import sys
import binascii
from diag import Diag

DIAG_SPC_F = 65

if len(sys.argv) != 2:
    print(f'用法: {sys.argv[0]} <SPC 的 hex,默认 303030303030>')
    sys.exit(1)

rsp = Diag().send_cmd(DIAG_SPC_F, data=binascii.unhexlify(sys.argv[1]))
# rsp[1] != 0 表示失败
print('SPC 结果: 0x%02x (%s)' % (rsp[1], 'OK' if rsp[1] == 0 else '失败'))
sys.exit(0 if rsp[1] == 0 else 2)
