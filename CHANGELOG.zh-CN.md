# 更新记录

[English](./CHANGELOG.md) | 简体中文

本项目遵循语义化版本号。版本号以 `package.json` 为唯一来源。

## [2.0.0] - 2026-08-23

首个开源版本。

### 桌宠与互动

- macOS 原生 AppKit 桌宠，运行时不依赖 Electron，也不需要 Codex/Claude 桌面端。
- 待机呼吸、随机小动作、拖动滞后与落脚回弹；头部、口袋、脚部和身体两侧的悬停与点击反馈。
- 右键菜单可切换桌宠、刷新用量、开关额度历史与系统通知、检查更新或退出。
- 支持内置素材与 `~/.cc-pets/pets/` 下的外部素材，兼容 `spriteVersionNumber` v1 / v2 网格。

### 额度与用量

- 从本机 `~/.codex/sessions` 与 Claude Code 官方 status line 数据读取 5 小时额度、周额度和重置时间。
- 悬停口袋展开额度面板，用两张卡分别展示 Codex、Claude 的剩余百分比、本机 Token 与近 7 天趋势。
- 可选记录最近 7 天的本地额度历史；默认关闭，仅保存在本机。
- 支持「订阅额度 / API 用量」两种展示模式。

### Agent 状态

- 由 Codex Hooks 与 Claude Code Hooks 驱动思考、工具调用、审批、子 Agent、完成与失败动画。
- 桌宠旁显示脱敏后的玻璃状态卡片，可折叠并显示活跃 CLI 会话数。
- 可分别启用任务完成、失败和等待审批的 macOS 系统通知。
- 第三方 CLI Agent 可通过统一 Provider 事件协议接入，详见
  [`PROVIDER_PROTOCOL.zh-CN.md`](./PROVIDER_PROTOCOL.zh-CN.md)。

### 台词

- 桌宠台词全部来自 `~/.cc-pets/speech.txt`，可在内置编辑器中修改，支持实时数据槽位。
- 可为单只宠物写专属台词（`~/.cc-pets/speech/<宠物名>.txt`），按小节整体覆盖通用台词。
- 四档碎碎念频率，Agent 工作期间不插嘴。

### 安装与集成

- `npm install -g cc-pets` 自动构建原生应用、安装两套 Hooks 与 shell 集成，并安装
  `~/Applications/CC Pets.app`。
- 通过 `~/.cc-pets/shims` 下的软链接管 `codex` / `claude`，任意大小写写法都能拉起桌宠。
- `cc-pets install` / `uninstall` / `uninstall-app` 提供可重复执行的初始化与清理流程。

### 隐私

- 不上传会话内容、额度、凭据或使用统计，不包含遥测。
- 状态卡片与通知只显示 Provider、状态类别和脱敏后的工具类别。
