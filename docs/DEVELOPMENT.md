# Tokens macOS 开发实施包

日期：2026-09-08。性质：给未来 Muse（OpenCode Worker）执行的顺序实施包。本文只管任务拆分与协作规则，不管架构决策——架构与验收归 Codex，产品需求以 [REQUIREMENTS.md](../REQUIREMENTS.md) 为准，架构基线以 [ARCHITECTURE.md](ARCHITECTURE.md) 为准。

## 范围重申（需求与本轮设计决定，不可自行扩大）

- 只统计本机用量，统计口径沿用上游，不重定义 Token、缓存、推理、去重、日期归属。
- 费用为按模型单价的估算，不做订阅分摊，不查剩余额度，无服务端、无上传、无账号。
- 界面 = 菜单栏 + 详情窗口 + 原生桌面小组件（小/中号）。
- 本轮工程决定：默认 10 分钟，可选 5 分钟；依据见 VALIDATION，实际 App 常驻/续航尚待验证。

## 现有产物 vs 规划路径（勿混淆）

现有产物（已存在，可读可用）：

- `validation/measure.py`、`validation/collector-probe/`、`validation/reference/`、`validation/widget-probe.swift`——其中 Rust 探针由 Muse 编写并按 Codex 反馈修正，Codex 已完成 release 构建与实际测试；性能与限制以 [VALIDATION.md](VALIDATION.md) 为准。
- `docs/ARCHITECTURE.md`、`REQUIREMENTS.md`——设计与需求基线。

规划路径（尚不存在，见下述各包；名称为提议，正式工程初始化时由 Codex 定稿）：

- `TokensApp/`（SwiftUI 主应用）、`Collector/`（Rust 辅助程序）、`TokensWidget/`（WidgetKit 扩展）、`Shared/`（协议模型与合成样例）。

## Worker 协作规则

1. 每个包一次只做一包，包内文件所有权独占；**不得回滚或修改包外文件**（无重叠写）。
2. 同一任务使用稳定 `request_id`；任务完成后才可跟进（followup after finished），中途不叠加新写。
3. 以实际产物与测试为准：返回真实变更文件、验证命令输出、未解决问题；被拒读的路径直接报告阻塞，不猜测、不绕过。
4. 所有源码/参考文件必须位于本仓库内；**禁止猜测上游 API**——以上游固定提交 `75aba19` 的仓库内固定来源为准，不确定的接口返回阻塞。
5. 不得虚构：性能数据、Xcode/签名可用性、Team ID、价格正确性。缺什么写明为前置阻塞。
6. 真实用户日志与凭据只由 Codex 在本机处理；Worker 只使用合成样例与汇总指标。

---

## P1：Collector + 协议 + 固定上游依赖

- 目标：在 `tokens-core` 固定提交上加一层薄本地 JSON 输出入口（schemaVersion 1，字段见 ARCHITECTURE.md §本地进程与快照协议），估算费用单独输出，不改 Token 口径。
- 提议目录/文件所有权：`Collector/`（含 `vendor/` 固定上游核心）、`Shared/sample-snapshot.json`（合成样例）、`Shared/protocol.md`（字段说明，如 ARCHITECTURE 已覆盖可省略）。
- 依赖：仓库内固定的上游来源（采用 vendored 的最小 Rust workspace，记录提交与原许可，便于局部核心适配和 Worker 读取；验证入口已改为这份仓库内相对依赖）；合成日志与价格夹具由 Codex 提供。
- 精确交付：`Collector` 可构建的辅助程序 + 一份版本化 JSON 样例 + 参数说明（数据目录/缓存目录/日期范围/时区，参数数组启动，无 shell 拼接）。
- 最小测试：合成夹具下 JSON 字段齐全、数值 64 位整数；零用量与缺价格有确定输出；未知版本/截断文件交由 P2 消费者测试；与上游完整扫描聚合对照一致，包括旧 mtime 下的当天记录；保持默认完整扫描缓存路径。
- Codex 验收：本机真实数据对照（Token、客户端、模型、日期一致；费用走单价估算路径）。
- 待定前置：上游固定来源形式已定为仓库内 vendored Rust workspace；真实日志对照由 Codex 执行（Worker 不接触）。

## P2：SwiftUI 主应用 + 菜单/调度/共享快照

- 目标：菜单栏（今日 Token，展开见费用/客户端/更新时间/刷新/详情入口）、详情窗口（今日/近七天/本月/模型分布）、后台定时采集、快照原子写入 App Group。
- 提议目录/文件所有权：`TokensApp/`（含调度器、快照写入器、UI）、`Shared/`（Swift/Rust 共用的合成 JSON 样例验收）。
- 依赖：P1 的协议与 JSON 格式冻结；合成快照样例。
- 精确交付：可运行的主应用 + 调度状态机（idle/running，合并并发请求，睡眠不唤醒、唤醒后最多补采一次）+ 原子写快照实现。
- 最小测试：调度单元测试（并发合并、失败保留旧快照并标错误）；快照读写测试（截断/未知版本/缺价格）；UI 手动检查（零用量、缺价格、错误态），不为简单界面新建快照测试框架。
- Codex 验收：5/10 分钟试跑的常驻内存/唤醒/能耗记录；退出/后台/睡眠场景行为符合 REQUIREMENTS 最小实测计划。
- 待定前置：采用本轮 10 分钟默认值与 5 分钟选项；登录启动选项以系统支持为准实测。

## P3：WidgetKit 桌面小组件

- 目标：小/中号桌面小组件，只读 App Group 快照，点击打开应用；刷新请求走 `WidgetCenter.reloadTimelines`，接受系统调度延迟。
- 提议目录/文件所有权：`TokensWidget/`（扩展全部文件）。
- 依赖：P2 的共享快照格式与写入实现；建议最低 macOS 14。
- 精确交付：小号（今日 Token/估算费用/更新时间）+ 中号（加客户端分项）+ 过期/错误占位态。
- 最小测试：快照缺失/过期/未知版本时的占位显示测试；深浅色与字体缩放检查。
- Codex 验收：在关闭开发者刷新豁免的正常系统设置下，实测安装后可添加、快照一致、记录实际刷新延迟；覆盖应用后台运行与退出场景。
- 待定前置：App Group Team/entitlement/签名配置待正式工程初始化；本机最小验证工程已完成签名、安装、App Group 和前后台更新验收；P3 需对正式实现重复功能验收，不能直接将合成演示当作正式统计应用。

## P4：安装/签名/公证/发行验收

- 目标：直接发行的可安装产物（统一 Swift 与 Rust 的最低系统版本为 macOS 14）（`.app` 含签名 helper 与 `.appex`，经 DMG 等载体交付），Developer ID 签名 + 公证 + Gatekeeper 通过。
- 提议文件所有权：安装与发行脚本/说明（新文件，路径由 Codex 定，如 `scripts/package.sh`、`docs/RELEASE.md`）。
- 依赖：P1–P3 完成并通过各自验收；Bundle ID/Team ID/应用名称由 Codex 在正式工程初始化时配置。
- 精确交付：可重复的打包-签名-公证流程 + 发行检查清单（含 REQUIREMENTS §最小实测计划全部 6 项的实测记录位）。
- 最小测试：全新机器（或新用户）安装→添加小组件→数据一致全链路；Gatekeeper 拦截情况记录。
- Codex 验收：逐项勾选最小实测计划；复核默认周期是否需要根据 App 常驻与续航观察调整，并记录依据。
- 待定前置：本机 Apple Development 签名已就绪，正式 Developer ID 与公证资质未验收；第一版先验收 arm64，Intel 为后续可选项；Mac App Store 另行评估，不阻塞直接发行。

---

## 未解决事项（Worker 不得自行决定）

1. 默认 10 分钟、可选 5 分钟已定为工程起点；P2/P4 仍需补做常驻与电池验证。
2. 正式工程采用仓库内 vendored 最小 Rust workspace，记录上游提交与许可；不要引用验证阶段的临时目录。
3. Bundle ID / Team ID / 应用名——正式工程初始化时配置。
4. 环境、开发证书和最小扩展实装前置已通过，见 [前置准备](PREPARATION.md)。
5. 完整扫描缓存性能已有实测；今日快速路径存在旧 mtime 少计反例，第一版不得启用；最小 Widget 实装已通过；正式应用的长时系统能耗仍待补验。
