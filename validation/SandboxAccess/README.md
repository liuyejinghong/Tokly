# SandboxAccess 可行性验证

独立验证程序，不覆盖已安装的Tokly 0.1.0。使用原Rust采集器，父程序开启App Sandbox、user-selected read-only和app-scope bookmarks；helper只有app-sandbox和inherit两项沙盒权限。

```sh
bash scripts/check-collector.sh
bash scripts/build-sandbox-check.sh
```

运行 `.build/SandboxAccess/ToklySandboxCheck.app`。先验证未授权读取被拒绝，再通过系统选择框分别授权本目录Fixtures/home中的 `.codex/sessions`、`.claude/projects`、`.local/share/opencode`。正常合计280Token。退出程序并重启后，不再选目录，执行采集仍应得到280Token。

此验证把授权URL映射为沙盒容器内的符号链接，在安全作用域有效期间启动继承沙盒的原helper；没有放宽父目录或修改parser。持久化bookmark留在程序私有容器，不提交Git。

已在2026-09-08实际验证：未授权拒绝、三个只读目录授权后280Token、重启恢复仍280Token。额外的OpenCode SQLite/WAL合成测试在数据库写连接保持打开时，沙盒与非沙盒均得380Token。该结果证明此链路可行，不等于商店审核或所有客户端都已验收。
