# P1B · 正式本地采集器

状态：等待 P1A 验收。只实现采集与本地价表估算，不做 UI 或联网价格更新。

## 输入与所有权

必须读 Shared/protocol.md、P1A接口、上游 pricing/mod.rs 和 pricing/lookup.rs。

可写：Collector/Cargo.toml、Collector/Cargo.lock、Collector/src/、Collector/tests/。
不得修改 Collector/vendor/，若确需增加核心接口，向 Codex 提交依据后再定范围；不得自己扩大。

## 交付

- 二进制名 tokens-collector，scan 参数与输出严格按 Shared/protocol.md。
- 业务入口有可用合成消息与价格服务直接测试的函数，CLI只负责参数、文件系统和序列化。
- 逐事件估算后再聚合，树形身份键为 clientId+canonical_model_id；保留五类 Token 的 Int64 精度。
- 只用已有本地价格缓存，不初始化联网 PricingService。未知单价与0单价按契约区分。
- 使用独立应用缓存，不能写入原 tokens CLI 的默认配置目录。
- 价格时间来源读取失败时返回null并警告，不能用“当前时间”冒充价表更新时间。
- 诊断只包含来源类型与可操作错误，不输出正文或私密路径到面向 Worker 的结果。

## 验收

P1A原口径对照，加协议必测项。Codex提供/审查精确检查脚本后才授权运行。Worker仅用合成输入；真实日志运行和跨版本结果核对由Codex完成。

待收据：实际源码差异、离线测试输出、成功和失败各一个合成CLI例子。通过后才向Swift端冻结实现版本。
