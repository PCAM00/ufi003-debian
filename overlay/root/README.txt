================================================================================
 UFI003 (MSM8916 / 骁龙410) Debian 使用说明
================================================================================

硬件        UFI003_MB_V02 / 512MB RAM / 4GB eMMC
系统        Debian 13 (trixie) arm64,已精简
内核        6.12.49-msm8916  boot-no-modem-oc.img  ← 去 modem + 超频至 1.2GHz
apt 源      仅阿里云 (mirrors.aliyun.com)

--------------------------------------------------------------------------------
1. 登录
--------------------------------------------------------------------------------
  用户 root    密码 1234
  开机 SSH 就是开的(22 端口),请尽快改密码: passwd

  串口调试: 接 U 口旁的串口(ttyMSM0, 115200)可看到内核与 systemd 输出。

--------------------------------------------------------------------------------
2. USB 主 / 从模式切换(最常用的东西)
--------------------------------------------------------------------------------
  /root/usb-mode.sh host       U 口当【主机】
                               插 RTL8153 网口转 USB,本机即可通过它上网
                               (NetworkManager 自动 DHCP,插上就能用)

  /root/usb-mode.sh gadget     U 口当【设备】(默认就是这个)
                               对电脑提供 RNDIS 网卡 + adb
                               本机在该网段固定 10.42.0.1/24
                               对端电脑网卡请设 10.42.0.2/24
                               想要对端插上就自动拿 IP: /root/usb-mode.sh nat on

  /root/usb-mode.sh status     看当前是 host 还是 gadget、网卡和地址

  /root/usb-mode.sh nat on     对端电脑共享本机网络(DHCP + NAT),用完 nat off 关掉

  开机默认 = gadget 模式,由 openstick-gc-startup.service 负责建立。

--------------------------------------------------------------------------------
3. 网络 / WiFi
--------------------------------------------------------------------------------
  WiFi 默认是【关】的(射频关闭),但驱动、固件、连接配置全部保留:
      nmcli radio wifi on                      # 打开 WiFi 射频
      nmcli connection up failsafe-ap          # 起一个应急热点
                                               # SSID openstick-failsafe / 密码 12345678
      nmcli connection down failsafe-ap        # 关掉热点
      nmcli radio wifi off                     # 再关掉射频
  想让它开机不自动关 WiFi: 把 /etc/default/wifi-default-off 里的 WIFI_OFF 改成 no

  RNDIS 静态地址在 /etc/NetworkManager/system-connections/rndis-usb0.nmconnection
  (文件权限必须是 600,否则 NetworkManager 会忽略它)

--------------------------------------------------------------------------------
4. 已去掉的东西(不插卡,所以 modem / GPS 全砍了)
--------------------------------------------------------------------------------
  - 内核用 boot-no-modem-oc.img:modem 子系统(GPS 也在 modem 里)不加载
  - rootfs 里删掉了 modem.* / mba.mbn / modem_pr / isdbtmm / nfc_test 等固件
  - 没装 modemmanager / rmtfs / qrtr-tools
  - 屏蔽了 openstick-sim-changer.service(换 SIM 用)和
    openstick-startup-diagnose.timer(它会在离线时自动拉起 WiFi 热点,与"默认不开 WiFi"冲突)

  无线(wcnss + wlan/prima)固件保留,所以 WiFi 随时能用。

--------------------------------------------------------------------------------
5. 精简相关
--------------------------------------------------------------------------------
  - 全局不装推荐包(/etc/apt/apt.conf.d/01norecommends)
  - 不落 doc/man/info/locale(/etc/dpkg/dpkg.cfg.d/01-nodoc)
  - 没装 vim/git/编译器等大件,需要时 apt install 即可(阿里云源很快)
  - zram 交换 = 内存的 300%,lzo-rle(小内存机器很有用)
  - systemd journal 上限 32M,不会无限写 eMMC
    (/etc/systemd/journald.conf.d/10-size.conf)

--------------------------------------------------------------------------------
6. 常用检查
--------------------------------------------------------------------------------
  ip -br addr                       # 网卡与地址
  nmcli device status               # NetworkManager 视角
  systemctl status openstick-gc-startup.service
  dmesg | grep -iE 'dwc3|udc|r8152|wcnss'
  journalctl -b | tail -50

--------------------------------------------------------------------------------
7. 刷机(简要)
--------------------------------------------------------------------------------
  boot.img     → 写 boot 分区:  dd if=boot.img of=/dev/disk/by-partlabel/boot bs=1M
  rootfs.img   → 写 rootfs 分区(用 EDL / QFIL / 已有系统里 dd 到对应分区)
  内核 deb     → 想手动换内核时: apt purge linux-image* && apt install ./linux-image*.deb

  ★ rootfs 第一次启动会自动 resize 到整块 eMMC(openstick-expanddisk-startup.service)
================================================================================
