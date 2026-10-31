#!/bin/bash
# ==============================================================================
#  UFI003 · USB 主/从(gadget)模式 快速切换
# ------------------------------------------------------------------------------
#  /root/usb-mode.sh host            U 口当主机:可插 RTL8153 网卡,给本机(410)上网
#  /root/usb-mode.sh gadget          U 口当设备:RNDIS(10.42.0.1/24)+ adb
#  /root/usb-mode.sh status          看当前模式 / 网卡 / 地址
#  /root/usb-mode.sh persist host|gadget|off  记住开机时用哪种模式(默认 off=不干预)
#  /root/usb-mode.sh wifi on|off     开/关 WiFi 射频(关:不自动连,重启保持)
#
#  默认「延迟 + 脱离会话」执行:命令立刻返回,3 秒后由 systemd 独立完成切换,
#  所以即使你现在是通过 USB(RNDIS/SSH 或 adb shell)连进来的,USB 断了也不会
#  把切换过程杀掉。
#    --delay N    延迟 N 秒(默认 3)
#    --now        立即执行(老行为,会当场断开)
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
STATE_FILE="${STATE_FILE:-/etc/usb-mode.role}"      # 开机想用哪种角色(host/gadget/off)

die() { echo "错误: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "请用 root 运行(当前 uid=$(id -u))"; }
cur_role() { cat "$ROLE_FILE" 2>/dev/null || echo "?"; }
udc_state() { cat "$UDC_DIR/state" 2>/dev/null || echo "?"; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() { sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

show_brief() {
    echo "--- USB role : $(cur_role) (udc: $(udc_state)) ---"
    ip -br addr 2>/dev/null | grep -v '^lo' || true
    if have nmcli; then
        nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null || true
    fi
}

# 把「真正的切换」丢给 systemd 独立执行,调用者的会话马上就能返回
detach_run() {
    local target="$1" delay="$2"
    if have systemd-run; then
        systemd-run --unit=usb-mode-switch --collect --on-active="${delay}s" \
            /bin/bash "$0" "$target" --now >/dev/null 2>&1 && return 0
    fi
    # 退路:setsid 双 fork,脱离控制终端
    setsid /bin/bash -c "sleep $delay; exec /bin/bash '$0' '$target' --now" \
        </dev/null >/var/log/usb-mode.log 2>&1 &
    return 0
}

schedule() {
    local target="$1" delay="$2" label="$3"
    echo "==> 已安排:${delay} 秒后切到 ${label}"
    echo "    (本会话(USB 串口/RNDIS/SSH)随后会断开,切换会在后台完成,不需要你等)"
    detach_run "$target" "$delay"
    echo "    查看结果:status  ->  或稍后重新连上来执行 $0 status"
    exit 0
}

cmd_host() {
    need_root
    local delay=3 now=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --delay) delay="${2:-3}"; shift 2 ;;
            --now)   now=1; shift ;;
            *) shift ;;
        esac
    done
    [ "$now" = "1" ] || schedule host "$delay" "USB host 模式"
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
    echo host > "$STATE_FILE" 2>/dev/null || true
    logger -t usb-mode "switched to host"
}

cmd_gadget() {
    need_root
    local delay=3 now=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --delay) delay="${2:-3}"; shift 2 ;;
            --now)   now=1; shift ;;
            *) shift ;;
        esac
    done
    [ "$now" = "1" ] || schedule gadget "$delay" "USB gadget 模式"
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
    echo gadget > "$STATE_FILE" 2>/dev/null || true
    logger -t usb-mode "switched to gadget"
}

cmd_persist() {
    need_root
    case "${1:-}" in
        host|gadget) echo "$1" > "$STATE_FILE"; echo "==> 下次开机自动切到 USB $1 模式" ;;
        off) rm -f "$STATE_FILE"; echo "==> 已取消开机自动切换(开机保持固件默认)" ;;
        *) echo "用法: $0 persist host|gadget|off"; exit 1 ;;
    esac
}

cmd_apply() {
    # 开机时由 usb-mode-apply.service 调用
    [ -f "$STATE_FILE" ] || { echo "未设置持久模式,保持默认"; exit 0; }
    local want; want="$(cat "$STATE_FILE" 2>/dev/null)"
    local cur; cur="$(cur_role)"
    echo "持久模式=$want 当前=$cur"
    [ "$want" = "$cur" ] && { echo "已一致,无需切换"; exit 0; }
    case "$want" in
        host)   "$0" host --now ;;
        gadget) "$0" gadget --now ;;
        *) echo "未知持久模式: $want"; exit 1 ;;
    esac
}

cmd_wifi() {
    need_root
    case "${1:-}" in
        off) nmcli radio wifi off; echo "==> WiFi 射频已关(状态持久,重启保持)" ;;
        on)  nmcli radio wifi on;  echo "==> WiFi 射频已开" ;;
        status|"") echo "WiFi 射频: $(nmcli -t -f WIFI general status 2>/dev/null || echo '?')" ;;
        *) echo "用法: $0 wifi on|off|status"; exit 1 ;;
    esac
}

cmd_status() {
    echo "USB role  : $(cur_role)   (udc: $(udc_state))"
    echo "gadget 服务: $(systemctl is-active "$GC_SVC" 2>/dev/null)"
    echo "WiFi 射频 : $(nmcli -t -f WIFI general status 2>/dev/null || echo '?')"
    echo "开机持久模式: $(cat "$STATE_FILE" 2>/dev/null || echo '未设置(用固件默认)')"
    echo "待执行的切换: $(systemctl is-active usb-mode-switch 2>/dev/null || echo '无')"
    show_brief
}

case "${1:-}" in
    host)   shift; cmd_host "$@" ;;
    gadget) shift; cmd_gadget "$@" ;;
    persist) shift; cmd_persist "$@" ;;
    apply)  cmd_apply ;;
    wifi)   shift; cmd_wifi "$@" ;;
    status) cmd_status ;;
    -h|--help|help|"") usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
esac
