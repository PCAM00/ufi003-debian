#!/bin/bash
# ==============================================================================
#  IMEI / 基带(EFS)查看、备份与改写(只有"带基带"固件里有意义)
# ------------------------------------------------------------------------------
#  /root/imei.sh status             看基带/DIAG 通道是否就绪
#  /root/imei.sh get                读当前 IMEI(mmcli 优先,失败用 DIAG NV550)
#  /root/imei.sh set <15位IMEI>      改 IMEI(需要 --yes 确认: set <IMEI> --yes)
#  /root/imei.sh nv read [item]     直接读 NV 项(默认 550)
#  /root/imei.sh nv write <item> <hex>   直接写 NV 项(危险,自己负责)
#  /root/imei.sh backup             备份 modemst1/modemst2 到 /root/imei-backup
#  /root/imei.sh restore <时间戳>    从备份恢复两个分区
#  /root/imei.sh list               列出已有备份
#
#  原理:IMEI 存在 modem 的 EFS 里,对应 NV 项 550。
#        改号走 DIAG:diag-router(modem rpmsg 通道)→ diag-nv.py。
#        写之前要先发 SPC(默认 000000)解锁,否则 modem 返回 error 66 / 0x42。
#
#  ⚠️ 改 IMEI 在多数地区受监管,请只对自己的设备、自行承担责任;
#     写坏了基带可能没信号 —— 先 backup,再动手。
# ==============================================================================
set -u

MS1=/dev/disk/by-partlabel/modemst1
MS2=/dev/disk/by-partlabel/modemst2
D=/root/imei-backup
TOOLS=/usr/local/share/diag-tools

die() { echo "错误: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ---- DIAG 通道就绪检查 ------------------------------------------------------
diag_ready() {
    [ -x /usr/local/bin/diag-router ] || return 1
    systemctl is-active --quiet diag-router.service || return 1
    ls /dev/rpmsg/hexagon/DIAG >/dev/null 2>&1
}

need_diag() {
    diag_ready || die "DIAG 通道没就绪:检查 'systemctl status diag-router'、
      以及 modem 是否加载(dmesg | grep -iE 'mss|remoteproc|rpmsg')。
      注意:modem 重启后 diag-router 也要重启。"
}

nv() { python3 "$TOOLS/diag-nv.py" "$@"; }

get_imei_mmcli() {
    have mmcli || return 1
    mmcli -m any --output-keyvalue 2>/dev/null | grep -iE "equipment identifier" | cut -d: -f2- | tr -d ' \t'
}

# ---- 子命令 -----------------------------------------------------------------
cmd_status() {
    echo "== 基带 =="
    if [ -b "$MS1" ]; then echo "modemst1/2 分区: 在"; else echo "modemst1/2 分区: 不存在(不是带基带固件?)"; fi
    echo "ModemManager : $(systemctl is-active ModemManager.service 2>/dev/null)"
    if have mmcli; then echo "modem 列表  : $(mmcli -L 2>/dev/null | head -1)"; fi
    echo "diag-router  : $(systemctl is-active diag-router.service 2>/dev/null)"
    echo "rpmsg DIAG   : $(ls /dev/rpmsg/hexagon/DIAG 2>/dev/null || echo '(无)')"
    echo "默认 SPC     : 000000(303030303030)"
}

cmd_get() {
    i=$(get_imei_mmcli)
    if [ -n "${i:-}" ]; then echo "IMEI(mmcli): $i"; return 0; fi
    need_diag
    echo "mmcli 读不到,改用 DIAG NV550:"
    nv read 550
}

cmd_set() {
    imei="${1:-}"
    [ "${imei:-}" != "" ] || die "用法: imei.sh set <15位IMEI> --yes"
    [ "$imei" -eq "$imei" ] 2>/dev/null || die "IMEI 必须是 15 位数字"
    [ ${#imei} -eq 15 ] || die "IMEI 必须是 15 位数字"
    [ "${2:-}" = "--yes" ] || die "改号有风险,确认请加 --yes: imei.sh set $imei --yes"
    need_diag
    echo "==> 1) 先备份 modemst1/2"
    cmd_backup || die "备份失败,不改"
    echo "==> 2) 发 SPC 解锁(000000)"
    python3 "$TOOLS/diag-spc.py" 303030303030 || echo "    (SPC 非 0 或已解锁,继续)"
    echo "==> 3) 读 NV550 -> 改 IMEI -> 写回 -> 复核"
    nv set-imei "$imei"
    rc=$?
    echo "==> 4) 重启 modem 让新 IMEI 生效"
    systemctl restart ModemManager.service 2>/dev/null || true
    if have mmcli; then mmcli -m 0 -r 2>/dev/null || true; fi
    echo "    完事后用: imei.sh get"
    return $rc
}

cmd_nv() {
    sub="${1:-read}"
    case "$sub" in
        read)  need_diag; nv read "${2:-550}" ;;
        write) need_diag; [ "${2:-}" != "" ] && [ "${3:-}" != "" ] || die "用法: imei.sh nv write <item> <128字节hex>"
               python3 "$TOOLS/diag-spc.py" 303030303030 >/dev/null 2>&1 || true
               nv write "$2" "$3" ;;
        *) die "nv 子命令: read | write" ;;
    esac
}

cmd_backup() {
    [ -b "$MS1" ] || die "找不到 $MS1(这版固件没有基带分区?)"
    mkdir -p "$D"
    ts=$(date +%Y%m%d-%H%M%S)
    dd if="$MS1" of="$D/modemst1-$ts.img" bs=1M status=none
    dd if="$MS2" of="$D/modemst2-$ts.img" bs=1M status=none
    echo "已备份(时间戳 $ts):"
    ls -l "$D" | tail -2
    echo "★ 建议把 $D 再拷一份到别的机器/U盘"
}

cmd_restore() {
    [ -b "$MS1" ] || die "找不到 $MS1"
    ts="${1:?用法: imei.sh restore <时间戳>}"
    f1="$D/modemst1-$ts.img"; f2="$D/modemst2-$ts.img"
    [ -f "$f1" ] && [ -f "$f2" ] || die "备份不存在: $D/modemst{1,2}-$ts.img"
    dd if="$f1" of="$MS1" bs=1M status=none
    dd if="$f2" of="$MS2" bs=1M status=none
    echo "已恢复,建议 reboot"
}

case "${1:-}" in
    status)  cmd_status ;;
    get)     cmd_get ;;
    set)     cmd_set "${2:-}" "${3:-}" ;;
    nv)      cmd_nv "${2:-read}" "${3:-}" "${4:-}" ;;
    backup)  cmd_backup ;;
    restore) cmd_restore "${2:-}" ;;
    list)    ls -l "$D" 2>/dev/null || echo "(还没有备份)" ;;
    -h|--help|help|"") usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
esac
