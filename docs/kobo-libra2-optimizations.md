# Kobo Libra 2 (N418) 系统与微信读书优化清单及作用范围

本文档汇总 `kobo-libra2` 分支在 **Kobo Libra 2（单核 i.MX6SL Cortex-A9 1 GHz + 512 MB RAM）** 上的全部性能优化措施，并按作用范围明确区分：
1. **全局系统、内核与墨水屏显示层优化（对所有程序均生效）**
2. **跨应用「分档隔离」的运行时策略（微信读书与其他 App 按不同配额生效）**
3. **仅针对微信读书的专属优化（按进程名 `com.tencent.weread.eink` / `:seg` 严格隔离，对其他程序零影响）**

> 每次新增或调整优化措施后，请同步更新本清单与末尾的实机基准测试记录。

---

## 一、全局系统、内核与墨水屏显示层优化（对所有程序均生效）

这些改动位于 Linux 宿主机内核参数、E-Ink 显示桥（`veradroid-epd`）、输入桥（`veradroid-input`）及 Android 容器底座，**所有运行在 VeraDroid 里的程序（桌面、阅读器、工具类 App）均直接受益**：

| 优化项目 | 作用范围 | 具体实现与对所有程序的效果 | 代码位置 |
| :--- | :---: | :--- | :--- |
| **1. ARM NEON Skia 字形加速 (`KFB_SKIA_OPT=1`) + E-Ink 文字笔锋加黑 (`KFB_FONT_GAMMA`)** | **所有 Android 应用**（均可在设置开关/调档） | 通过 `libkobo_madvise.so` 将 Android `libskia.so` 的 `_ZN6SkOpts16blit_mask_d32_a8E`（A8 抗锯齿字形混合）与 `_ZN6SkOpts16blit_row_color32E`（半透明纯色填充）替换为 ARM NEON 向量实现（文字渲染提速 3～4 倍）；并在 `blit_mask_d32_a8` 字形层提供 **4 档可调 E-Ink 文字边缘 Gamma 笔锋加黑**（`0=关`、`1=轻度 1.30`、`2=适中 1.55(默认)`、`3=浓郁 1.85`），翻页实时生效，**仅加黑文字抗锯齿边缘与宋体细横画，对书架封面、插图和灰色 UI 零影响**。 | `tools/kobo/libkobo_madvise.c`、`host/kobo/boot/lib/settings.sh`、`android/packages/VeraHome/src/com/veradroid/home/BlocksSettings.java`、`HostSettingsActivity.java` |
| **2. CPU `interactive` 调速器、触屏瞬时升频、25 ms 单指窗口、实体翻页键可定制长按与左右边缘滑动调光 / 色温** | **全局所有程序** | 启动容器时将 `interactive` 调速器设为 `hispeed_freq=1000000`、`go_hispeed_load=75`、`timer_rate=20000`、`min_sample_time=60000`（退出容器自动恢复）；手指触屏或按翻页键瞬间将 `scaling_min_freq` 拉满 1 GHz 保持 150ms；双指手势等待窗口 `--window` 收紧至 **`25 ms`**；支持为实体上一页/下一页键分别配置 **14 种长按快捷功能**（`关` / `全刷消残影` / `返回` / `快捷面板` / `回桌面` / `切换应用` / `夜间反色` / `开关前光` / `前光调亮` / `前光调暗` / `截屏` / `开关Wi-Fi` / `立即休眠` / `返回Kobo`，长按时长 `0.35s–1.0s` 可调，自动跟随旋转与互换设置，设为「关」时按下即翻页零释放延迟）；并新增 **左右边缘上下滑动无级调光 / 色温（`G_EDGE_LIGHT=1`，支持开关与 `G_EDGE_LIGHT_SWAP` 左右边功能互换）**：参考 `Koboweread` `edge-light.h`，默认**靠近实体翻页键一侧的边缘（`0°` 为右边、`180°` 为左边）调节亮度**（直写 `mxc_msp430.0/brightness`），**另一侧调节色温**（直写 `lm3630a_led/color`），开启互换后两侧对调；每 50 ms 平滑更新、松手弹出单次墨水屏百分比角标，旋转后逻辑上滑始终调高、下滑始终调低，边缘轻点与横滑翻页透传给应用不受影响。 | `host/kobo/boot/lib/memory.sh`、`host/kobo/boot/lib/input.sh`、`host/kobo/boot/action.sh`、`host/kobo/boot/lib/settings.sh`、`host/kobo/models/libra2.conf`、`input/legacy/vinput.c`、`android/packages/VeraHome/src/com/veradroid/home/BlocksSettings.java`、`HostSettingsActivity.java`、`HomeActivity.java` |
| **3. eMMC / loop `deadline` I/O 调度器与分设备预读调优** | **全局所有程序** | 将 `mmcblk0` 与 `loop` 设备切换为 `deadline` 调度器（`read_expire=100ms, write_expire=1000ms, fifo_batch=4, front_merges=1`），并将 `mmcblk0` 预读设为 `128 KB`、`loop` 设为 `64 KB`，**降低所有程序的随机读延迟，避免小文件 I/O 放大**。 | `host/kobo/boot/lib/memory.sh` |
| **4. ZRAM 256 MB + VM 参数 + 开机 `vdsqueeze 64` 预挤压** | **全局所有程序** | 配置 256 MB ZRAM（`swappiness=100, page-cluster=0, dirty_ratio=15, dirty_background_ratio=5, vfs_cache_pressure=80, min_free_kbytes=6144`）；开机 `boot_completed` 后执行 `vdsqueeze 64` 将 Zygote 与 `system_server` 启动期冷匿名页提前压入 ZRAM，并配合 `VeraHome` 在 `onStop()` 退后台时主动调用 `VMRuntime.trimHeap()`，**为前台应用多腾出 35～50 MB 可用物理内存**。 | `tools/src/vdsqueeze.c`、`host/kobo/models/libra2.conf`、`host/kobo/boot/lib/memory.sh`、`android/packages/VeraHome/src/com/veradroid/home/HomeActivity.java` |
| **5. `kobo-sdcard` 零 FUSE 存储绑定挂载** | **全局所有程序** | 使用极简 C 辅助进程 `kobo-sdcard` 直接以内核 `MS_BIND` 挂载 `/data/media/0` 到 `/mnt/runtime/{default,read,write}/emulated`，替代 Android 原生 `sdcard` FUSE 守护进程，**所有程序读写 `/sdcard` 零 FUSE 上下文切换开销，且常驻节省 ~4 MB 内存**。 | `tools/kobo/kobo-sdcard.c`、`host/kobo/boot/lib/container.sh` |
| **6. 墨水屏硬件日蚀夜间模式、残影消除、黑场过滤、弹窗收起清理与状态栏微刷合并** | **全局所有程序** | • Kobo 硬件 `GLKW16`/`GCK16` 日蚀夜间模式波形 + 暗部压黑（`dark_crush`）+ 可选全刷消残影；<br>• 过滤 Activity 切换瞬间的 >85% 全黑未就绪过渡帧，消除切页面黑闪；<br>• **目录/工具栏/弹窗收起自动清理 (`kobo_is_overlay_dismiss`)**：4×4 网格检测 UI 蒙层/极简线条工具栏收起回到干净正文背景时，自动升级为无黑闪 `REAGL`/`GLKW16` 质量刷新，彻底消除边框残影；<br>• **翻页动画仅限阅读翻页生效 (`READER 0|1` + `DIR` 门控)**：`HostService` 实时识别前台是否为阅读页（微信读书 `ReaderFragmentActivity`、内置阅读器、`KOReader`、`Legado` 等）并通知 `veradroid-epd`，同时要求进入阅读页后的新翻页输入（`DIR 0..3`）且排除居中呼出菜单、目录/弹窗收起与返回/回桌面等导航动作，彻底杜绝桌面、书架、设置、开/关书等非翻页界面误触发翻页动画；<br>• 活跃阅读期（距上次翻页 `< 180s`）自动合并顶/底 `56px` 状态栏内宽度 `<= 360px` 的时钟跳分/电量微刷新，随下一次翻页一并刷出。 | `display/legacy/epd.c`、`host/kobo/boot/lib/epd.sh` |
| **7. Wi-Fi 传输层上报 + 阅读静止期 15s 自动 LPS 省电 + TCP 缓冲调优** | **全局所有程序** | • `ethernet-service-wifi.jar` 让 Android `ConnectivityManager` 正常上报 `TYPE_WIFI` / `TRANSPORT_WIFI`；<br>• **阅读静止期精细化 LPS**：触屏/按键瞬间（`action.sh poke`）唤醒 RTL8723DS 至 `LPS=0` 保证低延迟网络响应；亮屏静止阅读超过 `15 秒` 且无大流量下载时由 `wifi_ps_tick()` 自动切回 **`LPS=2 / IPS=0`**（省电 ~70～80 mA 同时保持关联态，WebAdmin 网页传书与 SSH 随时可达），仅整机休眠或退出时启用 `IPS=1`；<br>• TCP `rmem_max`/`wmem_max` 提升至 1 MB。 | `tools/kobo/patch-ethernet-wifi.py`、`host/kobo/boot/lib/network.sh`、`host/kobo/boot/action.sh` |
| **8. 后台 `VeraHome` 低频轮询、闲置 `VeraIME` 内存回收与双顶栏自动抑制** | **全局所有程序** | • `HostService.fgPoll` 兜底轮询间隔从 `10s` 放宽至 `120s`（依赖事件驱动 `ITaskStackListener`），消除前台看书时后台每 10 秒跨进程 Binder 唤醒与周期 GC；<br>• `bgnice_tick()` 在阅读前台期间自动对隐身闲置的 `com.veradroid.ime` 发送 `trim-memory COMPLETE` 并回收缓存辅助进程（`defcontainer`/`statementservice`/`externalstorage`）；<br>• 前台为自带顶栏的微信读书（`com.tencent.weread.eink`）时自动调用 `StatusBarService.setAppSuppressed(true)` 隐藏 `VeraHome` 悬浮顶栏并取消其 60s 时钟定时器，彻底解决双顶栏重叠与每分钟重绘唤醒。 | `android/packages/VeraHome/src/com/veradroid/home/HostService.java`、`android/packages/VeraHome/src/com/veradroid/home/StatusBarService.java`、`host/kobo/boot/lib/bgnice.sh` |
| **9. Android 框架 `boot.oat` + `services.odex` 离线 `--non-debuggable` 重编译支持** | **全局所有程序** | 提供 `tools/kobo/compile-boot-nodebug.sh` 与容器自动 bind-mount 支持（注：当前 VeraDroid 镜像 `/system/framework/*.jar` 为 AOSP `dex-stripped` 裁剪版，需配合未裁剪 AOSP `javalib.jar` 或 ROM 编译期关闭 `--debuggable` 使用，脚本已内置保护检测）。 | `tools/kobo/compile-boot-nodebug.sh`、`host/kobo/boot/lib/container.sh` |

---

## 二、微信读书与其他程序「分档隔离」的运行时策略

以下两项对微信读书和其他程序采用**不同的参数档位**，既满足微信读书重度排版与书架封面的需求，又避免其他轻量应用浪费内存：

| 优化项目 | 微信读书 (`com.tencent.weread.eink` / `:seg`) | 其他所有程序 (`VeraHome` / 第三方 App) | 代码位置 |
| :--- | :--- | :--- | :--- |
| **1. Skia 字形缓存上限 (`SkGraphics::SetFontCacheLimit`)** | **16 MB / 16,384 字形**（防止中文大字库整章排版与跨章时字形缓存频繁抖动重栅格化） | **8 MB / 4,096 字形**（由 `KFB_SKIA_OPT=1` 控制，兼顾文字渲染加速与低内存占用） | `tools/kobo/libkobo_madvise.c` |
| **2. ART 虚拟机堆参数与 `getMemoryClass()`** | **`minfree=4m, maxfree=8m, growthlimit=96m, target_utilization=0.75, gctype=MS`**（为 Glide 书架封面缓存池提供 96 MB `MemoryClass`，同时增大空闲堆窗口减少翻页/排版期的 GC 次数） | **`minfree=2m, maxfree=8m, growthlimit=64m`**（保持紧凑堆上限，避免后台或工具类进程吃满 512 MB RAM） | `tools/kobo/libkobo_madvise.c`、`host/kobo/models/libra2.conf` |

---

## 三、仅针对微信读书的专属优化（对其他程序零影响）

以下所有优化在 C 层（`libkobo_madvise.c`）与 Java 层（`kobo-weread-opt.jar`）均通过 **`/proc/self/cmdline` 严格校验进程名是否为 `com.tencent.weread.eink` 或 `com.tencent.weread.eink:seg`**。对于其他任何程序，这些逻辑**完全不会加载、不会拦截、不会执行**：

| 微信读书专属优化项目 | 作用机制与效果 | 是否影响其他程序 | 代码位置 |
| :--- | :--- | :---: | :--- |
| **1. 微信读书 APK `speed-profile` 热点 AOT 编译、开机预读与充电闲时自动增量刷新** | 使用 `weread-speed-profile.sh` 向运行中的微信读书发送 `SIGUSR1` 采集真实阅读/翻页/书架热点方法 profile，以 `speed-profile` 过滤器重编译 `base.odex`（体积从全量 `speed` 的 **`70.6 MB` 降至 `38.0 MB`**，减少 `32.6 MB` 冷代码页缓存压力），开机后后台 `dd` 预热进 Page Cache；充电且闲置 `>= 120s` 且实时 `primary.prof` 增长 `>= 2 KB` 时由 `compile_watch()` 自动触发增量刷新（每 24h 最多一次）。 | **无影响**（仅重编译微信读书自身 `base.odex`） | `tools/kobo/weread-speed-profile.sh`、`host/kobo/boot/lib/compile.sh`、`host/kobo/boot/lib/afterboot.sh` |
| **2. SQLite WAL 模式转换、定期离线 `WAL Checkpoint + optimize` 维护与 `*-wal`/日志/遥测库 `fsync` 免阻塞** | • 容器启动前离线自动检测并将 `WRBook`、`WRReader` 切换为 SQLite `WAL` 模式；已处于 WAL 模式且 `-wal >= 2 MB` 或距上次维护满 7 天时自动执行 `PRAGMA wal_checkpoint(TRUNCATE); PRAGMA optimize;` 消除 WAL 膨胀与 B-Tree 统计过期；<br>• `skip_weread_log_sync()` 首行检查 `if (!is_weread_proc()) return 0;`，仅对微信读书的 `*-wal`、`/log/`、`/logs/`、`/BusReport/`、`wr.log.*`、`bugly_db*`、`WaitReport*`、`beacon*` 跳过阻塞式 `fsync`/`fdatasync`（主数据库 checkpoint 落盘仍保留完整 `fsync`）。 | **完全零影响**（其他程序的 `fsync`/`fdatasync` 100% 原样直通内核） | `tools/kobo/libkobo_madvise.c`、`host/kobo/boot/lib/container.sh` |
| **3. 遥测与热更新域名 DNS 拦截 (`getaddrinfo`)** | 仅在 `is_weread_proc()` 为真时拦截 `bugly.qq.com`、`android.rqd.qq.com`、`tpns.tencent.com`、`beacon.qq.com`、`oss.weread.qq.com`、`dldir1*.qq.com` 等遥测与自动下载更新域名，立即返回 `EAI_NONAME` 并配合只读空目录 `tinker`/`update` 彻底屏蔽升级弹窗与后台流量。 | **完全零影响**（其他程序的 DNS 解析不受任何拦截） | `tools/kobo/libkobo_madvise.c`、`host/kobo/boot/lib/container.sh` |
| **4. 思源宋体 `11.3 MB` OTF 离线解压与 `FontMap` `mmap` 映射** | 容器启动时离线从微信读书 APK 解压 `SourceHanSerifCN-Medium_FDK_motify_strip.otf`（`11.3 MB`）到 `/data/local/tmp/weread-fonts/`，运行期由 `FontMap` 线程以 `Typeface.createFromFile()`（只读 `mmap` 共享物理页）替换 `TypefaceUtil.fontCacheMap`，消除每次冷启动的 ZIP 解压流拷贝。 | **完全零影响** | `host/kobo/boot/lib/container.sh`、`tools/kobo/weread-opt/KoboWeReadOpt.java` |
| **5. 微信读书线程池优先级编排（消除单核 MS GC 优先级反转）** | 仅针对微信读书内部线程设定严格优先级阶梯：`TypeSetting (-6) > main (-10/0) > WRCommonPool/WRNetworkPool (10) > MPool/OkHttp (13) > WRLowPriorityPool/WRPreloadPool (19) >= :seg 全线程 (19)`，并在主动触发 `concurrentGC() + trimHeap()` 时临时切至 `nice 0`，根除单核 CPU 上低优先级线程持锁执行 Stop-The-World GC 被 `:seg` 抢占导致的数秒卡顿与 ANR。 | **完全零影响** | `tools/kobo/libkobo_madvise.c`、`tools/kobo/weread-opt/KoboWeReadOpt.java` |
| **6. `WRWebViewPool.preInit` 延迟初始化与 `RMonitor` 停用** | 仅阻止微信读书启动时预创建空闲 Chromium WebView 实例（节省 25～35 MB RAM）并调用 `RMonitor.abolish()` 停用腾讯性能监控采样线程；不修改系统 WebView 组件本身。 | **完全零影响**（其他 App 使用 WebView 完全正常） | `tools/kobo/libkobo_madvise.c`、`tools/kobo/weread-opt/KoboWeReadOpt.java` |
| **7. `kobo-weread-opt.jar` 全部 10 项 Java 运行期插件** | 仅通过 `DexClassLoader` 注入 `com.tencent.weread.eink` 与 `:seg` 进程：<br>• **`SegPrestart`**：主进程启动 4s 后提前拉起 `:seg` 分词服务，避免首次开书叠加 `:seg` 冷启动洪峰；<br>• **`OpenBoost`**：监听 `ReaderFragmentActivity` 创建后的前 `2.5s` 首屏排版窗口，临时将 `WRCommonPool`/`WRNetworkPool`/`MPool`/`OkHttp`/`Rx*` 降到 `nice 16`（仍高于 `:seg` 的 `nice 19` 防止 GC 优先级反转），把单核 CPU 让给主线程与 `TypeSetting` 排版线程；<br>• **`FontSizeCache`**：内存缓存字号 `SharedPreferences`（消除每帧数千次 XML HashMap 查找），并**自动将「↑ 上滑显示工具栏」底部悬浮提示药丸设为 `View.GONE`**；<br>• **`SyncThrottle`**：对 `LoadBookLightRead`、`LoadBestBookMarks` 及**按书籍维度（`"0,1"`）的 `LoadBookChapterReviewList`** 执行 12 小时持久化限流（关闭 30 秒分页拉取窗口，彻底消除大书跨章时后台连续拉取数百条热门想法写入 `WRBook` SQLite 导致返回书架卡在「加载中...」的问题）；<br>• **`MarkUsersCache`**：热门划线用户表 `4,000` 条 LRU 内存缓存；<br>• **`ChapterPrefetch`**：按电源状态动态将预排版章节半径从 `±1` 扩至充电 `±3` 章 / 电池 `±2` 章；<br>• **`ReaderPageRelease`**：退回书架闲置 30s 后清空残留 `ReaderFragmentActivity` 视图引用；<br>• **`SegDictRelease`**：`:seg` 进程闲置 30s 后卸载 `21 MB` IK 分词词典结构；<br>• **`MemoryTrim`**：主进程与 `:seg` 周期性执行 `concurrentGC() + trimHeap()` 并对空闲 anonymous dalvik 堆页调用 `madvise(MADV_DONTNEED)`。 | **完全零影响**（其他 App 不会加载此 JAR） | `tools/kobo/weread-opt/KoboWeReadOpt.java` |

---

## 四、Kobo Libra 2 实机基准测试基线记录（`v9`）

- **测试环境**：Kobo Libra 2 (N418)，固件 `4.38.23852`，VeraDroid `kobo-libra2`，微信读书墨水屏版 `1.9.7`
- **测试负载**：6 本书（7 次打开/返回书架切换）+《三体全集》连续 22 页翻页 + 呼出目录 + 跨章跳转 + 跨章后连续 8 页翻页（全程 `com.tencent.weread.eink` 保持前台，0 次 ANR、0 次退回桌面）

| 测试维度 | 实测指标 | 基线结果 (`v9`) |
| :--- | :--- | :--- |
| **连续 22 页翻页**（《三体全集》） | 第 2～22 页非全刷页均值 / 中位数 / 最快（18 页 `fast`） | **`550.5 ms`** / **`512.5 ms`** / **`432 ms`** |
| | 第 2～22 页周期全刷页均值（第 6、12、18 页 `FLASH`） | `695.3 ms`（`619 / 725 / 742 ms`） |
| | 第 2～22 页全部 21 页综合均值 / 中位数 | **`571.2 ms`** / **`530.0 ms`** |
| **目录与跨章翻页**（《三体全集》） | 呼出目录面板（`OPEN_TOC`） | **`1,151 ms`** |
| | 目录跨章跳转（`CHAP_SWITCH`） | **`2,437 ms`** |
| | 跨章后连续 8 页翻页均值 / 最快 | **`572.0 ms`** / **`348 ms`** |
| | 跨章后关闭返回书架（`CLOSE[Book1]`） | **`2,924 ms`** |
| **6 本书（7 次打开）切换** | 7 次开书平均耗时 / 最快开书 | **`9,456 ms`** / **`5,970 ms`**（《夜晚的潜水艇》） |
| | 《三体全集》间隔 5 本书后热重开耗时 | **`8,999 ms`**（较首次 `12,247 ms` 提速 **26.5%**） |
| | 7 次关书返回书架平均耗时 / 最快返回 | **`3,438 ms`** / **`1,794 ms`** |
| **内存与进程 RSS 稳定性** | 起点（书架页）→ 终点（7 次切书 + 54 页翻页后） | `MemAvail: 235.1MB → 174.0MB`<br>`MainRSS: 172.5MB → 156.4MB (-16.1MB)`<br>`SegRSS: 80.0MB → 50.7MB (-29.3MB)`<br>`HomeRSS: 32.2MB → 25.0MB (-7.2MB)` |
