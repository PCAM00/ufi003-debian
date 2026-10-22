#!/bin/bash
# ==============================================================================
#  UFI003 · USB 主/从(gadget)模式 快速切换
# ------------------------------------------------------------------------------
#  /root/usb-mode.sh host        U 口当主机:可插 RTL8153 网卡,给本机(410)上网
#  /root/usb-mode.sh gadget      U 口当设备:RNDIS(10.42.0.1/24)+ adb
#  /root/usb-mode.sh status      看当前模式 / 网卡 / 地址
#
#  原理:msm8916 的 ci_hdrc 支持运行时切角色,写 /sys/class/udc/ci_hdrc.0/device/role
#        gadget 模式的 RNDIS 由 openstick-gc-startup.service(调用 /usr/bin/gc)建立
#  RNDIS 地址由 NetworkManager 静态配置(10.42.0.1/24,对端设 10.42.0.2/24)
# ==============================================================================
set -u

ROLE_FILE="${ROLE_FILE:-/sys/class/udc/ci_hdrc.0/device/role}"
UDC_DIR="${UDC_DIR:-/sys/class/udc/ci_hdrc.0}"
GC_SVC="openstick-gc-startup.service"
GC_BIN="${GC_BIN:-/usr/bin/gc}"
RNDIS_IF="${RNDIS_IF:-usb0}"
RNDIS_ADDR="10.42.0.1/24"

die() { echo "错误: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "请用 root 运行(当前 uid=$(id -u))"; }
cur_role() { cat "$ROLE_FILE" 2>/dev/null || echo "?"; }
udc_state() { cat "$UDC_DIR/state" 2>/dev/null || echo "?"; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() { sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

show_brief() {
    echo "--- USB role : $(cur_role) (udc: $(udc_state)) ---"
    ip -br addr 2>/dev/null | grep -v '^lo' || true
    if have nmcli; then
        nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null || true
    fi
}

cmd_host() {
    need_root
    echo "==> 切到 USB host 模式(U 口当主机)"
    systemctl stop "$GC_SVC" 2>/dev/null || true
    if [ -x "$GC_BIN" ]; then
        "$GC_BIN" -d 2>/dev/null || true
        "$GC_BIN" -c 2>/dev/null || true
    fi
    echo host > "$ROLE_FILE" || die "写 $ROLE_FILE 失败"
    sleep 2
    systemctl restart NetworkManager 2>/dev/null || true
    sleep 3
    echo "==> 已是 host 模式。插上 RTL8153 后 NetworkManager 会自动 DHCP 上网。"
    show_brief
}

cmd_gadget() {
    need_root
    echo "==> 切到 USB gadget 模式(RNDIS + adb)"
    systemctl stop "$GC_SVC" 2>/dev/null || true
    echo gadget > "$ROLE_FILE" || die "写 $ROLE_FILE 失败"
    sleep 1
    systemctl restart "$GC_SVC" 2>/dev/null || true
    sleep 4
    systemctl restart NetworkManager 2>/dev/null || true
    sleep 2
    echo "==> 已是 gadget 模式:$RNDIS_IF = $RNDIS_ADDR(对端电脑请设 10.42.0.2/24)"
    show_brief
}

cmd_status() {
    echo "USB role  : $(cur_role)   (udc: $(udc_state))"
    echo "gadget 服务: $(systemctl is-active "$GC_SVC" 2>/dev/null)"
    echo "WiFi 射频 : $(nmcli -t -f WIFI general status 2>/dev/null || echo '?')"
    show_brief
}

case "${1:-}" in
    host)   cmd_host ;;
    gadget) cmd_gadget ;;
    status) cmd_status ;;
    -h|--help|help|"") usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
esac
