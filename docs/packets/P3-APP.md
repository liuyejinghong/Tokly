# P3 · 主应用、菜单栏与采集调度

状态：P1B与P2实现已验收，可执行。

可写：TokensApp/、Tokens.xcodeproj/、Config/AppInfo.plist、Config/App.entitlements；构建脚本和本机签名配置由Codex维护。

必须按 docs/prototype/approved-v2.fragment.html 与 docs/PRODUCT-PROTOTYPE.md实现原生SwiftUI界面，不搬HTML运行时，不复制演示数据或比例公式。

- 默认今日总览；左侧为总览、模型、来源、小组件、设置。
- 客户端可展开子模型；模型页以客户端分组；详情范围与来源保持一致。
- 月视图默认日曲线、可切周汇总，无横向滚动；图表用Swift Charts等系统能力。
- 首次启用、本机来源检测/选择、无数据、失败保留旧值、部分或全部无价均需呈现。
- 设置：10分钟默认/5分钟可选、菜单栏主指标、登录启动。外观跟随系统。
- 内置helper以参数数组调用；主应用是唯一调度者。合并并发请求，最多一个待执行请求；窗口关闭仍运行，显式退出停止。
- 跨日和唤醒补采一次，不强制系统唤醒，不重放所有漏过的周期。
- 完整响应私有保存，成功后原子发布今日WidgetSnapshot并请求刷新；失败不覆盖旧成功值。
- 使用明确 Window(id:) 避免已复现的SceneID启动问题。
- 正式app使用独立Bundle ID与App Group，不复用preflight身份和数据。

验收：先合成数据与调度检查，再由Codex跑真实采集、UI流程及资源观察。签名/安装/系统设置变化由Codex按已有授权范围办理，不交给Worker。

## 锁定构建和运行边界

唯一允许命令 `bash scripts/check-app.sh`：先编译Foundation-only的TokensApp/ScanScheduler.swift和TokensApp/Tests/Checks.swift（@main、注入合成动作），再构建Tokens.xcodeproj / Tokens scheme，macOS14 arm64、CODE_SIGNING_ALLOWED=NO。不运行app、不读取真实HOME、不签名、不安装、不变更登录启动设置。

正式Bundle ID `local.tokensmacos.app`；App Group `team.tokensmacos.app`，与preflight分离。主app非沙盒，Widget后续加入；现在仅定义App Group entitlement和共享快照路径。无需团队凭据或Local.xcconfig；P5才做实际签名和安装。Xcode工程使用原生构建/复制阶段，不添加自定义脚本构建阶段。通过文件引用和Copy Files把已有 `.build/collector-target/release/tokens-collector` 放入app Contents/MacOS/；不重编Rust、不引用临时本机验收路径。

包含已验收Shared三个Swift文件（引用、不得修改）；所有UI数值来自Shared和有效scan。helper位于Bundle.main.executableURL同目录，Process.arguments数组；stdout/stderr并行排空，避免管道填满阻塞。不要在主线程等待进程。终止/超时/失败保留最后成功快照，最多一个待执行扫描，来源选择变化时防止旧请求覆盖新选择。

价格每天最多按需刷新一次且与scan不同进程，失败不得影响Token展示。用户未启用任何来源时不传空clients触发全部；不将旧来源数据冒充新选择。首次流程解释本机读取并允许选择来源；来源名称/ID对齐核心注册表，不暗示账号API数据已同步。原型只供视觉参考；运行代码不嵌入演示数据或测试URL开关。合成调度检查放Tests中，排除app target。

登录启动只在用户实际切换设置时调用SMAppService，展示实际状态与错误；Worker检查不得触发注册。Widget页先提供配置/添加指引，P4提供扩展。深链 `tokensmacos://today` 和菜单栏入口都重置今日范围/主窗口过滤，保留全部启用来源今日汇总。

## 首轮验收返工

原48项纯调度检查与构建通过，但不能证明实际进程和UI接线正确。检查脚本现增加Tests/RunnerFixture.swift（无网络/无HOME的合成子进程）和CollectorRunner.swift+Tests/RunnerChecks.swift独立可执行验收。仅这些合成进程可运行；不运行正式app或真实collector。Runner应独立Foundation，测试可注入临时fixture executable URL，不增加产品CLI测试开关。覆盖双管道大输出、取消/超时后子进程真正退出、非零退出。

返工依据见 docs/evidence/p3-review.md。保留原文件所有权和唯一命令；无需新增依赖/框架。Shared协议和已验收统计口径不变。
