# Veradroid-Libra2

*An optimized Android 7.1.1 reading environment (VeraDroid port) for **Kobo Libra 2 (N418)** — supporting both **NickelMenu** and **KOReader**, true `mem` deep sleep, NEON Skia E-Ink rendering, and incremental offline upgrades.*

将开源项目 [VeraDroid](https://github.com/xyc0677/veradroid)（`legacy` 分支，Android 7.1.1 / 32-bit ARMv7）深度移植并优化到 **Kobo Libra 2 (N418)**，复用并融合 [Koboweread](https://github.com/scokyfei/Koboweread) 的内核模块与阅读器硬件调优方案。

Android 运行在独立的 `ext4` 系统镜像（`veradroid-sys.img`）与挂载命名空间容器内，**不刷机、不替换 Kobo 内核、不改动 Kobo 系统分区与原生书库**；退出后自动卸载镜像与 loop 设备，不影响 USB 传书，随时一键返回 Kobo 原生界面（Nickel）或 KOReader。

- **上游项目**：[VeraDroid](https://github.com/xyc0677/veradroid)（原作者 `ajie` · [veradroid.wenjin.jp](https://veradroid.wenjin.jp)）
- **Kobo 移植与优化**：`scokyfei`（参考 [Koboweread](https://github.com/scokyfei/Koboweread)）
- **开源协议**：GPL-3.0-or-later（见 [`LICENSE`](LICENSE)、[`NOTICE`](NOTICE)、[`THIRD_PARTY.md`](THIRD_PARTY.md)）

> 本项目为社区开源项目，与 Rakuten Kobo、Google、腾讯或 Amazon 均无关联。发布的安装包不含任何个人数据或第三方闭源应用 APK（如微信读书需由用户自行安装）。

---

## 适用设备与环境

| 项目 | 要求 |
|---|---|
| 设备型号 | **Kobo Libra 2 (N418)**（i.MX6SL 单核 Cortex-A9 + NEON，512 MB RAM，1264×1680 300 ppi） |
| 支持固件 | **4.38.23852**（内核 `4.1.15-00868-g58a2758be07`）或 **4.34.20097**（内核 `4.1.15-00838-g349fbf5767c`） |
| 启动入口 | **NickelMenu**（可独立使用，无需安装 KOReader）或 **KOReader 插件**（两者可同时安装） |
| 存储空间 | 全新安装建议 Kobo 剩余空间 **≥ 2.5 GB**（首次启动自动创建 2 GB ext4 镜像） |

---

## 核心特性

- **双入口无缝切换**：同时提供 **NickelMenu** 入口（内置独立 `fbink` / `fbdepth`，无需 KOReader）与 **KOReader 插件** 入口；进入时自动暂停 Nickel / KOReader，退出时自动恢复原界面与帧缓冲色深。
- **深度墨水屏显示优化 (`veradroid-epd`)**：
  - 原生 `1264×1680`（300 ppi）局部刷新、REAGL / GL16 / A2 滚动波形、Eclipse 夜间波形（`GLKW16`/`GCK16`）与暗底压黑；
  - **4 档实时 E-Ink 文字笔锋加黑**（Skia NEON 字形层加速 + Gamma 增强）与 **32×32 插图智能抖动**（文字锐利、插图柔和）；
  - 阅读页专属翻页动画门控、弹窗/目录收起自动清残影、大图后自动消残影、单应用独立显示配置。
- **完整硬件操控与手势 (`veradroid-input`)**：
  - Elan 触摸屏 `--swap-xy` 坐标映射、**重力感应自动旋转**（`kx122`，0°/90°/180°/270° 无重启随动）；
  - 实体翻页键支持互换与 **14 种长按快捷功能**；
  - **左右边缘上下滑动无级调亮度与色温**（直写 `mxc_msp430` / `lm3630a` sysfs，支持左右互换）；
  - 底边三段手势、顶边下拉快捷面板、双指手势、四角长按（默认左下角长按 2 秒返回 Kobo）。
- **USB MTP 实时传书 & 蓝牙翻页器 / 蓝牙音频**：
  - 支持在 Android 运行中直接插 USB 线开启 **MTP 双卷传输**（同时挂载 `VeraDroid` 安卓存储与 `Kobo Onboard` 原生书库，传书/字体/APK 无需退出系统）；
  - 基于 Kobo 原生 BlueZ 5.63 与 BlueALSA，支持 **蓝牙 HID 翻页器**（`vdbtkeys` 实时键位映射与方向互换）及 **A2DP 蓝牙耳机/音箱音频输出**（内置自研 `audio.primary.kindle.so` HAL，听书/朗读直接走蓝牙，播放期间自动防休眠）。
- **低内存、流畅翻页与深度省电调优**：
  - `256 MB` ZRAM + `vdsqueeze` 冷页预挤压 + 零 FUSE `kobo-sdcard` 绑定挂载 + 后台应用智能 `speed-profile` / `speed` AOT 预编译；
  - 微信读书专项流畅度调优（`WRCommonPool` 防优先级反转、保守 CMS 堆窗口防连环 GC、实体翻页键按下即解除限频与 400 ms Boost、阅读模式全刷静默优化）；
  - **真 `mem` 深度休眠**（过滤 Linux 4.1 伪 RTC 唤醒，待机功耗低至 ~0.1%/h）、阅读静止 15s 自动 Wi-Fi LPS 省电（充电/SSH 期间自动保持全速）、CPU 静止柔和限频、独立无操作息灯。
- **完整 VeraHome 桌面生态**：
  - 6 大分层设置、6 格快捷下拉面板（含蓝牙开关与长按管理）、顶栏蓝牙状态图标、内置应用商店 & 字体商店（6 位绑定码登录）、本机 APK 一键扫描安装、局域网网页传书 / Kobo 专属管理后台（PIN 保护）、离线阅读器、阅读时长统计、自定义屏保与锁屏（支持 Kobo 根目录 `reset-pin.txt` 重置）。
- **纯净系统、配置备份与离线增量升级**：
  - 首次启动自动为设备生成随机 `android_id`；Wi-Fi 直接复用 Kobo 宿主机网络配置，安装包不含任何个人隐私；
  - 支持**配置一键备份与还原**（归档至 `.adds/Veradroid-Libra2/backup/`，自动剔除凭证与锁屏密码）及**一键导出诊断日志包**（直出至 Kobo 盘根目录或经 Web 管理端直接下载）；
  - 内置桌面与双入口离线升级管理器（`localupdate.sh`），支持 SHA-256 校验、防降级检查、失败自动回滚，增量升级 **100% 保留已装应用、书籍、阅读进度与设置**。

完整的技术实现、微信读书专项优化与实机基准测试数据见：[`docs/kobo-libra2-optimizations.md`](docs/kobo-libra2-optimizations.md)。

---

## 安装与升级指南

请前往本仓库 [Releases](https://github.com/scokyfei/Veradroid-Libra2/releases) 页面下载对应压缩包：

- **`Veradroid-Libra2-<版本>-full.zip`**（约 138 MB）：**全新安装完整包**
- **`Veradroid-Libra2-<版本>-upgrade.zip`**（约 4.6 MB）：**增量升级包**

### 一、全新安装（免 SSH，USB 解压即用）

1. 确保 Kobo Libra 2 剩余空间 **≥ 2.5 GB**。
2. 用 USB 数据线连接电脑，打开 Kobo U 盘根目录（即设备上的 `/mnt/onboard`）。
3. 将 `Veradroid-Libra2-<版本>-full.zip` 中的 `.adds` 文件夹完整解压合并到 Kobo 根目录：
   ```text
   .adds/
   ├── Veradroid-Libra2/                         # 主程序与纯净 Android rootfs
   ├── nm/Veradroid-Libra2                       # NickelMenu 入口（不覆盖你已有的 nm/config）
   └── koreader/plugins/Veradroid-Libra2.koplugin/  # KOReader 插件入口
   ```
4. 安全弹出 USB，直接从以下任一入口启动：
   - **NickelMenu**：右下角菜单 → `Veradroid-Libra2 (Android)`
   - **KOReader**：顶部菜单 → 工具 → `Veradroid-Libra2` → `启动 Veradroid-Libra2 (Android)`
5. 首次启动会自动创建 2 GB ext4 系统镜像（约 1–2 分钟，屏幕有进度提示，请勿关机），完成后自动删除临时 `rootfs.tar.gz` 并直接进入 Android 桌面。
   > 若习惯使用 SSH 安装，也可直接执行：`sh /mnt/onboard/.adds/Veradroid-Libra2/install.sh`

### 二、增量升级（保留全部应用、书籍与设置）

- **方式 A（推荐，自动校验与失败回滚）**：
  1. 将 `Veradroid-Libra2-<版本>-upgrade.zip` 直接复制到 Kobo 的 `.adds/Veradroid-Libra2/update/` 目录。
  2. 弹出 USB 后，点击 NickelMenu「`Veradroid-Libra2 检查更新`」或 KOReader「`应用离线升级包`」，或直接启动 `Veradroid-Libra2` 即可自动完成升级。
- **方式 B（USB 覆盖解压）**：
  - 将 `-upgrade.zip` 中的 `.adds` 目录直接解压覆盖到 Kobo 根目录即可（升级包不含 `veradroid-sys.img` 与 `settings.conf`，不会清除任何个人数据）。

### 三、安装第三方应用（如微信读书墨水屏版）

1. **应用商店**：进入桌面 →「应用商店」直接搜索安装；
2. **USB 自动安装**：将 32 位 ARM（`armeabi-v7a`）APK 放入 `.adds/Veradroid-Libra2/apps/`，启动后自动安装并清理原 APK；
3. **局域网传书网页**：打开桌面「传书与安装」，在电脑/手机浏览器上传 APK 或电子书。

### 四、常用操作

- **返回 Kobo / KOReader**：长按屏幕**左下角 2 秒**，或从顶部下拉面板点击「返回 Kobo」。
- **实体翻页键**：上键下一页、下键上一页；默认长按上键全刷消残影、长按下键返回（均可在设置中自定义）。
- **无级调光 / 色温**：在屏幕左右边缘上下滑动即可平滑调节前光亮度与色温。
- **电源键**：短按休眠进入深度待机，再按唤醒。

---

## 从源码编译与打包

```sh
# 1. 使用 Zig 0.13 交叉编译 Kobo ARMv7 静态二进制（无需 Docker）
ZIG=/path/to/zig FBINK_DIR=/path/to/fbink E2FSPROGS_TAR=/path/to/e2fsprogs-1.47.1.tar.xz \
  sh tools/kobo/build-kobo-bin.sh build/kobo-bin

# 2. 编译 VeraHome.apk（需 JDK 17 + android-25 android.jar + d8 + aapt2 + apksigner）
TOOLS_DIR=/path/to/tools bash tools/kobo/build-verahome.sh

# 3. 生成纯净发布包（full.zip + upgrade.zip + SHA256SUMS.txt，内置隐私审计）
BIN_DIR=build/kobo-bin \
EXTRA_BIN_DIR=/path/to/extra-kobo-bins \
LEGACY_DIR=/path/to/veradroid-legacy/veradroid-pw6 \
KMOD_DIR=/path/to/Koboweread/kernels \
  sh tools/kobo/build-release.sh dist
```

---

## 项目目录概览

| 目录 | 说明 |
|---|---|
| [`host/kobo/`](host/kobo/) | Kobo Libra 2 宿主机脚本（容器、显示、输入、休眠、网络、编译、离线升级、NickelMenu & KOReader 双入口、硬件配置） |
| [`display/legacy/epd.c`](display/legacy/epd.c) | Kobo EPDC v2 墨水屏显示桥（FBInk + NEON 灰度转换 + 局部插图抖动 + Eclipse 夜间波形） |
| [`input/legacy/vinput.c`](input/legacy/vinput.c) | 触摸 / 实体翻页键 / `kx122` 自动旋转 / 边缘滑光输入前端 |
| [`android/packages/VeraHome/`](android/packages/VeraHome/) | Kobo 适配版 VeraHome 桌面与系统服务源码 |
| [`tools/kobo/`](tools/kobo/) | Kobo 编译、打包、Bionic `madvise`/Skia NEON 垫片与运行时优化脚本 |
| [`docs/kobo-libra2-optimizations.md`](docs/kobo-libra2-optimizations.md) | 完整功能清单、优化说明与 Kobo Libra 2 实机基准测试记录 |

## 致谢与许可

- 感谢 [VeraDroid](https://github.com/xyc0677/veradroid) 作者 `ajie` 构建的优秀墨水屏 Android 框架。
- 感谢 [NiLuJe/FBInk](https://github.com/NiLuJe/FBInk)、[KOReader](https://github.com/koreader/koreader)、[NickelMenu](https://github.com/pgaskin/NickelMenu) 与 [霞鹜文楷 (LXGW WenKai)](https://github.com/lxgw/LxgwWenKai)。
- 本项目遵循 **GPL-3.0-or-later** 开源协议，详见 [`LICENSE`](LICENSE) 与 [`THIRD_PARTY.md`](THIRD_PARTY.md)。
