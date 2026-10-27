Adreno 306 headless GPU 测试(来自 https://github.com/nerv-notebook/msm8916-headless-gpu,MIT)

本固件已在内核里开 CONFIG_DRM_MSM=m + headless 补丁,DTS 里 &gpu 也已开启。

验证:
  systemctl restart systemd-modules-load   # 或 reboot
  ls /dev/dri/                             # 期望 card1 renderD128
  dmesg | grep -iE 'adreno|msm .*gpu'      # 期望 'loaded qcom/a300_pm4.fw'
  python3 /root/gpu-test/test_adreno_3d.py
  python3 /root/gpu-test/benchmark_gpu.py

要求:Mesa freedreno 用户态(libdrm-freedreno1/libgbm1/libegl-mesa0/libgles2 已装)
