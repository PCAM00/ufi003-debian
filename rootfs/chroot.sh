#!/bin/bash
# ==============================================================================
#  在 chroot 内以 root 运行:UFI003 Debian rootfs 的全部定制
#    - apt 只用阿里云源(见 overlay/etc/apt/sources.list)
#    - 精简:不装推荐包 + 不落 doc/man/locale
#    - 不插卡:去掉 modem / GPS(modem 固件、ModemManager、rmtfs 全部不要)
#    - network-manager 装上;ssh 开机就开
#    - WiFi 默认关闭但配置保留
#    - gadget RNDIS = 10.42.0.1/24
#    - /root/usb-mode.sh 切换 USB 主从模式
# ==============================================================================
set -e
export DEBIAN_FRONTEND=noninteractive
export LANG=C LANGUAGE=C LC_ALL=C

DIST=trixie
LANG_TARGET=en_US.UTF-8
PASSWORD=1234
NAME=ufi003

echo "=============================================================="
echo "[1/8] apt update(阿里云源)"
echo "=============================================================="
apt-get update

echo "=============================================================="
echo "[2/8] 精简安装核心组件"
echo "=============================================================="
apt-get -y install --no-install-recommends \
    locales ca-certificates tzdata \
    network-manager wpasupplicant iw rfkill dnsmasq-base nftables \
    openssh-server \
    zram-tools fake-hwclock systemd-timesyncd \
    iproute2 iputils-ping curl nano less usbutils rsync

echo "=============================================================="
echo "[3/8] 安装项目自带 deb(固件/工具,已去 modem)+ 内核"
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
echo "[7/8] 去掉 modem/GPS 残留 + 关掉用不上的服务"
echo "=============================================================="
rm -rf /usr/lib/firmware/modem.* /usr/lib/firmware/mba.mbn \
       /usr/lib/firmware/modem_pr /usr/lib/firmware/isdbtmm.* \
       /usr/lib/firmware/nfc_test.bin

# 换 SIM / 离线自动拉 WiFi 热点 / ModemManager:不插卡都用不上,屏蔽掉
for u in ModemManager.service openstick-sim-changer.service \
         openstick-startup-diagnose.service openstick-startup-diagnose.timer; do
    systemctl disable "$u" >/dev/null 2>&1 || true
    systemctl mask "$u" >/dev/null 2>&1 || true
done

# 该开的服务:ssh / NetworkManager / zram / WiFi默认关 / gadget 与首次扩容
systemctl enable ssh.service NetworkManager.service zramswap.service \
                 wifi-default-off.service 2>/dev/null || true
systemctl enable openstick-gc-startup.service openstick-button-monitor.service \
                 openstick-expanddisk-startup.service \
                 regenerate-ssh-host-keys.service 2>/dev/null || true

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
ensure_enabled wifi-default-off.service multi-user.target
ensure_enabled regenerate-ssh-host-keys.service multi-user.target
ensure_enabled openstick-expanddisk-startup.service multi-user.target
ensure_enabled openstick-gc-startup.service default.target
ensure_enabled openstick-button-monitor.service default.target

echo "=============================================================="
echo "[8/8] 清理 + 生成校验报告"
echo "=============================================================="
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
apt-get clean

set +e
{
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
    for p in network-manager openssh-server wpasupplicant zram-tools nftables dnsmasq-base \
             openstick-utils openstick-firmware; do
        printf '%-22s %s\n' "$p" "$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || echo '(未安装)')"
    done
    printf '%-22s ' linux-image
    dpkg-query -W -f='${Package} ${Version}\n' 'linux-image-*' 2>/dev/null || echo '(未安装)'
    echo
    echo "== 内核文件 =="
    ls -1 /boot 2>/dev/null
    echo
    echo "== modem 相关残留(应为空) =="
    ls -1 /usr/lib/firmware 2>/dev/null | grep -iE '^modem|^mba|isdbtmm|nfc_test' || echo "(已清空)"
    echo
    echo "== WiFi 固件(应保留) =="
    ls -1 /usr/lib/firmware 2>/dev/null | grep -iE '^wcnss' || echo "(缺失!)"
    ls -1 /usr/lib/firmware/wlan/prima/ 2>/dev/null || true
    echo
    echo "== NetworkManager 连接配置 =="
    ls -l /etc/NetworkManager/system-connections/ 2>/dev/null
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
cat <<EOF > /tmp/info.md
- 发行版: Debian $(cat /etc/debian_version) (trixie) arm64,已精简
- 内核版本: ${vmlinuz_name#*-}   (boot-no-modem-oc.img:去 modem/GPS + 超频 1.2GHz)
- 默认用户名: root
- 默认密码: $PASSWORD
- RNDIS 地址: 10.42.0.1/24(gadget 模式;对端电脑设 10.42.0.2/24)
- WiFi: 默认关闭(nmcli radio wifi on 可开;驱动与固件保留,不预置任何热点配置)
- USB 主从切换: /root/usb-mode.sh host | gadget | status | nat on|off
- apt 源: 仅阿里云
EOF

echo "==> chroot 定制完成"
