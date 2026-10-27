# ufi003-debian(定制版)

适用于 MSM8916 / 骁龙410 的 4G 上网棒,目前**只编两块板子**:

| 板子 | 型号 | compatible |
| --- | --- | --- |
| **ufi003** | UFI003 4G Modem Stick | `thwc,ufi003` |
| **jz02** | jz02-v10 4G Modem Stick | `thwc,jz02v10` |

上游:[KyonLi/ufi003-debian](https://github.com/KyonLi/ufi003-debian);
内核用本仓库配套的 fork **[PCAM00/ufi003-kernel](https://github.com/PCAM00/ufi003-kernel)**
(release `kernel-gpu-1`,见下方 GPU 说明)。

改过的部分见 `overlay/`(配置与脚本)、`rootfs/chroot.sh`(装包与定制)、
`deb-pkgs/repack-nomodem.sh`(精简官方 deb)。

## 本分支的定制内容

| 项目 | 做法 |
| --- | --- |
| 发行版 | Debian **13 (trixie)** arm64 |
| 超频 | 每块板子单独出 boot:`boot-<board>-oc.img` 把 DTB 加上 3 档 OPP(1094.4/1152/1209.6MHz)→ **1.2GHz** |
| **GPU** | 内核开 `CONFIG_DRM_MSM=m` + headless 补丁,DTB 里 `&gpu` 开启 → `/dev/dri/renderD128`(Adreno 306,OpenGL ES 3.0) |
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

## 两块板子(每次构建出两个 release)

| release | boot 镜像 | rootfs | 说明 |
| --- | --- | --- | --- |
| `…-ufi003` | `boot-ufi003-oc.img`(1.2GHz)/ `boot-ufi003.img`(原频兜底) | `rootfs.img.xz` | UFI003,带基带 |
| `…-jz02` | `boot-jz02-oc.img`(1.2GHz)/ `boot-jz02.img`(原频兜底) | `rootfs-jz02.img.xz` | jz02-v10,带基带 |

两块都是 **modem(带基带)** 变体:保留完整基带固件 + ModemManager + rmtfs + qrtr-tools,
带 `/root/imei.sh` 与 `/root/nasdump.py(信令抓取)`。

boot 镜像由 `.github/build-oc-modem.sh` 按板子生成:DTB 从内核 deb 里取,
加 3 档 OPP 后与内核 release 的 Image.gz/ramdisk 重新拼装(纯 Python 打包,带 SHA1 id)。

每个 release 附件:`emmc_appsboot-test-signed.mbn`(lk2nd,best-effort)、`verify-<board>.txt`、`info-<board>.md`。

## Adreno 306 headless GPU

无屏板子的 MDSS 是 disabled,MSM DRM 的 Adreno 就一直等不到 master。本固件在内核里解决:

1. `ufi003_defconfig` 开 `CONFIG_DRM_MSM=m`(它 select `DRM_SCHED`)
2. `adreno_device.c` 打 [headless 补丁](https://github.com/nerv-notebook/msm8916-headless-gpu):
   mdss 缺失/disabled 时自主注册 dummy msm master
3. DTB 里 `&gpu { status = "okay" }`
4. rootfs 装 Mesa freedreno 用户态 + `/etc/modules-load.d/gpu.conf`(自动加载 `msm`)

验证:

```sh
ls /dev/dri/                       # 期望 card1 + renderD128
dmesg | grep -iE 'adreno|msm .*gpu'
python3 /root/gpu-test/test_adreno_3d.py
python3 /root/gpu-test/benchmark_gpu.py
```

## 默认账号与地址

- root / `1234`(请 `passwd` 改掉)
- gadget 模式:RNDIS `usb*` = 静态 **10.42.0.1/24**,对端电脑设 **10.42.0.2/24**
- WiFi:默认开着。连网:`nmtui`,或 `nmcli device wifi connect <SSID> password <密码>`
  (不预置任何热点/AP 配置)

## IMEI(modem 变体)

带基带固件里带 `/root/imei.sh`:

```sh
/root/imei.sh status          # 基带/DIAG 通道是否就绪
/root/imei.sh get             # 读 IMEI(mmcli,失败则走 DIAG NV550)
/root/imei.sh set <15位IMEI> --yes   # 改号(先备份 -> SPC 解锁 -> 写 NV550 -> 复核)
/root/imei.sh backup          # 备份 modemst1/modemst2 到 /root/imei-backup
```

改号链路:modem → rpmsg(`hexagon`)→ `diag-router`(prebuilt,glibc aarch64)→ `/usr/local/share/diag-tools/diag-nv.py`。
需要 modem 已加载;modem 重启后 `systemctl restart diag-router`。
⚠️ 改 IMEI 在多数地区受监管,请只对自己的设备、自担风险;先 backup 再动手。

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
