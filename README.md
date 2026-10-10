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
| modem / GPS | **去掉**:用 no-modem 内核,rootfs 里删掉 `modem.*`/`mba.mbn`/`modem_pr`/`isdbtmm`/`nfc_test`,不装 modemmanager/rmtfs/qrtr-tools,屏蔽 `ModemManager`、`openstick-sim-changer`、`openstick-startup-diagnose`(后者会在离线时自动拉起 WiFi 热点) |
| apt 源 | **仅阿里云**(`mirrors.aliyun.com`) |
| USB Gadget | `rndis` + `ffs(adb)`,RNDIS 静态地址 **10.42.0.1/24** |
| 网络管理 | 装 **NetworkManager**;host 模式插 RTL8153 自动 DHCP 上网 |
| SSH | `openssh-server`,开机即开,`PermitRootLogin yes`,首次启动重新生成 host key |
| WiFi | **默认关闭**(开机 `nmcli radio wifi off`),但驱动/固件/连接配置全部保留;带一个默认不启用的应急热点配置 |
| 精简 | 不装推荐包、不落 doc/man/info/locale、无 vim/git/编译器;zram 300%;journal 上限 32M |
| 主从切换 | `/root/usb-mode.sh host\|gadget\|status\|nat on\|off` |

## 产物(release 附件)

| 文件 | 用途 |
| --- | --- |
| `rootfs.img.xz` | 根文件系统(sparse ext4),解压后写入 rootfs 分区 |
| `boot.img` | 内核 = `boot-no-modem-oc.img`(去 modem + 1.2GHz) |
| `boot-no-modem-oc.img` | 同上,保留原文件名 |
| `emmc_appsboot-test-signed.mbn` | lk2nd 引导(best-effort,失败不影响出包) |
| `verify.txt` / `info.md` | 构建校验报告 / 摘要 |

## 默认账号与地址

- root / `1234`(请 `passwd` 改掉)
- gadget 模式:RNDIS `usb*` = **10.42.0.1/24**,对端电脑设 `10.42.0.2/24`
- 应急热点(默认关):`openstick-failsafe` / `12345678`

## USB 主 / 从模式切换

机器上直接跑(详见 `/root/README.txt`):

```sh
/root/usb-mode.sh host      # U 口当主机:插 RTL8153 网口转 USB,本机借此上网
/root/usb-mode.sh gadget    # U 口当设备:RNDIS 10.42.0.1/24 + adb(开机默认)
/root/usb-mode.sh status    # 看当前状态
/root/usb-mode.sh nat on    # 对端电脑共享本机网络(DHCP + NAT)
```

原理是切 msm8916 dwc3 的角色:`/sys/class/udc/ci_hdrc.0/device/role`。

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
