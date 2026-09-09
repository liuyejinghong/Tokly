# App Store 沙盒适配进度

本分支为0.2.0/build4开发线，未创建0.2.0发布标签，未提交Apple审核。main及已安装0.1.0保持独立。

## 已验证

- 独立SandboxAccess验证程序：未授权目录拒绝；授权Codex/Claude/OpenCode合成目录后总量280，与非沙盒基线一致；退出再启动、不重新选择目录，仍为280。
- 活跃SQLite/WAL合成场景：原bundled SQLite在继承沙盒、只读目录授权下读得380，与非沙盒基线一致。
- 接入主应用的Store Check构建：通过系统选目录后显示160Token，下载三个公开价表，向独立App Group发布160Token组件摘要。
- 撤销授权：目录授权记录清空，旧私有快照的revision不再匹配，共享组件文件删除，原0.1.0组件文件仍在。
- 系统SQLite构建：现有Collector测试与Clippy通过；380Token合成结果和默认bundled构建相同；链接系统libsqlite3，不再引入statfs/fstatfs符号。
- 新增目录边界、损坏授权存储、快照revision与普通协议兼容检查通过。
- 最新普通构建回归：Collector 48项、App 102项、Widget 59项通过，App与Widget编译成功。
- 最新Store Check签名构建成功，arm64主程序、独立身份、两份隐私清单和第三方许可资源已核对。
- 审核说明中的合成Codex样例经系统SQLite版Collector验证为1,600,000 Token。

## 2026-09-09 最终组合回归

0.2.0/build4的独立签名测试包已验证三类合成目录授权、退出重启后重新扫描、撤销授权，以及系统SQLite活跃WAL读取。三个只读目录经用户明确授权后由系统选择器取得，未授权真实用户会话目录。

- 启动失效恢复：授权revision与旧私有快照不一致时，不恢复旧统计，删除独立App Group的合成残留文件。残留文件只验证删除行为，不代表组件格式解码验收。
- 活跃WAL：非沙盒基线与系统SQLite沙盒主应用均为380Token；主应用退出后重新启动，不重新选目录，重新采集仍为380。
- 发现并防护的边界：写入程序关闭后，WAL辅助文件消失。旧实现返回280，漏掉数据库内100Token。新实现先建立只读事务并保持至helper退出；不可读时终止本次扫描，界面提示启动OpenCode后重试，保留上次380及成功时间。实际沙盒验证通过。
- 撤销Codex授权：移除bookmark，授权revision变化，旧私有快照失效、测试组件文件删除；已安装0.1.0的组件文件仍在。
- 回归：目录检查新增只读写入拒绝、损坏数据库拒绝、写入连接关闭后读取事务保持WAL检查；App现有102项检查及编译通过。

**OpenCode仍有限制**：只读WAL数据库缺少辅助文件时，不能保证在OpenCode关闭状态下刷新。此时整个扫描保留旧结果，用户可启动OpenCode后重试或停用该来源。此防护避免了已复现的权限漏读，不是所有数据库/schema/并发场景的完整验收。依据：[SQLite只读WAL约束](https://www.sqlite.org/wal.html#read_only_databases)。不把实时变化的源数据库声明为immutable，也不修改源数据库日志模式。

## 设计与隔离

主应用通过NSOpenPanel取得具体目录的只读授权并保存bookmark；执行扫描前恢复授权，在helper退出后释放。授权目录映射到应用容器内的稳定路径，Rust parser和计数公式不改。不同授权revision使用不同映射命名空间，避免换目录后复用错误缓存。

私有快照与授权revision写在同一个原子文件中；目录变更或启动时发现revision不匹配，会使旧展示/组件数据失效。授权被撤销不删除源日志，旧派生缓存可能留在应用容器，隐私草稿如实说明。

当前沙盒验证界面仅接入三类来源，Codex会话/归档和Claude项目/转录可分别授权。其他客户端不应在商店描述中宣称支持，除非完成授权映射与核验。普通构建仍保留原来源列表。

| 项目 | 独立验证身份 |
| --- | --- |
| App | local.tokensmacos.storecheck |
| Widget | local.tokensmacos.storecheck.widget |
| App Group | TEAM.tokensmacos.storecheck |
| 深链 | tokly-store-check://today |

这三项与正式0.1.0隔离。脚本会核对Info.plist，防止Xcode配置优先级把测试版误配到旧App Group。

## 构建与检查

```sh
bash scripts/check-collector.sh          # 普通bundled SQLite路径
bash scripts/check-store-collector.sh    # macOS系统SQLite路径
bash scripts/check-directory-access.sh
bash scripts/check-app.sh
bash scripts/check-widget.sh
python3 scripts/check-upstream.py
python3 scripts/third-party-notices.py
bash scripts/build-store-check.sh
```

Store构建依赖已有Config/Local.xcconfig与Apple Development身份。默认输出`.build/ToklyStoreCheck/Build/Products/Release/Tokly.app`；可用`TOKLY_STORE_DERIVED`指定另一个派生目录。它是开发测试包，不是App Store分发Archive。

helper使用app-sandbox与inherit，主应用使用sandbox、user-selected read-only、app-scope bookmarks和network client。系统SQLite构建固定SDK库目录，避免意外链接Homebrew SQLite。商店测试构建固定arm64，因为当前Rust helper未提供Intel版本。

## 上架资料与剩余门槛

用户已确定首版免费，公开支持邮箱为393156845@qq.com。草稿位于[distribution/app-store](../distribution/app-store/)。

- 决定正式版是否接受上述OpenCode关闭状态限制；提交前文案和审核说明必须明确，不能宣称所有状态均可后台读取。
- macOS14实际运行验证；目前实测机器为macOS26。
- 确认付费Apple Developer Program资格，注册正式App Store记录、分发签名/配置与Archive验证。会员状态尚未收到确认；不得自动购买或接受协议。
- 发布并复核公开支持/隐私页面，接入应用内链接。当前只有草稿，不存在已确认的公开URL。
- 完成App Privacy、出口合规、年龄分级、版权主体和卖方信息；隐私清单不代替这些表单。
- 最终截图、审核用合成样例与商店文案核对。不得上传真实用户日志作为截图或样例。
- 复核第三方许可及Rust运行库通知。生成的147个Cargo依赖许可文本已收集，不能据此宣称所有工具链/分发事项已自动审核完成。

具体隐私API说明见[privacy-api-audit.md](../distribution/app-store/privacy-api-audit.md)。本阶段不保证Apple审核结果，也不修改或重新发布已冻结的0.1.0标签。
