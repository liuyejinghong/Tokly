# P1C · 独立价格更新

状态：P1B实现验收完成，可执行。

可写：Collector/src/price_update.rs、Collector/src/main.rs、Collector/src/lib.rs（仅导出price_update模块）、Collector/tests/price_update.rs。禁止改统计聚合；manifest/lock由Codex预备。

交付独立 prices refresh 命令，复用原版公开价格源适配和缓存结构。命令只抓取公开价格数据，不读取会话，不发送本机模型使用列表或账号。

- scan 继续纯本地；首次无价格时仍可提供 Token。
- 刷新由主应用按需触发，价格每日更新即可，不随5/10分钟采集重复联网。
- 网络失败保留最近可用价表；不能把失败下载写成有效空表。
- 每个价格文件采用原子写入，记录真实更新时间。UI不等待此命令才显示用量。
- 用本地合成响应/已有离线数据测缓存与失败路径；真实网络验证由Codex执行，不给Worker宽泛网络命令。

验收：无价表→有效价表、陈旧缓存→成功更新、网络失败→缓存保留；采集与价格更新互不阻塞。后续并发锁只解决实际读写互斥，不建立后台服务框架。

## 锁定CLI和实现边界

`tokens-collector prices refresh --config-dir ABS`，stdout单个JSON：schemaVersion=1、generatedAt、sources数组（source=litellm/openrouter/models-dev，status=updated/failed，updatedAt可空）、warnings数组。全成功退出0，任一源失败退出1，参数非法退出2；部分成功结果可输出，主应用不把价格刷新失败当scan失败。

原适配器fetch会自己写缓存，不能直接指向正式config运行。用临时隔离config承接下载，复用公开适配器，然后验证非空有效定价数据并逐文件原子落入正式cache；失败时正式文件逐字节不变。没有真实网络授权给Worker；通过可注入获取结果的业务入口，用合成数据覆盖成功、空/损坏/失败保留、部分成功。不要增加面向产品的自定义URL、测试开关或守护服务。tokio/tempfile已在manifest准备，唯一允许命令仍为 `bash scripts/check-collector.sh`。
