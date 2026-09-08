# P2 · Swift 数据层和时间口径

状态：协议已定义，依赖 P1B 合成响应用于联调。

可写：Shared/UsageSnapshot.swift、Shared/UsageAggregation.swift、Shared/WidgetSnapshot.swift、Shared/Tests/。Shared/protocol.md 和已确认样例由Codex管理。

- 解码Collector协议v1，拒绝未知版本、截断或非法数据，保留Int64。
- 唯一聚合路径负责总量、费用、客户端→模型、模型详情；不能各视图重复实现不同加法。
- 今日：按本地小时；近7天：含今日的7个日期；本月：自然月首日至今日。
- 月曲线显示每日值，周柱按周一至周日、截于本月；4–6段，未来null，当前未结束周注明截止日。
- 日/小时数据只是同一用量的不同投影，不得相加两份。客户端过滤只影响主窗口，菜单栏与Widget仍显示今日所有启用来源。
- 从菜单栏/Widget打开详情时重置为今日正确范围。
- WidgetSnapshot只含日期、更新时间、今日汇总、客户端摘要及必要显示偏好，不含整个历史协议或源路径。

检查：闰月/4-5-6周/跨月/时区/早月近7天/父子守恒/同模型跨客户端/Int64大数/缺价与免费/旧日期快照。采用Foundation及小型可执行检查，避免新增测试框架。
