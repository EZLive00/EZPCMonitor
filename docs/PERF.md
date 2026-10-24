# 资源占用记录

这个项目的卖点是「轻」，所以每加一个功能、每改一次热路径，都要跑一遍
`./scripts/measure.sh`，把数字和上一行比。**看 delta，不看绝对值。**

## 怎么量

```bash
./scripts/measure.sh                          # 构建 + 测量，追加一行
./scripts/measure.sh --no-build --note "..."  # 用现有产物
```

脚本自己会把环境固定住：Release 构建、采集 1 秒（CPU 另测一档 5 秒）、悬浮窗卡片形态、
主题跟随系统、历史记录关闭。跑之前备份 `settings.json` 和 UserDefaults，跑完原样还回去。

## 口径

| 列 | 怎么来的 |
|---|---|
| `.app` | `du -sm`，磁盘占用（含 `smartctl` 705 KB） |
| 二进制 | `stat` 取主可执行文件大小 |
| 悬浮窗 footprint | `footprint -p`，**不含** dyld 共享缓存，横向比较看这个 |
| 悬浮窗 RSS | 内核 `sysinfo` 报的口径，含共享缓存，比 footprint 大 |
| 主面板 footprint | 打开主面板 8 秒后 |
| CPU 1s / 5s | 采集频率 1 秒 / 5 秒下的常驻 CPU（单核百分比，5 次采样取中位数） |

CPU 走 `scripts/probe.swift` 而不是 `top` / `ps`：那两个要 `task_for_pid` 权限，在受限
环境里直接 `operation not permitted`。probe 复用内核自己的全进程表，和界面上显示的
数字同源。

## 噪声

同一份代码连测两次，数字会差：内存 ±1~2 MB，CPU ±0.5%。所以**改动小于 2 MB 或 1%
的差异没有意义**，别拿它当"优化成功"的证据。

## 记录

| 日期 | 提交 | 说明 | .app | 二进制 | 悬浮窗 footprint | 悬浮窗 RSS | 主面板 footprint | CPU 1s | CPU 5s |
|---|---|---|---|---|---|---|---|---|---|
| 2026-10-24 | `8c902c8` | 基线：主面板背景之前 | 6 MB | 4.9 MB | 17 MB | 41 MB | 32 MB | 7.3% | 2.3% |
