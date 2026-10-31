# agent.md · macOS 原生桌面程序开发守则

> 复制到新项目根目录。开工前通读；改架构前重读「分层」和「测量」。
> 每条都来自实际踩坑，不是风格偏好——删之前先想想当初为什么写它。

## 0 底线

- 只用 Apple 原生框架（AppKit / SwiftUI / Foundation），不嵌 WebView。
- 最低系统版本显式写进编译参数（`-target arm64-apple-macos13.0`），不靠默认值。
- 零遥测、不开内核扩展、不要 root。
- **体积和常驻内存是竞争力**。能塞进 10 MB 就别塞 100 MB。

## 1 工程形态：不建 Xcode 工程

`swiftc` 直接编译 + 手工组装 `.app`，四步流水：

1. 逻辑内核（独立 crate / package）
2. 资源（i18n 字典、图标、随包二进制）
3. `swiftc -O -target arm64-apple-macosX.Y $(所有 .swift)`
4. 组装 `Contents/{MacOS,Resources,Info.plist}` + `codesign -s -`

理由：`build.sh` 一行可复现，CI 无痛，diff 里没有 `.xcodeproj` 噪声。
代价：Info.plist、资源路径、签名全得自己管。

- 资源用 `Bundle.main.resourceURL` 取，不要相对路径。
- **Info.plist 与代码必须一致**：`LSUIElement` 改完，LaunchServices 会缓存旧值；
  代码里再 `NSApp.setActivationPolicy(.regular)` 兜一次。
- 菜单栏常驻：`applicationShouldTerminateAfterLastWindowClosed` 返回 `false`；
  `applicationShouldHandleReopen` 里主动开主窗口——默认实现是「有窗口才提上来」，
  而平时唯一窗口是被收起的悬浮窗，点 Dock 图标会像没反应。

## 2 分层

```
内核（纯逻辑，不认识 UI） ──C ABI + JSON──▶ 外壳（SwiftUI / AppKit）
```

- **内核不碰语言**。文案在 UI 层；错误回 `{"error": "...", "code": "..."}`，
  `code` 供 UI 分支（`denied` / `readonly` / `nospace` / `io`），文案进 i18n 表。
- **用 JSON 而不是生成绑定**：加字段不用动 ABI，Swift 侧 `Decodable` 少写一个 key 也能解。
  一秒一次、不到 2 KB 的快照，序列化开销可忽略。
- C ABI 出口用 `catch_unwind` 兜 panic——一次越界不该带走整个宿主进程。
- 慢调用（读 SMART、写盘）走「缓存 + 超时」，绝不拖住采集主循环。

## 3 界面

**固定尺寸窗口**

- SwiftUI 的 `VStack` 在固定高度里**从顶部裁**，不是从底部。撑爆时丢的是标题和关闭按钮。
- 内容会长，就拆「上半钉住 + 下半 `ScrollView`」；别去抠十几点高度，抠到最后处处是巧合。
- **不要嵌套 `ScrollView`**：滚轮到底滚谁全看指针停在哪，比多滚两屏更糟。

**文案**

- 写给人看，不是写给字段看。`阈值 99%` → `低于 99% 会报警`；空备注补 `纠不回来的坏块`。
- 术语要么配一句人话，要么不显示。
- 术语用字重区分，不用颜色——颜色一多，说明区比数据区还热闹。

**时间与数字**

- **不要用 `DateFormatter` 默认 locale**：中文界面会冒出 `10:34 PM`。固定 `HH:mm` / `MM-dd HH:mm`，
  今天只给时刻、更早的带日期。
- 千位分隔、单位换算各写一个 helper，别在 View 里散落 `String(format:)`。

**外观**

- 深浅色都要过一遍。半透明 / 磨砂在**白色桌面**上最容易白字白底。
- 视觉改动一律 A/B 截图对比，不靠记忆。

## 4 系统权限（最容易翻车）

- **TCC 拦在 `open(2)`，不在 `stat(2)`**。权限位看着 `drwxr-xr-x` 也会 `EPERM`。
  判断能不能写 = 真建一个探针文件再删掉。
- errno 分类，给不同话术：

  | errno | code | 界面说什么 |
  |---|---|---|
  | `EROFS` | `readonly` | 只读盘，写不了 |
  | `ENOSPC` | `nospace` | 空间不够，需要 N MB |
  | `EACCES` / `EPERM` | `denied` | 没权限 + **「打开系统设置」按钮** |
  | 其它 | `io` | 原样给技术细节（好过只写「失败」） |

- 深链直达设置页：
  `x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders`
  （改完用 `lsappinfo front` 确认前台是「系统设置」且标题对得上）
- **不要跨卷兜底**。用户选了 A 盘就在 A 盘上做，写不进去就报错。
  悄悄换到 B 盘、产出挂着 A 盘名字的数字，比失败糟得多。
  唯一例外：启动卷根目录必然不可写 → 退到家目录（APFS 的 System/Data 是同一块 NAND），
  并在结果里标记来源，界面照实说明。
- 本次失败不要清掉上一次成功的结果。

## 5 测量

没有数字的「轻量」只是形容词。

- `scripts/measure.sh`：固定测量环境（备份用户设置、跑完还原），输出一行追加到 `docs/PERF.md`。
- 量：`.app` 体积、二进制体积、常驻 footprint、RSS、CPU（1s / 5s 两档取中位数）。
- **刚 `build.sh` 完别立刻量**：Spotlight 在索引新二进制，实测内存 43 → 83 MB、CPU 6.4% → 17.7%。
  等一分钟。
- **CPU 用内核全进程表**（`sysinfo` 或自写探针），别用 `top` / `ps`——那两个要 `task_for_pid`，
  受限环境里直接 `operation not permitted`。
- 每个功能追加一行，和上一行比。没动就写「没动」，别省略。

## 6 验证

AI 看不见屏幕，「你看一眼」不可替代；但要把这一步做省力。

- 截图 `screencapture -x -o`。屏幕休眠时全是黑图，先 `caffeinate -u -t 8`。
- **Retina 是 ×2**：窗口 bounds（pt）× 2 = 全分辨率像素。坐标一定在**全分辨率裁图**上量，
  不要用缩放后的预览——差 85pt 就会点空。
- 造真实测试环境，别假设：
  - 只读卷：`hdiutil create -fs APFS -volname X` + `attach -readonly`
  - 无权限：系统里真实存在的 `EPERM` 目录（如 `/private`）
- 环境变量门控的分支：`open --env` 不存在，`open -n` 也不带环境变量。
  直接跑 `Contents/MacOS/<App> --flag`（后台），再 `open` 那个 `.app` 把窗口提上来。
- 进程控制：`killall <App>` 可靠；`pkill -f <名字>` 在受限环境里可能读不到别人的 cmdline，
  匹配不到却不报错。
- 临时验证钩子（假失败、假数据）**当天删掉**，`grep` 证明为 0，并把这个动作写进文档。

## 7 文档：三份，各管一件事

| 文件 | 管什么 | 写法 |
|---|---|---|
| `DECISIONS.md` | **为什么**这么定 | ADR：背景 / 决定 / 理由 / 代价 / 实测数据 |
| `DESIGN.md` | 结构长什么样 | 模块表、数据流、状态机 |
| `PERF.md` | 占用了多少 | 每功能一行的表格 + 方法论 |

- ADR 必须写「被否掉的方案和否掉的理由」——半年后最先忘的就是这个。
- 推翻旧 ADR 时，**在旧那条里留一行指针**（「某日更新：被 ADR-0xx 推翻，原因是…」），
  否则后人只读到旧结论。
- 决策记录只记已经拍板的，不是待办清单。

## 8 提交

- 一个功能做完就提交；功能一笔、文档一笔，分开。
- 提交信息写**为什么**，不写改了什么——diff 已经说明改了什么。
- 调试代码、`print`、假开关不许进提交。

## 9 反模式

- 固定高度塞满内容，靠裁掉一部分「看起来还行」
- 用 `stat` 判断可写性
- 写不进去就换一个目录继续跑
- 用系统 locale 格式化时间
- 刚 build 完就量性能
- 把字段名直接甩给用户
- 提交 `.xcodeproj`
- 临时钩子过夜
- 只改深色模式就交差

---

蒸馏自 EZPcMonitor（macOS 原生重写：55 个提交、35 条 ADR、7 种语言）。
