# Collector → macOS 数据协议 v1

状态：Codex 定义的执行契约，配合用户已确认的 v2 原型。原型中的演示计算不能复用到正式统计。

## 调用方式

    tokens-collector scan --home ABS --config-dir ABS --timezone IANA \
      --since YYYY-MM-DD --until YYYY-MM-DD --hourly-date YYYY-MM-DD \
      [--clients codex,claude,opencode]

- 三个目录/时间参数由主应用明确传入，不拼接 shell。两个目录必须为绝对路径，日期严格校验，since ≤ hourly-date ≤ until。
- 日期范围含首尾。主应用请求范围为“本月首日”和“今日往前6天”中较早者至今日；hourly-date 为今日。
- 默认客户端使用上游注册表的完整集合；显式 clients 只保留所选客户端。空选择由主应用处理为未启用来源，不以空列表误触发“全部”。
- 调用 collect_messages 时 today_only=false，use_env_roots=false，并设置隔离 TOKENS_CONFIG_DIR；数据源只从明确 home 和选定客户端读取。
- scan 不联网，不上传，不读取或切换账号；价格更新独立为后续 prices refresh。
- stdout 是一个 JSON 文档；诊断在 stderr。参数错误退出2，已知采集/输出失败退出1；失败不输出伪造的成功零值文档。
- generatedAt 为 UTC RFC3339，timezone 为分桶使用的 IANA 标识。日期与小时继承原版规范化消息的日期、记录时间及既有回退语义，不另写 parser。

## JSON 结构

根字段：

- schemaVersion：整数1
- generatedAt：UTC RFC3339字符串
- timezone：IANA字符串
- range：对象，since、until 都为 YYYY-MM-DD
- hourlyDate：YYYY-MM-DD
- pricingAsOf：本次已加载价格缓存的保守时间，多个可用缓存取最旧时间，可为null；损坏或未来时间的缓存不得冒充可用快照
- daily：按 date 升序的 DayBucket 数组
- hourly：hourlyDate 当天按 hour 升序的 HourBucket 数组
- sources：SourceStatus 数组
- warnings：非致命的 Warning 数组

DayBucket = { date, clients }
HourBucket = { hour, clients }，hour 为0–23的本地时钟小时。遇到重复时钟小时按小时标签合并。
ClientUsage = { clientId, models }
ModelUsage = { modelId, tokens, estimatedCost }

tokens = { input, output, cacheRead, cacheWrite, reasoning }，均为非负 Int64 整数。total 由五项按原版饱和加法求和，不经 Double 中转。客户端、模型、日期的合计由 Shared Swift 同一个聚合函数完成；不要传多份冗余汇总产生不同口径。

modelId 使用上游 canonical_model_id；分组键为 clientId+modelId。同一模型跨客户端分别保留。单价估算先逐条消息按原 provider/model 计算，再按这个分组键合并，不丢失计价所需的 provider 信息。

SourceStatus = { clientId, status, sourceCount }。
status 为 found 或 notFound，表示发现状态，不声称 parser 已证明所有记录完整。
Warning = { code, clientId, message }；clientId 可空。根协议禁止出现会话正文、session title、workspace 路径、凭据和账号信息。来源配置路径由主应用自己持有。

只有有记录的已发生日期/小时才输出 bucket。主应用可将成功快照覆盖范围内的无记录时间补零；未来时间保持null，不能写成零。缺失/失败快照不可因此补零。

## 费用语义

estimatedCost = { amountUsd, complete, unpricedTokens }

- amountUsd：可空的有限非负浮点数。表示完整定价事件的估值之和，不是来源账单金额。
- complete：该分组所有有 Token 的事件是否都能完整按单价定价。
- unpricedTokens：无法完整定价事件的 Token 总量，Int64。
- 保守规则：某事件匹配不到模型价格，或有用量的类别缺少有效基础单价，则整个事件视为未定价；不把缺失价格当免费。
- 有效单价必须为有限非负数，显式0为合法免费价格。输入需要 input 基础单价；输出/推理合计需要 output 基础单价；cacheRead/cacheWrite 非零时分别需要相应基础单价。可选阶梯缺失沿用原版定价处理。
- 基础单价齐全后，调用原版 PricingService.calculate_cost_with_provider，保留它的匹配、缓存与阶梯行为；不复制公式或按日合并后再乘单价。
- 忽略 UnifiedMessage.cost/cost_source 的原账单金额，不使用订阅信息，不额外加入客户端附加费。
- 有已定价事件也有未定价事件：amountUsd 为已知事件合计，complete=false，显示部分估算。
- 全部有量事件均未定价：amountUsd=null，complete=false。
- 没有 Token：amountUsd=0，complete=true，unpricedTokens=0。
- 已知免费与未知严格区分：合法零单价计算出0时仍为 complete=true。

从已有应用价格缓存加载，允许陈旧缓存并提供 pricingAsOf / PRICE_CACHE_STALE 警告；没有缓存也必须能统计 Token，费用为未知。测试只使用显式合成价表。真实公开价表联网更新由 P1C 实现。

## 失败和更新边界

明显不可读的已发现来源、文件系统异常或输出失败：错误退出，主应用保留上次成功快照。不存在来源可成功返回 notFound/无数据，不能把不可读误认不存在。未扩展的原版逐行容错行为不得偷偷重写；可观测错误需如实报告，不将 found 当完整性认证。

主应用私有目录保存全量响应；Widget App Group 只保存裁剪后的今日展示快照。跨日后旧快照保持原日期并标过期，新数据到达前不能把昨天的数值改称今日。

## 必测

父子相加、跨客户端同名模型、日/小时汇总一致、重复事件、旧mtime、离线无价格、真实零价格、部分价格缺失、来源账单金额被忽略、参数非法、早月范围包含上月的近7天数据、Int64精度。
