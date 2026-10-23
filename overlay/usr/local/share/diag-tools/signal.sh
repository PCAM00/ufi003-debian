#!/bin/sh
# 抓 modem DIAG 流验证 IMEI(等价于 nasdump.py,方便记)
exec python3 /usr/local/share/diag-tools/nasdump.py "$@"
