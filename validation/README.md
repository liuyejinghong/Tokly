# 本机验证工具

这些程序是架构验证用的探针，不是正式应用。汇总结论见 [VALIDATION.md](../docs/VALIDATION.md)。

## 输入与隔离

- 原版源码固定提交 `75aba190695c9de5f2695d9baba6afd3c8cb63f8`，验证时克隆至 `/private/tmp/tokens-research-20260908`。`reference/` 为 Worker 可读取的公开接口副本，保留原 MIT 许可。
- 采集器前置整理后，`collector-probe/Cargo.toml` 已改为仓库内 `Collector/vendor/tokens-core` 相对路径依赖，源码哈希见 `Collector/vendor/UPSTREAM.json`，不再依赖临时源码目录。
- Rust 使用 release 构建，验证缓存/输出在 `/private/tmp/tokens-validation-20260908`。原版核心没有改动。
- 真实 JSONL 使用 APFS clone 复制到隔离 home，保留 mtime；OpenCode 使用 SQLite backup API，从只读连接得到一致数据库副本。复制过程不是三个客户端的跨源原子时间点，只保证复制完成后用于重复测试的输入固定。
- 完整图表、原始日志及会话信息仅保存在本机临时目录，不能放进仓库或发送给 Worker。
- 价格输入为单次下载的公开 LiteLLM 表，另外两份价格缓存为空，以排除联网等待。此配置用于性能/口径对照，不用于证明正式产品价格覆盖完整。

## 命令

源码已随仓库固定，直接构建：

```sh
cargo build --release --manifest-path validation/collector-probe/Cargo.toml
```

通用测量入口，路径参数均需绝对路径；实际执行的示例：

```sh
python3 validation/measure.py \
  --binary /private/tmp/tokens-validation-20260908/target/release/tokens-macos-collector-probe \
  --home /private/tmp/tokens-validation-20260908/sample-home \
  --work /private/tmp/tokens-validation-20260908/full-measured \
  --pricing /private/tmp/tokens-validation-20260908/litellm.json \
  --label full --repeat 4
```

新增空 `--work` 目录表示消息缓存冷启动；重复使用表示缓存保留。`--today` 调用上游快速路径。默认客户端为 codex、claude、opencode，时区 Asia/Shanghai，Rayon 4 线程、Tokio 2 线程。`/usr/bin/time -l` 用于进程级指标；受限沙盒可能阻止 sysctl，使 time 工具报错，必须区分探针成功与测量失败。CPU 时间是 user+sys，不能当成电池耗电量。Apple 的 block I/O 计数为零也不代表没有文件读取。

合成数据检查：

```sh
python3 validation/check_fixture.py \
  --binary /private/tmp/tokens-validation-20260908/target/release/tokens-macos-collector-probe \
  --work /private/tmp/tokens-validation-20260908/fixture-new
```

使用新的 work 目录，避免已有夹具影响检查。覆盖重复 token_count、缓存一致、追加增量、归档重复及旧 mtime 反例。未知模型价格不影响 Token 断言。

`cadence.py` 是此次固定路径的 10 分钟观察脚本：t=0/300/600 秒采集同一隔离副本，t=300 秒在副本新增 160 Token 合成事件。不是 App 调度实现，也不是两组独立电池能耗实验。运行该脚本前需完成上述数据副本与构建准备。

Widget API 类型检查：

```sh
swiftc -typecheck -target arm64-apple-macosx14.0 \
  -module-cache-path /private/tmp/tokens-validation-20260908/swift-module-cache \
  validation/widget-probe.swift
```

通过只说明 SDK 接口可编译，不能证明小组件能安装、共享容器已授权或实际刷新达标。
