# P3 · 主应用、菜单栏与采集调度

状态：等待 P1B/P2 接口验收。

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
