# mac-tools

本地 macOS 工具集合，每个子项目独立构建和使用。

## LaunchDesk · 定时管家

原生 SwiftUI `launchd` 任务管理客户端，支持设置定时时间、启停个人任务、查看运行状态和日志。

- 每日多个时段、每周计划、固定间隔与高级日历规则
- 任务的持久启用状态及当前加载状态管理
- 新建、编辑和移到废纸篓
- 原始配置、退出码及日志查看
- `local.codex.ciallo-daily` 专属的最新执行面板

源码与使用说明见 [LaunchDesk](LaunchDesk/README.md)。

```bash
cd LaunchDesk
./build.sh
open dist/LaunchDesk.app
```

需要 Apple Silicon Mac、macOS 14 或以上，以及 Xcode Command Line Tools。
