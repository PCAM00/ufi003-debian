# 来自 https://git.abscue.de/affe_null/diag-tools(GPL-3,作者 Affe Null)
# 通过抽象 Unix socket 与 diag-router 通讯,转发到 modem 的 DIAG 通道
# 修:原文件用了 struct 但没 import
import struct
from socket import socket, AF_UNIX, SOCK_SEQPACKET

BUF_SIZE = 8192


class Diag:
    def __init__(self):
        self.sk = socket(AF_UNIX, SOCK_SEQPACKET, 0)
        # diag-router 绑定的是抽象的 108 字节全 0 名字
        self.sk.connect(b'\0' * 108)

    def send_cmd(self, *args, data=b''):
        hdr = b''
        for arg in args:
            hdr += struct.pack('<B', arg)
        self.sk.send(hdr + data)
        rsp = self.sk.recv(BUF_SIZE)
        if len(rsp) == 0:
            raise EOFError('diag-router 没有回应(它起来了吗? modem 加载了吗?)')
        if (len(args) == 0) or (rsp[0] == args[0]):
            return rsp
        raise RuntimeError('命令失败,状态 0x%02x(0x42 = 需要 SPC 解锁)' % rsp[0])


if __name__ == '__main__':
    print('这个文件不是脚本入口,直接用 imei.sh / diag-nv.py')
