#!/bin/sh
# 开机把 WiFi 射频关掉(默认行为)。
# 驱动、固件、NetworkManager 的全部连接配置都保留,想用 WiFi 时:
#     nmcli radio wifi on            # 本次开机生效
# 想永久放开:把 /etc/default/wifi-default-off 里的 WIFI_OFF 改成 no
set -u

[ -r /etc/default/wifi-default-off ] && . /etc/default/wifi-default-off

if [ "${WIFI_OFF:-yes}" != "yes" ]; then
    logger -t wifi-default-off "WIFI_OFF != yes,保持 WiFi 可用"
    exit 0
fi

# 等 NetworkManager 起来(nmcli 需要它)
i=0
while [ "$i" -lt 30 ]; do
    nmcli -t general status >/dev/null 2>&1 && break
    i=$((i + 1))
    sleep 1
done

if command -v nmcli >/dev/null 2>&1; then
    nmcli radio wifi off >/dev/null 2>&1 || true
fi
if command -v rfkill >/dev/null 2>&1; then
    rfkill block wifi >/dev/null 2>&1 || true
fi

logger -t wifi-default-off "WiFi 射频已关闭(配置保留,需要时 nmcli radio wifi on)"
exit 0
