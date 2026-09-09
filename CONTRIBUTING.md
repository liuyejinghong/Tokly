# 参与 Tokly

欢迎帮助 Tokly 改善本机 AI 用量统计、可用性和跨机器兼容性。

## 反馈问题

请先搜索已有 Issue。报告中说明 macOS 版本、Apple Silicon/Intel、Tokly版本与构建号、AI客户端及版本、复现步骤、实际结果和预期结果。

涉及数据时请提供合成或充分脱敏的最小样例，不要上传完整会话、账户信息、API密钥、价格/消息缓存、签名证书或目录授权文件。发现涉及隐私的漏洞，请联系维护者邮箱 393156845@qq.com，勿在公开 Issue 贴敏感内容。

## 提交改动

1. Fork仓库，从`main`建立分支。
2. 大范围功能或统计口径变更先开Issue讨论；小修复可以直接提交PR。
3. 说明解决的问题、用户可观察的变化及完成的验证。
4. 保留第三方许可证，不随意升级或修改固定的采集核心。

构建方法与代码地图见[开发者指南](docs/DEVELOPER-GUIDE.md)。按修改范围运行检查：

| 修改范围 | 检查 |
| --- | --- |
| Rust采集与估价 | `bash scripts/check-collector.sh`；修改固定核心时另跑 `python3 scripts/check-upstream.py` |
| 共用数据与聚合 | `bash scripts/check-shared.sh` |
| 主窗口、菜单栏与调度 | `bash scripts/check-app.sh`，交互变化另做实际界面验证 |
| 桌面小组件 | `bash scripts/check-widget.sh`，涉及签名/容器时另做实际运行验证 |
| 实验目录授权 | `bash scripts/check-directory-access.sh` |
| 文档 | 检查链接、命令和事实即可 |

不要提交`Config/Local.xcconfig`、构建产物、运行缓存或真实日志。源码构建检查通过不代表其他用户机器上的安装和小组件已经通过验证。

贡献代码按仓库的MIT许可证提供；第三方引入内容须保留来源及适用许可。
