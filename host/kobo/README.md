# VeraDroid for Kobo Libra 2 (N418)

将 [VeraDroid](https://github.com/xyc0677/veradroid)（`legacy` 分支，Android 7.1.1 Cortex-A9 / 32-bit binder）移植到 **Kobo Libra 2 (N418)**，参考 [Koboweread](https://github.com/scokyfei/Koboweread) 的 Kobo 内核模块、硬件参数与 KOReader 插件集成方式。

## 硬件与系统适配

| 项目 | Kobo Libra 2 (N418) 适配实现 |
|---|---|
| SoC / RAM | Freescale i.MX6 SoloLite（单核 Cortex-A9 + NEON），512 MB RAM，Linux 4.1.15 |
| 容器隔离 | `busybox unshare -m` 私有挂载命名空间 + 静态 `pivot_init` 切换根文件系统 + `HOSTNS=1` 共用 `wlan0`（`VdHostNet`） |
| 内核模块 | 复用 Koboweread 已在实机验证的 `binder_linux.ko`、`kobo_zsmalloc.ko`、`kobo_zram.ko`（支持固件 `4.38.23852` / `4.34.20097`） |
| 墨水屏显示 | `veradroid-epd`（`display/legacy/epd.c` + FBInk `FBINK_FOR_KOBO` + NEON 灰度转换），原生 `1264×1680`（300 ppi）局部刷新 / REAGL / A2 滚动 |
| 触摸与实体按键 | `veradroid-input`（`input/legacy/vinput.c` 新增 `--swap-xy` 适配 Elan 触摸屏 `1680×1264 → 1264×1680`，`--keydev` 独占 `gpio-keys`：上键 193 下一页、下键 194 上一页、电源键 116 休眠/唤醒） |
| 前光 / 色温 / 电量 | `host/kobo/boot/lib/kobo.sh` 直接读写 sysfs：`mxc_msp430.0/brightness`（0–100）、`lm3630a_led/color`（10–0 反转映射到 0–24）、`mc13892_bat` |
| 宿主 UI 协同 | `framework.sh` 自动检测并 `SIGSTOP` 暂停 KOReader 或 Nickel，备份/恢复 `/dev/fb0`，退出后完全卸载 ext4 镜像（不留 loop 占用，不影响 USB 传书） |
| 启动入口 | KOReader 插件 `veradroid_libra2.koplugin`（工具菜单 → VeraDroid (Libra 2)）及可选 NickelMenu 配置 |

## 编译与部署

1. 使用 Zig 0.13.0 交叉编译静态 ARMv7 二进制（无需 Docker）：
   ```sh
   ZIG=/path/to/zig FBINK_DIR=/path/to/fbink E2FSPROGS_TAR=/path/to/e2fsprogs-1.47.1.tar.xz \
     sh tools/kobo/build-kobo-bin.sh build/kobo-bin
   ```
2. 部署到 Kobo Libra 2 并初始化 `veradroid-sys.img`：
   ```sh
   KOBO_HOST=<KOBO_IP> KOBO_PORT=2222 \
   BIN_DIR=build/kobo-bin \
   LEGACY_DIR=/path/to/veradroid-legacy/veradroid-pw6 \
   KMOD_DIR=/path/to/Koboweread/kernels \
     sh tools/kobo/deploy-kobo.sh --init-img
   ```
   或构建面向终端用户的纯净安装包（全新安装 `-full.zip` + 增量升级 `-upgrade.zip`，同时支持 NickelMenu 与 KOReader 入口）：
   ```sh
   BIN_DIR=build/kobo-bin \
   EXTRA_BIN_DIR=/path/to/extra-kobo-bins \
   LEGACY_DIR=/path/to/veradroid-legacy/veradroid-pw6 \
   KMOD_DIR=/path/to/Koboweread/kernels \
     sh tools/kobo/build-release.sh dist
   ```
3. 启动 / 停止：
   - KOReader：顶部菜单 → 工具 → **VeraDroid (Libra 2)** → **启动 VeraDroid (Android)**
   - SSH：
     ```sh
     sh /mnt/onboard/.adds/veradroid-libra2/boot/veradroid.sh home
     sh /mnt/onboard/.adds/veradroid-libra2/boot/stop.sh
     ```
   - 退出回 Kobo：长按屏幕**左下角 2 秒**，或在 VeraHome 下拉面板点击返回。

## 功能变更、优化清单与实机基准记录

完整的**项目功能增删全景（新增功能 / 精简移除 / 硬件修复）**、**系统级与微信读书专属优化清单**（含作用范围、代码位置）及 **Kobo Libra 2 实机基准测试记录** 请参见：

- [`docs/kobo-libra2-optimizations.md`](../../docs/kobo-libra2-optimizations.md)
