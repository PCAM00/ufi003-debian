#!/bin/bash
# ==============================================================================
#  IMEI / 基带(EFS)查看与备份(只有"带基带"固件里有意义)
# ------------------------------------------------------------------------------
#  /root/imei.sh get               看当前 IMEI(需要 ModemManager 已起来)
#  /root/imei.sh backup            把 modemst1/modemst2 整分区备份到 /root/imei-backup
#  /root/imei.sh restore <时间戳>   从备份恢复两个分区
#  /root/imei.sh list              列出已有备份
#
#  说明:IMEI 存在 modemst1 分区(EFS 里的 NV 550 项,带校验和)。
#       在没验证写入格式之前,本脚本只做「备份/恢复」,防止写坏 EFS。
#       要改号:先 backup,再用可靠工具(社区常用 Windows 上的 QPST/QCN 工具)操作。
# ==============================================================================
set -u

MS1=/dev/disk/by-partlabel/modemst1
MS2=/dev/disk/by-partlabel/modemst2
D=/root/imei-backup

die() { echo "错误: $*" >&2; exit 1; }

have_part() {
    [ -b "$MS1" ] || die "找不到 $MS1(这版固件没有基带分区)"
}

get_imei() {
    mmcli -m any --output-keyvalue 2>/dev/null | grep -iE "equipment identifier" | cut -d: -f2- | tr -d ' \t'
}

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

case "${1:-}" in
    get)
        i=$(get_imei)
        if [ -n "$i" ]; then
            echo "当前 IMEI: $i"
        else
            echo "读不到 IMEI(ModemManager 起来了吗?用 mmcli -m any 看看)"
            exit 1
        fi
        ;;
    backup)
        have_part
        mkdir -p "$D"
        ts=$(date +%Y%m%d-%H%M%S)
        dd if="$MS1" of="$D/modemst1-$ts.img" bs=1M status=none
        dd if="$MS2" of="$D/modemst2-$ts.img" bs=1M status=none
        echo "已备份(时间戳 $ts):"
        ls -l "$D" | tail -2
        echo "★ 建议把 $D 再拷一份到别的机器/U盘"
        ;;
    restore)
        have_part
        ts="${2:?用法: imei.sh restore <时间戳>}"
        f1="$D/modemst1-$ts.img"; f2="$D/modemst2-$ts.img"
        [ -f "$f1" ] && [ -f "$f2" ] || die "备份不存在: $D/modemst{1,2}-$ts.img"
        dd if="$f1" of="$MS1" bs=1M status=none
        dd if="$f2" of="$MS2" bs=1M status=none
        echo "已恢复,建议 reboot"
        ;;
    list)
        ls -l "$D" 2>/dev/null || echo "(还没有备份)"
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        usage
        ;;
esac
