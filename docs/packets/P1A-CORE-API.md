# P1A · 本地采集核心接口

状态：已验收（2026-09-08），6项集成测试及Clippy通过。执行者：OpenCode Worker / Muse Spark 1.3 Contributor；Codex 验收。

## 目标

在固定版本 tokens-core 上暴露一个同步本地采集接口，供正式 collector 使用。保持现有 JSONL/SQLite 解析、去重、日期归属、客户端筛选、缓存和 generate_graph 行为。

接口精确定义：

    pub fn collect_messages(
        options: &ReportOptions,
        pricing: Option<&pricing::PricingService>,
    ) -> Result<Vec<UnifiedMessage>, String>

将 generate_graph_with_loaded_pricing 中 home/client 解析、调用 parse_all_messages_with_pricing_with_env_strategy、filter_messages_for_report 的已有逻辑原样提取到此接口；原 generate_graph 继续调用它，再执行活动时间与图表聚合。

pricing=None 时，此入口不初始化或联网获取价格。保留来源已有 cost 字段，不在这个包修改计费行为；正式统一单价估算由 P1B 实现。显式传入 pricing 时保留原来的计价处理。

正式调用会使用 today_only=false；既有 today_only 快捷路径及其已知局限不得在这个包偷偷修改。

## 文件所有权

可写且仅可写：

- Collector/vendor/tokens-core/src/lib.rs
- Collector/vendor/tokens-core/tests/collector_api.rs

可读：本包、Collector/vendor/tokens-core/、validation/check_fixture.py。不得读取真实日志、账号、凭据、Local.xcconfig 或任务目录外文件。不修改 UPSTREAM.json 原始哈希；Codex 验收后记录补丁。你不是唯一执行者，不回滚他人的修改。

## 检查

允许的 shell 命令仅为：

    bash scripts/check-collector-api.sh

脚本由 Codex 维护，不在 Worker 可写范围。测试只使用 tempfile 生成的合成日志和隔离 TOKENS_CONFIG_DIR，不使用用户 HOME。遵守全局环境变量/时区状态限制，串行执行或用已有 serial_test。

最小有意义的测试：

1. 重复 token_count 只计一次，已知合成用量得到160；追加后320。
2. 同一日志出现在当前与归档目录中仍只计一次；旧 mtime 的当日记录在完整扫描模式不丢失。
3. 客户端与日期筛选生效。
4. pricing=None 无需任何价格缓存即可返回正确 Token。
5. 显式合成 PricingService 传入时可计算已知估值；不需要调用真实网络。
6. 新接口聚合与既有 generate_graph 的 Token 结果一致；若调用后者，必须预置三个隔离价格缓存以避免联网。

不增依赖、不扩大成重构、不改任何 parser。接口无法按上述方式实现时报告具体源码依据，不猜测替代 API。

## 验收

Worker 返回实际差异、实际命令结果和未解决问题。Codex 检查 diff、重跑测试并确认唯一变化是接口提取及测试。Worker completed 不代表验收通过。
