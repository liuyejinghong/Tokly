# Tokens macOS · v2 开发包

更新：2026-09-08。用户已确认v2原型并要求开始分派。先完成可用的本机开发版本，再单独处理公开发行。

## 已固定的产品基线

- 本机用量、按模型单价估算；无账户管理、剩余额度、排行榜、云上传。
- 原生SwiftUI：总览、模型、来源、小组件、设置；默认今日。
- 客户端是父级，模型是子级；同名模型跨客户端分别保留。
- 今日按小时、近7天按日；本月为自然月，默认日曲线，可切自然周汇总（4–6段，未来null，部分周注明截止日）。
- 主窗口过滤不改变菜单栏/小组件今日总量；由这些入口打开的详情应是今日范围。
- 默认10分钟采集，可选5分钟；完整扫描+缓存，禁止采用已知会漏计的mtime快捷路径。
- 小号/中号原生桌面小组件，显示更新时间，遵守系统刷新调度。
- 部分缺价显示已知部分；全部缺价显示不可用；合法零单价不是缺价。

批准来源：[产品原型规则](PRODUCT-PROTOTYPE.md)、[可打开的原型](prototype/approved-v2.html)。原始片段和指纹也保存在 prototype/；它们是视觉/交互参考，不是生产计算逻辑。

## 执行顺序与验收

| 包 | 交付 | 依赖 | 当前状态 |
| --- | --- | --- | --- |
| [P1A](packets/P1A-CORE-API.md) | 保持原口径的本地核心接口与合成测试 | 已具备 | 已验收：6项测试与Clippy通过 |
| [P1B](packets/P1B-COLLECTOR.md) | 正式scan CLI、客户端/模型分桶、离线单价估算 | P1A验收 | 采集/估值实现已验收；非主目录覆盖列入P5关闭项 |
| [P1C](packets/P1C-PRICES.md) | 独立公开价表更新，失败保留缓存 | P1B验收 | 已验收：47项检查及三源联网更新通过 |
| [P2](packets/P2-SHARED.md) | Swift协议、时间/父子聚合、Widget快照 | P1B契约联调 | 已验收：103项检查及实际快照验证通过 |
| [P3](packets/P3-APP.md) | 原生主窗口、菜单栏、来源和调度 | P1B、P2 | 实现已验收：96项检查和构建通过；UI运行待P5 |
| [P4](packets/P4-WIDGET.md) | 原生小/中号Widget与正式数据联调 | P2、P3 | 实现已验收：59项检查及扩展构建通过 |
| [P5](packets/P5-INTEGRATION.md) | 本机签名开发版、真实数据与运行验收 | P1–P4 | 本机版已安装，范围与限制见LOCAL-DELIVERY |

数据契约以 [Shared/protocol.md](../Shared/protocol.md) 为准。Collector返回日/小时投影下的客户端→模型数据；Swift唯一聚合路径产生各视图汇总，避免重复公式和错加两种投影。

一个包通过后才启动有依赖的包。当前插件一次只跑一个指定Muse任务，不将上述表误报为已经并行运行。

## Worker 分派规则

固定角色 Sisyphus - ultraworker，固定 provider/model 为 opencode-go / muse-spark-1.3-contributor。不得静默替换模型，也不把它称为原生Codex子代理。

每次 start 提供：本包路径、绝对工作目录、字面可写文件、精确允许命令、前置输入和验收条件。Worker不是唯一编辑者，禁止回滚包外改动。源码与参考资料必须在已分配目录内。

Worker仅接触必要项目源码、批准原型、开发包和合成样例；真实会话、账号凭据、签名配置不发送。命令不能绕过这些数据边界。编译/测试脚本由Codex维护，Worker不可修改白名单脚本。

完成后读取实际差异、工具错误和检查输出；Codex独立运行关键检查，completed不等于验收通过。返工使用原任务 followup，确认finished后才重新分配文件。每次请求ID保持稳定，不用新ID重复不确定的调用。

## 本轮分派记录

用户已通过对话文本明确批准本项目后续 Muse Contributor 数据传输范围，知悉 Contributor 条款。授权包括已确认原型、开发包、必要源码和合成测试；不包含真实日志、账号凭据和本机签名配置。用户当前使用手机 remote，后续确需确认时应提供可直接文字回复的说明。

P1A 已提交：task_id `10d45d92-b058-4385-a495-25d331e3b533`，request_id `tokens-p1a-core-api-20260908-01`。拥有 lib.rs 和 collector_api.rs 两个文件，唯一允许命令为离线检查脚本。该包已完成。Codex检查了实际diff，修正冗余借用并补齐测试环境恢复；独立重跑6项测试通过，Clippy -D warnings通过。原始上游指纹保留，获准补丁登记在 Collector/vendor/LOCAL-PATCHES.json。

P1B 已启动：task_id `87b33c20-8406-44aa-94eb-732bde71758f`。仅拥有Collector根manifest、src/和tests/，不修改已验收vendor；离线测试/Clippy/release构建由固定脚本执行，真实数据验收仍由Codex承担。

## 现有基础与边界

前置验证见 [PREPARATION.md](PREPARATION.md)：原版核心已固定，Xcode和开发签名、App Group、真实Widget前后台刷新均已验证。正式实现仍要重新验收自己的协议和Bundle，不能用preflight合成结果替代正式统计。

新应用安装、签名权限变更、公开发布或购买会员不包含在Worker权限中；需要时由Codex在产物准备好后集中处理。现阶段没有远程推送或公开发布计划。

## 会话暂停后的跟进状态

用户已在2026-09-08明确授权自动跟进。原生线程 heartbeat 已创建并回读确认：ID为 tokens，状态ACTIVE，每5分钟，绑定当前Tokens会话。根据当前包状态验收、返工、继续分派；无变化保持安静，完成本机开发包或需要用户处理时暂停。它依赖本机宿主能运行，不是插件已经具备完成回调。

P1B Worker现已停止并提交结果，尚未由Codex独立验收；下一次自动跟进从实际diff、检查脚本和数据边界审查开始，不重复启动P1B。Worker报告28项测试/Clippy/release通过，但这些报告不能替代验收。重点复核pricingAsOf取最新缓存时间是否掩盖实际使用的陈旧价格，以及来源读取失败和原统计口径。

插件问题与根本改进建议见 [完成跟进问题说明](OPENCODE-WORKER-COMPLETION-HANDOFF.md)。

## P1B 首轮验收（2026-09-08 16:28 CST）

Codex独立重跑28项测试、Clippy与release构建，均通过；实际代码审查及合成复现发现现有测试漏掉失败边界，暂不冻结Swift实现。复现收据见 evidence/p1b-review-reproductions.json。

返工范围保持原P1B所有权：价表元数据必须和可加载数据一致，不能由新缓存掩盖旧缓存；不可读已发现会话不得成功返回空数据；零Token事件不能把全部缺价组变成已知0；公共API空客户端选择必须拒绝；stdout写失败必须退出1；默认来源状态须覆盖核心默认启用的synthetic。补齐相应合成回归和完整scan的重复事件/旧mtime覆盖，原parser与计价公式不改。

已提交同任务 followup：request_id `tokens-p1b-collector-rework-20260908-01`，turn=2，插件返回submitted/finished=false；保留Collector文件所有权，下一次跟进验收该轮。

第二轮独立36项测试/Clippy/release通过；发现不可读嵌套目录仍返回notFound，见 evidence/p1b-review-directory.json。已提交turn3，request_id `tokens-p1b-directory-readability-20260908-01`，finished=false；原文件所有权保留。其他已修正项保留，本机固定数据对照由Codex独立进行。

本机固定数据对照已完成：2026-09-01至09-08共13个日期/客户端组，五类Token均与同一语料最终上游基线一致；今日小时合计与日合计一致。首次选择的较早基线缺少前置测试注入的160Token合成事件，已核实并改用相同语料的最终基线。收据 evidence/p1b-real-parity.json；真实日志未交给Worker，价格金额未用原账单作对照。

## P1B 实现验收与后续边界

第三轮实际修复已复核，Codex独立37项测试、Clippy和release构建通过；主来源根、嵌套目录与已发现文件的不可读失败路径已覆盖，复用前轮13组真实语料Token对照。允许P1C和Swift契约联调继续。

这不是所有来源完整性认证：核心内置替代目录的遍历错误尚未统一暴露，且默认ScannerSettings/禁用环境覆盖使Worker列举的部分路径不可达。P5须针对实际启用来源确认可达替代根的失败行为；修复或明确限制支持范围后才能宣称本机交付完成。此项保留为交付关闭条件，不由绿色测试豁免。

## 当前活动Worker：P1C

P1C task_id `f641e33a-221f-438a-b06d-89dff2112ab2`，request_id `tokens-p1c-prices-20260908-01`，turn1，submitted/finished=false。拥有price_update.rs、main.rs、lib.rs（仅模块导出）和tests/price_update.rs，命令限check-collector.sh。下一次自动跟进检查此任务；P1B已经停止，无需重复等待或启动。

## 当前活动Worker：P2（P1C已验收）

P1C独立47项测试/Clippy/release通过；三公开源实际下载均updated，缓存非空且后续离线scan加载成功，收据 evidence/p1c-acceptance.json。Worker有一次越过精确命令白名单的git查询被插件拒绝，未执行；其余产物/检查已由Codex独立验收。沙箱首次网络失败，获准在沙箱外访问公开服务后成功，无用户日志参与。

P2 task_id `e34777de-714d-4808-82b0-1a06a8656f26`，request_id `tokens-p2-shared-20260908-01`，turn1，submitted/finished=false。仅拥有三个Shared Swift文件及Shared/Tests/，命令限 `bash scripts/check-shared.sh`。下次自动跟进检查此任务；P1B/P1C均已停止。

## 自动跟进暂停（2026-09-08 17:12 CST）

P2 Worker已停止，finished=true，APIError/RegionError HTTP403：This model is not available in your country. 服务标记isRetryable=false，未产出Swift文件。未切换模型、未修改网络路由或账号。自动跟进按授权暂停，等待用户决定恢复同一服务后重试，或明确改为Codex亲自实现。P1B/P1C已验收成果保留；P2–P5未完成。

## P2恢复（2026-09-08 17:15 CST）

用户恢复代理并明确要求重试。沿用原P2任务followup，request_id `tokens-p2-retry-20260908-01`，turn2；已观察到Muse成功回复并读取执行包/协议，running、finished=false、当前errors为空。每5分钟自动跟进已恢复ACTIVE，无模型或权限变更。

## P2 实现首轮验收（17:22 CST）

独立93项检查通过，实际Collector快照可解码，但费用浮点精度使日/小时一致性误报失败。独立合成检查还复现空桶+全缺价→错误已知0、ScanSnapshot Codable回读失败、Widget重打当前时间。周段部分缺覆盖仍输出总量、重复小时被重复合并也交回修正。同任务turn3，request_id `tokens-p2-acceptance-fixes-20260908-01`，finished=false。P2未验收；真实快照仅Codex本机使用，Worker只接收问题描述和合成复现要求。

## P2验收完成

第三轮实际源码复核、独立103项检查通过；原本机Collector快照的日/小时一致性现在通过，空桶+缺价返回null、Codable回读及Widget保留采集时间均通过独立复现。收据 evidence/p2-acceptance.json。P3准备分派。

## 当前活动Worker：P3

P3 task_id `99baa3c3-40d0-43ea-aa78-edb1c0045917`，request_id `tokens-p3-app-20260908-01`，turn1，submitted/finished=false。拥有TokensApp/、Tokens.xcodeproj/及两个App配置文件，唯一命令bash scripts/check-app.sh（合成调度检查+不签名构建）。不运行、不签名安装、不改系统设置。下一次跟进检查P3任务。

## P3首轮未通过验收

独立48项调度检查和构建通过，但实际进程取消、来源/时间范围一致性及多处UI接线有缺陷，依据 evidence/p3-review.md。同任务返工，检查脚本增加无网络/无HOME的合成子进程测试；正式app仍未运行。

已提交P3 turn2：request_id `tokens-p3-wiring-fixes-20260908-01`，同task_id，submitted/finished=false，保留所有权。下次从此轮结果继续。

## P3第二轮验收

独立61项调度+13项真实合成进程检查及构建通过。进程取消与UI接线修复保留；尚需修正价格并发启动、已覆盖空范围、Widget配置失效及冗余sidecar一致性，见 evidence/p3-review2.md。检查脚本增加实际RangeProjection合成验收。

P3 turn3已提交：request_id `tokens-p3-final-consistency-20260908-01`，同任务，submitted/finished=false，保留文件所有权。

## P3实现验收完成

第三轮实际代码复核，独立65项调度、13项合成进程、18项生产投影检查及unsigned构建通过。Codex去掉未发行sidecar清理代码，补齐价格取消错误分类。P4准备时给WidgetSnapshot增加统计timezone（避免系统时区不同导致跨日错判），Shared103项和主应用全检查再次通过。实际界面、签名安装、登录启动及桌面Widget仍须P5验证。

## 当前活动Worker：P4

P4 task_id `9437339b-81e4-43df-8ce1-58cbec669821`，request_id `tokens-p4-widget-20260908-01`，turn1，submitted/finished=false。拥有TokensWidget/、Tokens.xcodeproj/及两个Widget配置文件，命令限bash scripts/check-widget.sh（合成快照/状态检查+不签名构建）。下一次跟进检查P4。

## P4实现验收与P5准备（2026-09-08 18:24 CST）

P4实际源码检查、独立59项合成读写/状态检查和app+appex unsigned构建通过。Codex移除了fileExists误判权限错误的回退，并补权限拒绝测试。Worker读取范围外工具输出曾被阻止，未执行；不影响Codex独立验收。扩展已嵌入Tokens.app/Contents/PlugIns/TokensWidget.appex。

P5中，默认已核对客户端补了Codex归档、Claude transcripts、OpenCode数据根、headless根及已发现内置替代路径的读取检查；合成拒绝路径测试含未选择来源不受影响。Collector48项/Clippy/release通过，主应用96项和含扩展构建通过。验收范围为本机默认Codex/Claude/OpenCode语料与上述可达错误，未逐一认证其他客户端和自定义镜像配置；来源页已说明。原版parser/vendor未改动。

待用户确认：使用已有Apple Development身份为local.tokensmacos.app及.widget、team.tokensmacos.app签名，安装到/Users/ethan/Applications/Tokens.app，运行真实本机采集、添加正式小/中号桌面组件、检查前后台与退出行为。签名入口scripts/build-local.sh已准备；不含自动新建证书/配置文件权限，不购买/发布、不启用登录启动。若现有身份不足再以实际错误说明。之前授权仅限TokensPrep前置验证，正式应用身份是新范围。自动跟进暂停等待文字答复；P1–P4实现完成，P5未完成，尚不能声称可安装版或实际桌面通过。

## 本机开发版交付

用户已明确批准正式签名安装和桌面验证。主应用、helper、扩展使用现有开发身份，安装于/Users/ethan/Applications/Tokens.app；实际App Group由Config/Local.xcconfig中的团队前缀解析，与两份entitlement/Info.plist一致。未创建新证书、未购买或发布，未启用登录启动。

真实采集、价格加载、模型详情、正式小/中号桌面添加、后台刷新和退出保留已观察。Cua桌面坐标入口不支持，后通过Finder的Menu键打开编辑组件库完成添加。完整交付范围和未实测项目见LOCAL-DELIVERY.md。所有外部Worker均已停止。自动开发跟进结束并暂停，后续按用户反馈继续。

## 正式名称Tokly

用户已确定Tokly。工程改为Tokly.xcodeproj、scheme Tokly、产品Tokly.app；内部Bundle/数据/Widget标识保留。签名安装于/Users/ethan/Applications/Tokly.app，实际启动和旧数据读取通过；旧Tokens安装包已备份。图标已作为资源接入。
