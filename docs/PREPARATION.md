# 开发前置准备完成

日期：2026-09-08。结论：开发环境、固定源码、构建入口、开发签名、安装、App Group 和原生桌面小组件验证已完成，可以进入正式功能开发。

## 当前可用的基础

| 项目 | 验收结果 |
| --- | --- |
| Xcode | 26.6；首次初始化与 macOS SDK 检查通过 |
| Apple 账号与签名 | Personal Team；已生成有效 Apple Development 身份 |
| 主应用与扩展 | 两个 target 的签名构建通过，严格深度签名校验通过 |
| App Group | 两个 target 的 entitlement 一致；主应用实际写入、扩展实际读取 |
| 小组件 | 小号和中号均能在系统图库中显示并添加到真实桌面 |
| 更新一致性 | 两张小组件均从 160/revision1 更新到 320/revision2 |
| 后台写入与刷新 | 应用自行隐藏后写入 800/revision5，记录 `NSApp.isActive == false`；两张桌面小组件均显示800/revision5 |
| 主应用退出 | 进程已退出，两张小组件仍显示800/revision5 |
| 快照检查 | 正常编码、未知版本、负 Token、截断 JSON、Int64 精度检查通过 |
| Rust 来源与构建 | 仓库内固定上游源码；release 构建、原合成用量检查和逐文件哈希核对通过 |
| Worker | 指定 Muse Spark 1.3 Contributor 已实际执行，Codex 完成返工要求和运行验收 |

桌面上的两张 TokensPrep 小组件均为**合成数据测试卡片**，800 不是本机真实使用量。验证 app 已退出，没有增加常驻采集服务或登录启动项。它可在用户 Applications 目录重新打开。

本轮确认了后台写入和刷新可以工作，没有测量严格的刷新延迟上界，也没有保证 WidgetKit 每5/10分钟准时重绘。前两次后台尝试记录为前台，未算通过；最终以实际后台状态和真实桌面数据完成验收。

## 工程与复用入口

- 工程：`validation/WidgetSmoke/TokensPrep.xcodeproj`
- 安装位置：`/Users/ethan/Applications/TokensPrep.app`
- App Bundle ID：`local.tokensmacos.preflight`
- Widget Bundle ID：`local.tokensmacos.preflight.widget`
- 合成快照：应用独立 App Group 下的 `snapshot.json`
- 本机团队配置：`validation/WidgetSmoke/Config/Local.xcconfig`，已忽略，不作为共享源码
- 原版核心：`Collector/vendor/`；来源提交与逐文件 SHA-256 见 `UPSTREAM.json`，保留 MIT 许可

```sh
scripts/xcode-prep.sh check    # 工具链和工程识别
scripts/xcode-prep.sh compile  # 无需开发证书的编译检查
scripts/xcode-prep.sh build    # 使用已有签名构建，不自动申请新证书
scripts/check-prep.sh          # 快照数据边界检查
scripts/install-prep.sh        # 安装/更新同一验证 app，不覆盖其他 Bundle ID
```

脚本通过 DEVELOPER_DIR 指定完整 Xcode，系统全局 xcode-select 未改动。新机器从 `Local.xcconfig.example` 创建自己的配置。安装或使用签名身份仍需该机器上的相应授权。

本地 Git 仓库已初始化；未设置远程地址、未推送。构建产物、Worker 元数据及本机配置均被忽略。

## 已解决的问题

- 缺少开发证书：在用户明确授权后，由 Xcode 自动准备并完成签名。
- 本地软件安装审批：用户明确批准安装运行和小组件测试后完成安装。
- 首次启动崩溃：隐式 WindowGroup 在当前系统触发重复 SceneID，改成明确 ID 的单窗口后通过运行验证。
- 文件不存在与读取权限错误混淆：去除 fileExists 前置判断，仅将确实不存在映射为等待快照。
- 后台测试受到界面自动化激活影响：验证程序自行隐藏，再延迟写入，并记录写入时的真实前台状态。

## 后续开发范围

正式应用按 [架构](ARCHITECTURE.md) 和 [开发任务包](DEVELOPMENT.md) 执行。该验证工程的 PrepSnapshot 是最小合成协议，不是正式 collector v1 协议；不能直接用它代替完整 Token、单价估算、日期与客户端字段。

真实采集接入、正式 UI、5/10分钟调度、睡眠恢复、长时间能耗和正式发行包属于功能/发行开发阶段。Developer ID 公证或 Mac App Store 资格不属于本轮本机开发前置验收；本次没有购买会员或发布应用。
