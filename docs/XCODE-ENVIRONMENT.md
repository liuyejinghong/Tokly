# Xcode 环境

更新日期：2026-09-08。完整前置验收见 [PREPARATION.md](PREPARATION.md)。

| 项目 | 当前结果 |
| --- | --- |
| Xcode | `/Applications/Xcode.app`，26.6，build 17F113 |
| 首次初始化 | `xcodebuild -checkFirstLaunchStatus` 退出0 |
| macOS SDK | 26.5 |
| WidgetKit | 类型检查、主应用/扩展签名构建及桌面实装均通过 |
| Apple 账号 | Personal Team 已登录 |
| 开发证书 | 用户授权后自动准备成功，系统信任环境下检测到有效 Apple Development 身份 |
| 内置 Codex | 已登录，界面选择 GPT-5.5；非本项目依赖，未验证其模型请求 |
| 外部代理 MCP | 关闭，未改动；当前通过插件和命令行工作 |
| 全局开发目录 | 仍为 CommandLineTools；项目脚本指定完整 Xcode |

签名身份查询需要能访问系统钥匙串/信任服务的执行环境。受限沙盒内曾返回0个身份和 CSSMERR_TP_NOT_TRUSTED；在系统信任环境下，实际身份、签名链和 app/widget 校验通过，不能把沙盒内假阴性当成用户证书不存在。

Xcode 内置 Codex 可保留；当前 Codex 负责判断和验收，指定 Muse Worker 执行开发任务。没有启用额外 Xcode MCP 权限。
