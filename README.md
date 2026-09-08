# Tokly

Tokly 是一个原生 macOS AI 用量统计应用：读取本机客户端记录，展示 Token 用量及按模型单价计算的估算费用，提供主窗口、菜单栏弹窗和桌面小组件。

本仓库是项目的私有源码备份，也是后续 agents 接手工作的入口。它包含实现、固定的上游核心、合成测试和验收记录；不包含用户会话日志、运行时缓存、签名私钥或已编译安装包。不要假定原开发机器上的工具、凭据、临时文件和已安装应用在新的 checkout 中仍然存在。

## 1. 当前状态与阅读顺序

截至 **2026-09-08**，Tokly 已完成本机开发版并经过用户试用确认，已在开发机器安装运行。主应用、Rust helper、小号/中号 Widget 已接通真实数据；这是本机开发签名版，尚未做公开发行公证或 App Store 发布。

后续 agent 建议按以下顺序接手：

1. 检查 `git status --short`、当前分支和最近提交，保留已有未提交改动。
2. 阅读本 README，确认当前产品行为、构建入口与数据边界。
3. 涉及数据时阅读 [Shared/protocol.md](Shared/protocol.md)，再看实际 producer/consumer 源码。
4. 涉及界面时阅读 [产品原型规则](docs/PRODUCT-PROTOTYPE.md)，并结合本 README 中后续确认的行为。
5. 按修改范围运行相关检查；需要判断历史验收时再查 [交付记录](docs/LOCAL-DELIVERY.md) 和 [证据目录](docs/evidence/)。

**旧文档包含历史状态，不能仅凭某一段文字推断当前实现。** `REQUIREMENTS.md`、早期架构/前置验证文档，以及 `docs/packets/` 中仍可能出现“尚未实现”、旧名称 Tokens、待执行包或旧路径。`docs/DEVELOPMENT.md` 和 `docs/LOCAL-DELIVERY.md` 也保留了多轮追加记录，应结合后续条目与 Git 历史阅读。

判断当前行为时以最近用户确认、当前实现和可复现检查相互核对；JSON 字段与费用语义以协议为契约。发现冲突应定位并修正，不能用旧原型覆盖已经确认的新行为，也不能把代码缺陷当作新的需求。

## 2. 已确定的产品行为

| 区域 | 当前约定 |
| --- | --- |
| 统计范围 | 只统计这台设备已有的记录；不做账户管理、剩余额度查询、订阅费用分摊或云端用量同步 |
| 主窗口 | 总览、模型、来源、小组件、设置；客户端为父级、模型为子级；同名模型在不同客户端下保持独立身份 |
| 日期范围 | 今日、近7天（含今日）、本月（自然月）；“本月”不是滚动30天 |
| 月图 | 默认每日曲线，可切周一至周日的自然周汇总；月首/月尾截断，未来日期或周为空值 |
| 菜单栏状态项 | 始终显示今日主指标；设置可选 Token 或估算费用 |
| 菜单栏弹窗 | 默认今日，可切近7天/本月；默认按模型展示、Token 降序，设置可切客户端；不继承主窗口筛选 |
| 模型列表 | 菜单栏模型行保留客户端副标题；跨客户端同名模型不擅自合并 |
| 打开主窗口 | 菜单栏“打开统计窗口”跟随弹窗所选日期范围，并清除主窗口客户端筛选；Widget 深链打开今日 |
| 数字单位 | 共用 K/M/B 格式；达到十亿用 B，例如 `3,670,880,000 → 3.67B` |
| 采集周期 | 默认10分钟，可选5分钟；主应用为唯一调度者，最多一个扫描和一个待执行请求 |
| 生命周期 | 关闭窗口继续菜单栏运行；显式退出停止采集；睡眠不主动唤醒，恢复时合并补采 |
| 价格更新 | 与扫描分离，每日按需尝试；失败保留缓存；首次成功加载后补采更新估值 |
| 桌面组件 | 小号/中号，只读裁剪后的今日快照；与主窗口筛选无关；更新时间来自采集，不是绘制时间 |

原型 HTML 仅是设计参考，内含合成数据。正式应用使用 SwiftUI / Swift Charts，不能把原型中的演示数值、比例或公式搬进生产路径。

### 不得改变的统计语义

- Token 解析、缓存、去重与日期回退语义复用固定的上游核心。`scan` 使用完整扫描加缓存，保持 `today_only=false`、`use_env_roots=false`。
- **不要重新启用基于文件 mtime 的今日快捷路径。** 已有旧 mtime 文件包含今日记录的漏计反例。
- 五类 Token 为非负 `Int64`，通过饱和加法汇总，不能先转换为 `Double` 再求和。格式化和图表展示时的转换不能反向成为统计来源。
- 先按每条事件的原 provider/model 估价，再按客户端和 canonical model 分组；不能先按日合并再乘单价。
- 忽略来源自带账单金额。`amountUsd` 是模型单价估值，不是实际支付费用。
- 某事件缺少所需有效基础单价时，整条事件算未定价。混合情况显示已知部分；全部有量事件缺价时金额为 `nil`；合法零单价仍是已定价。
- `daily` 和 `hourly` 是同一批用量的两种投影，不能相加。费用一致性比较允许浮点重组误差，Token 与身份比较保持精确。
- 只有成功快照覆盖范围内的空桶才能补零；缺失、失败、未覆盖或未来数据不能显示为零。
- 来源/时区改变后，旧请求结果不得覆盖新配置；旧组件数据不能继续冒充当前启用来源。跨日旧值保留原日期，不改称“今日”。

完整字段与约束见 [数据协议](Shared/protocol.md)；示例见 [sample-snapshot.json](Shared/sample-snapshot.json)。

## 3. 代码地图与数据流

```text
本机客户端记录 → Collector scan → validated ScanSnapshot
                                      ├─ 主窗口 / 菜单栏投影
                                      ├─ 应用私有 scan.json
                                      └─ WidgetSnapshot → App Group → WidgetKit
公开价格源 → Collector prices refresh → 应用私有价格缓存 ──┘
```

| 路径 | 责任 / 修改入口 |
| --- | --- |
| [Collector/src/main.rs](Collector/src/main.rs) | `scan`、`prices refresh` CLI 与退出码 |
| [Collector/src/lib.rs](Collector/src/lib.rs) | 请求校验、来源读取边界、离线价格加载、逐事件估值与协议输出 |
| [Collector/src/price_update.rs](Collector/src/price_update.rs) | 临时目录下载、数据有效性检查、成功价表原子更新，失败保留原缓存 |
| [Collector/vendor/](Collector/vendor/) | 固定上游 Rust 核心；不是可随意更新的依赖目录 |
| [Shared/UsageSnapshot.swift](Shared/UsageSnapshot.swift) | 协议编解码、边界校验、Token/费用类型 |
| [Shared/UsageAggregation.swift](Shared/UsageAggregation.swift) | 共用聚合、日/小时/周口径、费用状态与 `TokenFormat` |
| [Shared/WidgetSnapshot.swift](Shared/WidgetSnapshot.swift) | 裁剪后的组件协议与 builder，保留统计时区和原更新时间 |
| [TokensApp/AppState.swift](TokensApp/AppState.swift) | 主应用状态、配置、扫描生命周期、价格更新与发布 |
| [TokensApp/ScanScheduler.swift](TokensApp/ScanScheduler.swift) | 合并请求、日期范围、参数构建和调度判断 |
| [TokensApp/CollectorRunner.swift](TokensApp/CollectorRunner.swift) | `Process` 参数数组调用、双管道排空、取消/超时及子进程清理 |
| [TokensApp/SnapshotStore.swift](TokensApp/SnapshotStore.swift) | 私有快照、App Group 发布与配置失效 |
| [TokensApp/RangeProjection.swift](TokensApp/RangeProjection.swift) | 所选范围的客户端/模型投影、菜单栏排名和覆盖判断 |
| [TokensApp/Views/](TokensApp/Views/) | 主窗口与菜单栏 SwiftUI 界面 |
| [TokensWidget/WidgetData.swift](TokensWidget/WidgetData.swift) | 只读快照、有效性/过期判断与展示文本 |
| [TokensWidget/TokensWidget.swift](TokensWidget/TokensWidget.swift) | Provider、跨日 timeline、Widget 注册 |
| [Tokly.xcodeproj/](Tokly.xcodeproj/) | `Tokly` scheme；主应用、扩展、helper 签名复制与嵌入 |
| [Config/](Config/) | Info.plist、entitlements、本机签名配置模板 |
| [assets/branding/](assets/branding/) | 图标源图与已接入的 `Tokly.icns` |
| [validation/](validation/) | 早期性能探针、原型/WidgetSmoke 验证；不属于正式应用运行链路 |

主应用当前不启用 App Sandbox，负责本机文件采集；Widget 扩展启用沙盒，只读 App Group 快照。不要把主应用的文件扫描或网络路径引入扩展。

### 名称与内部标识

对外名称为 **Tokly**，但以下内部标识刻意保留。不要为了统一字符串而全局替换 `Tokens` / `tokens`：

| 项目 | 当前值 |
| --- | --- |
| Xcode 工程 / scheme / 应用 | `Tokly.xcodeproj` / `Tokly` / `Tokly.app` |
| 主应用 Bundle ID | `local.tokensmacos.app` |
| 扩展 Bundle ID | `local.tokensmacos.app.widget` |
| Widget kind | `TokensWidget` |
| 深链 | `tokensmacos://today` |
| App Group 配置 | `TOKENS_APP_GROUP = $(DEVELOPMENT_TEAM).tokensmacos.app` |
| Info.plist 中的组标识键 | `TokensAppGroupIdentifier` |
| 源码目录 | `TokensApp/`、`TokensWidget/` |

这些标识承担偏好设置、数据目录、深链和已添加组件的连续性。更改它们属于迁移工作，不是普通品牌文案修改。`TokensPrep` 是独立的历史合成验证应用，不能当作正式 Tokly 的运行证据。

## 4. 从新 checkout 构建

以下命令均在仓库根目录执行。无需原开发机器上的绝对工作路径。

### 环境

- macOS、完整 Xcode 和可用的 macOS SDK；仅安装 Command Line Tools 不足以构建 SwiftUI / WidgetKit targets。
- Rust/Cargo（含 Clippy）、Python 3，以及 Xcode 自带的 Swift 工具链。
- 目标最低 macOS 14，当前运行验收面向 Apple Silicon。验证机器使用 Xcode 26.6、Rust 1.95.0；项目尚未定义更低版本的已测工具链范围。
- 脚本默认使用 `/Applications/Xcode.app/Contents/Developer`，可通过 `DEVELOPER_DIR` 指定别处的完整 Xcode，不需要修改系统全局 `xcode-select`。

### 首次准备 Rust 依赖

Rust 检查脚本使用项目内 `.build/cargo-home`，并强制离线执行。**新 clone 不包含这个缓存，必须先下载依赖。** 下载仅涉及构建依赖，不读取用户会话。

```sh
mkdir -p .build/cargo-home
CARGO_HOME="$PWD/.build/cargo-home" CARGO_NET_OFFLINE=false \
  cargo fetch --locked --manifest-path Collector/Cargo.toml
CARGO_HOME="$PWD/.build/cargo-home" CARGO_NET_OFFLINE=false \
  cargo fetch --locked --manifest-path Collector/vendor/Cargo.toml
```

保留两个已提交的锁文件。若依赖下载失败，检查网络与本机代理；不要删锁文件、换版本或把缺缓存误判为源码失败。

### 检查与不签名构建

```sh
python3 scripts/check-upstream.py
bash scripts/check-collector-api.sh
bash scripts/check-collector.sh
bash scripts/check-shared.sh
bash scripts/check-app.sh
bash scripts/check-widget.sh
```

执行顺序有意义：`check-collector.sh` 先生成 release helper，Xcode 的原生 Copy Files 阶段再把它嵌入应用。不能在全新 checkout 中跳过 helper 构建就直接运行 Xcode 检查。

| 脚本 | 实际覆盖 |
| --- | --- |
| `check-upstream.py` | 上游固定文件及已登记补丁的哈希一致性 |
| `check-collector-api.sh` | 提取的核心 API 合成回归；不代表上游全套测试 |
| `check-collector.sh` | Collector 测试、严格 Clippy、release helper 构建 |
| `check-shared.sh` | Foundation 可执行检查：协议、聚合、时间和费用边界 |
| `check-app.sh` | 调度、真实合成子进程、生产投影检查，再构建不签名应用及扩展 |
| `check-widget.sh` | 合成文件/状态/时区检查，再构建不签名应用及扩展 |

不签名产物：`.build/TokensDerivedData/Build/Products/Debug/Tokly.app`。
Helper：`.build/collector-target/release/tokens-collector`。

这些脚本不会运行正式应用、读取真实日志、添加桌面组件或开启登录启动。测试中的子进程是专用合成 fixture。当前仓库没有 GitHub Actions CI，推送成功不代表检查通过。

### 本机开发签名

在具备可用开发身份的机器上，创建未跟踪的配置文件并填写本机团队：

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
# 编辑 Config/Local.xcconfig，填写 DEVELOPMENT_TEAM。
bash scripts/build-local.sh
```

已有 `Local.xcconfig` 时不要覆盖它。签名配置、证书和钥匙串不从仓库恢复，也不应提交。主应用与扩展必须解析到同一个实际 App Group；helper 通过 `CodeSignOnCopy` 使用开发签名。

签名产物：`.build/TokensSigned/Build/Products/Release/Tokly.app`。安装前先验证：

```sh
codesign --verify --deep --strict \
  .build/TokensSigned/Build/Products/Release/Tokly.app
```

`build-local.sh` 只构建，不安装、不购买、不公证，也不自动申请新证书。安装或更新时先正常退出旧进程，确认目标属于本应用，再复制签名包；不能覆盖其他同名应用。原开发机器的安装位置是 `~/Applications/Tokly.app`，其他机器不必沿用该位置。

不签名构建通过不等于 App Group、Gatekeeper 或真实桌面组件通过；换机器后必须重新验证签名和组件读取。

## 5. CLI 与本机数据位置

### 无真实日志的 scan 示例

```sh
demo_dir=$(mktemp -d /private/tmp/tokly-demo.XXXXXX)
mkdir -p "$demo_dir/home" "$demo_dir/config"
.build/collector-target/release/tokens-collector scan \
  --home "$demo_dir/home" --config-dir "$demo_dir/config" \
  --timezone Asia/Shanghai \
  --since 2026-09-01 --until 2026-09-08 --hourly-date 2026-09-08 \
  --clients codex,claude,opencode
```

这是空 home，预期为无记录/缺价格的成功快照，不代表真实用量为零。`scan` 不联网；参数错误退出2，采集/输出失败退出1，成功输出单个 JSON 文档。

独立价表刷新会联网访问公开价格源，可在上面的临时 config 中验证：

```sh
.build/collector-target/release/tokens-collector prices refresh \
  --config-dir "$demo_dir/config"
```

刷新结果全成功退出0；任一源失败退出1并可保留部分成功结果。不要把价格刷新报告当作 `ScanSnapshot` 解码。下载先进入临时目录，验证后逐文件原子更新正式缓存，失败不能覆盖最近可用价表。

### 正式应用数据

| 数据 | 位置 / 用途 |
| --- | --- |
| 完整成功快照 | `~/Library/Application Support/local.tokensmacos.app/scan.json` |
| 消息与价格缓存 | 同一私有目录下的 `config/`；价格文件在 `config/cache/` |
| 展示偏好 | Bundle ID 对应的 `UserDefaults`，不在 Git 仓库中 |
| 组件快照 | `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` 解析的容器内 `widget-snapshot.json` |
| 本机签名配置 | `Config/Local.xcconfig`，已忽略 |

组件快照仅包含日期、统计时区、更新时间、今日汇总、客户端摘要及展示偏好。不要把全量历史、源日志路径、会话正文或凭据写入 App Group。不能把开发机器的 `~/Library/Group Containers/...` 绝对路径写死到另一台机器。

## 6. 验证程度与已知限制

已记录的本机验收包括：开发签名与严格深度校验、真实用量/部分费用显示、模型详情、正式小号/中号组件添加、后台更新、主应用退出后组件保留数据。菜单栏容器的早期布局问题已经修复，后续还增加了模型排名、日期切换和 B 单位；用户已确认当前版本可用。

已自动检查的边界包括：原口径合成回归、旧 mtime、重复事件、Int64 精度、缺价/免费、日/小时一致性、范围覆盖、客户端身份、请求合并、子进程取消/超时、权限失败及 Widget 缺失/损坏/跨日状态。

未覆盖或需要重新验收的范围：

- 其他上游客户端和自定义镜像配置尚未逐一核对。当前本机口径核对重点是 Codex、Claude Code、OpenCode。
- 真实睡眠恢复、真实午夜切换、浅色桌面、长期能耗以及登录启动注册效果未逐项实测；部分仅有合成检查。
- WidgetKit 的刷新时机由系统决定，不能承诺按采集周期准时更新。
- Widget 深链代码和配置已检查，实际桌面点击未取得独立自动化通过证据。
- Intel 运行、公开发行公证、App Store、自动升级与跨机器签名尚未验收。

证据是历史观察，不是当前机器健康状态。不要将一次构建、测试计数、Worker 的 completed 状态或旧截图代替当前验收。

## 7. 修改任务怎么落地

| 修改类型 | 先看 | 必要验证 |
| --- | --- | --- |
| Token/估值/来源读取 | 协议、Collector、相关上游 parser/pricing | Collector 检查；改动核心 API 时补 API/指纹检查；真实口径变更需同语料对照 |
| 日期、聚合、单位 | Shared；注意 App 与 Widget 共用 | Shared + 主应用投影 + Widget 检查 |
| 菜单栏/主窗口 | 对应 View、AppState、RangeProjection | 主应用检查及真实 UI；布局问题不能只靠编译验收 |
| 子进程/调度 | CollectorRunner、ScanScheduler、AppState | 合成 runner/调度检查，必要时复核后台与退出 |
| Widget | Shared payload、WidgetData、Provider、发布路径 | Widget 检查、包含扩展的构建，以及正式签名桌面读取/刷新 |
| 品牌/Bundle/存储 | 本 README 标识表、Config、工程和 SnapshotStore | 区分文案与迁移，验证已有数据和已添加 Widget 不丢失 |

优先修复真实缺陷的公共路径，复用已有聚合与标准库，不引入第二套计数公式、额外常驻服务或仅供假想扩展的框架。测试与改动风险相称；文档修改只需核对命令、路径、链接和事实，不必重跑全套应用构建。

历史 Muse 分包、task_id 和自动跟进记录位于 `docs/DEVELOPMENT.md`，它们是开发证据，不是当前正在运行的任务，也不意味着新 agent 必须继续相同路由或获得了新的外部数据发送权限。不要自动重启旧自动化或重复分派已完成包。

## 8. 上游、资产与历史材料

核心复用 [missuo/tokens](https://github.com/missuo/tokens) 的固定提交 `75aba190695c9de5f2695d9baba6afd3c8cb63f8`。来源及原始指纹见 [UPSTREAM.json](Collector/vendor/UPSTREAM.json)，获准本地补丁见 [LOCAL-PATCHES.json](Collector/vendor/LOCAL-PATCHES.json)。当前补丁为本地采集 API 提取和合成测试；不能静默更新 vendor 或只改哈希来掩盖未审查修改。

上游 MIT 声明保存在 [Collector/vendor/LICENSE](Collector/vendor/LICENSE)，复用/分发时须保留。品牌图标源图和 ICNS 在 [assets/branding/](assets/branding/)，生成方式、提示词及名称选择记录见 [BRANDING.md](docs/BRANDING.md)。第三方核心许可不应被误解为对仓库所有其他资产的单独授权结论。

更多材料：

- [Shared/protocol.md](Shared/protocol.md)：Collector 与 Swift 的数据契约。
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)：架构背景及早期设计约束。
- [docs/LOCAL-DELIVERY.md](docs/LOCAL-DELIVERY.md)：按阶段追加的本机交付记录。
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)：开发包、返工和验收记录。
- [docs/PRODUCT-PROTOTYPE.md](docs/PRODUCT-PROTOTYPE.md)、[docs/prototype/](docs/prototype/)：批准的原型基线；后续菜单栏增强见本 README。
- [validation/README.md](validation/README.md)、[docs/VALIDATION.md](docs/VALIDATION.md)：早期性能实验和方法；其中原机器临时语料不在仓库内。
- [docs/OPENCODE-WORKER-COMPLETION-HANDOFF.md](docs/OPENCODE-WORKER-COMPLETION-HANDOFF.md)：Worker 完成通知问题的历史分析，不是当前宿主能力保证。

## 9. 版本与当前性能基线

版本遵循x.y.z：大版本/新增功能/优化修复。应用及扩展从Config/Version.xcconfig读取版本和构建号，Collector版本同步；具体流程见 [VERSIONING.md](docs/VERSIONING.md)，每版变化见 [CHANGELOG.md](CHANGELOG.md)。检查命令为 `python3 scripts/version.py check`，递增工具不会自动发布。

签名脚本默认Release，诊断时可传Debug；安装包记录构建配置和源码提交。不要用历史Debug或早期collector-probe的资源测量代表新的Release。`scripts/profile-runtime.py`支持对指定已运行app bundle做只读CPU时间、RSS和physical footprint采样；不读取会话正文、不自动触发采集，结果默认由调用者指定位置保存。
