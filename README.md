# EZPcMonitor

跨平台轻量级 PC 硬件监控 · 半透明悬浮窗 · macOS 原生版

监控 **CPU / 内存 / 磁盘 / 网络 / 温度 / GPU**，用一块毛玻璃悬浮窗常驻桌面，双击展开完整主面板。

<p align="center">
  <img src="docs/screenshots/native-widget.png" width="288" alt="悬浮窗">
</p>

<p align="center">
  <img src="docs/screenshots/native-widget-bar.png" width="340" alt="紧凑条">
</p>

<p align="center">
  <img src="docs/screenshots/native-dashboard.png" width="760" alt="主面板">
</p>

## v0.2：外壳换成原生的

v0.1 是 Tauri 2 + React：Rust 采集，前端画界面，WebView 渲染。功能齐了，但两件事一直别扭——

一个是开销：一个监控软件自己占 71 MB 主进程 + 三个 WebKit 辅助进程，合计 166 MB，
「轻量」这两个字站不住。另一个是外观：毛玻璃是系统给的，可阴影、圆角、字体、动画
全都要跟 WebView 的 CSS 打架，最后做出来的是「网页在模仿 macOS」，不是 macOS。

v0.2 把**外壳**整个重写成 AppKit + SwiftUI，**采集内核一行没动**：Rust 还在 `core/`，
中间隔一层 C ABI + JSON。没有 WebView，没有 JS 运行时，也没有打包器。

| | Electron | Tauri 2（v0.1） | **原生（v0.2）** |
|---|---|---|---|
| 安装包 | 90–150 MB | 4.12 MB | **5.9 MB** |
| 常驻内存 | 150–300 MB | 71 MB（主进程）/ 166 MB（全进程） | **18 MB**（`phys_footprint`） |
| 主面板打开 | — | 166 MB | **33 MB** |
| 常驻 CPU | 3–8% | 2.4% 单核 | **约 5.5% 单核**（1 秒采集）· **约 1%**（5 秒采集） |
| 渲染 | Chromium | WebKit | AppKit / SwiftUI |
| 温度采集 | 需要 native 插件 | Rust 直连 IOKit | Rust 直连 IOKit |

`.app` 比 Tauri 版还大 1.8 MB，是因为 Tauri 那 4.12 MB 根本没算 WebKit——它借系统的。
原生版 5.9 MB 里有 705 KB 是自带的 `smartctl`，剩下是 4.9 MB 的二进制和图标。
**内存差 4 倍，这才是重点。**

CPU 那行不是笔误：1 秒一拍时确实要 5.5%，其中采集内核约 1%，其余是每秒重绘整块毛玻璃。
默认留 1 秒是因为曲线要跟手；只想挂着看，在设置里改成 5 秒，占用掉到 1% 左右。

## 特性

- **真·半透明**：`NSVisualEffectView` 的 `.behindWindow` 混合，桌面内容实时透过来，不是静态模糊图
- **主面板背景可换**：系统材质 / 六种纯色（着色玻璃，桌面照样透过来）/ 自己选一张照片（磨砂处理）。不透明度单独一根滑杆，只作用于背景层，文字和卡片始终不透明
- **无边框感的窗口**：内容延伸到标题栏底下，标题栏只剩三个红绿灯，正文和标题栏之间那条分隔线去掉了；正文自动让开红绿灯（安全区），窗口任意空白处都能拖
- **两种形态**：卡片（双环 + 温度 + 趋势）/ 紧凑条（单行）。条模式右键会把整条换成操作按钮，双击展开回卡片
- **主面板与悬浮窗互斥**：打开面板自动收起悬浮窗，关掉面板再放回来；自己点 ✕ 收起来的不会被翻出来
- **托盘全控**：形态切换（卡片 / 紧凑条 / 显示隐藏）、不透明度（100/90/80/70/60%）、采集频率都在菜单里点，偏好下次启动还记得
- **采集频率可调**：高（1 秒）/ 中（5 秒）/ 低（10 秒）三档 + 自定义（0.5–60 秒），托盘菜单和主面板齿轮都能改，改完当拍生效并记住
- **历史可回溯**：开启后每 10 秒记一条，保留 1 小时到 30 天（或自定义），点「历史」就能看过去六项指标的曲线和峰值。**默认关闭**，写不写盘你说了算
- **程序榜**：历史窗口里切到「程序」，按进程名合并出 top10 高占用榜，CPU / 内存 / 磁盘三个维度、按平均 / 峰值 / 活跃占比 / 增长任意排序——直接回答「刚才是谁卡的我」
- **一键报告**：一张 PNG 长图装下结论、六项走势和 Top5 高占用程序，存到下载目录或直接进剪贴板
- **设置窗口**：监控 / 通用 / 外观 / 历史记录 / 关于分组，齿轮和托盘「设置…」进的是同一个地方
- **深色 / 浅色两套配色**：默认跟随系统，也可以手动固定；`NSColor(name:dynamicProvider:)` 让同一份代码在两种外观下各出一套色，浅色不是「把深色调亮」，是重新配的一版
- **七种界面语言**：简体中文 / 繁體中文 / English / 日本語 / 한국어 / Français / Español，默认跟随系统语言，设置里随时切换，**不用重启**——托盘菜单和窗口标题跟着一起变
- **GPU 独立成卡**：利用率曲线 + 显存占用，和磁盘并列在第二行
- **不挡操作**：一键鼠标穿透（`ignoresMouseEvents`），全屏游戏里也安全
- **悬浮窗不抢焦点**：`NSPanel` + `.nonactivatingPanel`，点它不会把你正在用的 App 挤到后台
- **硬盘工具**：容量、实时读写、健康状态一眼可见；点开二级页看完整 SMART 属性表、实时曲线，还能做顺序读写测速。**`smartctl` 随包自带**，不用另装
- **按需采集**：悬浮窗只采必要指标，进程列表仅主面板可见时采集
- **零网络**：没有遥测、不联网；除设置文件外不写盘，历史记录需要你手动开启

## 快速开始

```bash
# 依赖：Xcode Command Line Tools / Rust 1.80+
#      Node 22 是可选的，只用来从 TS 字典导出 strings.json（没有就沿用已有的）
./macos/build.sh          # 构建 → macos/build/EZPcMonitor.app
./macos/build.sh --open   # 构建并启动
./macos/build.sh --debug  # 不优化（快，但别拿它量内存和 CPU）
```

验收/截图用的三个启动参数，直接拉对应窗口，省得去点菜单栏图标：

```bash
./macos/build/EZPcMonitor.app/Contents/MacOS/EZPcMonitor --dashboard
./macos/build/EZPcMonitor.app/Contents/MacOS/EZPcMonitor --history
./macos/build/EZPcMonitor.app/Contents/MacOS/EZPcMonitor --settings
```

## 项目结构

```
├── core/                      Rust 采集内核（跨平台，不认识 Swift）
│   ├── include/ezpcm_core.h   C ABI，宿主只需要这一个头文件
│   └── src/
│       ├── engine.rs          ezpcm_call 的方法分发
│       ├── metrics.rs         采集内核（CPU / 内存 / 磁盘 / 网络 / 温度）
│       ├── diskhealth.rs      硬盘健康（diskutil + smartctl）
│       ├── bench.rs           顺序读写测速
│       ├── gpu.rs             GPU provider
│       ├── history.rs         历史记录（JSONL + 按保留时长修剪）
│       ├── procstats.rs       程序榜（小时分片 JSONL + 按名字合并统计）
│       ├── settings.rs        设置持久化
│       └── i18n.rs            内核侧的文案（SMART 属性名等）
├── macos/                     macOS 外壳（AppKit + SwiftUI）
│   ├── Sources/EZPcMonitor/
│   │   ├── App/               Main · AppDelegate · AppModel · 菜单栏
│   │   ├── Core/              Engine(C ABI 封装) · Models · History · Leaders · L10n
│   │   └── UI/                悬浮窗 · 主面板 · 背景 · 历史 · 设置 · 磁盘详情 · 报告图 · 组件
│   ├── i18n/                  七份字典（TS 源码，构建时导出 JSON）
│   ├── Resources/             Info.plist · AppIcon.icns · strings.json · bin/smartctl
│   ├── tools/                 extract-strings.mjs（TS → strings.json）
│   └── build.sh               构建入口
├── docs/                      技术方案 / 决策记录 / 截图
└── app-icon.png               图标源图（scripts/gen_icon.py 画 1024² PNG，再用 iconutil 转 .icns）
```

## 架构：Rust 内核 + C ABI + SwiftUI

内核对外只有**四个符号**：

```c
EzpcmEngine *ezpcm_engine_new(data_dir, config_dir, bundled_smartctl);
char        *ezpcm_call(engine, method, args);   /* 返回 UTF-8 JSON，失败也是 JSON */
void         ezpcm_string_free(char *s);
void         ezpcm_engine_free(engine);
```

`ezpcm_call` 是唯一的数据入口，方法名走字符串（`snapshot` / `recent` / `history` /
`leaders` / `health` / `bench` / `settings` / `patch` …），参数和返回值都是 JSON。

三个选择值得说明：

**为什么不用绑定生成器。** UniFFI 那类工具解决的是「结构体很多、要自动对齐」的问题，
这里恰好不是——内核对外十几个方法，为它引一套代码生成 + 构建插件，维护成本大于收益。
手写一层 C ABI 一共四个函数，一页纸看得完。

**为什么是 JSON 而不是 C struct。** 加一个指标不用动 ABI：内核里加字段，Swift 侧的
`Decodable` 多一个 `let`，二进制契约不变。换成 struct 就要重新对齐内存布局、重新定版本。
历史文件本来就是 JSONL，形状天然一致。1 秒一拍的量级上，序列化开销测不出来。

**为什么外壳轮询、内核不回调。** 跨语言回调要把函数指针和生命周期一起管：内核线程
持有 Swift 闭包，Swift 对象释放时内核还在回调，这类崩溃只在偶发时机出现。轮询把并发
问题关在内核内部（一把锁），外壳只看得到「一次同步函数调用」；返回里带 `seq`，
没变就不重绘。

主面板、历史、设置三个窗口各自独立持有视图，关掉就整个放掉——`NSHostingView` 里的
表格和进度条不该在关窗之后继续占内存。

## 平台支持

| 指标 | macOS 13+ | Windows | Linux |
|---|---|---|---|
| CPU / 内存 / 磁盘 / 网络 / 磁盘测速 | ✅ | 内核已实现，缺外壳 | 内核已实现，缺外壳 |
| 温度 | ✅ 无需 root | 同上 | ✅ 无需 root |
| GPU 利用率 | ✅ | 同上 | ✅ amdgpu |
| 硬盘健康 / 寿命 | ✅ 自带 smartctl，免安装 | 同上 | ✅ 自带 / 系统包 |

`core/` 里的 `cfg(target_os)` 分支都还在（Windows 走 WMI / PDH，Linux 读 `/proc` 和 sysfs），
C ABI 也是跨平台的。**缺的只是外壳**：要支持 Windows / Linux，得再写一套 UI。

## 硬盘工具

一级页面（主面板磁盘卡）只放一眼能看懂的东西：容量、实时读写、一行状态。**复杂信息
全部收进二级页**——点磁盘行打开，里面有完整属性表、实时读写曲线和顺序读写测速。

数据分三层，能拿到多少报多少：

| 层 | 依赖 | 能拿到 |
|---|---|---|
| 系统级 | 无（macOS `diskutil`） | 健康状态 Verified / Failing、固态还是机械、总线类型 |
| 完整 SMART | **随包自带的 `smartctl`** | 磨损百分比、可用备用块、累计读/写量、通电时间与次数、介质错误、异常掉电、完整属性表 |
| 降级 | — | 拿不到的字段直接不显示，**不用估算值冒充实测** |

`smartctl` 已经打进 App 里（`Contents/Resources/bin/`），用户不需要装任何东西；
跑不起来（比如架构不匹配）则自动回落到系统装的那份。外置 USB 硬盘盒常见不支持
SMART 直通，这种情况会显示系统给的状态并说明原因，而不是报错。

**关于「寿命」的措辞**：界面写的是「磨损」而不是「剩余寿命」。`percentage_used` 是厂商标称
耐久度的磨损记账，**不是故障预测**——盘可能在磨损 0% 时猝死，也可能磨损 80% 还活得好好的。
所以详情页把「介质错误」这类**已经发生**的计数摆在磨损旁边，并明确写了这句提醒。

**测速**只做顺序读/写各一次（256 / 512 / 1024 MB 可选），写前 `fsync`、读时绕开 page cache，
测完自动删除临时文件。不做 4K 随机——那是跑分软件的事，日常监控用不上，还多消耗 SSD 寿命。

## 设置

主面板右上角齿轮，或托盘菜单 → `设置…`，打开的是同一个窗口。按功能分组：

<p align="center">
  <img src="docs/screenshots/native-settings.png" width="620" alt="设置">
</p>

**监控**：采集频率高（1 秒）/ 中（5 秒）/ 低（10 秒），也可以填 0.5–60 秒的任意值。
托盘菜单里也有同样的三档，两处改的是同一份状态。

改动**当拍生效**：采集线程每轮现读一次间隔，不等当前 sleep 走完。频率存在
`settings.json`，下次启动还是这个值。

内部还有一层更慢的分级（磁盘 IO 2s / 温度 5s / 容量 30s），判断依据是**时间戳**而不是
「第几拍」，所以把主频率调到 10 秒，温度不会变成 50 秒才刷新——它跟着主拍走，只是每拍
检查一次该不该刷新。

## 主题

深色是原版，浅色是另配的一版——不是把深色反相，而是重新定了一遍：卡片改白底加淡投影、
正文用墨蓝而不是纯黑、图表曲线统一压深一档（1.6px 的线在白底上会被冲掉）。

设置 → 通用 → 主题：**跟随系统** / **深色** / **浅色**。跟随系统时会跟着 macOS 的外观
切换实时变，不用重启；手动固定后就不再管系统怎么设。

<p align="center">
  <img src="docs/screenshots/native-dashboard-light.png" width="760" alt="浅色主题">
</p>

配色用 `NSColor(name:dynamicProvider:)` 声明一次，两套色值都挂在同一个颜色上：视图代码
只说「这是次要文字」，由 AppKit 按当前 `NSApp.appearance` 决定用哪一档。切换主题因此
不需要重建窗口，也不会出现「界面变浅了、标题栏还是深的」。

## 主面板背景

设置 → 外观 → 窗口背景。三档，都只影响主面板，历史和设置窗口跟随主题：

| 档位 | 怎么画的 |
|---|---|
| 系统材质（默认） | `NSVisualEffectView` 的 `.underWindowBackground`，磨的是窗口背后的桌面，跟着桌面内容实时变 |
| 纯色（6 种） | 同一层材质打底，再盖一层带透明度的色——macOS 的「着色玻璃」，颜色是染上去的，底下的桌面依然被磨过 |
| 自定义图片 | 导入时缩到 720px、高斯磨好、存成 45 KB 的 JPEG；合成时上面再盖一层材质负责压暗和降饱和 |

<p align="center">
  <img src="docs/screenshots/native-dashboard-tinted.jpg" width="760" alt="纯色背景">
</p>

图片那档为什么在**导入时**磨而不是合成时磨：照片是静止的，磨出来的像素每次都一样，
实时磨等于每帧重算一遍同样的结果。而且开销基本正比于图片像素数——同一张图 1400px 让
主面板从 31 MB 涨到 47 MB，720px 只有 36 MB，两者显示出来是同一片渐变（模糊之后 15px
以上就没有细节了）。完整的拆解表在 [docs/PERF.md](docs/PERF.md)。

<p align="center">
  <img src="docs/screenshots/native-dashboard-photo.jpg" width="760" alt="图片背景">
</p>

色块的点击语义：没选过图 → 弹文件面板；选过但没在用 → 应用它；正在用 → 不动，换图走
右键菜单（换一张… / 清空）。

背景存在 UserDefaults 而不是 `settings.json`——它只影响一个窗口怎么画，内核不需要知道。


## 语言

简体中文 / 繁體中文 / English / 日本語 / 한국어 / Français / Español 七种，**默认跟随系统语言**，
设置里随时切换。

<p align="center">
  <img src="docs/screenshots/native-history.png" width="760" alt="历史记录">
</p>

切换**立即生效，不用重启**：主面板、悬浮窗、三个窗口、托盘菜单、窗口标题一起变。

没有引 i18n 库——只需要查表、插值和单复数。`macos/i18n/zh-CN.ts` 是唯一基准，其余六份的
类型由它推导，**少翻一条键构建就报错**；构建时导出成 `strings.json`，Swift 侧的 `L10n`
读这一份（194 条文案 + 8 个单复数键 × 7 种语言），托盘菜单是 `NSMenu` 画的，用的是同一份。

两处例外，都是刻意的：**SMART 属性名**在非中文下用英文（`Percentage Used`、`Available Spare`
——smartctl / CrystalDiskInfo 里本来就这么写，硬翻反而对不上号）；**容量单位**统一按
SI 记号（KB / MB / GB）显示。

## 历史记录

「刚才是谁把 CPU 吃满了？」——这个问题实时曲线答不了，得能往回看。

**默认关闭**。开启后每 10 秒记一条（和采集频率无关，1 秒刷新也不会把文件撑大），
保留时长可选：

| 保留 | 预计占用 |
|---|---|
| 1 小时 | 约 30 KB |
| 6 小时 | 约 180 KB |
| 24 小时 | 约 710 KB |
| 7 天 | 约 4.8 MB |
| 30 天 | 约 21 MB |

点主面板右上角「历史」，切时间窗看 CPU / 内存 / 温度 / 网络 / 磁盘 IO / GPU 六项曲线。
实线是**区间内峰值**、阴影是**均值**——只画均值会把「飙到 100% 的那十秒」平均掉。

数据是 `history.jsonl`（一行一条，约 85 字节），只追加；修剪时整文件重写一次并用
`rename` 原子替换，掉电不会留下半截文件。文件在
`~/Library/Application Support/dev.ezpc.monitor/`，设置里能看到实时占用，也能一键清空。

### 程序榜：是谁卡的

曲线回答「什么时候卡的」，程序榜回答「是谁卡的」。同一个窗口右上角切到「程序」，
时间窗和曲线共用——它本来就是从同一段历史里算出来的。

按**进程名合并**（Chrome 开二十个进程也只占一行），扫的是全量进程表而不是当前前几名，
所以「每个子进程都不高、加起来最高」的应用不会漏掉。维度可选 CPU / 内存 / 磁盘，
每列都能点表头排序，默认按**峰值**：

| 列 | 回答的问题 |
|---|---|
| 平均 | 这段窗口里它平均占了多少（分母是窗口内全部样本，没出现记 0） |
| 峰值 | 最高冲到过多少、几点冲的 |
| 活跃占比 | 有多少比例的采样它超过了阈值——「是不是一直在动」 |
| 增长 | 窗口内内存涨了多少——「是不是在漏」（仅内存） |

没用中位数：桌面进程的 CPU 是大量 0 组成的稀疏分布，中位数恒为 0，
和完全不动的进程分不出来。

底层存的是**原始样本**而不是统计结果——每 30 秒一拍写进 `procs/` 下按小时分片的
JSONL（约 600 字节/拍，一天不到 2 MB），所以任何统计口径都能以后再加。

### 一键报告

<p align="center">
  <img src="docs/screenshots/native-report.png" width="420" alt="资源占用报告">
</p>

点「报告」直接生成一张 PNG 长图（2160 × 2734）：结论条（整机 CPU 峰值 + 最费 CPU 的程序）、
六项指标走势、Top5 高占用程序，底部带生成时间和采样点数。默认落在下载目录
（重名自动加序号，不覆盖旧图），旁边的「复制」直接进剪贴板，粘到聊天窗口就能发。

图用 SwiftUI 的 `ImageRenderer` 离屏渲染。有个坑：位图没有 appearance 概念，
`Color.primary` 这类动态色在离屏渲染时会被解析成当前外观的颜色，深色主题下可能整张是黑的
——所以报告页的颜色全部写字面量十六进制。

## 性能

实测环境：macOS 15.5 / Apple M1 Pro / Release 构建 / 1 秒采集

| 指标 | 实测 |
|---|---|
| 安装包（`.app`） | **6.2 MB**（含自带的 705 KB smartctl） |
| 二进制 | 5.2 MB |
| 悬浮窗常驻内存 | **17 MB**（`phys_footprint`）/ 42 MB（RSS，含 dyld 共享缓存） |
| 主面板打开 | **32 MB**（默认背景）· 36 MB（换成自定义图片） |
| 常驻 CPU | **约 6.6% 单核**（1 秒采集）· **约 2.4%**（5 秒采集） |

几个说明：

- 用 `phys_footprint` 而不是 RSS。RSS 把 dyld 共享缓存算进每个进程，同一份系统库在十个
  进程里会被统计十次，横向比较没有意义。
- 6.6% 里有约 1% 是采集内核（同口径下单独跑内核测的），其余是每秒重绘整块毛玻璃。
  想省电就把频率调到 5 秒或 10 秒。
- 进程列表只在主面板可见时采集，关窗立刻 `wantProcs(false)`。
- 换图片背景多 4 MB，因为要整窗铺一张图；默认的系统材质没有这笔开销。
- 每次改动的逐项数字和 delta 记在 [docs/PERF.md](docs/PERF.md)，`./scripts/measure.sh` 追加。

## 文档

- [docs/DESIGN.md](docs/DESIGN.md) —— v0.1（Tauri 版）的完整技术方案：选型对比、采集矩阵、
  权限模型、悬浮窗规范、路线图。目录结构那几节已经过时，结论仍然有效。
- [docs/DECISIONS.md](docs/DECISIONS.md) —— 决策记录。ADR-001 ~ 015 是 WebView 时期，
  ADR-016 起是原生版（为什么换外壳、为什么是 C ABI + JSON、为什么轮询、为什么不用
  Xcode 工程）。**改动架构前请先读这里**，理由比结论更容易被忘掉。

## License

MIT
