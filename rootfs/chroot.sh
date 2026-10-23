#!/bin/bash
# ==============================================================================
#  在 chroot 内以 root 运行:UFI003 Debian rootfs 的全部定制
#    - apt 只用阿里云源(见 overlay/etc/apt/sources.list)
#    - 精简:不装推荐包 + 不落 doc/man/locale
#    - VARIANT=nomodem:去 modem/GPS(删固件、不装 ModemManager/rmtfs)
#    - VARIANT=modem  :带基带(保留固件,装 ModemManager + rmtfs + qrtr-tools)
#    - network-manager 装上;ssh 开机就开
#    - WiFi 默认开着(nmcli radio wifi off 关)
#    - gadget RNDIS = 静态 10.42.0.1/24(对端 10.42.0.2/24,不做 NAT)
#    - /root/usb-mode.sh 切换 USB 主从模式
# ==============================================================================
set -e
export DEBIAN_FRONTEND=noninteractive
export LANG=C LANGUAGE=C LC_ALL=C

VARIANT="${VARIANT:-nomodem}"
DIST=trixie
LANG_TARGET=en_US.UTF-8
PASSWORD=1234
NAME=ufi003

echo "=============================================================="
echo "[1/8] apt update(阿里云源)  [VARIANT=${VARIANT}]"
echo "=============================================================="
apt-get update

echo "=============================================================="
echo "[2/8] 精简安装核心组件"
echo "=============================================================="
EXTRA=""
if [ "$VARIANT" = "modem" ]; then
    EXTRA="modemmanager rmtfs qrtr-tools"
fi
# shellcheck disable=SC2086
apt-get -y install --no-install-recommends \
    locales ca-certificates tzdata \
    network-manager wpasupplicant iw rfkill nftables net-tools \
    openssh-server \
    zram-tools fake-hwclock systemd-timesyncd \
    iproute2 iputils-ping curl nano less usbutils rsync \
    $EXTRA

echo "=============================================================="
echo "[3/8] 安装项目自带 deb(固件/工具)+ 内核"
echo "=============================================================="
apt-get -y install /tmp/*.deb

echo "=============================================================="
echo "[4/8] locale / 时区"
echo "=============================================================="
sed -i -e "s/# $LANG_TARGET UTF-8/$LANG_TARGET UTF-8/" /etc/locale.gen
sed -i -e "s/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/" /etc/locale.gen
locale-gen
update-locale LANG=$LANG_TARGET LC_ALL=$LANG_TARGET LANGUAGE=$LANG_TARGET
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

echo "=============================================================="
echo "[5/8] root 密码 / SSH / 主机名"
echo "=============================================================="
echo -e "$PASSWORD\n$PASSWORD" | passwd
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?UseDNS.*/UseDNS no/' /etc/ssh/sshd_config
rm -f /etc/ssh/ssh_host_*

echo "=============================================================="
echo "[6/8] zram(300%,lzo-rle)/ journal 上限 / resolv.conf"
echo "=============================================================="
sed -i 's/^#\?ALGO=.*/ALGO=lzo-rle/' /etc/default/zramswap
sed -i 's/^#\?PERCENT=.*/PERCENT=300/' /etc/default/zramswap
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=32M\n' > /etc/systemd/journald.conf.d/10-size.conf
echo -n > /etc/resolv.conf

echo "=============================================================="
echo "[7/8] 按变体处理 modem / 服务"
echo "=============================================================="
if [ "$VARIANT" = "modem" ]; then
    echo "  -> 带基带:保留 modem 固件,启用 ModemManager/rmtfs"
    # 只屏蔽"离线自动拉热点"的诊断(不想要热点),换 SIM/基带相关全部保留
    systemctl disable openstick-startup-diagnose.service openstick-startup-diagnose.timer >/dev/null 2>&1 || true
    systemctl mask openstick-startup-diagnose.service openstick-startup-diagnose.timer >/dev/null 2>&1 || true

    # diag-router:IMEI/NV 读写走 DIAG(rpmsg/hexagon 通道)
    # 二进制是 prebuilt/diag-router(CI 里用 qemu+arm64 容器编好,已提交进仓库);build.sh 提前拷入
    if [ -x /usr/local/bin/diag-router ]; then
        echo "  -> diag-router 已就位(IMEI 改号可用)"
    else
        echo "!! 缺 /usr/local/bin/diag-router(imei.sh 只能备份/恢复)"
    fi
else
    echo "  -> 无基带:删 modem/GPS 固件,屏蔽相关服务"
    rm -rf /usr/lib/firmware/modem.* /usr/lib/firmware/mba.mbn \
           /usr/lib/firmware/modem_pr /usr/lib/firmware/isdbtmm.* \
           /usr/lib/firmware/nfc_test.bin
    for u in ModemManager.service openstick-sim-changer.service \
             openstick-startup-diagnose.service openstick-startup-diagnose.timer; do
        systemctl disable "$u" >/dev/null 2>&1 || true
        systemctl mask "$u" >/dev/null 2>&1 || true
    done
fi

# 该开的服务:ssh / NetworkManager / zram / gadget 与首次扩容
systemctl enable ssh.service NetworkManager.service zramswap.service 2>/dev/null || true
systemctl enable openstick-gc-startup.service openstick-button-monitor.service \
                 openstick-expanddisk-startup.service \
                 regenerate-ssh-host-keys.service 2>/dev/null || true
if [ "$VARIANT" = "modem" ]; then
    systemctl enable ModemManager.service rmtfs.service diag-router.service 2>/dev/null || true
fi

# systemctl enable 在 chroot 里偶尔会静默失败,这里补 symlink 兜底
ensure_enabled() {
    unit="$1"; target="$2"
    link="/etc/systemd/system/${target}.wants/${unit}"
    [ -e "/lib/systemd/system/${unit}" ] || return 0
    if [ ! -L "$link" ] && [ ! -e "$link" ]; then
        mkdir -p "/etc/systemd/system/${target}.wants"
        ln -sf "/lib/systemd/system/${unit}" "$link"
        echo "  [ensure] 补上 ${target}.wants/${unit}"
    fi
}
ensure_enabled ssh.service multi-user.target
ensure_enabled NetworkManager.service multi-user.target
ensure_enabled zramswap.service multi-user.target
ensure_enabled regenerate-ssh-host-keys.service multi-user.target
ensure_enabled openstick-expanddisk-startup.service multi-user.target
ensure_enabled openstick-gc-startup.service default.target
ensure_enabled openstick-button-monitor.service default.target
if [ "$VARIANT" = "modem" ]; then
    ensure_enabled ModemManager.service multi-user.target
    ensure_enabled rmtfs.service multi-user.target
    ensure_enabled diag-router.service multi-user.target
fi

echo "=============================================================="
echo "[8/8] 清理 + 生成校验报告"
echo "=============================================================="
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
apt-get clean

set +e
{
    echo "== 变体 =="
    echo "$VARIANT"
    echo "== Debian 版本 =="
    cat /etc/debian_version
    grep -E '^(PRETTY_NAME|VERSION_CODENAME)' /etc/os-release
    echo
    echo "== apt 源 =="
    cat /etc/apt/sources.list
    echo
    echo "== 开机启用的 unit =="
    echo "-- multi-user.target.wants --"
    ls -1 /etc/systemd/system/multi-user.target.wants/ 2>/dev/null | sort
    echo "-- default.target.wants --"
    ls -1 /etc/systemd/system/default.target.wants/ 2>/dev/null | sort
    echo "-- 被屏蔽的 unit(mask) --"
    ls -1 /etc/systemd/system/ 2>/dev/null | grep -E '^ModemManager|^openstick-sim|^openstick-startup'
    echo
    echo "== 关键包 =="
    for p in network-manager openssh-server wpasupplicant zram-tools nftables net-tools \
             modemmanager rmtfs qrtr-tools openstick-utils openstick-firmware; do
        printf '%-22s %s\n' "$p" "$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || echo '(未安装)')"
    done
    printf '%-22s ' linux-image
    dpkg-query -W -f='${Package} ${Version}\n' 'linux-image-*' 2>/dev/null || echo '(未安装)'
    echo
    echo "== 内核文件 =="
    ls -1 /boot 2>/dev/null
    echo
    if [ "$VARIANT" = "nomodem" ]; then
        echo "== modem 相关残留(应为空) =="
        ls -1 /usr/lib/firmware 2>/dev/null | grep -iE '^modem|^mba|isdbtmm|nfc_test' || echo "(已清空)"
    else
        echo "== modem 固件(应保留) =="
        echo "modem/mba 文件数: $(ls -1 /usr/lib/firmware 2>/dev/null | grep -icE '^modem|^mba')"
    fi
    echo
    echo "== WiFi 固件(应保留) =="
    ls -1 /usr/lib/firmware 2>/dev/null | grep -iE '^wcnss' || echo "(缺失!)"
    ls -1 /usr/lib/firmware/wlan/prima/ 2>/dev/null || true
    echo
    echo "== NetworkManager 连接配置 =="
    ls -l /etc/NetworkManager/system-connections/ 2>/dev/null
    echo
    echo "== DIAG / IMEI 工具(modem 变体)=="
    ls -l /usr/local/bin/diag-router /usr/local/bin/rpmsgexport 2>/dev/null || echo "(无)"
    ls -1 /usr/local/share/diag-tools/ 2>/dev/null || true
    ls -l /lib/udev/rules.d/50-rpmsg.rules 2>/dev/null || true
    echo
    echo "== /root =="
    ls -l /root/ 2>/dev/null
    echo
    echo "== 系统占用 =="
    df -h / | tail -1
    du -sh /usr 2>/dev/null
    du -sh /var 2>/dev/null
} > /tmp/verify.txt 2>&1
set -e

cat /tmp/verify.txt

rm -f /tmp/*.deb

vmlinuz_name=$(basename /boot/vmlinuz-*)
if [ "$VARIANT" = "modem" ]; then
    KDESC="boot-modem.img(带基带,原频) / boot-oc-modem.img(带基带 + 1.2GHz)"
else
    KDESC="boot-no-modem-oc.img(去 modem/GPS + 超频 1.2GHz)"
fi
cat <<EOF > /tmp/info.md
- 变体: $VARIANT
- 发行版: Debian $(cat /etc/debian_version) (trixie) arm64,已精简
- 内核版本: ${vmlinuz_name#*-}   ($KDESC)
- 默认用户名: root
- 默认密码: $PASSWORD
- RNDIS 地址: 静态 10.42.0.1/24(gadget 模式;对端设 10.42.0.2/24,不做 NAT)
- WiFi: 默认开(nmcli radio wifi off 可关;不预置任何热点配置)
- USB 主从切换: /root/usb-mode.sh host | gadget | status
- IMEI: /root/imei.sh status|get|set|backup(改号走 DIAG,详见脚本头注释)
- apt 源: 仅阿里云
- /tmp 在 eMMC 上(非内存盘);ext4 未设 commit= 参数(跟随酷安包默认)
EOF

echo "==> chroot 定制完成(VARIANT=$VARIANT)"
