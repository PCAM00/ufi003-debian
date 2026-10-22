# ufi003-debian(定制版)

适用于 **UFI003_MB_V02**(MSM8916 / 骁龙410 / 512MB RAM / 4GB eMMC)的 Debian 固件构建。
上游:[KyonLi/ufi003-debian](https://github.com/KyonLi/ufi003-debian),内核来自
[KyonLi/ufi003-kernel](https://github.com/KyonLi/ufi003-kernel)。

改过的部分见 `overlay/`(配置与脚本)、`rootfs/chroot.sh`(装包与定制)、
`deb-pkgs/repack-nomodem.sh`(精简官方 deb)。

## 本分支的定制内容

| 项目 | 做法 |
| --- | --- |
| 发行版 | Debian **13 (trixie)** arm64 |
| 超频 | 直接用 `boot-no-modem-oc.img`,CPU 超到 **1.2GHz** |
| modem / GPS | **两种变体**:no-modem = 去掉(no-modem 内核 + 删固件 + 不装 modemmanager/rmtfs/qrtr-tools + 屏蔽相关服务);modem = 带基带(完整固件 + ModemManager + rmtfs + qrtr-tools)。两版都屏蔽 `openstick-startup-diagnose`(离线自动拉热点,不要) |
| apt 源 | **仅阿里云**(`mirrors.aliyun.com`) |
| USB Gadget | `rndis` + `ffs(adb)`;RNDIS = 静态 **10.42.0.1/24**(对端设 10.42.0.2/24,不做 NAT) |
| 网络管理 | **NetworkManager**(配 nmtui);host 模式插 RTL8153 自动 DHCP 上网 |
| SSH | `openssh-server`,开机即开,`PermitRootLogin yes`,首次启动重新生成 host key |
| WiFi | **默认开着**(射频不关);要关用 `nmcli radio wifi off`(状态会保存),驱动/固件全保留 |
| 登录提示 | `/etc/motd` 只留一行系统名;USB 角色 + IP 由 `/etc/profile.d/00-usb-ip.sh` 动态打印 |
| /tmp | **在 eMMC 上**(不做 tmpfs 内存盘,避免 464MB 机器把 /tmp 写爆) |
| 精简 | 不装推荐包、不落 doc/man/info/locale;装 `net-tools`(ifconfig)、curl、nano、less、usbutils、rsync;zram 300%;journal 上限 32M |
| 主从切换 | `/root/usb-mode.sh host\|gadget\|status` |

## 两种变体(每次构建出两个 release)

| 变体 | boot 镜像 | rootfs | 说明 |
| --- | --- | --- | --- |
| **no-modem**(默认) | `boot.img` / `boot-no-modem-oc.img` | `rootfs.img.xz` | 去 modem/GPS + 1.2GHz,不插卡 |
| **modem(带基带)** | `boot-oc-modem.img`(1.2GHz)/ `boot-modem.img`(原频兜底) | `rootfs-modem.img.xz` | 保留 modem 固件 + ModemManager + rmtfs,插卡可 4G;带 `/root/imei.sh` |

带基带版的 1.2GHz 镜像是 CI 里现场打的(`.github/build-oc-modem.sh`):
把官方 modem DTB 加 3 档 OPP(1094.4 / 1152 / 1209.6 MHz)后重新拼 boot 镜像。

每个 release 附件:`emmc_appsboot-test-signed.mbn`(lk2nd,best-effort)、`verify-*.txt`(构建校验)、`info-*.md`(摘要)。

## 默认账号与地址

- root / `1234`(请 `passwd` 改掉)
- gadget 模式:RNDIS `usb*` = 静态 **10.42.0.1/24**,对端电脑设 **10.42.0.2/24**
- WiFi:默认开着。连网:`nmtui`,或 `nmcli device wifi connect <SSID> password <密码>`
  (不预置任何热点/AP 配置)

## USB 主 / 从模式切换

机器上直接跑(详见 `/root/README.txt`):

```sh
/root/usb-mode.sh host      # U 口当主机:插 RTL8153 网口转 USB,本机借此上网
/root/usb-mode.sh gadget    # U 口当设备:RNDIS 10.42.0.1/24 + adb(开机默认)
/root/usb-mode.sh status    # 看当前状态
```

原理是切 msm8916 的 USB 角色:`/sys/class/udc/ci_hdrc.0/device/role`。

## 构建

推送到 `master` 即触发 GitHub Actions(`.github/workflows/build.yml`),构建完自动建 tag + release。
也可以在 Actions 页面手动 `workflow_dispatch`。

本地构建(需要 root):`rootfs/build.sh`,依赖
`debootstrap debian-archive-keyring rsync qemu-user-static binfmt-support android-sdk-libsparse-utils`。

构建期三点说明:

- **耗时几乎全在 qemu 模拟 arm64 上**。runner 是 x86_64，`debootstrap --second-stage`
  要模拟 arm64 去 `dpkg --configure` 整个基础系统——实测**这一阶段就占 51 分钟**
  （而下载 147 个基础包只要 ~5 分钟）。整轮构建约 **70 分钟**，和上游一致，属正常。
- **debootstrap 走 `deb.debian.org`** 而不是阿里云：runner 在海外，直连官方源更稳。
  成品系统里的 apt 源**仍然只有阿里云**，由 `overlay/etc/apt/sources.list` 决定，
  与构建期用哪个源无关。
- **必须装 `debian-archive-keyring`**。缺了它 debootstrap 会打印
  `Cannot check Release signature` 并**跳过校验**，等于基础系统是未经验证下载的；
  `build.sh` 现在会前置检查并直接拒绝构建。

## 注意

- rootfs 的 `/etc/fstab` 用 `PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e`
  (与上游一致)。若你的设备分区 PARTUUID 不同,需要改这一行,否则起不来。
- 没插卡,所以 modem 相关功能(4G 上网、短信、GPS)全部不可用,这是设计如此。
- `openstick-expanddisk-startup.service` 会在首次启动时把 rootfs 扩到整块 eMMC。
- 引导器生态要统一:本包是 `thwc,ufi003` 一套(lk2nd + 上游 boot.img)。
  不要和 `handsome,openstick` 那套(旧 OpenStick 引导器/DTB)混用,否则会起不来。
