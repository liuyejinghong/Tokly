# P4 · 原生桌面小组件

状态：Shared/主应用实现接口就绪，可执行；实际桌面验收由Codex集成阶段完成。

可写：TokensWidget/、Config/WidgetInfo.plist、Config/Widget.entitlements。P3已停止，本包同时拥有Tokens.xcodeproj/以添加并嵌入扩展，不修改主应用源码。

- 小号：今日主指标、另一项摘要、更新时间；中号增加客户端摘要。
- Token/估算费用主指标跟随设置；完整未知单价显示不可用，不能显示免费。
- 只读App Group中的今日快照，不运行collector、不访问用户会话或网络。
- 点击打开今日总览；不继承主窗口此前的月/客户端过滤。
- 旧日期/过期/文件损坏/无快照状态明确，不把昨天的数字重新标为今天。
- 遵守系统刷新策略；不承诺5/10分钟准点，不用开发者模式豁免作为通过依据。

验收：小/中号实际桌面、两种外观、前后台更新、主应用退出、跨日旧值、缺价和无数据。复用preflight经验但必须验收正式Bundle与协议。

## 锁定构建与数据契约

唯一允许命令 `bash scripts/check-widget.sh`：Foundation-only TokensWidget/WidgetData.swift + Tests/Checks.swift和Shared三个源文件，@main测试首参数为批准scan样例；再unsigned构建Tokens scheme（含扩展）。不得运行正式app、Widget宿主、真实App Group、签名或安装；测试只读取临时合成文件。

扩展Bundle ID `local.tokensmacos.app.widget`，App Group `team.tokensmacos.app`，group文件 `widget-snapshot.json`。与主应用原子发布一致。Shared/WidgetSnapshot.swift 已增加timezone，builder从scan继承；跨日判断和timeline午夜entry必须用此统计时区，不隐式用扩展系统时区。所有展示的更新时间保留updatedAt，不能改成timeline刷新时间。

共享三个Swift源文件引用（不得修改），不引用TokensApp/SnapshotStore等主应用代码，不含进程启动或网络依赖。WidgetData应提供可传入URL/now的读取与展示状态纯接口，用于合成验证：missing、invalid/unreadable、current、expired；校验日期/时区/非负Token和金额/费用语义，损坏不显示伪零。文件缺失（包括用户关闭来源后的主动失效）必须占位，不能回退已失效数据。显示小/中号、系统颜色、containerBackground(for:.widget)、合理文字缩放、accessibility标签。

点击tokensmacos://today。Timeline安排下次统计日边界条目标过期（保留原日期数值）；可安排合理刷新请求，但不承诺准点。Placeholder只能有占位视觉，不嵌入演示用量。设置现有showCost表示费用主指标，false为Token主指标，次指标适当显示。Tests覆盖跨日/非系统时区、缺价/真免费、损坏/缺失/无数据以及主应用builder→编码→WidgetData读取。Xcode只原生构建/嵌入阶段，无自定义脚本，无签名团队配置。
