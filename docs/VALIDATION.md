# Tokens macOS 验证报告

后续更新：完整 Xcode、开发签名与最小桌面小组件前后台链路现已通过，见 [PREPARATION.md](PREPARATION.md)。下文保留首次采集测试时的环境与范围记录。

日期：2026-09-08。源码：`missuo/tokens@75aba190695c9de5f2695d9baba6afd3c8cb63f8`。

## 结论

复用原版 Rust 核心可行，测试入口已 release 构建并在本机数据副本上运行。完整扫描冷缓存成本明显，缓存命中后降至秒级；因此采用短生命周期辅助程序，避免把扫描峰值内存留在常驻 UI 中。

原版 `today_only` 快速路径在此次真实副本上与完整扫描当日结果一致，但合成的旧文件修改时间案例可稳定复现少计。默认不启用该快捷路径，以完整扫描和原缓存保证与原版核心一致。新增索引优化需另行通过同一组对照，不能在此阶段重写口径。

桌面小组件相关 API 类型检查通过；完整扩展安装、共享容器签名权限和实际刷新验收未完成。当前机器无完整 Xcode，未检测到有效代码签名身份。

## 环境和方法

| 项目 | 实际值 |
| --- | --- |
| 硬件 | Mac15,6，12 CPU，36 GiB 内存 |
| 系统 | macOS 26.5.2，arm64 |
| Swift | 6.2.4，Command Line Tools |
| Rust | Cargo 1.95.0，release 构建 |
| 扫描线程 | Rayon 4；Tokio 2 |
| 统计时区 | Asia/Shanghai |
| 价格输入 | 固定公开 LiteLLM 表；OpenRouter/models.dev 缓存为空，排除联网等待 |
| 价格表 SHA-256 | `f68d88c12610ea31ab355a1293fde55aeed6fa78a1f4b182c67be47d80b1d202` |

| 数据副本 | 文件数 | 字节 |
| --- | ---: | ---: |
| Codex 当前及归档日志 | 3,315 | 21,472,667,830 |
| Claude Code projects/transcripts | 1,340 | 301,216,888 |
| OpenCode SQLite | 1 | 4,816,748,544 |

JSONL 使用 APFS clone 保留修改时间，SQLite 用只读连接与 backup API 复制。真实日志无修改、无上传；外部 Muse 未读取这些数据。复制期间不同客户端并非同一原子时点，复制完成后固定用于重复测试。机器同时运行其他应用；不是隔离性能实验室。

“冷缓存”指新的 tokens 消息缓存，不表示冷文件系统缓存。本机已先做过一次扫描，所以首次读取与操作系统磁盘缓存冷启动成本仍可能更高。峰值为进程 RSS，辅助程序退出即释放，不能当成未来菜单栏常驻内存。

## 即时重复扫描

前两组路径分别使用独立缓存目录，各一次消息冷缓存、三次热缓存；另补测今日查询复用完整历史缓存的实际情况。耗时来自 `/usr/bin/time -l` 外部包裹的进程；CPU 为 user+sys 总时间；MB 使用十进制。

| 路径 | 样本 | 耗时（秒） | CPU 时间（秒） | 峰值 RSS（MB） |
| --- | --- | ---: | ---: | ---: |
| 完整扫描 | 冷缓存 | 33.543 | 100.44 | 2,114.8 |
| 完整扫描 | 热缓存 1 | 1.922 | 2.56 | 856.3 |
| 完整扫描 | 热缓存 2 | 1.300 | 2.58 | 849.8 |
| 完整扫描 | 热缓存 3 | 1.285 | 2.56 | 856.4 |
| 今日快速路径 | 冷缓存 | 1.754 | 0.74 | 198.2 |
| 今日快速路径 | 热缓存 1 | 0.126 | 0.13 | 82.7 |
| 今日快速路径 | 热缓存 2 | 0.127 | 0.13 | 82.5 |
| 今日快速路径 | 热缓存 3 | 0.128 | 0.13 | 82.6 |
| 今日快速路径 | 复用完整历史缓存 | 0.778 | 0.62 | 360.2 |

今日快捷路径的约 83 MB 峰值只适用于独立小缓存；复用完整缓存时升到约 360 MB，不能将前者当成实际应用所有状态下的表现。

系统返回 block input/output operations 均为 0，此计数不能解释为没有磁盘 I/O；本轮没有可靠的物理磁盘读写字节测量。记录了 instructions/cycles，但未获得瓦时或电池耗电量。

## 真实 5／10 分钟间隔观察

同一个观测序列在 t=0、300、600 秒扫描固定副本，在第 300 秒前新增一条 160 Token 的合成记录。这验证间隔运行与少量新增数据，不是两个独立频率的电池 A/B 实验。未在此轮模拟持续大量日志写入。

| 时点 | 耗时（秒） | CPU 时间（秒） | 峰值 RSS（MB） |
| --- | ---: | ---: | ---: |
| 0 秒 | 2.125 | 2.60 | 855.4 |
| 300 秒 | 2.166 | 2.68 | 856.7 |
| 600 秒 | 2.018 | 2.56 | 851.8 |

第 5 分钟新增量严格为 160 Token，第 10 分钟无重复增加。计时采用 monotonic clock，本次两个后续采样的实际开始时刻均落在目标时点附近（原始数值见汇总证据）。

工程默认采用 **10 分钟，可切换 5 分钟**。以约 2.6 CPU 秒/次估算，持续运行一小时的采集 CPU 工作量约为 15.6 秒（10 分钟）或 31.2 秒（5 分钟）；这是基于单次测量的线性推算，不是能耗测量。5 分钟没有出现采集耗时接近周期的情况，但会使采集次数与短时内存峰值出现次数翻倍。默认 10 分钟是初始工程取舍，不代表 5 分钟不可用。

仍未验收：完整 App 的常驻内存、真实唤醒次数、睡眠恢复、价格联网更新的资源成本、持续重负载下的长时间扫描和电池续航。这些应在 P2/P4 实装阶段补齐。

## 正确性检查

- 真实固定副本：完整扫描四次的 summary/contributions 相等。浮点费用比较容差为相对 `1e-12`、绝对 `1e-6`；忽略 meta 生成时间与执行耗时。
- 真实副本：完整扫描的 2026-09-08 数据与今日快捷路径的 Token 分项、客户端/模型、费用一致；比较不要求热力图强度及活动时间一致。
- 合成案例：重复的 token_count 快照只计一次，冷/热缓存都得到 160 Token；追加事件后得到 320；同一日志复制到归档目录仍为 320。
- 旧 mtime 反例：保持当天事件内容，将两个合成日志的文件修改时间设为两天前；完整扫描仍为 320，今日快速路径为 0。这个反例只改隔离测试数据，不改真实日志。
- 探针缺少 `TOKENS_CONFIG_DIR` 时以退出码 2 拒绝启动，未创建结果文件，避免落入用户默认缓存目录。

这些检查证明所测输入和缓存行为，不代表所有客户端、所有 fork/压缩/恢复情况均已覆盖。正式费用“统一按模型单价估算”尚未实现，本轮复用的原版费用结果不作为该功能的验收。

## 小组件验证

已使用实际 SDK 对 `validation/widget-probe.swift` 执行面向 macOS 14 arm64 的 `swiftc -typecheck`，退出码 0。涉及 StaticConfiguration、TimelineProvider、App Group 容器 URL API 与 reloadTimelines。

`xcode-select -p` 指向 `/Library/Developer/CommandLineTools`；`xcrun --find xcodebuild` 失败；常用 Applications 目录未见 Xcode；`security find-identity -v -p codesigning` 返回 0 个有效身份。没有据此伪造 `.appex` 安装或 Widget 展示结果。

必须补做：完整 Xcode 工程构建、真实签名/App Group、安装后 Widget Gallery 可见、桌面添加、共享数据一致、应用后台/退出情况下的真实刷新延迟、正常系统模式下的能耗观察。Apple 文档中的前台刷新预算例外不能直接套用于后台菜单栏常驻。

## Worker 执行与验收

实际插件确认身份：`Sisyphus - ultraworker`，`opencode-go/muse-spark-1.3-contributor`。不是原生 Codex 子代理。

Muse 编写测试入口，初次因公开参考位于任务目录外而读失败并猜测接口；Codex 不接受该版本，提供目录内公开参考并通过同一 session followup 修正。修正后由 Codex 实际 release 构建、运行并验收。过程中遇到一次供应商限流，后续同一指定模型完成，未切换模型。另由 Muse 编写开发实施包，Codex 校验并结合实测更新。

成本和剩余额度工具未提供，不记为 0。此记录是执行质量依据，不进入最终应用界面。

## 复现与证据

工具使用方法见 [validation/README.md](../validation/README.md)。只收录不含真实用量内容的汇总证据到 `docs/evidence/`；私有图表与原始日志保持在本机临时目录。

- [上游核心](https://github.com/missuo/tokens/tree/75aba190695c9de5f2695d9baba6afd3c8cb63f8/cli/tokens-core)
- [Apple WidgetKit 刷新机制](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date/)
- [Apple App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- [Developer ID](https://developer.apple.com/developer-id/)
